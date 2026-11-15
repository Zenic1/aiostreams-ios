import SwiftUI

/// Watch together: start a party others join with its code, join one, and while in one, who's in
/// it, what it plays, its chat and reactions (features/party in the web app).
struct PartyView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var party = WatchParty.shared
    @ObservedObject private var follow = PartyFollow.shared
    @State private var relays: [(base: String, own: Bool)] = []
    @State private var working = false
    @State private var error: String?
    @State private var joining = false
    @State private var code = ""
    @State private var writing = false
    @State private var message = ""

    static let reactions = ["👍", "😂", "😮", "😢", "❤️", "🎉"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(24)) {
                PageTitle(text: L("Watch together"))
                if party.status == nil { outside } else { inside }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .task { await loadRelays() }
        .alert(L("Join a party"), isPresented: $joining) {
            TextField(L("Party code"), text: $code)
            Button(L("Join")) { Task { await join() } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The code the party's host sees, like ABCDE-12345."))
        }
        .alert(L("Send a message"), isPresented: $writing) {
            TextField(L("Message"), text: $message)
            Button(L("Send")) {
                party.say(message)
                message = ""
            }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    // MARK: Not in a party

    @ViewBuilder private var outside: some View {
        VStack(alignment: .leading, spacing: Theme.px(14)) {
            Text(L("Watch with friends, each on their own device: what one plays, pauses or skips to, everyone does."))
                .font(Theme.font(Theme.base))
                .foregroundStyle(Theme.gray400)
            if let ended = party.ended { Text(ended).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300) }
            ErrorText(text: error)
            HStack(spacing: Theme.px(8)) {
                if let relay = relays.first {
                    Button { Task { await start(relay.base) } } label: { Label(L("Start a party"), systemImage: "person.2.fill") }
                        .buttonStyle(SoftPillStyle(selected: true))
                }
                Button { code = ""; joining = true } label: { Label(L("Join a party"), systemImage: "arrow.right.circle") }
                    .buttonStyle(SoftPillStyle())
                if working { ProgressView() }
            }
            .disabled(working)
            .focusSection()
            if let relay = relays.first {
                Text(relay.own ? L("Parties run on your server.") : L("Parties run on %@.", WatchParty.host(relay.base)))
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray500)
            }
        }
        .pagePadding()
    }

    // MARK: In a party

    @ViewBuilder private var inside: some View {
        VStack(alignment: .leading, spacing: Theme.px(20)) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.px(16)) {
                if let code = party.code {
                    Text(PartyCode.formatted(code))
                        .font(.system(size: Theme.px(40), weight: .bold, design: .monospaced))
                }
                Text(statusText).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
            }
            Text(L("Others join with this code in Watch together, on %@.", WatchParty.host(party.relay ?? "")))
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)

            if let entry = party.playing {
                VStack(alignment: .leading, spacing: Theme.px(6)) {
                    Text(L("Playing")).font(Theme.font(Theme.xs, .medium)).foregroundStyle(Theme.gray400)
                    Text(entry.item?.title ?? L("something this device cannot read")).font(Theme.font(Theme.lg, .semibold))
                    if follow.away.contains(entry.playlistItemId) {
                        Button { follow.backToParty() } label: { Label(L("Back to the party"), systemImage: "play.fill") }
                            .buttonStyle(SoftPillStyle(selected: true))
                    }
                }
            } else {
                Text(L("Nothing's playing. Play a title and it starts for everyone."))
                    .font(Theme.font(Theme.base))
                    .foregroundStyle(Theme.gray400)
            }
            if let problem = follow.problem { Text(problem).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300) }

            HStack(alignment: .top, spacing: Theme.px(40)) {
                VStack(alignment: .leading, spacing: Theme.px(8)) {
                    Text(L("In the party")).font(Theme.font(Theme.lg, .semibold))
                    ForEach(party.members) { member in
                        HStack(spacing: Theme.px(8)) {
                            Image(systemName: member.host ? "crown.fill" : "person.fill")
                                .foregroundStyle(member.host ? Color.yellow : Theme.gray400)
                            Text(member.you ? L("%@ (you)", member.name) : member.name)
                            if member.away { Text(L("away")).foregroundStyle(Theme.gray500) }
                            if member.buffering { Text(L("loading")).foregroundStyle(Theme.gray500) }
                            if let offset = member.offsetMs, offset > 0 {
                                Text(L("%@ s behind", String(format: "%.1f", offset / 1000))).foregroundStyle(Theme.gray500)
                            }
                        }
                        .font(Theme.font(Theme.base))
                    }
                }
                .frame(width: Theme.px(320), alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.px(8)) {
                    Text(L("Chat")).font(Theme.font(Theme.lg, .semibold))
                    ForEach(party.chat.suffix(12)) { line in
                        (Text(line.you ? L("You") : line.name).bold() + Text(": " + line.text))
                            .font(Theme.font(Theme.base))
                            .lineLimit(2)
                    }
                    if party.chat.isEmpty {
                        Text(L("No messages yet.")).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray500)
                    }
                }
            }
            .focusable()

            HStack(spacing: Theme.px(8)) {
                Button { writing = true } label: { Label(L("Send a message"), systemImage: "bubble.left") }
                    .buttonStyle(SoftPillStyle())
                ForEach(Self.reactions, id: \.self) { emoji in
                    Button(emoji) { party.react(emoji) }.buttonStyle(SoftPillStyle())
                }
                Button { party.leave() } label: { Label(L("Leave the party"), systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(SoftPillStyle())
            }
            .focusSection()
        }
        .pagePadding()
    }

    private var statusText: String {
        switch party.status {
        case .joining: return L("Joining…")
        case .reconnecting: return L("Reconnecting…")
        default: return party.isHost ? L("You're the host") : ""
        }
    }

    // MARK: Starting and joining

    private var identity: PartyIdentity? {
        guard let client = session.client else { return nil }
        return PartyIdentity(name: session.userName ?? L("Someone"),
                             server: relayBase(client.base.absoluteString) ?? client.base.absoluteString,
                             token: client.token)
    }

    /// The relays a party can start on: this server's, then the one it suggests (lib/party/actions.ts).
    private func loadRelays() async {
        guard let client = session.client else { return }
        let info: PublicSystemInfo? = try? await client.get("/System/Info/Public")
        var list: [(String, Bool)] = []
        let own = relayBase(client.base.absoluteString)
        if let own, (info?.aiostreams?.features?["parties"] ?? 0) > 0 { list.append((own, true)) }
        // A server with no party info gets the public relay; one that sends none means none.
        let parties = info?.aiostreams?.parties
        let fallback = parties == nil ? "https://aiostreams.viren070.me" : parties?.defaultRelay
        if let suggested = fallback.flatMap(relayBase), suggested != own { list.append((suggested, false)) }
        relays = list.map { (base: $0.0, own: $0.1) }
    }

    private func start(_ relay: String) async {
        guard let identity else { return }
        working = true
        error = nil
        defer { working = false }
        do { try await party.start(relay: relay, identity: identity) } catch { self.error = error.localizedDescription }
    }

    private func join() async {
        guard let identity else { return }
        guard let normal = PartyCode.normal(code) else {
            error = L("That isn't a party code.")
            return
        }
        // The party's relay: this server's when it has one, else the one it suggests.
        guard let relay = relays.first?.base else { return }
        working = true
        error = nil
        defer { working = false }
        do { try await party.join(relay: relay, code: normal, identity: identity) } catch { self.error = error.localizedDescription }
    }
}

/// What other members do, and reactions, said briefly over the page or the video.
struct PartyToasts: View {
    @State private var shown: String?
    @State private var hide: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            if let shown {
                Text(shown)
                    .font(Theme.font(Theme.base, .medium))
                    .padding(.horizontal, Theme.px(20))
                    .padding(.vertical, Theme.px(12))
                    .background(Capsule().fill(Color(white: 17 / 255).opacity(0.95)))
                    .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
                    .padding(.top, Theme.px(32))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: shown)
        .onReceive(WatchParty.shared.events) { event in
            switch event {
            case .action(let text), .notice(let text): show(text)
            case .react(let name, let emoji): show(name.isEmpty ? emoji : "\(name) \(emoji)")
            case .command: break
            }
        }
        .onReceive(WatchParty.shared.$chat.dropFirst()) { chat in
            if let last = chat.last, !last.you { show("\(last.name): \(last.text)") }
        }
    }

    private func show(_ text: String) {
        shown = text
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { shown = nil }
        }
    }
}
