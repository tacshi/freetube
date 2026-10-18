import Foundation
import Combine
import WebKit
import OSLog

/// Drives the `WKWebView`-based login flow per CLAUDE.md §9.
/// - Loads `accounts.google.com`.
/// - Watches for redirects to `youtube.com` after sign-in.
/// - Reads cookies from the login web view's own (ephemeral) `httpCookieStore`.
/// - Verifies all required cookies (`SAPISID`, `__Secure-3PAPISID`, `LOGIN_INFO`, `SID`, `HSID`,
///   `SSID`, `APISID`) are present before storing the cookie header in Keychain.
///
/// **Cookie capture is event-driven, not navigation-driven.** YouTube writes its session cookies
/// to the store asynchronously, and several of them land during in-page (SPA) navigations that
/// never fire `didCommit` / `didFinish`. Reading the store only from navigation callbacks left
/// the flow stuck on "Finishing sign-in…" whenever the last cookie arrived after `didFinish`.
/// We therefore also observe the cookie store (`WKHTTPCookieStoreObserver`) and re-check on
/// every change, plus a watchdog that re-runs the passive YouTube sign-in handshake once and
/// finally surfaces a failure instead of spinning forever.
@available(iOS 17.0, *)
@MainActor
final class LoginCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case awaitingCredentials
        case verifying
        case succeeded
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func resetState() {
        state = .idle
        watchdog?.cancel()
        watchdog = nil
    }

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginCoordinator")
    private let session = SessionManager.shared

    /// Set once the required cookie set has been captured; every later trigger is a no-op.
    private var didCaptureSession = false
    /// Serializes `captureCookies` — the store observer can fire many times in a burst.
    private var isCapturing = false
    /// A cookie change arrived while a capture was in flight; re-read once it finishes.
    private var recaptureRequested = false
    /// Number of times we re-ran the passive sign-in handshake (`startURL`). Capped so a
    /// genuinely broken account can't loop forever.
    private var bounceCount = 0
    private static let maxBounces = 2
    private weak var observedCookieStore: WKHTTPCookieStore?
    private weak var webView: WKWebView?
    private var watchdog: Task<Void, Never>?

    /// Start URL that tells Google "this is a YouTube sign-in" via the `service=youtube` and
    /// `continue=youtube.com/signin?...` parameters. Without these, accounts.google.com just
    /// returns to `myaccount.google.com` after successful login and never visits YouTube — so
    /// no YouTube cookies (SAPISID, LOGIN_INFO, etc.) are ever set in the WKWebView's data
    /// store, and the login flow silently captures nothing. Forcing the post-login bounce to
    /// `youtube.com` is the same trick yt-dlp / NewPipe / Invidious use for browser-based auth.
    ///
    /// `passive=true` also makes this URL the right *recovery* target: once the Google session
    /// exists, loading it again skips the form and replays the `accounts.youtube.com/SetSID` →
    /// `youtube.com/signin` handshake, which is what mints `LOGIN_INFO` and the `.youtube.com`
    /// copies of the SID family. Loading plain `youtube.com/` does not.
    static let startURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.google.com"
        components.path = "/ServiceLogin"
        components.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "uilel", value: "3"),
            URLQueryItem(name: "passive", value: "true"),
            URLQueryItem(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=%2F")
        ]
        guard let url = components.url else {
            preconditionFailure("Static login URL components are invalid")
        }
        return url
    }()
    static let signedInHostFragment = "youtube.com"

    /// Seconds to wait on youtube.com for the cookie set before replaying the handshake, and
    /// then before giving up with a visible error.
    private static let bounceAfter: Duration = .seconds(6)
    private static let failAfter: Duration = .seconds(20)

    func handleNavigation(to url: URL?, in webView: WKWebView) {
        guard !didCaptureSession else { return }
        guard let url else {
            log.debug("[login] handleNavigation called with nil url")
            return
        }
        self.webView = webView
        observeCookies(in: webView)
        log.info("[login] nav → host=\(url.host ?? "?", privacy: .public) path=\(url.path, privacy: .public)")

        let host = url.host?.lowercased() ?? ""
        // EU users get YouTube's cookie-consent interstitial before the session cookies are
        // set. Leave it interactive — the verifying overlay would cover the button they need.
        if host == "consent.youtube.com" {
            log.info("[login] on YouTube consent page — waiting for user")
            return
        }
        if host.contains(Self.signedInHostFragment) {
            if state != .verifying {
                log.info("[login] reached youtube.com — entering verifying state, watching cookie store")
                state = .verifying
                startWatchdog()
            }
            Task { await captureCookies(from: webView) }
            return
        }
        if isPostSignInGoogleURL(url) {
            replaySignInHandshake(reason: "landed on post-sign-in Google page \(host)\(url.path)")
        }
    }

    /// Heuristic for "Google login completed, now on an account-management page". When we see
    /// one of these, we know the credentials were accepted but the continue redirect to
    /// youtube.com didn't happen — so we replay the passive handshake.
    private func isPostSignInGoogleURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "myaccount.google.com" || host == "www.google.com" { return true }
        if host == "accounts.google.com" {
            // accounts.google.com/b/0/ManageAccount, /InteractiveLogin/CheckCookie, etc. show up
            // after a successful interactive sign-in.
            let path = url.path.lowercased()
            return path.contains("manageaccount") || path.contains("checkcookie") || path.contains("/b/")
        }
        return false
    }

    /// Reloads `startURL`. With a live Google session this is a redirect-only round trip
    /// through `SetSID` and `youtube.com/signin` that sets the YouTube-scoped session cookies.
    private func replaySignInHandshake(reason: String) {
        guard let webView else { return }
        guard bounceCount < Self.maxBounces else {
            log.notice("[login] not replaying sign-in handshake (already did \(self.bounceCount, privacy: .public)): \(reason, privacy: .public)")
            return
        }
        bounceCount += 1
        log.info("[login] replaying passive YouTube sign-in handshake (#\(self.bounceCount, privacy: .public)): \(reason, privacy: .public)")
        webView.load(URLRequest(url: Self.startURL))
    }

    // MARK: - Cookie store observation

    private func observeCookies(in webView: WKWebView) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        guard observedCookieStore !== store else { return }
        observedCookieStore?.remove(self)
        store.add(self)
        observedCookieStore = store
    }

    private func stopObserving() {
        observedCookieStore?.remove(self)
        observedCookieStore = nil
        watchdog?.cancel()
        watchdog = nil
    }

    /// Bounded wait while on youtube.com: replay the handshake once if the cookie set is still
    /// incomplete, then fail visibly rather than leave the user on an endless spinner.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.bounceAfter)
            guard let self, !Task.isCancelled, !self.didCaptureSession else { return }
            let missing = await self.missingRequiredCookies()
            guard !missing.isEmpty else {
                if let webView = self.webView { await self.captureCookies(from: webView) }
                return
            }
            self.replaySignInHandshake(reason: "still missing [\(missing.joined(separator: ","))] after \(Self.bounceAfter)")

            try? await Task.sleep(for: Self.failAfter)
            guard !Task.isCancelled, !self.didCaptureSession else { return }
            let stillMissing = await self.missingRequiredCookies()
            guard !stillMissing.isEmpty else {
                if let webView = self.webView { await self.captureCookies(from: webView) }
                return
            }
            let names = stillMissing.joined(separator: ", ")
            self.log.error("[login] giving up — required cookies never arrived: [\(names, privacy: .public)]")
            self.state = .failed(String(localized: "Signed in, but YouTube didn't issue the session cookies (missing: \(names)). Please try again."))
        }
    }

    private func missingRequiredCookies() async -> [String] {
        guard let store = observedCookieStore else { return CookieStore.requiredCookieNames.sorted() }
        return CookieStore.missingRequiredNames(in: await store.allCookies())
    }

    fileprivate func cookieStoreDidChange() {
        guard !didCaptureSession, state == .verifying, let webView else { return }
        Task { await captureCookies(from: webView) }
    }

    // MARK: - Capture

    private func captureCookies(from webView: WKWebView) async {
        guard !didCaptureSession else { return }
        guard !isCapturing else {
            recaptureRequested = true
            return
        }
        isCapturing = true
        defer { isCapturing = false }

        repeat {
            recaptureRequested = false
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let missing = CookieStore.missingRequiredNames(in: cookies)
            guard missing.isEmpty else {
                // Cheap, single-line progress log — the store observer fires per cookie, so
                // the full inventory is only dumped once on success.
                log.info("[login] captureCookies: total=\(cookies.count, privacy: .public) missing=[\(missing.joined(separator: ","), privacy: .public)] — waiting for more cookies")
                continue
            }
            logInventory(cookies)
            guard let header = CookieStore.shared.makeHeader(from: cookies) else {
                log.notice("[login] required cookie set incomplete after dedupe — waiting for next cookie change")
                continue
            }
            didCaptureSession = true
            stopObserving()
            log.info("[login] required cookies present, signing in (header length=\(header.count, privacy: .public))")
            await session.signIn(with: header)
            state = .succeeded
            log.info("[login] sign-in succeeded — state=.succeeded")
            return
        } while recaptureRequested && !didCaptureSession
    }

    /// Per-cookie dump — name, domain, path, flags, value length. **Cookie values are never
    /// logged** (CLAUDE.md §2: cookies are sensitive, value bytes must not touch logs).
    private func logInventory(_ cookies: [HTTPCookie]) {
        let sorted = cookies.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
        log.info("[login] === full cookie inventory (\(sorted.count, privacy: .public)) ===")
        for c in sorted {
            let flags: [String] = [
                c.isSecure ? "secure" : nil,
                c.isHTTPOnly ? "httpOnly" : nil,
                c.isSessionOnly ? "session" : nil
            ].compactMap { $0 }
            let flagText = flags.isEmpty ? "" : " flags=[\(flags.joined(separator: ","))]"
            let scope = c.domain.hasSuffix("youtube.com")
                ? "[yt]"
                : (c.domain.hasSuffix("google.com") ? "[g]" : "[other]")
            log.info("[login] cookie \(scope, privacy: .public) name=\(c.name, privacy: .public) domain=\(c.domain, privacy: .public) path=\(c.path, privacy: .public) valueLen=\(c.value.count, privacy: .public)\(flagText, privacy: .public)")
        }
        log.info("[login] === end cookie inventory ===")
    }

    /// Wipe WKWebView data store at sign-out time (called from `AccountViewModel.signOut`).
    static func clearWebData() async {
        let types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases
        ]
        await WKWebsiteDataStore.default()
            .removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}

// MARK: - WKHTTPCookieStoreObserver

@available(iOS 17.0, *)
extension LoginCoordinator: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            self?.cookieStoreDidChange()
        }
    }
}
