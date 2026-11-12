import Foundation
import OSLog

/// What to fetch to save one video: the segment URLs of the chosen video variant and, when the
/// stream keeps audio in a separate rendition (YouTube's normal layout), of its audio track.
/// The URLs are signed and time-limited — in memory only (CLAUDE.md §2.6).
nonisolated struct HLSDownloadPlan: Sendable {
    let videoSegments: [URL]
    /// `nil` when the video variant's segments already carry the audio.
    let audioSegments: [URL]?
    /// Short side of the chosen variant's picture (720 for 1280×720), for logs.
    let height: Int
}

nonisolated enum HLSDownloadError: LocalizedError {
    case liveStream
    case unsupportedStream

    var errorDescription: String? {
        switch self {
        case .liveStream: return String(localized: "Live streams can't be downloaded.")
        case .unsupportedStream: return String(localized: "This video can't be downloaded.")
        }
    }
}

/// Saves the HLS stream the player plays (`StreamService`, `VISIONOS` client) to disk: reads the
/// master playlist, picks an H.264 variant within a height cap, and fetches its segments in
/// order into one file per track. `DownloadManager` then joins the tracks into an MP4 with
/// ffmpeg.
///
/// **Why the HLS stream and not direct files:** YouTube's direct `videoplayback` formats (what
/// yt-dlp and the old download stack fetched) are Proof-of-Origin gated — without a token the
/// CDN serves the first minute and then answers 403. The HLS segments have no such gate, which
/// is also why playback uses them (CLAUDE.md §7).
///
/// `nonisolated`: everything here is network and file I/O. Call it from a `Task.detached` so it
/// stays off the main actor (CLAUDE.md §15.12).
nonisolated final class HLSDownloadService: Sendable {
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HLSDownloadService")

    /// Segments fetched at once per track.
    private static let concurrency = 6
    /// How far past the next segment to write we fetch ahead. Bounds the memory held when one
    /// early segment is slow and later ones are already in.
    private static let window = 16
    private static let attemptsPerSegment = 4

    /// - Parameter allowsCellular: `false` keeps every request off cellular data.
    init(allowsCellular: Bool) {
        // Ephemeral with no URL cache: video segments must not be mirrored into a disk cache.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.allowsCellularAccess = allowsCellular
        configuration.httpMaximumConnectionsPerHost = Self.concurrency
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Plan

    /// Reads the master playlist at `masterURL` and the chosen renditions' playlists.
    ///
    /// Picks the best H.264 variant whose short side is within `maxHeight` (the smallest one when
    /// none fits). H.264 because it plays everywhere an exported MP4 might go; YouTube's HLS
    /// carries it up to 1080p.
    func plan(masterURL: URL, maxHeight: Int) async throws -> HLSDownloadPlan {
        let master = try await text(at: masterURL)
        var audioGroups: [String: [(uri: String, isDefault: Bool)]] = [:]
        var variants: [(url: URL, height: Int, bandwidth: Int, isH264: Bool, audioGroup: String?)] = []
        var pending: [String: String]?

        for line in master.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = Self.attributes(in: line)
                guard attributes["TYPE"] == "AUDIO",
                      let group = attributes["GROUP-ID"],
                      let uri = attributes["URI"] else { continue }
                audioGroups[group, default: []].append((uri, attributes["DEFAULT"] == "YES"))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = Self.attributes(in: line)
            } else if !line.hasPrefix("#"), let attributes = pending {
                pending = nil
                guard let url = URL(string: line, relativeTo: masterURL)?.absoluteURL else { continue }
                let size = (attributes["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
                variants.append((
                    url: url,
                    height: size.min() ?? 0,
                    bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                    isH264: (attributes["CODECS"] ?? "").contains("avc1"),
                    audioGroup: attributes["AUDIO"]
                ))
            }
        }

        let h264 = variants.filter(\.isH264)
        let pool = h264.isEmpty ? variants : h264
        let fitting = pool.filter { $0.height <= maxHeight }
        let chosen = fitting.max { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
            ?? pool.min { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
        guard let chosen else { throw HLSDownloadError.unsupportedStream }

        let videoSegments = try await segments(at: chosen.url)
        var audioSegments: [URL]?
        if let group = chosen.audioGroup, let renditions = audioGroups[group], !renditions.isEmpty {
            // Several renditions in a group are dubs; `DEFAULT=YES` marks the original track.
            let rendition = renditions.first(where: \.isDefault) ?? renditions[0]
            guard let url = URL(string: rendition.uri, relativeTo: masterURL)?.absoluteURL else {
                throw HLSDownloadError.unsupportedStream
            }
            audioSegments = try await segments(at: url)
        }
        log.info("plan: \(chosen.height, privacy: .public)p video=\(videoSegments.count, privacy: .public) segments audio=\(audioSegments?.count ?? 0, privacy: .public) segments")
        return HLSDownloadPlan(videoSegments: videoSegments, audioSegments: audioSegments, height: chosen.height)
    }

    /// Segment URLs of a media playlist, in play order — an `EXT-X-MAP` init section first when
    /// the rendition is fragmented MP4, so the concatenated file is self-contained.
    private func segments(at playlistURL: URL) async throws -> [URL] {
        let playlist = try await text(at: playlistURL)
        var urls: [URL] = []
        var isComplete = false
        for line in playlist.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("#EXT-X-ENDLIST") {
                isComplete = true
            } else if line.hasPrefix("#EXT-X-KEY:"), Self.attributes(in: line)["METHOD"] != "NONE" {
                throw HLSDownloadError.unsupportedStream
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = Self.attributes(in: line)["URI"],
                   let url = URL(string: uri, relativeTo: playlistURL)?.absoluteURL {
                    urls.append(url)
                }
            } else if !line.hasPrefix("#"), let url = URL(string: line, relativeTo: playlistURL)?.absoluteURL {
                urls.append(url)
            }
        }
        // No end marker means the playlist is still growing: a live stream.
        guard isComplete else { throw HLSDownloadError.liveStream }
        guard !urls.isEmpty else { throw HLSDownloadError.unsupportedStream }
        return urls
    }

    /// Parses an HLS attribute list (`KEY=value,KEY="quoted, with commas"`). YouTube's URIs
    /// contain commas, so splitting on `,` alone would cut them apart.
    static func attributes(in line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var quoted = false
        for character in line[line.index(after: colon)...] {
            if character == "\"" {
                quoted.toggle()
            } else if character == "=", !readingValue {
                readingValue = true
            } else if character == ",", !quoted {
                result[key] = value
                key = ""
                value = ""
                readingValue = false
            } else if readingValue {
                value.append(character)
            } else {
                key.append(character)
            }
        }
        if !key.isEmpty { result[key] = value }
        return result
    }

    // MARK: - Segments

    /// Fetches `urls` a few at a time and appends them to `file` in order.
    ///
    /// - Parameter onSegment: called after each segment is written, with the number written so far.
    func download(_ urls: [URL], to file: URL, onSegment: @escaping @Sendable (Int) -> Void) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            var written = 0
            var inFlight = 0
            var fetched: [Int: Data] = [:]
            while written < urls.count {
                while inFlight < Self.concurrency, next < urls.count, next - written < Self.window {
                    let index = next
                    let url = urls[index]
                    group.addTask { (index, try await self.data(at: url)) }
                    next += 1
                    inFlight += 1
                }
                guard let (index, data) = try await group.next() else { break }
                inFlight -= 1
                fetched[index] = data
                while let ready = fetched.removeValue(forKey: written) {
                    try handle.write(contentsOf: ready)
                    written += 1
                    onSegment(written)
                }
            }
        }
    }

    /// One segment, retried with a growing pause — a dropped connection or a brief suspension in
    /// the background shouldn't fail a long download.
    private func data(at url: URL) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<Self.attemptsPerSegment {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1 << (attempt - 1)))
            }
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                log.notice("segment: HTTP \(status, privacy: .public) (attempt \(attempt + 1, privacy: .public))")
                lastError = URLError(.badServerResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                log.notice("segment: \(error.localizedDescription, privacy: .public) (attempt \(attempt + 1, privacy: .public))")
                lastError = error
            }
        }
        throw lastError
    }

    private func text(at url: URL) async throws -> String {
        let data = try await data(at: url)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw HLSDownloadError.unsupportedStream
        }
        return text
    }
}
