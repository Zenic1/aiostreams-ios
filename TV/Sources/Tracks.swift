import AetherEngineFeatures
import Foundation

// Which audio and subtitles a title starts with, as the web app picks them (lib/playback/audio-tracks.ts,
// lib/subtitles/tracks.ts, lib/playback/show-tracks.ts): the account's languages, its ranking of
// track types (AudioTypes, SubtitleTypes in the user's configuration), and what was last picked for
// the show, kept where the web app keeps it, so a pick on one device carries to the others.

/// The kinds of audio track the user ranks.
enum AudioKind: String, CaseIterable {
    case main, description, commentary

    init(title: String?, visualImpaired: Bool = false) {
        let title = title ?? ""
        if visualImpaired || title.range(of: #"\b(audio description|descriptive audio|described video)\b"#,
                                         options: [.regularExpression, .caseInsensitive]) != nil {
            self = .description
        } else if title.range(of: #"\bcommentary\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            self = .commentary
        } else {
            self = .main
        }
    }

    var label: String {
        switch self {
        case .main: return L("Main")
        case .description: return L("Audio description, narrating what is on screen")
        case .commentary: return L("Commentary")
        }
    }
}

/// The kinds of subtitle the user ranks; a commentary track always comes last.
enum SubtitleKind: String, CaseIterable {
    case normal, sdh, forced, signs

