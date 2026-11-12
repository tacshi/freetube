import Foundation

/// Serialized payload written as a single extended attribute on each downloaded file. The file
/// system is the source of truth for downloads — no SwiftData row — and the metadata travels
/// with the file.
///
/// **Encoding**: binary property list. Smaller and faster to decode than JSON, and
/// `Date`/`Data` round-trip without manual coding keys.
///
/// **What's NOT stored here**: the file URL and size, which come from the file system at read
/// time. Never a stream URL (CLAUDE.md §2.6).
struct DownloadMetadata: Codable, Sendable {
    /// YouTube video ID.
    let videoID: String
    let title: String
    let channelName: String
    /// How the file was made: `"hls"` now; `"ytdl"` / `"url-fetch"` on files from the old
    /// yt-dlp download stack.
    let formatID: String
    let downloadedAt: Date
    /// Set only on old Link-tab files (the pasted URL).
    let originalURL: String?
    /// Compressed JPEG bytes of the thumbnail, ~10 KB. Inline so the list works offline and
    /// the file is self-describing — no sidecar files in the Documents folder.
    let thumbnailData: Data?
    /// Playback duration in seconds, read once at write time so the Downloads list doesn't
    /// open every file to show it.
    let duration: TimeInterval?
    /// YouTube's thumbnail URL (public, not signed), for the player's artwork. Missing on
    /// files written before this field existed.
    var thumbnailURL: String?
}
