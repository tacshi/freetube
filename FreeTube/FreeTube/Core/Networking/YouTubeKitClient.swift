import Foundation
import OSLog
import YouTubeKit

/// Holds the single `YouTubeModel` instance the rest of the app talks to. Services depend on this
/// type for the model handle and for cookie application.
///
/// Per CLAUDE.md §6: `YouTubeKit` must not be imported anywhere outside `Core/Networking/`. Domain
/// types (Video, Channel, …) are mapped from YouTubeKit response types inside the services that
/// own each response.
nonisolated final class YouTubeKitClient: @unchecked Sendable {
    static let shared = YouTubeKitClient()

    /// Default iOS-client model. Returns HLS manifest URLs when available (great for music videos),
    /// but its per-format `/videoplayback` URLs are PoT-protected → segment fetches 403.
    let model = YouTubeModel()

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "YouTubeKitClient")

    private init() {}

    /// Visitor token YouTube issued to this install (empty until `ensureVisitorData()` ran).
    /// `StreamService` sends it as `X-Goog-Visitor-Id`; without one YouTube answers stream
    /// requests with "Sign in to confirm you're not a bot".
    var visitorData: String { model.visitorData }

    /// Current cookie header string as YouTubeKit holds it. Read-only mirror of
    /// `model.cookies` so callers outside this file don't have to touch YouTubeKit types
    /// directly (services without a YouTubeKit import — e.g. our raw-HTTP fallbacks — can
    /// still inject the auth header).
    var cookies: String { model.cookies }

    /// Drops the cached visitor token so the next request fetches a fresh one. Called by
    /// `SessionManager` after clearing cookies — the visitor token YouTube issued may have been
    /// tied to the now-expired auth.
    func clearVisitorData() {
        model.visitorData = ""
    }

    /// Pushes the latest cookie header string into `YouTubeModel`. Called by `SessionManager`.
    func applyCookies(_ cookies: String) {
        model.cookies = cookies
        model.alwaysUseCookies = !cookies.isEmpty

        // Sanity-log the auth state. We never log cookie values themselves — only presence /
        // length — and we ask the model to compute SAPISIDHASH (without keeping the value) to
        // confirm YouTubeKit's auth-header generator agrees that the cookie set is usable.
        let hashOK = !cookies.isEmpty && model.generateSAPISIDHASHForCookies(cookies) != nil
        let containsSAPISID = cookies.range(of: "SAPISID=") != nil
        let containsSID = cookies.range(of: "; SID=") != nil || cookies.hasPrefix("SID=")
        log.info("[client] applyCookies length=\(cookies.count, privacy: .public) state=\(cookies.isEmpty ? "anon" : "auth", privacy: .public) alwaysUseCookies=\(self.model.alwaysUseCookies, privacy: .public) hasSAPISID=\(containsSAPISID, privacy: .public) hasSID=\(containsSID, privacy: .public) sapisidHashGenerable=\(hashOK, privacy: .public)")
    }

    /// `VideoInfosResponse` requires a `visitorData` token. YouTubeKit doesn't fetch one for you;
    /// the canonical way to obtain it (per `YouTubeModel.visitorData` docs) is to run a `SearchResponse`
    /// first and pull `visitorData` out of the response. We do that once at app bootstrap and stash
    /// the token on the shared model so subsequent video requests auto-inject it.
    func ensureVisitorData() async {
        guard model.visitorData.isEmpty else { return }
        do {
            let response = try await SearchResponse.sendThrowingRequest(
                youtubeModel: model,
                data: [.query: "music"]
            )
            if let visitorData = response.visitorData, !visitorData.isEmpty {
                model.visitorData = visitorData
                log.info("Visitor data bootstrapped")
            } else {
                log.error("SearchResponse returned no visitorData")
            }
        } catch {
            log.error("Visitor-data bootstrap failed: \(String(describing: error), privacy: .public)")
        }
    }
}
