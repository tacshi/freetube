import Foundation
import OSLog

/// Reports watch progress to the signed-in YouTube account, the way YouTube's own players do.
protocol WatchProgressServicing: Sendable {
    /// Tracking endpoints for `videoID`, bound to the signed-in account.
    func tracking(videoID: String) async throws -> WatchTracking
    /// GETs a tracking URL with `parameters` merged into its query (existing keys replaced).
    func ping(_ url: URL, parameters: [String: String]) async
}

/// Reads `playbackTracking` from the signed-in watch page (`ytInitialPlayerResponse`) and sends
/// the stats pings with the account cookies — the same mechanism yt-dlp's `--mark-watched`
/// uses, extended with periodic watchtime pings carrying the current position (`cmt`), so the
/// account's history and resume point stay in sync with the app.
///
/// These are undocumented YouTube endpoints; failures are logged and otherwise ignored —
/// playback never depends on them. Cookie values are never logged (CLAUDE.md §2.5).
final class WatchProgressService: WatchProgressServicing {
    private let client: YouTubeKitClient
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "WatchProgressService")

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    nonisolated init(client: YouTubeKitClient = .shared, session: URLSession = .shared) {
        self.client = client
        self.session = session
    }

    func tracking(videoID: String) async throws -> WatchTracking {
        let cookies = client.cookies
        guard !cookies.isEmpty else { throw YouTubeServiceError.notAuthenticated }
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "bpctr", value: "9999999999"),
            URLQueryItem(name: "has_verified", value: "1")
        ]
        guard let url = components?.url else { throw YouTubeServiceError.streamExtractionFailed }
        var request = URLRequest(url: url)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            log.error("tracking: watch page failed id=\(videoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard let html = String(data: data, encoding: .utf8),
              let playerJSON = Self.jsonObject(after: "ytInitialPlayerResponse = ", in: html),
              let player = try? JSONSerialization.jsonObject(with: Data(playerJSON.utf8)) as? [String: Any],
              let tracking = player["playbackTracking"] as? [String: Any],
              let playback = Self.baseURL(tracking["videostatsPlaybackUrl"]),
              let watchtime = Self.baseURL(tracking["videostatsWatchtimeUrl"])
        else {
            log.error("tracking: no playbackTracking id=\(videoID, privacy: .public)")
            throw YouTubeServiceError.decoding(CocoaError(.propertyListReadCorrupt))
        }
        log.info("tracking: ready id=\(videoID, privacy: .public)")
        return WatchTracking(playbackURL: playback, watchtimeURL: watchtime)
    }

    func ping(_ url: URL, parameters: [String: String]) async {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var items = (components.queryItems ?? []).filter { parameters[$0.name] == nil }
        items += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        guard let target = components.url else { return }
        var request = URLRequest(url: target)
        request.setValue(client.cookies, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.debug("ping \(url.path, privacy: .public) cmt=\(parameters["cmt"] ?? "-", privacy: .public) → HTTP \(status, privacy: .public)")
        } catch {
            log.error("ping \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func baseURL(_ value: Any?) -> URL? {
        ((value as? [String: Any])?["baseUrl"] as? String).flatMap(URL.init(string:))
    }

    /// The balanced `{…}` JSON object that follows `marker` in `text` (string-aware brace match).
    private static func jsonObject(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker),
              let open = text[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
