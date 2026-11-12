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
            if hostedView.player !== player { hostedView.player = player }
            return hostedView
        }
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.player = player
        view.playerLayer.videoGravity = .resizeAspect
        // A running PiP window is the one case where the picture must stay attached while the
        // app is in the background.
        view.keepsVideoInBackground = { [weak self] in
            self?.controller?.isPictureInPictureActive ?? false
        }
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
    ///
    /// **Detaches the player while the app is in the background** (screen locked, or another
    /// app in front) so the audio keeps playing, like a music app. iOS pauses a player whose
    /// video is still attached to a layer when the app leaves the screen — even with the
    /// `.playback` audio session and `audiovisualBackgroundPlaybackPolicy` set — and taking the
    /// player off the layer is what Apple's guidance for background audio from video says to
    /// do. The picture is re-attached on return.
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        // `layerClass` guarantees the type.
        var playerLayer: AVPlayerLayer { unsafeDowncast(layer, to: AVPlayerLayer.self) }

        /// The player to show. Set this rather than `playerLayer.player`, so a SwiftUI update
        /// that arrives in the background can't re-attach the picture.
        var player: AVPlayer? {
            didSet {
                if !isInBackground { playerLayer.player = player }
            }
        }
        /// Asked on entering the background; `true` leaves the picture attached.
        var keepsVideoInBackground: @MainActor () -> Bool = { false }
        private var isInBackground = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Selector-based observers need no removal: they end with the view.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(willEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        @objc private func didEnterBackground() {
            isInBackground = true
            if !keepsVideoInBackground() { playerLayer.player = nil }
        }

        @objc private func willEnterForeground() {
            isInBackground = false
            if playerLayer.player !== player { playerLayer.player = player }
        }
    }
}
