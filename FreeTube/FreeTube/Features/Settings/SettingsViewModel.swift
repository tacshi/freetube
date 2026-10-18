import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class SettingsViewModel {
    var preferences = UserPreferences()

    var preferredQuality: VideoQuality {
        get { preferences.preferredQuality }
        set { preferences.preferredQuality = newValue }
    }

    var appearanceMode: AppearanceMode {
        get { preferences.appearanceMode }
        set { preferences.appearanceMode = newValue }
    }

    var autoplayNext: Bool {
        get { preferences.autoplayNext }
        set { preferences.autoplayNext = newValue }
    }

    var syncWatchProgress: Bool {
        get { preferences.syncWatchProgress }
        set { preferences.syncWatchProgress = newValue }
    }

    // MARK: - Diagnostics

    /// Two-way binding for the "Save logs to file" toggle. Routes through
    /// `LogFileWriter.shared.setEnabled(_:)` so the writer starts/stops in addition to the
    /// persisted flag flipping — otherwise the toggle would change state on disk but
    /// nothing would actually start capturing until the next launch.
    var logToFile: Bool {
        get { LogFileWriter.shared.isEnabled }
        set { LogFileWriter.shared.setEnabled(newValue) }
    }

    /// Convenience pass-through so the Settings view doesn't need to import the writer
    /// directly when binding actions to its state.
    var currentLogFileURL: URL? { LogFileWriter.shared.currentLogFileURL }

    func clearLogFiles() {
        LogFileWriter.shared.clearAllLogs()
    }

    var restrictedSearchMode: Bool {
        get { preferences.restrictedSearchMode }
        set { preferences.restrictedSearchMode = newValue }
    }
}
