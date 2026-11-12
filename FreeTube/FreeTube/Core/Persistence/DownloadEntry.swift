import Foundation

/// One downloaded file, from `DownloadsStore`'s scan of the Documents folder. `metadata == nil`
/// means the file has no xattr of ours (dropped in through the Files app, say) — it still shows,
/// with its file name as the title.
@available(iOS 17.0, *)
struct DownloadEntry: Identifiable, Sendable {
    let fileURL: URL
    let metadata: DownloadMetadata?
    let fileSize: Int64
    let modifiedAt: Date
    /// Playback duration in seconds, resolved off-main during the scan so rows never read an
    /// `AVURLAsset` while rendering.
    let duration: TimeInterval?

    var id: String { fileURL.path }

    /// YouTube video ID, or the file name (without extension) for a file without metadata.
    var videoID: String { metadata?.videoID ?? fileURL.deletingPathExtension().lastPathComponent }
    var title: String { metadata?.title ?? fileURL.deletingPathExtension().lastPathComponent }
    var channelName: String { metadata?.channelName ?? "" }
    /// Newest-first sort key.
    var sortDate: Date { metadata?.downloadedAt ?? modifiedAt }

    /// The video this file holds, for handing to `PlayerStateManager.load` — which plays the
    /// file instead of streaming when one exists for the ID.
    var video: Video {
        Video(
            id: videoID,
            title: title,
            channelID: "",
            channelName: channelName,
            channelThumbnailURL: nil,
            thumbnailURL: metadata?.thumbnailURL.flatMap(URL.init(string:)),
            duration: duration,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
    }
}
