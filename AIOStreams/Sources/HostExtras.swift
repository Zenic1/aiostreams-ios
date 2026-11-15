import AetherEngineFeatures
import AVFoundation
import MediaPlayer
import UIKit

/// The stats over the video, which the page's player asks for (player-stats-overlay) where the
/// app draws them, as the desktop app's mpv draws its own: what's playing and how, once a second.
/// A technical readout, so in English, as mpv's own is.
final class StatsLabel: UILabel {
    private var timer: Timer?
    private weak var engine: AetherEngine?

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        layer.cornerRadius = 8
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ engine: AetherEngine?) {
        self.engine = engine
        timer?.invalidate()
        timer = nil
        isHidden = engine == nil
        guard engine != nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @MainActor private func refresh() {
        guard let engine else { return }
        let size = engine.sourceVideoWidth > 0 ? "\(engine.sourceVideoWidth)x\(engine.sourceVideoHeight)" : "-"
        let rate = engine.sourceVideoFrameRate.map { String(format: " %.3g fps", $0) } ?? ""
        var format = String(describing: engine.videoFormat)
        if engine.sourceVideoFormat != engine.videoFormat { format = "\(engine.sourceVideoFormat) -> \(format)" }
        if let profile = engine.sourceDVProfile { format += " (P\(profile))" }
        var lines = [
            "Engine    AetherEngine \(AetherEngine.version)",
            "Video     \(engine.sourceVideoCodecName?.uppercased() ?? "-") \(size)\(rate)",
            "Format    \(format)",
        ]
        if engine.sourceVideoBitrate > 0 {
            lines.append(String(format: "Bitrate   %.1f Mbps", Double(engine.sourceVideoBitrate) / 1_000_000))
        }
        lines += [
            "Decoder   \(engine.activeVideoDecoder ?? "-")",
            "Audio     \(engine.activeAudioDecoder ?? "-") (\(engine.audioDelivery))",
            "Route     \(engine.videoRoute)\(engine.sourceContainerFormat.map { ", \($0)" } ?? "")",
            String(format: "Buffered  %.0f s", max(0, engine.bufferedPosition - engine.currentTime)),
        ]
        text = lines.map { "  \($0)  " }.joined(separator: "\n")
        let fitted = sizeThatFits(CGSize(width: 420, height: CGFloat.greatestFiniteMagnitude))
        let inset = superview?.safeAreaInsets ?? .zero
        frame = CGRect(x: inset.left + 12, y: inset.top + 12, width: fitted.width, height: fitted.height + 12)
    }
}

/// The device's media volume and the screen's brightness, which swipes on the page's video set,
/// as the Android app's levels do. The volume is the system's, set through a volume view's slider,
/// the one way an app sets it; the brightness goes back to what it was when the page lets it go.
@MainActor
final class Levels {
    private let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }()
    private var brightnessBefore: CGFloat?

    /// The volume view must be on screen for its slider to work, out of sight.
    func install(in root: UIView) { root.addSubview(volumeView) }

    var reading: [String: Any] {
        ["type": "levels", "volume": Double(AVAudioSession.sharedInstance().outputVolume),
         "brightness": Double(UIScreen.main.brightness)]
    }

    func set(_ level: String?, _ value: Double?) {
        switch level {
        case "volume":
            guard let value, let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = Float(min(max(value, 0), 1))
            slider.sendActions(for: .valueChanged)
        case "brightness":
            if let value {
                if brightnessBefore == nil { brightnessBefore = UIScreen.main.brightness }
                UIScreen.main.brightness = CGFloat(min(max(value, 0), 1))
            } else if let before = brightnessBefore {
                UIScreen.main.brightness = before
                brightnessBefore = nil
            }
        default:
            break
        }
    }
}
