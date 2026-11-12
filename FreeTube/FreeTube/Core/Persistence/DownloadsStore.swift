import AVFoundation
import Foundation
import Observation
import OSLog
import UIKit

/// The downloaded videos: a scan of the Documents folder plus each file's metadata xattr
/// (`FileXattr`, `DownloadMetadata`). **The file system is the single source of truth** — the
/// Documents folder is exposed in the Files app (`UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`), so the user can copy files out, AirDrop them, or drop
/// their own in, and whatever is there is what the list shows.
///
/// Rescans on launch, after every change the app makes, and when the app comes back to the
/// foreground (to pick up changes made in the Files app).
@available(iOS 17.0, *)
@Observable
@MainActor
final class DownloadsStore {
    static let shared = DownloadsStore()

    /// xattr key holding the serialized `DownloadMetadata` for a file.
    nonisolated static let metadataXattrKey = "com.leshko.freetube.downloadMetadata"

    /// JPEG compression target. ~10 KB at 200×112 for typical YouTube thumbnails — fits
    /// comfortably in an xattr value.
    nonisolated static let thumbnailMaxWidth: CGFloat = 200
    nonisolated static let thumbnailJpegQuality: CGFloat = 0.55

    /// Downloaded files, newest first.
    private(set) var entries: [DownloadEntry] = []
    /// `entries` by video ID, for the "is this downloaded?" checks rows and the player make.
    private(set) var filesByVideoID: [String: URL] = [:]

    @ObservationIgnored private let log = AppLog(subsystem: "com.leshko.freetube", category: "DownloadsStore")
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    /// Bumped per scan so a slow older scan can't overwrite a newer one's result.
    @ObservationIgnored private var scanGeneration = 0

    private init() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    // MARK: - Read

    /// Rescans the Documents folder. The directory listing, per-file attributes and xattr reads
    /// all run on a detached `.utility` task — never on the main thread.
    func reload() async {
        scanGeneration += 1
        let generation = scanGeneration
        let scanned = await Task.detached(priority: .utility) { Self.scanDirectory() }.value
        guard generation == scanGeneration else { return }
        apply(scanned)
    }

    private func apply(_ scanned: [DownloadEntry]) {
        entries = scanned
        filesByVideoID = Dictionary(scanned.map { ($0.videoID, $0.fileURL) }, uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func scanDirectory() -> [DownloadEntry] {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory(),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return fileURLs
            .filter { ["mp4", "m4v", "mov", "m4a", "mp3"].contains($0.pathExtension.lowercased()) }
            .compactMap(makeEntry(from:))
            .sorted { $0.sortDate > $1.sortDate }
    }

    // MARK: - Write

    /// Tags a freshly written file with its metadata and rescans. Returns once the file is in
    /// `entries`, so the caller can drop its in-progress state without a gap.
    func add(video: Video, fileURL: URL) async {
        let thumbnailURL = video.thumbnailURL
        await Task.detached(priority: .utility) {
            var thumbnail: Data?
            if let thumbnailURL, let raw = try? await URLSession.shared.data(from: thumbnailURL).0 {
                thumbnail = Self.compressedThumbnail(raw)
            }
            let metadata = DownloadMetadata(
                videoID: video.id,
                title: video.title,
                channelName: video.channelName,
                formatID: "hls",
                downloadedAt: .now,
                originalURL: nil,
                thumbnailData: thumbnail,
                duration: Self.readDuration(at: fileURL),
                thumbnailURL: thumbnailURL?.absoluteString
            )
            if let blob = try? PropertyListEncoder().encode(metadata) {
                try? FileXattr.write(blob, key: Self.metadataXattrKey, at: fileURL)
            }
        }.value
        await reload()
    }

    /// Deletes a downloaded file (its xattr goes with it).
    func delete(_ entry: DownloadEntry) {
        do {
            try FileManager.default.removeItem(at: entry.fileURL)
            log.info("deleted \(entry.videoID, privacy: .public)")
        } catch {
            log.error("delete failed for \(entry.videoID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        // Drop it from the published state right away so the row disappears with the swipe;
        // the rescan then confirms.
        apply(entries.filter { $0.id != entry.id })
        Task { await reload() }
    }

    // MARK: - Internals

    /// Where downloads live: the **Documents root**, which is what the Files app shows for the
    /// app. Other app data (SwiftData store, caches) lives elsewhere, so the user sees only
    /// their media (and `Logs/` when file logging is on).
    nonisolated static func downloadsDirectory() -> URL {
        URL.documentsDirectory
    }

    private nonisolated static func makeEntry(from url: URL) -> DownloadEntry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let metadata = FileXattr.read(key: metadataXattrKey, at: url)
            .flatMap { try? PropertyListDecoder().decode(DownloadMetadata.self, from: $0) }
        return DownloadEntry(
            fileURL: url,
            metadata: metadata,
            fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: (attributes[.modificationDate] as? Date) ?? .distantPast,
            duration: metadata?.duration ?? readDuration(at: url)
        )
    }

    /// Synchronous `AVURLAsset.duration` read. Deprecated API but appropriate here: the file is
    /// local, the call only walks the moov atom (a few KB of header), and it's only invoked
    /// from detached `.utility` tasks.
    nonisolated static func readDuration(at url: URL) -> TimeInterval? {
        let seconds = AVURLAsset(url: url).duration.seconds
        return (seconds.isFinite && seconds > 0) ? seconds : nil
    }

    /// Downscale + JPEG-compress the thumbnail so it fits comfortably in an xattr value.
    private nonisolated static func compressedThumbnail(_ raw: Data) -> Data? {
        guard let image = UIImage(data: raw) else { return nil }
        let scale = min(1, thumbnailMaxWidth / max(image.size.width, 1))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: thumbnailJpegQuality)
    }
}
