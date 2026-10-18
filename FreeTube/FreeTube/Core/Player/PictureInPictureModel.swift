import AVKit
import Observation

/// Picture in Picture for the custom player. Wraps `AVPictureInPictureController` around the
/// `AVPlayerLayer` that `VideoSurface` renders into, and mirrors its possible / active state so
/// the controls overlay can show and flip the PiP button.
///
/// PiP only starts from the button — never automatically on backgrounding (that was
/// disorienting: audio continued with a floating window appearing the moment the user switched
/// apps, and it burned battery).
@available(iOS 17.0, *)
@Observable
@MainActor
final class PictureInPictureModel {
    private(set) var isPossible = false
    private(set) var isActive = false

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var activeObservation: NSKeyValueObservation?

    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              controller?.playerLayer !== layer,
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            guard let model = self else { return }
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in model.isPossible = possible }
        }
        activeObservation = controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] pip, _ in
            guard let model = self else { return }
            let active = pip.isPictureInPictureActive
            Task { @MainActor in model.isActive = active }
        }
        self.controller = controller
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }
}
