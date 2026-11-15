import Combine
import Foundation

// Playing along with a watch party, as the web app does (lib/party/playback.ts, follow.ts): each
// member's own server finds the party's title and plays its own version of it; commands run at
// the moment they name, on the relay's clock, and a drift is taken up by a seek. The player's own
// controls ask the group instead of acting.

/// Keeps one player on the party's timeline while it plays the party's title.
@MainActor
final class PartyFollower {
    private weak var model: PlayerModel?
    let playlistItemId: String
    private let party = WatchParty.shared
    private var bag = Set<AnyCancellable>()
    private var ticker: Task<Void, Never>?
    private var scheduled: [Task<Void, Never>] = []
    private var bufferTask: Task<Void, Never>?

    private var lastSeekAt = -Double.infinity
    private var settleUntil: Double = 0
    private var seekStartedAt: Double?
    /// How long a seek takes to land, learnt from the last few, so a seek aims ahead of the group.
    private var seekLead: Double = 250
    private var reported = "none"
    private var awaitingReady = true
    private var pauseAt: Double?
    private var lastResume: Double = 0
    private var wasWaiting = true
    private var stopped = false

    private static func now() -> Double { RelayClock.monotonic() }

    init(model: PlayerModel, playlistItemId: String) {
        self.model = model
        self.playlistItemId = playlistItemId
        party.events.sink { [weak self] event in
            if case .command(let command) = event { self?.onCommand(command) }
        }.store(in: &bag)
        model.$waiting.dropFirst().sink { [weak self] waiting in self?.onWaiting(waiting) }.store(in: &bag)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    private var timeline: WatchParty.Timeline? {
        party.timeline?.playlistItemId == playlistItemId ? party.timeline : nil
    }

    private func position() -> Double { (model?.position ?? 0) * 1000 }

    private func expected(_ timeline: WatchParty.Timeline) -> Double { timeline.position(at: party.clock.now()) }

    private func setPaused(_ paused: Bool) {
        guard let model, model.paused != paused else { return }
        if paused { model.engine.pause() } else { model.engine.play() }
    }

    private func seekTo(_ positionMs: Double) {
        let now = Self.now()
        model?.followSeek(max(positionMs, 0) / 1000)
        settleUntil = now + 1500
        lastSeekAt = now
        seekStartedAt = now
    }

    private func seekIfOff(_ positionMs: Double) {
        if abs(position() - positionMs) > 250 { seekTo(positionMs) }
    }

    private func after(_ ms: Double, _ run: @escaping () -> Void) {
        scheduled.append(Task { [weak self] in
            if ms > 0 { try? await Task.sleep(for: .milliseconds(Int(ms))) }
            guard !Task.isCancelled, self?.stopped == false else { return }
            run()
        })
    }

    private func clearScheduled() {
        for task in scheduled { task.cancel() }
        scheduled = []
        pauseAt = nil
    }

    /// Tells the group this member is buffering, or ready to play.
    private func send(_ type: String) {
        let when = party.clock.now()
        let positionMs = position()
        let paused = model?.paused ?? true
        party.request([
            "type": type, "when": when, "positionMs": positionMs,
            "isPlaying": type == "Buffer" || !paused, "playlistItemId": playlistItemId,
        ])
        if type == "Ready", reported == "buffer", !paused, timeline?.playing == true {
            party.playOn(playlistItemId, positionMs: positionMs, when: when)
        }
        reported = type == "Buffer" ? "buffer" : "ready"
    }

    private func onCommand(_ command: WatchParty.Command) {
        guard command.playlistItemId == playlistItemId else { return }
        clearScheduled()
        let delay = command.when - party.clock.now()
        switch command.command {
        case "Unpause":
            if delay > 0 {
                seekIfOff(command.positionMs)
                after(delay) { [weak self] in self?.setPaused(false) }
            } else {
                let late = command.positionMs - delay
                if abs(position() - late) > 250 { seekTo(late + seekLead) }
                setPaused(false)
            }
        case "Pause":
            after(delay) { [weak self] in self?.pause(on: command.positionMs) }
        case "Seek":
            setPaused(true)
            seekTo(command.positionMs)
            awaitingReady = true
        default:
            setPaused(true)
        }
    }

    /// A member just behind plays on to where the group paused, rather than jumping.
    private func pause(on positionMs: Double) {
        let behind = positionMs - position()
        if model?.paused == false, behind > 250, behind < 3000 {
            pauseAt = positionMs
            after(behind + 1000) { [weak self] in self?.pause(on: positionMs) }
            return
        }
        pauseAt = nil
        setPaused(true)
        seekIfOff(positionMs)
    }

    private func onWaiting(_ waiting: Bool) {
        let now = Self.now()
        defer { wasWaiting = waiting }
        if let started = seekStartedAt, wasWaiting, !waiting {
            let took = now - started
            if took < 3000 { seekLead = (seekLead * 0.7 + took * 0.3).rounded() }
            seekStartedAt = nil
        }
        // A short stall costs only this member, who catches up after it; a longer one holds the group.
        if waiting, !wasWaiting, timeline?.playing == true {
            bufferTask?.cancel()
            bufferTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, !self.stopped, self.model?.waiting == true,
                      self.timeline?.playing == true else { return }
                self.send("Buffer")
            }
            return
        }
        if !waiting, wasWaiting {
            bufferTask?.cancel()
            if reported == "buffer" { send("Ready") }
        }
    }

