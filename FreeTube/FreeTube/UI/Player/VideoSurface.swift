import SwiftUI
import AVKit

/// The player's video picture: an `AVPlayerLayer` (aspect-fit, black bars) with no system
/// controls. `PlayerControlsOverlay` draws the controls on top, and `PictureInPictureModel`
/// attaches to this layer for PiP.
///
/// Replaces the former `AVPlayerViewController` surface, whose built-in controls can't be
/// rearranged or trimmed (no API to hide the volume button or move the top-bar buttons), and
/// whose own tap / double-tap / pan handling fought the player's gestures.
@available(iOS 17.0, *)
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let pictureInPicture: PictureInPictureModel

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        if let layer = view.playerLayer {
            layer.player = player
            layer.videoGravity = .resizeAspect
            pictureInPicture.attach(to: layer)
        }
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if let layer = view.playerLayer, layer.player !== player {
            layer.player = player
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }
}
