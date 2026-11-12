import Foundation
import Network
import Observation
import OSLog
import UIKit

/// Downloads videos to MP4 files the user can play offline and export to other apps.
///
/// **How a download runs** (`run(_:)`):
/// 1. Resolve the same HLS stream the player uses (`StreamService`).
/// 2. `HLSDownloadService` fetches the chosen variant's video and audio segments into two
///    temporary files.
/// 3. ffmpeg joins them into one MP4 without re-encoding (`FFmpegRunner`, `-c copy`).
/// 4. The MP4 moves to the Documents folder and `DownloadsStore` tags it with its metadata.
///
/// Downloads are explicit — the user taps Download. Playback never downloads (CLAUDE.md §7);
/// it only prefers a file that already exists.
///
/// **While the app is in the background** iOS suspends it shortly after it leaves the screen
/// (unless audio is playing); the download picks up where it was on return, since each segment
/// retries.
@available(iOS 17.0, *)
@Observable
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    /// Unfinished downloads, oldest first. A failed one stays until retried or dismissed.
    private(set) var jobs: [DownloadJob] = []
    /// Fraction done (0…1) per downloading video. Separate from `jobs` so only views that draw
    /// progress re-render as it ticks.
    private(set) var progressByVideoID: [String: Double] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Identifies the current run of each video's download, so a cancelled run that is still
    /// winding down can't clear the state of a download restarted in the meantime.
    @ObservationIgnored private var runTokens: [String: UUID] = [:]
    @ObservationIgnored private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    @ObservationIgnored private let store = DownloadsStore.shared
    @ObservationIgnored private let streams: any StreamServicing = StreamService()
    @ObservationIgnored private let preferences = UserPreferences()
    @ObservationIgnored private let log = AppLog(subsystem: "com.leshko.freetube", category: "DownloadManager")
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    /// Downloads running at once; the rest wait as `.queued`.
    private static let maxConcurrent = 2
    /// Share of a download's progress bar given to the video track; audio is a small fraction
    /// of the bytes.
    private static let videoShare = 0.92

    private init() {
        pathMonitor.start(queue: DispatchQueue(label: "com.leshko.freetube.download-path"))
        Self.removeTemporaryFiles()
    }

    // MARK: - State

    /// The downloaded file for a video, or nil. A dictionary lookup — fine to call from view bodies.
    func localFile(for videoID: String) -> URL? {
        store.filesByVideoID[videoID]
    }

    func job(for videoID: String) -> DownloadJob? {
        jobs.first { $0.id == videoID }
    }

    func progress(for videoID: String) -> Double {
        progressByVideoID[videoID] ?? 0
    }

    /// Downloads waiting or in progress — the Downloads tab's badge.
    var activeCount: Int {
        jobs.count(where: \.isActive)
    }

    // MARK: - Commands

    /// Queues `video` for download at the quality set in Settings. No-op when it's already
    /// downloaded or on its way; a failed job is retried.
    func download(_ video: Video) {
        guard localFile(for: video.id) == nil else { return }
        if let index = jobs.firstIndex(where: { $0.id == video.id }) {
            guard !jobs[index].isActive else { return }
            jobs[index].status = .queued
        } else {
            jobs.append(DownloadJob(video: video, status: .queued))
        }
        startQueued()
    }

    /// Stops a download (or dismisses a failed one) and discards what was fetched.
    func cancel(videoID: String) {
        tasks[videoID]?.cancel()
        tasks[videoID] = nil
        runTokens[videoID] = nil
        jobs.removeAll { $0.id == videoID }
        progressByVideoID[videoID] = nil
        startQueued()
    }

    /// Deletes a downloaded file.
    func delete(videoID: String) {
        guard let entry = store.entries.first(where: { $0.videoID == videoID }) else { return }
        store.delete(entry)
    }

    // MARK: - Queue

    private func startQueued() {
        for job in jobs where job.status == .queued {
            guard tasks.count < Self.maxConcurrent else { return }
            let video = job.video
            let token = UUID()
            setStatus(.downloading, for: video.id)
            runTokens[video.id] = token
            tasks[video.id] = Task { [weak self] in
                await self?.run(video, token: token)
            }
        }
    }

    private func setStatus(_ status: DownloadJob.Status, for videoID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == videoID }) else { return }
        jobs[index].status = status
    }

    private func run(_ video: Video, token: UUID) async {
        beginBackgroundTime(for: video.id)
        let workDirectory = Self.temporaryDirectory.appendingPathComponent(video.id, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
            endBackgroundTime(for: video.id)
        }

        do {
            let fileURL = try await fetch(video, workDirectory: workDirectory)
            await store.add(video: video, fileURL: fileURL)
            log.info("download[\(video.id, privacy: .public)] done")
            guard runTokens[video.id] == token else { return }
            jobs.removeAll { $0.id == video.id }
        } catch {
            // `cancel(videoID:)` dropped the token: nothing of this run is left to update.
            guard runTokens[video.id] == token else {
                log.info("download[\(video.id, privacy: .public)] cancelled")
                return
            }
            log.error("download[\(video.id, privacy: .public)] failed: \(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            setStatus(.failed(message), for: video.id)
        }
        progressByVideoID[video.id] = nil
        tasks[video.id] = nil
        runTokens[video.id] = nil
        startQueued()
    }

    /// Asks iOS for the short grace period it grants after the app leaves the screen, so a
    /// download that is nearly done can finish. The expiration handler must end the task —
    /// iOS kills an app that lets one run out.
    private func beginBackgroundTime(for videoID: String) {
        endBackgroundTime(for: videoID)
        backgroundTasks[videoID] = UIApplication.shared.beginBackgroundTask(withName: "download-\(videoID)") { [weak self] in
            Task { @MainActor [weak self] in self?.endBackgroundTime(for: videoID) }
        }
    }

    private func endBackgroundTime(for videoID: String) {
        guard let task = backgroundTasks.removeValue(forKey: videoID), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }

    /// Steps 1–4 of the class comment. Returns the finished file in the Documents folder.
    private func fetch(_ video: Video, workDirectory: URL) async throws -> URL {
        let allowsCellular = preferences.allowCellularDownloads
        if !allowsCellular, pathMonitor.currentPath.usesInterfaceType(.cellular),
           !pathMonitor.currentPath.usesInterfaceType(.wifi) {
            throw DownloadError.cellularNotAllowed
        }

        let stream = try await streams.resolveStream(videoID: video.id)
        try Task.checkCancellation()

        let maxHeight = preferences.downloadQuality.heightCap ?? 720
        let videoFile = workDirectory.appendingPathComponent("video.ts")
        let audioFile = workDirectory.appendingPathComponent("audio.ts")
        let videoID = video.id
        let videoShare = Self.videoShare

        // Detached so the playlist parsing and file writes stay off the main actor (CLAUDE.md
        // §15.12); the cancellation handler forwards `cancel(videoID:)` into it.
        let transfer = Task.detached(priority: .utility) { [weak self] () -> Bool in
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let service = HLSDownloadService(allowsCellular: allowsCellular)
            let plan = try await service.plan(masterURL: stream.hlsURL, maxHeight: maxHeight)
            let progress = DownloadProgress(
                videoTotal: plan.videoSegments.count,
                audioTotal: plan.audioSegments?.count ?? 0,
                videoShare: plan.audioSegments == nil ? 1 : videoShare
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.publishProgress(fraction, for: videoID) }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await service.download(plan.videoSegments, to: videoFile) { progress.videoWritten($0) }
                }
                if let audioSegments = plan.audioSegments {
                    group.addTask {
                        try await service.download(audioSegments, to: audioFile) { progress.audioWritten($0) }
                    }
                }
                try await group.waitForAll()
            }
            return plan.audioSegments != nil
        }
        let hasSeparateAudio = try await withTaskCancellationHandler {
            try await transfer.value
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()

        setStatus(.saving, for: video.id)
        let muxed = workDirectory.appendingPathComponent("output.mp4")
        try await mux(video: videoFile, audio: hasSeparateAudio ? audioFile : nil, to: muxed)
        try Task.checkCancellation()

        let destination = Self.destination(for: video)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: muxed, to: destination)
        return destination
    }

    /// Progress arrives per segment from two tracks; this keeps the bar from moving backwards
    /// and drops updates for a job that was cancelled meanwhile.
    private func publishProgress(_ fraction: Double, for videoID: String) {
        guard runTokens[videoID] != nil, fraction > (progressByVideoID[videoID] ?? 0) else { return }
        progressByVideoID[videoID] = fraction
    }

    // MARK: - Muxing

    /// Joins the downloaded tracks into one MP4 with `ffmpeg -c copy` — a repackaging, no
    /// re-encode, so it takes seconds and loses no quality.
    ///
    /// YouTube's HLS segments are MPEG-TS video and ADTS AAC audio, neither of which AVFoundation
    /// can read from a local file, so `AVAssetExportSession` isn't an option. `aac_adtstoasc`
    /// rewrites the audio headers into the form MP4 requires (it passes other audio through);
    /// `+faststart` puts the index at the front so other apps can start playing immediately.
    private func mux(video: URL, audio: URL?, to output: URL) async throws {
        var args = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "warning", "-i", video.path]
        if let audio {
            args += ["-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"]
        }
        args += ["-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart", output.path]
        let exitCode = await FFmpegRunner.shared.run(args)
        log.info("ffmpeg exit=\(exitCode, privacy: .public)")
        guard exitCode == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw DownloadError.conversionFailed
        }
    }

    // MARK: - Files

    private static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    /// Clears partial downloads left behind when the app was killed mid-download.
    private static func removeTemporaryFiles() {
        let directory = temporaryDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// `Documents/<title> [<id>].mp4` — a name that still means something once the file is in
    /// another app, with the ID keeping two videos of the same title apart.
    private static func destination(for video: Video) -> URL {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let title = video.title
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let name = title.isEmpty ? video.id : "\(title.prefix(80)) [\(video.id)]"
        return DownloadsStore.downloadsDirectory().appendingPathComponent(name).appendingPathExtension("mp4")
    }
}
