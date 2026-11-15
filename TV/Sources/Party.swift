import Combine
import CommonCrypto
import CryptoKit
import Foundation

// Watch parties, as the web app has them (lib/party): watching together through a relay, at
// `<relay>/party/v1`, with what members say sealed with the party's key, which comes from its code,
// so the relay holds neither. The relay keeps the group (Jellyfin's SyncPlay, ported); each member
// plays its own copy and follows the group's commands at the moments they name, on the relay's clock.

// MARK: - Codes and keys

enum PartyCode {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 10

    static func new() -> String {
        String((0..<length).map { _ in alphabet[Int(UInt8.random(in: 0...255) & 31)] })
    }

    /// A code as typed: any case, with dashes or spaces, and O, I and L as the digits they look like.
    static func normal(_ input: String) -> String? {
        let code = input.uppercased()
            .replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "[IL]", with: "1", options: .regularExpression)
        guard code.count == length, code.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return code
    }

    static func formatted(_ code: String) -> String { "\(code.prefix(5))-\(code.dropFirst(5))" }
}

/// A party's id on the relay and its key, both from its code: slow to derive on purpose, as the
/// relay knows the id, and finding the code behind it means trying every one.
struct PartyKeys {
    let id: String
    let key: SymmetricKey

    private static let salt = Array("aiostreams-party-1".utf8)

