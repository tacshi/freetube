import Foundation

/// A download that hasn't finished: waiting, in progress, or failed. Finished downloads are files
/// (`DownloadsStore`), not jobs. Progress lives apart from the job
/// (`DownloadManager.progress(for:)`) so lists that only care about the status don't re-render
/// on every progress tick.
struct DownloadJob: Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        /// Waiting for a free slot.
        case queued
        /// Fetching the stream.
        case downloading
        /// Stream is on disk; joining video and audio into the MP4.
        case saving
        case failed(String)
    }

    let video: Video
    var status: Status
    var id: String { video.id }

    /// Queued, downloading or saving — everything but failed.
    var isActive: Bool {
        if case .failed = status { return false }
        return true
    }
}
