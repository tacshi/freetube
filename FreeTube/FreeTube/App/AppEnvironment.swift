import SwiftUI
import OSLog

/// Shared singletons placed into the SwiftUI environment by `FreeTubeApp`.
/// Views observe these via `@Environment(PlayerStateManager.self)` etc.
@available(iOS 17.0, *)
@MainActor
final class AppEnvironment {
    let playerStateManager = PlayerStateManager()

    init() {
        // Touch `LogFileWriter.shared` first so the file-logging writer (if enabled)
        // captures every subsequent line in this init — audio session setup, remote
        // commands. The writer's own first entry timestamp is set to "1 minute ago" so it
        // also grabs the pre-init logs from app startup.
        _ = LogFileWriter.shared
        AudioSessionConfigurator.configure()
        RemoteCommandCenter.wire(to: playerStateManager)
    }
}
