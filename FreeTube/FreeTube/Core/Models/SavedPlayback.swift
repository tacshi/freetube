import Foundation

/// The app's own saved playback position for a video (from `WatchHistoryEntry`).
struct SavedPlayback: Sendable {
    let position: TimeInterval
    let duration: TimeInterval?
    /// `nil` for positions saved before the timestamp was recorded.
    let savedAt: Date?
}
