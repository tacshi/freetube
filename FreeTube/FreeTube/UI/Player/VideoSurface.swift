import SwiftUI
import AVKit

/// The player's video picture: an `AVPlayerLayer` (aspect-fit, black bars) with no system
/// controls. `PlayerControlsOverlay` draws the controls on top.
///
/// The layer itself belongs to `PictureInPictureModel` and is the same for the player's whole
/// lifetime; each `VideoSurface` just hosts it. When a layout change rebuilds the surface, the
/// new one takes the layer over, so a running PiP window (whose controller is tied to that
/// layer) survives — see `PictureInPictureModel`.
///
/// Replaces the former `AVPlayerViewController` surface, whose built-in controls can't be
/// rearranged or trimmed (no API to hide the volume button or move the top-bar buttons), and
/// whose own tap / double-tap / pan handling fought the player's gestures.
@available(iOS 17.0, *)
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let pictureInPicture: PictureInPictureModel

    func makeUIView(context: Context) -> HostView {
        let host = HostView()
        host.backgroundColor = .black
        host.adopt(pictureInPicture.layerView(for: player))
        return host
    }

    func updateUIView(_ host: HostView, context: Context) {
        // Only re-point the player; never pull the layer back from a newer surface.
        _ = pictureInPicture.layerView(for: player)
    }

    /// Holds the shared `PlayerLayerView`, sized to fill.
    final class HostView: UIView {
        func adopt(_ view: UIView) {
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
    }
}