    /// nil for commentary. Signs before forced, as files often flag a signs and songs track forced.
    static func of(title: String?, forced: Bool, hearingImpaired: Bool) -> SubtitleKind? {
        let title = (title ?? "").lowercased()
        func has(_ pattern: String) -> Bool { title.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\bcommentary\b"#) { return nil }
        if has(#"\b(signs?|songs?)\b"#) { return .signs }
        if forced || has(#"\bforced\b"#) { return .forced }
        if hearingImpaired || has(#"\b(sdh|cc|hearing[ -]impaired)\b"#) { return .sdh }
        return .normal
    }

    var label: String {
        switch self {
        case .normal: return L("Full")
        case .sdh: return L("SDH, with sounds described")
        case .forced: return L("Forced, for foreign parts only")
        case .signs: return L("Signs and songs")
        }
    }
}

/// Language codes as one spelling: ISO 639-2/T, from a two-letter code or a bibliographic one
/// (Jellyfin's `ger`, `fre`), so `en`, `eng`, `de` and `ger` compare as they should.
enum LanguageCodes {
    private static let bibliographic = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
        "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
        "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    static func normal(_ code: String?) -> String? {
        guard let raw = code?.lowercased().split(separator: "-").first.map(String.init), !raw.isEmpty,
              !["und", "mul", "zxx", "mis"].contains(raw) else { return nil }
        if raw.count == 2 { return Locale.LanguageCode(raw).identifier(.alpha3) ?? raw }
        return bibliographic[raw] ?? raw
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a = normal(a), let b = normal(b) else { return false }
        return a == b
    }

    /// The first of `languages` any of `items` is in, and those items.
    static func first<T>(_ languages: [String], in items: [T], language: (T) -> String?) -> [T]? {
        for wanted in languages {
            let found = items.filter { same(language($0), wanted) }
            if !found.isEmpty { return found }
        }
        return nil
    }
}

/// What the player starts with, from the account's settings and the show's pick.
struct TrackRules {
    var audioLanguages: [String] = []
    var subtitleLanguages: [String] = []
    /// Jellyfin's SubtitleMode: Default, Always, Smart, OnlyForced or None.
    var subtitleMode = "Default"
    var audioTypes: [AudioKind] = AudioKind.allCases
    var subtitleTypes: [SubtitleKind] = SubtitleKind.allCases
    var playDefaultAudio = true

    /// The audio stream to start with, where the version has several: the first of the user's
    /// languages it has, then the best-ranked type in that language. nil leaves it to the engine.
    func audioStream(in streams: [MediaStream]) -> MediaStream? {
        let tracks = streams.filter { $0.type == "Audio" && $0.index != nil }
        guard tracks.count > 1 else { return nil }
        func rank(_ track: MediaStream) -> Int {
            audioTypes.firstIndex(of: AudioKind(title: track.title ?? track.displayTitle)) ?? audioTypes.count
        }
        let mainRank = audioTypes.firstIndex(of: .main) ?? 0
        let usual = tracks.filter { rank($0) <= mainRank }
        let pool = usual.isEmpty ? tracks : usual
        let defaults = playDefaultAudio ? pool.filter { $0.isDefault == true } : []
        let from = defaults.isEmpty ? pool : defaults
        let base = LanguageCodes.first(audioLanguages, in: from, language: \.language)?.first ?? from[0]
        let sameLanguage = tracks.filter { track in
            base.language == nil ? track.language == nil : LanguageCodes.same(base.language, track.language)
        }
        return sameLanguage.min { rank($0) < rank($1) } ?? base
    }

    /// The subtitle to start with, by the mode, the languages and the type ranking; nil for none.
    func subtitleStream(in streams: [MediaStream], audioLanguage: String?) -> MediaStream? {
        let tracks = streams.filter { $0.type == "Subtitle" && $0.index != nil }
        guard !tracks.isEmpty else { return nil }
        func kind(_ track: MediaStream) -> SubtitleKind? {
            SubtitleKind.of(title: track.title ?? track.displayTitle, forced: track.isForced ?? false,
                            hearingImpaired: track.isHearingImpaired ?? false)
        }
        func rank(_ track: MediaStream) -> Int {
            guard let kind = kind(track) else { return subtitleTypes.count }
            return subtitleTypes.firstIndex(of: kind) ?? subtitleTypes.count
        }
        func best(_ list: [MediaStream]) -> MediaStream? { list.min { rank($0) < rank($1) } }
        switch subtitleMode {
        case "None":
            return nil
        case "OnlyForced":
            // Forced lines in the language being heard.
            let forced = tracks.filter { kind($0) == .forced || kind($0) == .signs }
            return forced.first { LanguageCodes.same($0.language, audioLanguage) } ?? forced.first { $0.language == nil }
        case "Smart":
            // Only where the audio isn't already in one of the user's subtitle languages.
            if subtitleLanguages.contains(where: { LanguageCodes.same($0, audioLanguage) }) { return nil }
            fallthrough
        default:
            guard let found = LanguageCodes.first(subtitleLanguages, in: tracks, language: \.language) else { return nil }
            return best(found)
        }
    }
}

/// What was last picked for each show (or channel), under the web app's display preferences
/// `aiostreams-web-tracks`: `audio|subtitle`, a language each, `off` for no subtitles, a subtitle's
/// type after its language (`eng:forced`).
@MainActor
final class ShowPicks {
    static let shared = ShowPicks()
    private static let prefsId = "aiostreams-web-tracks"

    private var picks: [String: String] = [:]
    private var loadedFor: String?

    /// The show an item's pick belongs to: an episode's series, a channel, a programme's channel.
    static func show(of item: Item) -> String? {
        switch item.type {
        case "Episode": return item.seriesId
        case "TvChannel": return item.id
        case "Program": return item.channelId
        default: return nil
        }
    }

    func load(client: JellyfinClient, userId: String) async {
        guard loadedFor != userId else { return }
        let prefs = try? await client.json("GET", "/DisplayPreferences/\(Self.prefsId)", ["client": Self.prefsId, "userId": userId])
        picks = ((prefs?["CustomPrefs"] as? [String: Any]) ?? [:]).compactMapValues { value in
            (value as? String).flatMap { $0.contains("|") ? $0 : nil }
        }
        loadedFor = userId
    }

    func pick(for item: Item) -> (audio: String?, subtitle: String?) {
        guard let show = Self.show(of: item), let entry = picks[show] else { return (nil, nil) }
        let parts = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let audio = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        let subtitle = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (audio, subtitle)
    }

    /// Saves a pick for the item's show; nil for one side forgets that side.
    func save(for item: Item, audio: String??, subtitle: String??, client: JellyfinClient, userId: String) {
        guard let show = Self.show(of: item) else { return }
        let current = pick(for: item)
        let nextAudio = audio ?? current.audio
        let nextSubtitle = subtitle ?? current.subtitle
        let entry = nextAudio != nil || nextSubtitle != nil ? "\(nextAudio ?? "")|\(nextSubtitle ?? "")" : ""
        guard entry != (picks[show] ?? "") else { return }
        if entry.isEmpty { picks.removeValue(forKey: show) } else { picks[show] = entry }
        // A server may keep a key it isn't sent, so a forgotten pick is sent empty.
        var custom: [String: Any] = picks
        if entry.isEmpty { custom[show] = "" }
        let body: [String: Any] = ["Id": Self.prefsId, "Client": Self.prefsId, "CustomPrefs": custom]
        Task {
            _ = try? await client.json("POST", "/DisplayPreferences/\(Self.prefsId)", ["client": Self.prefsId, "userId": userId], body: body)
        }
    }

    /// The rules with the show's pick first, where the settings say to remember picks; a channel
    /// starts without subtitles unless one was picked on it.
    func rules(_ base: TrackRules, for item: Item, rememberAudio: Bool, rememberSubtitles: Bool) -> TrackRules {
        var rules = base
        if item.isChannel || item.type == "Program" { rules.subtitleMode = "None" }
        let picked = pick(for: item)
        if rememberAudio, let audio = picked.audio {
            rules.audioLanguages = [audio] + base.audioLanguages.filter { !LanguageCodes.same($0, audio) }
            rules.playDefaultAudio = false
        }
        if rememberSubtitles, let subtitle = picked.subtitle {
            if subtitle == "off" {
                rules.subtitleMode = "None"
            } else {
                let parts = subtitle.split(separator: ":").map(String.init)
                rules.subtitleLanguages = [parts[0]] + base.subtitleLanguages.filter { !LanguageCodes.same($0, parts[0]) }
                rules.subtitleMode = "Always"
                if parts.count > 1, let kind = SubtitleKind(rawValue: parts[1]) {
                    rules.subtitleTypes = [kind] + base.subtitleTypes.filter { $0 != kind }
                }
            }
        }
        return rules
    }
}
