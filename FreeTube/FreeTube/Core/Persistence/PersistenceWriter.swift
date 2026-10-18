import Foundation
import SwiftData

/// Background actor for every SwiftData write the app performs.
///
/// **Why an actor:** SwiftData `ModelContext` is not thread-safe — it must only be used from the
/// thread/actor that created it. The `@ModelActor` macro generates an initializer that constructs
/// a context bound to this actor's isolated executor, so all writes happen on a single dedicated
/// background queue and never block the main thread. `@Query` views observing the main context
/// still pick up changes automatically once `save()` lands (SwiftData propagates persistent-store
/// notifications back to the main context).
///
/// **What's serialized here:** WatchHistory (incl. playback position), FavoriteVideo, SearchHistory writes.
/// Reads (favorite lookup, recent history, etc.) still go through SwiftUI `@Query` or the main
/// context — those are reactive and indexed.
@available(iOS 17.0, *)
@ModelActor
actor PersistenceWriter {
    static let shared = PersistenceWriter(modelContainer: PersistenceController.sharedContainer)

    // MARK: - WatchHistoryEntry

    /// Bump `watchedAt` on a play, or insert a new row. One indexed-column fetch + one write.
    func upsertWatchHistory(
        videoID: String,
        title: String,
        channelName: String,
        thumbnailURL: URL?
    ) {
        let target = videoID
        let descriptor = FetchDescriptor<WatchHistoryEntry>(predicate: #Predicate { $0.videoID == target })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.watchedAt = .now
            existing.title = title
            existing.channelName = channelName
            existing.thumbnailURL = thumbnailURL
        } else {
            modelContext.insert(WatchHistoryEntry(
                videoID: videoID,
                title: title,
                channelName: channelName,
                thumbnailURL: thumbnailURL
            ))
        }
        try? modelContext.save()
    }

    // MARK: - Playback position

    /// Records how far into `videoID` playback got, on the row `upsertWatchHistory` created when
    /// the video was opened. No-op when there's no row (nothing to resume into).
    func savePlaybackPosition(videoID: String, position: TimeInterval, duration: TimeInterval) {
        let target = videoID
        let descriptor = FetchDescriptor<WatchHistoryEntry>(predicate: #Predicate { $0.videoID == target })
        guard let entry = try? modelContext.fetch(descriptor).first else { return }
        entry.lastPosition = position
        if duration > 0 { entry.duration = duration }
        try? modelContext.save()
    }

    /// Where to resume `videoID`, or nil to start from the beginning: never played, stopped in
    /// the first few seconds, or watched to (nearly) the end — like YouTube, a finished video
    /// starts over.
    func resumePosition(videoID: String) -> TimeInterval? {
        let target = videoID
        let descriptor = FetchDescriptor<WatchHistoryEntry>(predicate: #Predicate { $0.videoID == target })
        guard let entry = try? modelContext.fetch(descriptor).first,
              entry.lastPosition >= 5 else { return nil }
        if entry.duration > 0, entry.lastPosition >= entry.duration - 10 { return nil }
        return entry.lastPosition
    }
}