    static func derive(_ code: String) async -> PartyKeys {
        await Task.detached(priority: .userInitiated) {
            let secret = Array(code.utf8)
            var bits = [UInt8](repeating: 0, count: 48)
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.map { Int8(bitPattern: $0) }, secret.count,
                                     PartyKeys.salt, PartyKeys.salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000,
                                     &bits, bits.count)
            return PartyKeys(id: Base64URL.encode(Data(bits[0..<16])), key: SymmetricKey(data: Data(bits[16...])))
        }.value
    }

    /// A value sealed as the web app seals it: its JSON, in AES-GCM, after a random nonce.
    func seal(json: Data) -> String {
        guard let box = try? AES.GCM.seal(json, using: key, nonce: AES.GCM.Nonce()) else { return "" }
        return Base64URL.encode(Data(box.nonce) + box.ciphertext + box.tag)
    }

    func seal(_ text: String) -> String {
        seal(json: (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)) ?? Data())
    }

    func seal<T: Encodable>(_ value: T) -> String {
        seal(json: (try? JSONEncoder().encode(value)) ?? Data())
    }

    /// What `seal` sealed, as JSON; nil for anything not sealed with this key.
    func unseal(_ sealed: String) -> Data? {
        guard let bytes = Base64URL.decode(sealed), bytes.count > 28,
              let nonce = try? AES.GCM.Nonce(data: bytes.prefix(12)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes.dropFirst(12).dropLast(16), tag: bytes.suffix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    func unsealText(_ sealed: String?) -> String? {
        guard let sealed, let data = unseal(sealed) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
    }

    func unsealItem(_ sealed: String) -> PartyItem? {
        unseal(sealed).flatMap { try? JSONDecoder().decode(PartyItem.self, from: $0) }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}

// MARK: - What a party plays

/// A title as members read it: sealed, so the relay never does (lib/party/items.ts).
struct PartyItem: Codable, Equatable {
    /// The title's id on the starter's server; most ids name the same title on any.
    var id: String
    /// Another id for it every server resolves, where `id` is only the starter's.
    var sharedId: String?
    var type: String
    var name: String
    var year: Int?
    var seriesName: String?
    var season: Int?
    var episode: Int?
    var runtimeMs: Double?
    /// The starter's version, which members play too where they have it.
    var version: Version?

    struct Version: Codable, Equatable {
        var filename: String?
        var size: Int64?
        var releaseGroup: String?
        var resolution: String?
    }

    init(_ item: Item, source: MediaSource?) {
        id = item.id
        sharedId = item.aiostreams?.sharedId
        type = item.type ?? "Movie"
        name = item.name ?? ""
        year = item.productionYear
        seriesName = item.seriesName
        season = item.parentIndexNumber
        episode = item.indexNumber
        runtimeMs = item.runTimeTicks.map { Double($0) / JellyfinClient.ticksPerMs }
        if let found = source?.aiostreams {
            version = Version(filename: found.filename, size: found.size, releaseGroup: found.releaseGroup, resolution: found.resolution)
        }
    }

    var title: String {
        guard type == "Episode", let seriesName else { return name }
        let code = episode.map { e in season.map { String(format: "S%02dE%02d", $0, e) } ?? String(format: "E%02d", e) }
        return [seriesName, code, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The member's own version closest to the starter's.
    func matching(_ sources: [MediaSource], fallback: ([MediaSource]) -> MediaSource?) -> MediaSource? {
        if let filename = version?.filename, let file = sources.first(where: {
            $0.aiostreams?.filename == filename && (version?.size == nil || $0.aiostreams?.size == nil || $0.aiostreams?.size == version?.size)
        }) { return file }
        if let group = version?.releaseGroup, let release = sources.first(where: {
            $0.aiostreams?.releaseGroup == group && $0.aiostreams?.resolution == version?.resolution
        }) { return release }
        return fallback(sources) ?? sources.first
    }
}

/// Who a member is to a party: a name, and the server it's signed in to, whose relay knows it.
struct PartyIdentity {
    var name: String
    var server: String
    var token: String?
}

/// A relay's address: its server, which may sit under a path, without the relay's own path or a
/// media server's after it.
func relayBase(_ input: String) -> String? {
    let text = input.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, let url = URL(string: text.lowercased().hasPrefix("http") ? text : "https://\(text)"),
          let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host else { return nil }
    var path = url.path.replacingOccurrences(of: "/(party|jellyfin)(/.*)?$", with: "", options: [.regularExpression, .caseInsensitive])
    while path.hasSuffix("/") { path.removeLast() }
    return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")\(path)"
}

/// The relay's clock, from ping round trips; of the last few, the quickest trip says the most.
struct RelayClock {
    private var samples: [(offset: Double, rtt: Double)] = []
    private(set) var offset = Date().timeIntervalSince1970 * 1000 - RelayClock.monotonic()
    private(set) var rtt: Double = 0

    static func monotonic() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    var synced: Bool { !samples.isEmpty }

    mutating func add(t0: Double, t1: Double, t2: Double, t3: Double) {
        let trip = t3 - t0 - (t2 - t1)
        guard trip >= 0 else { return }
        samples = Array(samples.suffix(7)) + [((t1 - t0 + (t2 - t3)) / 2, trip)]
        let best = samples.min { $0.rtt < $1.rtt }!
        offset = best.offset
        rtt = best.rtt
    }

    func now() -> Double { Self.monotonic() + offset }

    mutating func reset() {
        samples = []
        offset = Date().timeIntervalSince1970 * 1000 - Self.monotonic()
    }
}

// MARK: - The party

@MainActor
final class WatchParty: ObservableObject {
    static let shared = WatchParty()

    enum Status { case joining, live, reconnecting }

    struct Member: Identifiable, Equatable {
        let id: String
        var name: String
        var host: Bool
        var away: Bool
        var buffering: Bool
        var you: Bool
        var offsetMs: Double?
    }

    struct Message: Identifiable, Equatable {
        let id: String
        let from: String
        let name: String
        let text: String
        let you: Bool
    }

    struct Entry: Equatable {
        let playlistItemId: String
        let item: PartyItem?
        let ref: String
        let runtimeMs: Double
    }

    /// Where the group is: from `positionMs` at `when` (relay clock), moving while playing.
    struct Timeline: Equatable {
        var playlistItemId: String
        var positionMs: Double
        var when: Double
        var playing: Bool

        func position(at now: Double) -> Double {
            playing && now > when ? positionMs + (now - when) : positionMs
        }
    }

    struct Command {
        let playlistItemId: String
        let when: Double
        let positionMs: Double
        /// Unpause, Pause, Seek or Stop.
        let command: String
    }

    enum Event {
        case command(Command)
        case react(name: String, emoji: String)
        /// Another member paused, played, jumped or started something; said with their name.
        case action(String)
        case notice(String)
    }

    @Published private(set) var code: String?
    @Published private(set) var relay: String?
    @Published private(set) var status: Status?
    @Published private(set) var you: String?
    @Published private(set) var members: [Member] = []
    @Published private(set) var chat: [Message] = []
    @Published private(set) var group = "Idle"
    @Published private(set) var queue: [Entry] = []
    @Published private(set) var playingIndex = -1
    @Published private(set) var timeline: Timeline?
    @Published private(set) var controlLocked = false
    /// Why the last party ended, for the page to say.
    @Published private(set) var ended: String?

    let events = PassthroughSubject<Event, Never>()
    private(set) var clock = RelayClock()

    private var keys: PartyKeys?
    private var identity: PartyIdentity?
    private var creating = false
    private var welcomed = false
    private var seat: String?
    private var ticket: String?
    private var hostTicket: String?
    private var resumeState: [String: Any]?
    private var resuming = false
    private var offsetSent: Double?? = .none
    private var socket: URLSessionWebSocketTask?
    private var timers: [Task<Void, Never>] = []
    private var failures = 0
    private var heard: Double = 0
    private var pinged: Double = 0
    private var answerBy: Double?

    var live: Bool { status == .live }
    var isHost: Bool { members.first { $0.you }?.host == true }

    /// What the party plays now; nothing once it stopped.
    var playing: Entry? { timeline == nil ? nil : (queue.indices.contains(playingIndex) ? queue[playingIndex] : nil) }

    // MARK: Starting, joining, leaving

    func start(relay: String, identity: PartyIdentity) async throws {
        try await enter(relay: relay, code: PartyCode.new(), identity: identity, creating: true)
    }

    func join(relay: String, code: String, identity: PartyIdentity) async throws {
        try await enter(relay: relay, code: code, identity: identity, creating: false)
    }

    private func enter(relay: String, code: String, identity: PartyIdentity, creating: Bool) async throws {
        if status != nil { leave() }
        let keys = await PartyKeys.derive(code)
        reset()
        self.keys = keys
        self.identity = identity
        self.creating = creating
        self.code = code
        self.relay = relay
        status = .joining
        ended = nil
        connect()
        // Until the relay lets this member in, or turns it away, or 15 seconds pass.
        let deadline = Date().addingTimeInterval(15)
        while status == .joining || (status == .reconnecting && !welcomed) {
            if Date() > deadline { end(L("%@ didn't answer.", Self.host(relay))) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if status == nil { throw PartyError(message: ended ?? L("The party ended.")) }
    }

    func leave() {
        guard status != nil else { return }
        send(["t": "leave"])
        end(L("You left the party."))
    }

    private func reset() {
        welcomed = false
        seat = nil
        ticket = nil
        hostTicket = nil
        resumeState = nil
        resuming = false
        offsetSent = .none
        failures = 0
        you = nil
        members = []
        chat = []
        group = "Idle"
        queue = []
        playingIndex = -1
        timeline = nil
        controlLocked = false
        clock.reset()
    }

    private func end(_ reason: String) {
        guard status != nil else { return }
        stopSocket()
        status = nil
        ended = reason
        timeline = nil
    }

    struct PartyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func host(_ relay: String) -> String { URL(string: relay)?.host ?? relay }

    // MARK: Asking the group

    func request(_ request: [String: Any]) { send(["t": "request", "request": request]) }

    /// Starts titles for everyone: the first, with what follows it here after.
    func play(_ items: [PartyItem], startMs: Double) {
        guard let keys else { return }
        let entries: [[String: Any]] = items.prefix(20).map { ["ref": keys.seal($0), "runtimeMs": $0.runtimeMs ?? 0] }
        request(["type": "Play", "items": entries, "index": 0, "startMs": startMs])
    }

    func say(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard live, !trimmed.isEmpty, let keys else { return }
        send(["t": "chat", "text": keys.seal(trimmed)], answered: true)
    }

    func react(_ emoji: String) {
        guard live, let keys else { return }
        send(["t": "react", "emoji": keys.seal(emoji)])
        events.send(.react(name: members.first { $0.you }?.name ?? "", emoji: emoji))
    }

    /// How far behind the party this member plays, which the relay hears as it changes.
    func offset(behind ms: Double) {
        guard clock.synced else { return }
        let offset: Double? = abs(ms) < 1000 ? nil : (ms / 500).rounded() * 500
        if case .some(let sent) = offsetSent, sent == offset { return }
        offsetSent = .some(offset)
        var message: [String: Any] = ["t": "offset"]
        if let offset { message["offsetMs"] = offset }
        send(message)
    }

    /// Where the party plays, which brings it back after the relay restarts.
    func resume(at positionMs: Double) {
        guard !queue.isEmpty, let timeline else { return }
        resumeState = [
            "items": queue.map { ["ref": $0.ref, "runtimeMs": $0.runtimeMs] },
            "index": max(playingIndex, 0),
            "positionMs": positionMs,
            "playing": timeline.playing,
        ]
    }

    /// A member the group waited for plays on from where it is; the group resumes as it gets there.
    func playOn(_ playlistItemId: String, positionMs: Double, when: Double) {
        timeline = Timeline(playlistItemId: playlistItemId, positionMs: positionMs, when: when, playing: true)
    }

    // MARK: The relay

    private func connect() {
        guard let relay, var components = URLComponents(string: "\(relay)/party/v1") else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        failures = 0
        heard = RelayClock.monotonic()
        clock.reset()
        send(hello())
        for wait in [0.0, 1, 2] {
            timers.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                if !Task.isCancelled { self?.ping() }
            })
        }
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.check()
            }
        })
        receive(on: socket)
    }

    private func stopSocket() {
        for timer in timers { timer.cancel() }
        timers = []
        answerBy = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.received(text) }
                    self.receive(on: socket)
                case .failure:
                    self.closed()
                }
            }
        }
    }

    private func closed() {
        stopSocket()
        guard status != nil else { return }
        guard welcomed else { return end(L("Couldn't reach %@.", Self.host(relay ?? ""))) }
        status = .reconnecting
        let wait = [1.0, 2, 5, 10, 20][min(failures, 4)]
        failures += 1
        timers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { self?.connect() }
        })
    }

    private func send(_ message: [String: Any], answered: Bool = false) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
        if answered && answerBy == nil { answerBy = RelayClock.monotonic() + 8000 }
    }

    private func ping() {
        pinged = RelayClock.monotonic()
        var message: [String: Any] = ["t": "ping", "t0": pinged]
        if clock.synced { message["rtt"] = clock.rtt }
        send(message, answered: true)
    }

    /// A network that drops silently never closes the socket, so a quiet one is asked.
    private func check() {
        let now = RelayClock.monotonic()
        if let answerBy, now > answerBy { return closed() }
        if now - pinged >= 60_000 || now - heard >= 30_000 { ping() }
    }

    private var token: String? {
        guard let identity, let relay else { return nil }
        return identity.server == relay || identity.server.hasPrefix(relay + "/") ? identity.token : nil
    }

    private func hello() -> [String: Any] {
        guard let keys, let identity else { return [:] }
        var base: [String: Any] = ["v": 1, "party": keys.id, "name": keys.seal(identity.name)]
        if let token { base["token"] = token }
        if creating && !welcomed {
            base["t"] = "create"
            if token != nil, let code { base["code"] = code }
            return base
        }
        if resuming, let ticket, let resumeState {
            base["t"] = "resume"
            base["ticket"] = ticket
            base["state"] = resumeState
            if let hostTicket { base["host"] = ["ticket": hostTicket, "lock": ["control": controlLocked, "joins": false]] }
            return base
        }
        base["t"] = "join"
        if let seat { base["seat"] = seat }
        return base
    }

    private func received(_ text: String) {
        heard = RelayClock.monotonic()
        answerBy = nil
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["t"] as? String else { return }
        switch type {
        case "pong":
            if let t0 = message["t0"] as? Double, let t1 = message["t1"] as? Double, let t2 = message["t2"] as? Double {
                clock.add(t0: t0, t1: t1, t2: t2, t3: RelayClock.monotonic())
            }
        case "welcome":
            welcomed = true
            resuming = false
            offsetSent = .none
            seat = message["seat"] as? String
            ticket = message["ticket"] as? String
            hostTicket = message["host"] as? String
            you = message["you"] as? String
            members = readMembers(message["members"])
            chat = ((message["chat"] as? [[String: Any]]) ?? []).compactMap(readChat)
            group = message["state"] as? String ?? "Idle"
            controlLocked = ((message["lock"] as? [String: Any])?["control"] as? Bool) ?? false
            status = .live
        case "members":
            let before = members
            members = readMembers(message["members"])
            if let joined = message["joined"] as? String, let member = members.first(where: { $0.id == joined && !$0.you }) {
                events.send(.action(L("%@ joined", member.name)))
            }
            if let left = message["left"] as? String, let member = before.first(where: { $0.id == left }) {
                events.send(.action(L("%@ left", member.name)))
            }
        case "status":
            for change in (message["members"] as? [[String: Any]]) ?? [] {
                guard let id = change["id"] as? String, let at = members.firstIndex(where: { $0.id == id }) else { continue }
                members[at].host = change["host"] as? Bool ?? members[at].host
                members[at].away = change["away"] as? Bool ?? members[at].away
                members[at].buffering = change["buffering"] as? Bool ?? members[at].buffering
                members[at].offsetMs = change["offsetMs"] as? Double
            }
        case "queue":
            if let snapshot = message["queue"] as? [String: Any] { readQueue(snapshot) }
            resume(at: timeline?.positionMs ?? 0)
            action(by: message["by"] as? String, reason: (message["queue"] as? [String: Any])?["reason"] as? String)
        case "state":
            group = message["state"] as? String ?? group
            action(by: message["by"] as? String, reason: message["reason"] as? String)
        case "command":
            guard let command = message["command"] as? [String: Any], let id = command["playlistItemId"] as? String,
                  let kind = command["command"] as? String else { return }
            offsetSent = .none
            let when = (command["when"] as? Double) ?? clock.now()
            let positionMs = (command["positionMs"] as? Double) ?? 0
            if kind == "Stop" {
                timeline = nil
                group = "Idle"
            } else {
                timeline = Timeline(playlistItemId: id, positionMs: positionMs, when: when, playing: kind == "Unpause")
            }
            events.send(.command(Command(playlistItemId: id, when: when, positionMs: positionMs, command: kind)))
        case "chat":
            if let chatMessage = (message["message"] as? [String: Any]).flatMap(readChat) {
                chat = Array((chat + [chatMessage]).suffix(100))
            }
        case "react":
            if let emoji = keys?.unsealText(message["emoji"] as? String) {
                let name = members.first { $0.id == message["from"] as? String }?.name ?? L("Someone")
                events.send(.react(name: name, emoji: emoji))
            }
        case "lock":
            controlLocked = ((message["lock"] as? [String: Any])?["control"] as? Bool) ?? false
        case "host":
            hostTicket = message["ticket"] as? String
        case "error":
            refused(message["code"] as? String ?? "")
        case "closed":
            end(Self.ending(message["reason"] as? String ?? "ended"))
        default:
            break
        }
    }

    private func readMembers(_ value: Any?) -> [Member] {
        ((value as? [[String: Any]]) ?? []).compactMap { member in
            guard let id = member["id"] as? String else { return nil }
            return Member(id: id, name: keys?.unsealText(member["name"] as? String) ?? L("Someone"),
                          host: member["host"] as? Bool ?? false, away: member["away"] as? Bool ?? false,
                          buffering: member["buffering"] as? Bool ?? false, you: id == you,
                          offsetMs: member["offsetMs"] as? Double)
        }
    }

    private func readChat(_ value: [String: Any]) -> Message? {
        guard let from = value["from"] as? String, let at = value["at"] as? Double else { return nil }
        return Message(id: "\(from):\(at)", from: from, name: members.first { $0.id == from }?.name ?? L("Someone"),
                       text: keys?.unsealText(value["text"] as? String) ?? "", you: from == you)
    }

    private func readQueue(_ snapshot: [String: Any]) {
        let entries: [Entry] = ((snapshot["playlist"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let id = entry["playlistItemId"] as? String, let ref = entry["ref"] as? String else { return nil }
            return Entry(playlistItemId: id, item: keys?.unsealItem(ref), ref: ref, runtimeMs: entry["runtimeMs"] as? Double ?? 0)
        }
        let index = snapshot["playingIndex"] as? Int ?? -1
        let isPlaying = snapshot["isPlaying"] as? Bool ?? false
        let reason = snapshot["reason"] as? String ?? ""
        queue = entries
        playingIndex = index
        // A new title waits for everyone to load it.
        if entries.indices.contains(index), reason != "Queue", reason != "QueueNext", !isPlaying { group = "Waiting" }
        timeline = entries.indices.contains(index)
            ? Timeline(playlistItemId: entries[index].playlistItemId, positionMs: snapshot["startPositionMs"] as? Double ?? 0,
                       when: clock.now(), playing: isPlaying)
            : nil
    }

    /// What others see a member's request do, said with their name.
    private func action(by member: String?, reason: String?) {
        guard let member, member != you, let reason else { return }
        let name = members.first { $0.id == member }?.name ?? L("Someone")
        switch reason {
        case "Pause": events.send(.action(L("%@ paused", name)))
        case "Unpause": events.send(.action(L("%@ resumed", name)))
        case "Seek":
            if let timeline { events.send(.action(L("%@ jumped to %@", name, Self.clock(timeline.positionMs)))) }
        case "NewPlaylist", "SetCurrentItem", "PreviousItem":
            if let playing { events.send(.action(L("%@ started %@", name, playing.item?.title ?? L("something this device cannot read")))) }
        default:
            break
        }
    }

    private func refused(_ code: String) {
        // A rejoin after the relay restarted brings the party back from its ticket.
        if code == "not-found" && !resuming && ticket != nil && resumeState != nil {
            resuming = true
            send(hello())
            return
        }
        if code == "not-found" && !welcomed { return end(L("No party has that code on %@.", Self.host(relay ?? ""))) }
        if welcomed && ["control", "rate", "invalid"].contains(code) { return events.send(.notice(Self.refusal(code))) }
        end(Self.refusal(code))
    }

    static func refusal(_ code: String) -> String {
        switch code {
        case "version": return L("That relay runs a different version of watch parties.")
        case "invalid": return L("The relay could not read that.")
        case "not-found": return L("That party has ended.")
        case "exists": return L("Try starting the party again.")
        case "full": return L("That party is full.")
        case "locked": return L("That party is not letting anyone new in.")
        case "denied": return L("That relay doesn't let you in.")
        case "busy": return L("That relay is too busy for another party.")
        case "rate": return L("Too many tries. Wait a moment and try again.")
        default: return L("Only the host controls playback.")
        }
    }

    private static func ending(_ reason: String) -> String {
        switch reason {
        case "removed": return L("The host removed you from the party.")
        case "idle": return L("The party ended after a long time with nothing playing.")
        case "left": return L("You left the party.")
        default: return L("The party ended.")
        }
    }

    static func clock(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