    private func tick() {
        guard let model, !stopped, model.started || !model.waiting else { return }
        guard party.live else { return }
        let now = Self.now()
        // Some seeks finish inside what's buffered, without the player ever waiting.
        if awaitingReady && !model.waiting && now - lastSeekAt > 300 {
            awaitingReady = false
            party.request(["type": "IgnoreWait", "ignoreWait": false])
            send("Ready")
        }
        guard let timeline else { return }
        if !model.paused && now - lastResume >= 5000 {
            lastResume = now
            party.resume(at: position())
        }
        if let pauseAt {
            if position() >= pauseAt - 50 { pause(on: pauseAt) }
            return
        }
        guard timeline.playing, !model.paused, !model.waiting, now >= settleUntil else { return }
        let expected = expected(timeline)
        let drift = position() - expected
        party.offset(behind: -drift)
        // Without changes of speed, which would stretch passed-through sound, a drift is taken up by a seek.
        if abs(drift) > 1000 && now - lastSeekAt > 2000 { seekTo(expected + seekLead) }
    }

    func stop() {
        stopped = true
        clearScheduled()
        bufferTask?.cancel()
        ticker?.cancel()
        bag.removeAll()
    }
}

/// Opens what the party plays on this Apple TV, and closes it when the party stops: the party's
/// title found on this member's own server, in the version closest to the starter's.
@MainActor
final class PartyFollow: ObservableObject {
    static let shared = PartyFollow()

    /// A player to open for the party, which the app's play flow takes.
    @Published var open: PlayRequest?
    /// The party's title this player plays, which closes when the party stops it.
    @Published private(set) var bound: String?
    /// Titles left the player for: they aren't opened again until "Back to the party".
    @Published private(set) var away: Set<String> = []
    /// Why the last title couldn't be followed.
    @Published private(set) var problem: String?

    private var session: Session?
    private var opening: String?
    private var lastSource: MediaSource?
    private var bag = Set<AnyCancellable>()
    private let party = WatchParty.shared

