import Foundation

// Remote control, as the web app takes it (features/remote/server-events.ts, lib/remote): the
// server's socket tells this Apple TV what other devices send it, so the web app's remote (and any
// Jellyfin app's) can open a title here, play one, pause, seek and change tracks. The app tells the
// server it takes these while the socket is open.

enum RemoteKey {
    case pause, play, toggle, stop, next, previous
    /// To a position, in milliseconds.
    case seek(Double)
    /// By milliseconds, back or forward.
    case skip(Double)
}

enum RemoteCommand {
    case show(itemId: String)
    case play(itemId: String, startMs: Double, sourceId: String?)
    case key(RemoteKey)
    /// A track by the server's stream index; a subtitle below zero turns them off.
    case track(audio: Bool, index: Int)
}

@MainActor
final class ServerEvents {
    static let shared = ServerEvents()

    /// What the player does with a command while it's up; false hands it to the pages.
    var playerHandler: ((RemoteCommand) -> Bool)?
    /// What the pages do with a command: open a title, or play one.
    var pageHandler: ((RemoteCommand) -> Void)?
    /// The skip step for Rewind and FastForward, in seconds.
    var skipStep: Double = 10

    private var client: JellyfinClient?
    private var socket: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var failures = 0
    private static let retries: [Double] = [2, 5, 15, 60]

    private static let capabilities: [String: Any] = [
        "PlayableMediaTypes": ["Video"],
        "SupportedCommands": ["DisplayContent", "SetAudioStreamIndex", "SetSubtitleStreamIndex"],
        "SupportsMediaControl": true,
    ]

    func start(client: JellyfinClient) {
        guard client.token != nil, self.client?.base != client.base || self.client?.token != client.token else { return }
        stop()
        self.client = client
        connect()
    }

    func stop() {
        retry?.cancel()
        keepAlive?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        client = nil
        failures = 0
    }

    private func connect() {
        guard let client, let token = client.token,
              var components = URLComponents(url: client.url("/socket", ["ApiKey": token, "deviceId": client.deviceId]),
                                             resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        Task {
            // The server keeps what a device can do only while its socket is open.
            _ = try? await client.json("POST", "/Sessions/Capabilities/Full", body: Self.capabilities)
        }
        receive(on: socket)
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .success(let message):
                    self.failures = 0
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: socket)
                case .failure:
                    self.reconnect()
                }
            }
        }
    }

    private func reconnect() {
        keepAlive?.cancel()
        socket = nil
        guard client != nil else { return }
        let wait = Self.retries[min(failures, Self.retries.count - 1)]
        failures += 1
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["MessageType"] as? String else { return }
        if type == "ForceKeepAlive" {
            // The server closes a socket that stays quiet for longer than this.
            let seconds = (message["Data"] as? Double) ?? 60
            keepAlive?.cancel()
            keepAlive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(seconds / 2))
                    guard !Task.isCancelled else { return }
                    self?.socket?.send(.string(#"{"MessageType":"KeepAlive"}"#)) { _ in }
                }
            }
            return
        }
        if type == "UserDataChanged" {
            NotificationCenter.default.post(name: .watchStateChanged, object: nil)
            return
        }
        guard let command = command(type, message["Data"] as? [String: Any] ?? [:]) else { return }
        AppLog.info("remote", "\(type) \(command)")
        if playerHandler?(command) == true { return }
        pageHandler?(command)
    }

    /// A Jellyfin id without dashes.
    private static func plain(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let plain = text.replacingOccurrences(of: "-", with: "").lowercased()
        return plain.count == 32 && plain.allSatisfy(\.isHexDigit) ? plain : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double, number == number.rounded() { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private func command(_ type: String, _ data: [String: Any]) -> RemoteCommand? {
        switch type {
        case "Playstate":
            switch data["Command"] as? String {
            case "Pause": return .key(.pause)
            case "Unpause": return .key(.play)
            case "PlayPause": return .key(.toggle)
            case "Stop": return .key(.stop)
            case "NextTrack": return .key(.next)
            case "PreviousTrack": return .key(.previous)
            case "Seek": return Self.integer(data["SeekPositionTicks"]).map { .key(.seek(Double($0) / JellyfinClient.ticksPerMs)) }
            case "Rewind": return .key(.skip(-skipStep * 1000))
            case "FastForward": return .key(.skip(skipStep * 1000))
            default: return nil
            }
        case "Play":
            guard (data["PlayCommand"] as? String ?? "PlayNow") == "PlayNow" else { return nil }
            let ids = data["ItemIds"] as? [Any] ?? []
            let at = Self.integer(data["StartIndex"]) ?? 0
            guard let itemId = Self.plain(at < ids.count ? ids[at] : ids.first) else { return nil }
            let source = Self.plain(data["MediaSourceId"])
            let ticks = Self.integer(data["StartPositionTicks"]) ?? 0
            return .play(itemId: itemId, startMs: Double(ticks) / JellyfinClient.ticksPerMs,
                         sourceId: source == itemId ? nil : source)
        case "GeneralCommand":
            let arguments = data["Arguments"] as? [String: Any] ?? [:]
            switch data["Name"] as? String {
            case "DisplayContent":
                return Self.plain(arguments["ItemId"]).map { .show(itemId: $0) }
            case "SetAudioStreamIndex":
                return Self.integer(arguments["Index"]).map { .track(audio: true, index: $0) }
            case "SetSubtitleStreamIndex":
                return Self.integer(arguments["Index"]).map { .track(audio: false, index: $0) }
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
