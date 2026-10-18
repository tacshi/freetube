import Foundation

/// The account-bound watch-tracking endpoints from a signed-in player response
/// (`playbackTracking.videostatsPlaybackUrl` / `videostatsWatchtimeUrl`). Pinging them is how
/// YouTube records a view in the account's history and the resume point it shows on every
/// device. Signed URLs — keep in memory only.
struct WatchTracking: Sendable {
    let playbackURL: URL
    let watchtimeURL: URL
}
