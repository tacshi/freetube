import Foundation
import OSLog

/// Downloads a YouTube caption track (WebVTT from the timedtext endpoint) and parses it into
/// cues. The track URLs come from `StreamService`'s `/player` response and don't need a
/// Proof-of-Origin token.
protocol CaptionServicing: Sendable {
    func fetchCues(for track: CaptionTrack) async throws -> [CaptionCue]
}

final class CaptionService: CaptionServicing {
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "CaptionService")

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchCues(for track: CaptionTrack) async throws -> [CaptionCue] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: track.url)
        } catch {
            log.error("captions: request failed lang=\(track.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let text = String(data: data, encoding: .utf8) else {
            log.error("captions: HTTP \(status, privacy: .public) lang=\(track.id, privacy: .public)")
            throw YouTubeServiceError.decoding(CocoaError(.fileReadCorruptFile))
        }
        let cues = WebVTTParser.parse(text)
        log.info("captions: loaded \(cues.count, privacy: .public) cues lang=\(track.id, privacy: .public)")
        return cues
    }
}
