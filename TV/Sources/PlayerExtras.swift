import AetherEngineFeatures
@preconcurrency import AVKit
import Combine
import SwiftUI

// MARK: - Stats

/// What's playing and how, over the video's corner, as the web app's stats overlay shows it: the
/// source's codec, size, frame rate and bitrate, the format on screen, what decodes it, and how
/// far ahead it's buffered.
struct StatsOverlay: View {
    @ObservedObject var engine: AetherEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                ForEach(lines, id: \.0) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.px(12)) {
                        Text(line.0).foregroundStyle(Theme.gray400).frame(width: Theme.px(120), alignment: .leading)
                        Text(line.1)
                    }
                }
            }
            .font(.system(size: Theme.px(14), weight: .medium, design: .monospaced))
            .padding(Theme.px(16))
            .background(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous).fill(.black.opacity(0.7)))
        }
    }

    private var lines: [(String, String)] {
        var out: [(String, String)] = []
        let size = engine.sourceVideoWidth > 0 ? "\(engine.sourceVideoWidth)×\(engine.sourceVideoHeight)" : "–"
        let rate = engine.sourceVideoFrameRate.map { String(format: "%.3g fps", $0) } ?? ""
        out.append((L("Video"), [engine.sourceVideoCodecName?.uppercased() ?? "–", size, rate].filter { !$0.isEmpty }.joined(separator: " · ")))
        var format = String(describing: engine.videoFormat)
        if engine.sourceVideoFormat != engine.videoFormat { format = "\(engine.sourceVideoFormat) → \(format)" }
        if let profile = engine.sourceDVProfile { format += " (P\(profile))" }
        out.append((L("Format"), format))
        if engine.sourceVideoBitrate > 0 {
            out.append((L("Bitrate"), String(format: "%.1f Mbps", Double(engine.sourceVideoBitrate) / 1_000_000)))
        }
        out.append((L("Decoder"), engine.activeVideoDecoder ?? "–"))
        out.append((L("Audio"), [engine.activeAudioDecoder ?? "–", String(describing: engine.audioDelivery)].joined(separator: " · ")))
        out.append((L("Route"), [String(describing: engine.videoRoute), engine.sourceContainerFormat].compactMap { $0 }.joined(separator: " · ")))
        let ahead = max(0, engine.bufferedPosition - engine.currentTime)
        out.append((L("Buffered"), String(format: "%.0f s", ahead)))
        return out
    }
}

// MARK: - Picture in Picture

/// The video in a corner while the app's pages are used, through AVKit's window. While it's up,
/// the player's model lives on here; going back to it (the window's button) opens the player
/// again on the same model, and closing the window stops it.
@MainActor
final class TVPictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    static let shared = TVPictureInPicture()

    /// The player to open again, once the window asks to go back to it.
    @Published private(set) var restoring: PlayerModel?
    private(set) var model: PlayerModel?
    private var controller: AVPictureInPictureController?
    private var started: (() -> Void)?
    private var returning = false

    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Whether this title can go into the window: AVKit's window takes the engine's own player
    /// layer, which the software path doesn't have on tvOS.
    static func available(_ engine: AetherEngine) -> Bool { supported && engine.nativePlayerLayer != nil }

    /// Starts the window; `started` closes the player's screen once it's up.
    func start(_ model: PlayerModel, started: @escaping () -> Void) {
        guard let layer = model.engine.nativePlayerLayer else { return }
        stop()
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        self.controller = controller
        self.model = model
        self.started = started
        model.engine.pictureInPictureActive = true
        Task {
            // AVKit says when it's ready to start, a moment after the controller is made.
            for _ in 0..<20 where controller?.isPictureInPicturePossible != true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            controller?.startPictureInPicture()
        }
    }

    /// Closes the window and the player in it, as starting another title does.
    func stop() {
        guard let model else { return }
        returning = false
        controller?.stopPictureInPicture()
        finish(stopping: model)
    }

    /// The player opened again has its model back.
    func restored() { restoring = nil }

    private func finish(stopping model: PlayerModel?) {
        model?.engine.pictureInPictureActive = false
        model?.stop()
        controller?.delegate = nil
        controller = nil
        self.model = nil
        started = nil
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            started?()
            started = nil
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            returning = true
            restoring = model
        }
        completionHandler(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            if returning {
                // The player's open again on the model; the window lets it go.
                model?.engine.pictureInPictureActive = false
                self.controller?.delegate = nil
                self.controller = nil
                model = nil
                returning = false
            } else {
                finish(stopping: model)
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            AppLog.warn("pip", "did not start: \(error.localizedDescription)")
            model?.engine.pictureInPictureActive = false
            self.controller = nil
            model = nil
            started = nil
        }
    }
}