    func attach(_ session: Session) {
        self.session = session
        guard bag.isEmpty else { return }
        party.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.follow() } }
            .store(in: &bag)
    }

    /// The player for the party's title closed: this member sits the title out, staying in the party.
    func leftPlayer(_ playlistItemId: String) {
        guard bound == playlistItemId else { return }
        bound = nil
        away.insert(playlistItemId)
        party.request(["type": "IgnoreWait", "ignoreWait": true])
    }

    /// Back to the party's title after leaving its player.
    func backToParty() {
        if let entry = party.playing { away.remove(entry.playlistItemId) }
        Task { await follow() }
    }

    /// Starts a title for everyone, with what follows it here after, in place of playing it here alone.
    func playForParty(_ request: PlayRequest) {
        let items = [PartyItem(request.item, source: request.source)] + request.queue.prefix(19).map { PartyItem($0, source: nil) }
        party.play(items, startMs: request.startMs ?? 0)
    }

    private func sitOut(_ entry: WatchParty.Entry, _ message: String) {
        away.insert(entry.playlistItemId)
        problem = message
        party.request(["type": "IgnoreWait", "ignoreWait": true])
    }

    private func follow() async {
        guard party.status != nil else {
            bound = nil
            away = []
            return
        }
        guard party.live, let entry = party.playing else {
            // The party stopped: its player closes.
            if party.status == .live, bound != nil { bound = nil }
            return
        }
        guard bound != entry.playlistItemId, !away.contains(entry.playlistItemId), opening != entry.playlistItemId,
              let client = session?.client, let userId = session?.userId else { return }
        guard let item = entry.item else {
            return sitOut(entry, L("This device couldn't read what the party is playing."))
        }
        opening = entry.playlistItemId
        defer { if opening == entry.playlistItemId { opening = nil } }
        guard let local = await find(item, client: client, userId: userId) else {
            return sitOut(entry, L("%@ isn't on your server.", item.title))
        }
        guard let info = try? await client.playbackInfo(userId: userId, itemId: local.id) else {
            return sitOut(entry, L("Couldn't open %@.", item.title))
        }
        let sources = (info.mediaSources ?? []).filter { $0.aiostreams?.ytId == nil }
        let previous = lastSource?.aiostreams?.bingeGroup
        guard var source = item.matching(sources, fallback: { list in
            previous.flatMap { group in list.first { $0.aiostreams?.bingeGroup == group } }
        }) else {
            return sitOut(entry, L("No version of %@ plays here.", item.title))
        }
        // The party moved on meanwhile.
        guard party.playing?.playlistItemId == entry.playlistItemId else { return }
        // Named again, the version brings its subtitles from the configuration's subtitle addons.
        var playSession = info.playSessionId
        if let named = try? await client.playbackInfo(userId: userId, itemId: local.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) {
            source = match
            playSession = named.playSessionId ?? playSession
        }
        let startMs = party.timeline.map { $0.position(at: party.clock.now()) } ?? 0
        lastSource = source
        problem = nil
        bound = entry.playlistItemId
        open = PlayRequest(item: local, source: source, playSessionId: playSession, startMs: startMs,
                           partyEntry: entry.playlistItemId)
    }

    /// The title on this member's server: by its id, else by its name.
    private func find(_ item: PartyItem, client: JellyfinClient, userId: String) async -> Item? {
        for id in [item.id, item.sharedId].compactMap({ $0 }) {
            let found: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": id, "Fields": "Overview"])
            if let first = found?.items?.first { return first }
        }
        let episode = item.type == "Episode"
        guard let name = episode ? item.seriesName : item.name else { return nil }
        let results: ItemsResult? = try? await client.get("/Items", [
            "userId": userId, "SearchTerm": name, "Recursive": "true", "IncludeItemTypes": episode ? "Series" : "Movie", "Limit": "10",
        ])
        let same = { (other: String?) in other?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let found = results?.items?.first(where: {
            same($0.name) && (episode || item.year == nil || $0.productionYear == nil || $0.productionYear == item.year)
        }) else { return nil }
        guard episode else { return found }
        let episodes: ItemsResult? = try? await client.get("/Shows/\(found.id)/Episodes", ["userId": userId])
        return episodes?.items?.first { $0.parentIndexNumber == item.season && $0.indexNumber == item.episode }
    }
}
