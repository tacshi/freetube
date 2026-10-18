import Foundation
import OSLog

/// Resolves the URL `AVPlayer` streams for a video.
protocol StreamServicing: Sendable {
    /// HLS manifest URL and caption tracks for `videoID`. URLs are signed and time-limited —
    /// keep them in memory only (CLAUDE.md §2.6).
    func resolveStream(videoID: String) async throws -> ResolvedStream
}

/// Calls YouTube's innertube `/player` endpoint as the **`VISIONOS`** client and returns
/// `streamingData.hlsManifestUrl` plus the caption tracks (`captions.…captionTracks`, as WebVTT
/// timedtext URLs — also playable without a PoT). For ordinary videos and live streams that manifest's segments
/// play without a Proof-of-Origin token, so `AVPlayer` can stream it directly — the same client
/// yt-dlp uses for its HLS formats (`INNERTUBE_CLIENTS["visionos"]` in
/// `yt_dlp/extractor/youtube/_base.py`; keep the context below in sync with it).
///
/// **Why raw `URLSession` and not YouTubeKit:** `VideoInfosResponse.decodeData` only understands
/// the HTML watch page (it scrapes `ytInitialPlayerResponse` + the player JS path), so pointing a
/// `YouTubeModel` at `/player` throws "Couldn't get player path." on every call. And the clients
/// YouTubeKit does ship don't stream: the watch page has HLS only for live, the iOS client returns
/// only PoT-locked adaptive formats, and the TVHTML5 clients answer `UNPLAYABLE` / `ERROR`.
///
/// Anonymous on purpose: never sends the signed-in cookies (YouTube rejects web-session cookies
/// on this request). Requires the install's visitor token — without it YouTube replies
/// "Sign in to confirm you're not a bot".
final class StreamService: StreamServicing {
    private let client: YouTubeKitClient
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "StreamService")

    private static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
    private static let clientName = "VISIONOS"
    private static let clientNameID = "101"
    private static let clientVersion = "1.02"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    nonisolated init(client: YouTubeKitClient = .shared, session: URLSession = .shared) {
        self.client = client
        self.session = session
    }

    func resolveStream(videoID: String) async throws -> ResolvedStream {
        log.info("resolve start id=\(videoID, privacy: .public)")
        await client.ensureVisitorData()
        do {
            return try await requestHLS(videoID: videoID)
        } catch YouTubeServiceError.notAuthenticated {
            // "Confirm you're not a bot" usually means the visitor token went stale. Mint a
            // fresh one and try once more before giving up.
            log.notice("resolve: bot check for \(videoID, privacy: .public), refreshing visitor token")
            client.clearVisitorData()
            await client.ensureVisitorData()
            return try await requestHLS(videoID: videoID)
        }
    }

    private func requestHLS(videoID: String) async throws -> ResolvedStream {
        guard let endpoint = Self.endpoint else { throw YouTubeServiceError.streamExtractionFailed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.clientNameID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        let visitorData = client.visitorData
        if !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": Self.clientName,
                    "clientVersion": Self.clientVersion,
                    "deviceMake": "Apple",
                    "deviceModel": "RealityDevice17,1",
                    "userAgent": Self.userAgent,
                    "osName": "visionOS",
                    "osVersion": "26.5.23O471",
                    "hl": Locale.current.language.languageCode?.identifier ?? "en"
                ]
            ],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("resolve: request failed id=\(videoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            log.error("resolve: HTTP \(status, privacy: .public) id=\(videoID, privacy: .public)")
            throw status == 429 ? YouTubeServiceError.rateLimited : YouTubeServiceError.streamExtractionFailed
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("resolve: unreadable JSON id=\(videoID, privacy: .public)")
            throw YouTubeServiceError.decoding(CocoaError(.propertyListReadCorrupt))
        }

        let playability = json["playabilityStatus"] as? [String: Any]
        let playStatus = playability?["status"] as? String ?? "?"
        let reason = playability?["reason"] as? String ?? ""
        let hls = ((json["streamingData"] as? [String: Any])?["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
        log.info("resolve: id=\(videoID, privacy: .public) status=\(playStatus, privacy: .public) reason=\(reason, privacy: .public) hls=\(hls != nil, privacy: .public)")

        if let hls {
            return ResolvedStream(hlsURL: hls, captions: Self.captionTracks(in: json))
        }
        switch playStatus {
        case "LOGIN_REQUIRED":
            throw YouTubeServiceError.notAuthenticated
        case "UNPLAYABLE", "ERROR":
            throw YouTubeServiceError.videoUnavailable
        default:
            throw YouTubeServiceError.streamExtractionFailed
        }
    }

    /// `captions.playerCaptionsTracklistRenderer.captionTracks`, each pointed at WebVTT.
    private static func captionTracks(in json: [String: Any]) -> [CaptionTrack] {
        let renderer = (json["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let tracks = renderer?["captionTracks"] as? [[String: Any]] ?? []
        return tracks.compactMap { track in
            guard let base = track["baseUrl"] as? String,
                  let language = track["languageCode"] as? String,
                  var components = URLComponents(string: base.hasPrefix("/") ? "https://www.youtube.com" + base : base)
            else { return nil }
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "fmt" }
                + [URLQueryItem(name: "fmt", value: "vtt")]
            guard let url = components.url else { return nil }
            let nameJSON = track["name"] as? [String: Any]
            let name = nameJSON?["simpleText"] as? String
                ?? (nameJSON?["runs"] as? [[String: Any]])?.first?["text"] as? String
                ?? language
            let isAuto = (track["kind"] as? String) == "asr"
            return CaptionTrack(
                id: language + (isAuto ? ".asr" : ""),
                name: name,
                languageCode: language,
                isAutoGenerated: isAuto,
                url: url
            )
        }
    }
}
