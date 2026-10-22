import Foundation
import SwiftData
import OSLog

/// Owns the SwiftData `ModelContainer`. Inject the container into the SwiftUI scene via
/// `.modelContainer(_:)` so any `@Query` view picks it up automatically.
///
/// `nonisolated` so `PersistenceWriter` (an actor) can read `sharedContainer`; `ModelContainer`
/// is `Sendable`.
@available(iOS 17.0, *)
nonisolated enum PersistenceController {
    static let log = AppLog(subsystem: "com.leshko.freetube", category: "Persistence")

    static let sharedContainer: ModelContainer = {
        // Older installs may still have a `DownloadedVideo` table in the on-disk SQLite store
        // from when the app downloaded videos; SwiftData ignores tables for models that aren't
        // in the active schema, so it's left untouched.
        let schema = Schema([
            WatchHistoryEntry.self,
            SearchHistoryEntry.self,
            FavoriteVideo.self,
            FavoritePlaylist.self
        ])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            log.fault("Failed to construct ModelContainer: \(String(describing: error), privacy: .public)")
            fatalError("Unable to create ModelContainer: \(error)")
        }
    }()
}
