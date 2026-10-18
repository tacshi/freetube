import Foundation

/// Resume points YouTube reports for the signed-in account, keyed by video ID.
///
/// Signed-in feeds (Home, History, Subscriptions, search, channel lists) carry each video's
/// watch progress; YouTubeKit exposes it as `YTVideo.startTime` (exact seconds when YouTube
/// sends `watchEndpoint.startTimeSeconds`, otherwise derived from the red progress bar's
/// percentage). `Mappers.video(from:)` records it here; `PlayerStateManager` compares it with
/// the app's own saved position and resumes from whichever is newer.
///
/// Kept out of `Video` on purpose: `Video` is compared by value (queue lookups, list diffing),
/// and a resume point that differs between two copies of the same video would break that.
/// In memory only — it's re-learned every time a feed loads.
nonisolated final class YouTubeResumeCache: @unchecked Sendable {
    static let shared = YouTubeResumeCache()

    struct Entry: Sendable {
        let seconds: TimeInterval
        let duration: TimeInterval?
        /// When the feed reporting this value was loaded — YouTube doesn't say when it recorded
        /// the progress, so this is the newest the value can be known to be.
        let observedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    private init() {}

    func record(videoID: String, seconds: TimeInterval, duration: TimeInterval?) {
        guard seconds > 0 else { return }
        lock.lock()
        entries[videoID] = Entry(seconds: seconds, duration: duration, observedAt: Date())
        lock.unlock()
    }

    func entry(for videoID: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[videoID]
    }
}
