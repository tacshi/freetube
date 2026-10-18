import Foundation
import SwiftUI

/// Lightweight user preferences stored in `UserDefaults` via `@AppStorage`. Use this for primitive flags only;
/// anything queryable belongs in SwiftData.
struct UserPreferences {
    /// Quality ceiling for progressive-MP4 streams. HLS streams adapt on their own (AVPlayer
    /// picks the variant), so `.auto` is the right default now that playback always streams.
    @AppStorage("preferredQuality") var preferredQualityRaw: String = VideoQuality.auto.rawValue
    @AppStorage("autoplayNext") var autoplayNext: Bool = true
    /// When true, `LogFileWriter` opens a new file under `Documents/Logs/` on every app
    /// launch and mirrors the unified-log entries for our subsystem into it. Useful for
    /// capturing diagnostic traces from TestFlight / sideload installs where Console.app
    /// access isn't practical. Defaults off — only a handful of users will ever flip this.
    @AppStorage("logToFile") var logToFile: Bool = false
    @AppStorage("restrictedSearchMode") var restrictedSearchMode: Bool = false
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.system.rawValue
    /// Persisted playback rate (1.0 = normal speed). Mirrors `AVPlayer.defaultRate`, which is the
    /// value the player's ⋯ speed menu writes (`PlayerStateManager.setPlaybackRate`).
    /// `PlayerStateManager` reads this on init and observes the player's `defaultRate` to write
    /// changes back here — so a relaunch picks up where the last session left off.
    @AppStorage("playbackRate") var playbackRate: Double = 1.0
    /// Language of the captions the user last turned on (`CaptionTrack.languageCode`); empty when
    /// captions were last turned off. New videos auto-select a matching track.
    @AppStorage("preferredCaptionLanguage") var preferredCaptionLanguage: String = ""
    /// Report watch progress to the signed-in YouTube account (history + resume point shared with
    /// YouTube's own apps). User-requested exception to "no remote reporting" (CLAUDE.md §2.4):
    /// it only talks to YouTube, only when signed in, and can be turned off in Settings.
    @AppStorage("syncWatchProgress") var syncWatchProgress: Bool = true

    var preferredQuality: VideoQuality {
        get { VideoQuality(rawValue: preferredQualityRaw) ?? .auto }
        nonmutating set { preferredQualityRaw = newValue.rawValue }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        nonmutating set { appearanceModeRaw = newValue.rawValue }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
