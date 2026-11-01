import Foundation

/// Hardware-keyboard player keys, like YouTube on the web: ← / → seek −10s / +10s, ↑ / ↓ change
/// the volume.
///
/// `MacCommands` registers the plain arrow keys (enabled only while the full-screen player is
/// shown) and posts `.freetubePlayerKeyCommand` with one of these as the `object`;
/// `PlayerControlsOverlay` performs it and shows the same feedback as a double-tap seek. The
/// overlay owns the handling so key seeks accumulate in the "+20s" flash like double taps.
///
/// **Text fields keep their arrows.** Since iOS 15 a key command doesn't take priority over
/// system behavior (`UIKeyCommand.wantsPriorityOverSystemBehavior` defaults to `false`), so
/// while the comment composer has focus the arrows move its cursor instead of seeking.
enum PlayerKeyCommand {
    case seekBackward
    case seekForward
    case volumeUp
    case volumeDown
}

extension Notification.Name {
    /// Posted by `MacCommands` for an arrow key in the player; `object` is a `PlayerKeyCommand`.
    static let freetubePlayerKeyCommand = Notification.Name("com.leshko.freetube.playerKeyCommand")
}
