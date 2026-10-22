import AVKit
import Observation
import UIKit

/// Picture in Picture for the custom player. Owns the player's one `AVPlayerLayer` (inside
/// `layerView`) and the `AVPictureInPictureController` around it, and mirrors its possible /
/// active state so the controls overlay can show and flip the PiP button.
///
/// **Why the model owns the layer.** `FullScreenPlayer` rebuilds `VideoSurface` whenever its
/// layout branch changes (theater mode ↔ stacked / side by side). iPadOS also re-lays the app
/// out at the other orientation for its app-switcher snapshot when the app goes to the
/// background, which flips that branch. A new layer used to mean a new PiP controller, and
/// dropping the old one ended the running PiP window the moment the user went to the Home
/// Screen. Now every `VideoSurface` hosts this same view, so the controller lives as long as
/// the player.
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

    @ObservationIgnored private var hostedView: PlayerLayerView?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var activeObservation: NSKeyValueObservation?

    /// The player's video view, created (with its PiP controller) on first use. `VideoSurface`
    /// moves it into whichever surface is on screen.
    func layerView(for player: AVPlayer) -> PlayerLayerView {
        if let hostedView {
            if hostedView.playerLayer.player !== player { hostedView.playerLayer.player = player }
            return hostedView
        }
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        hostedView = view
        attach(to: view.playerLayer)
        return view
    }

    private func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
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

    /// A view whose backing layer is an `AVPlayerLayer`.
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        // `layerClass` guarantees the type.
        var playerLayer: AVPlayerLayer { unsafeDowncast(layer, to: AVPlayerLayer.self) }
    }
}
