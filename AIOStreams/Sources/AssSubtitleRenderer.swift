import AetherEngineFeatures
import AssRenderingFeatures
import Combine
import UIKit

/// The libass half of the subtitle overlay. AetherEngine (with `preserveASSMarkup`) hands us the
/// raw ASS event lines, the script header and any fonts attached to the container. This puts them
/// back together into a whole script, lets libass paint it, and hands the resulting bitmap to
/// `SubtitleOverlayView`. Everything is used from the main actor; the renderer itself works on its
/// own queue.
final class AssSubtitleRenderer {
    private static let fontFolder = "aeth-ass-fonts"

    private let changed: () -> Void
    private var renderer: AssSubtitlesRenderer?
    private var builder: ASSScriptBuilder?
    private var rawScript: String?
    private var frameCancellable: AnyCancellable?
    private var reloadTask: Task<Void, Never>?
    private var generation = 0
    private var look = SubtitleLook()
    private var canvas: CGSize = .zero
    private var scale: CGFloat = 1
    private var lastTime = -Double.infinity
    private(set) var frame: ProcessedImage?

    init(fontAttachments: [FontAttachment], changed: @escaping () -> Void) {
        self.changed = changed
        Self.installFonts(fontAttachments)
        let fonts = Self.fontsDirectory
        let config = FontConfig(
            fontsPath: fonts,
            fontsCachePath: Self.cachesDirectory,
            defaultFontFamily: "Arial",
            fontProvider: .coreText
        )
        let renderer = AssSubtitlesRenderer(fontConfig: config)
        self.renderer = renderer
        frameCancellable = renderer.framesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let self else { return }
                self.frame = image
                self.changed()
            }
    }

    deinit {
        reloadTask?.cancel()
        frameCancellable?.cancel()
    }

    /// A new track brings its own styles: start an empty script for it. The engine's own builder
    /// dedupes re-emitted events, so a seek needs no reset here.
    func prepare(header: String?) {
        builder = ASSScriptBuilder(header: header?.isEmpty == false ? header! : Self.defaultHeader)
        rawScript = nil
        frame = nil
        renderer?.freeTrack()
        generation += 1
        reloadTask?.cancel()
        changed()
    }

    /// True when a cue body is a raw libavcodec event line rather than ordinary text. Those cues
    /// belong to libass and must not also be drawn as text by the overlay.
    static func isEventLine(_ text: String) -> Bool {
        let first = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return !first.isEmpty && first.allSatisfy(\.isNumber)
    }

    func accepts(_ text: String) -> Bool { Self.isEventLine(text) }

    @discardableResult
    func add(rawEvent text: String, start: Double, end: Double) -> Bool {
        guard accepts(text), let builder else { return false }
        guard builder.add(rawEventText: text, start: start, end: end) else { return true }
        rawScript = builder.script()
        rebuild()
        return true
    }

    func setLook(_ look: SubtitleLook) {
        // Lifting the subtitles only changes `position`, which libass never reads: don't rebuild a
        // whole script on every frame of that animation.
        var previous = self.look
        previous.position = look.position
        guard previous != look else { self.look = look; return }
        let wasForced = self.look.forceStyle
        self.look = look
        // With "override styled subtitles" on, the page's look is baked into the script. Changes to
        // it while forced need a new script; otherwise the page only affects unstyled cues.
        if look.forceStyle || wasForced { rebuild() }
    }

    /// Source PTS, already offset by the page's subtitle delay. Throttled to a frame's worth so a
    /// fast clock does not queue a libass render for every tick when nothing changed on screen.
    func setTime(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if abs(seconds - lastTime) < 1.0 / 30, seconds >= lastTime { return }
        lastTime = seconds
        renderer?.setTimeOffset(seconds)
    }

    func setCanvas(_ size: CGSize, scale: CGFloat) {
        guard size.width > 1, size.height > 1, scale > 0 else { return }
        guard canvas != size || self.scale != scale else { return }
        canvas = size
        self.scale = scale
        renderer?.setCanvasSize(size, scale: scale)
    }

    func free() {
        generation += 1
        reloadTask?.cancel()
        builder = nil
        rawScript = nil
        frame = nil
        renderer?.freeTrack()
        lastTime = -Double.infinity
    }

    private func rebuild() {
        guard let rawScript else { return }
        let script = look.forceStyle ? ASSPageStyle.apply(look, to: rawScript) : rawScript
        generation += 1
        let current = generation
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            // A burst of cues arrives together; one rebuild after they settle is enough.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, current == self?.generation else { return }
            self?.renderer?.reloadTrack(content: script)
        }
    }

    // MARK: - Fonts

    private static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static var fontsDirectory: URL {
        let url = cachesDirectory.appendingPathComponent(fontFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Attached fonts are per title. Clear the folder first so a font from the previous file does
    /// not win a name collision in the next one's styles.
    private static func installFonts(_ attachments: [FontAttachment]) {
        let folder = fontsDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        for attachment in attachments {
            let name = (attachment.filename as NSString).lastPathComponent
            guard !name.isEmpty, !name.contains("/") else { continue }
            try? attachment.data.write(to: folder.appendingPathComponent(name))
        }
    }

    /// Used only when a sidecar's extradata carried no header of its own. The intrinsic size follows
    /// the engine's 384x288 default ASS play resolution.
    private static let defaultHeader = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 384
    PlayResY: 288

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """
}

/// The page's "override styled subtitles" setting, expressed in the units an ASS script uses.
/// Styles are rewritten as well as each line being prefixed: an inline `\r` resets a run to its
/// style, which would otherwise undo a prefix-only override.
private enum ASSPageStyle {
    static func apply(_ look: SubtitleLook, to script: String) -> String {
        let playResY = Self.playResY(in: script)
        let size = min(max(Int((SubtitleLook.baseFontSize * look.scale * Double(playResY) / 720).rounded()), 8), 400)
        let font = look.fontFamily ?? "Arial"
        let primary = color(look.color)
        let outline = color(look.outlineColor)
        let background = color(look.backColor)
        let border = min(max(Int(look.outlineSize.rounded()), 0), 20)
        let shadow = min(max(Int(look.shadowSize.rounded()), 0), 20)
        let prefix = #"{\fn\#(font)\fs\#(size)\c\#(primary)\b\#(look.bold ? 1 : 0)\bord\#(border)\shad\#(shadow)}"#

        var foundStyle = false
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            if line.hasPrefix("Style:") {
                let rewritten = rewrite(style: line, font: font, size: size,
                                        primary: primary, outline: outline, background: background,
                                        bold: look.bold, border: border, shadow: shadow)
                if rewritten != line { foundStyle = true }
                return rewritten
            }
            return line
        }
        // A header without a style table still gets the page's look, on every event line.
        guard foundStyle else {
            return lines.map { $0.hasPrefix("Dialogue:") ? inject(prefix, into: $0) : $0 }
                        .joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }

    private static func playResY(in script: String) -> CGFloat {
        for line in script.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("playresy:") else { continue }
            let value = trimmed.dropFirst("playresy:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let points = Double(value), points > 0 { return CGFloat(points) }
        }
        return 288
    }

    private static func color(_ uiColor: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // ASS is &HAABBGGRR&, with 00 alpha meaning opaque.
        return String(format: "&H00%02X%02X%02X&",
                      Int((blue * 255).rounded()), Int((green * 255).rounded()), Int((red * 255).rounded()))
    }

    private static func rewrite(style line: String, font: String, size: Int,
                                primary: String, outline: String, background: String,
                                bold: Bool, border: Int, shadow: Int) -> String {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // V4+ styles: Name, Font, Size, Primary, Secondary, Outline, Back, Bold, ..., Outline, Shadow, ...
        guard fields.count >= 23 else { return line }
        fields[1] = font
        fields[2] = String(size)
        fields[3] = primary
        fields[5] = outline
        fields[6] = background
        fields[7] = bold ? "1" : "0"
        fields[16] = String(border)
        fields[17] = String(shadow)
        return fields.joined(separator: ",")
    }

    private static func inject(_ prefix: String, into dialogue: String) -> String {
        guard dialogue.hasPrefix("Dialogue:") else { return dialogue }
        var index = dialogue.startIndex
        for _ in 0..<9 {
            guard let comma = dialogue[index...].firstIndex(of: ",") else { return dialogue }
            index = dialogue.index(after: comma)
        }
        return String(dialogue[..<index]) + prefix + String(dialogue[index...])
    }
}
