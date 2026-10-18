import SwiftUI
import WebKit
import OSLog

@available(iOS 17.0, *)
struct LoginWebView: UIViewRepresentable {
    @ObservedObject var coordinator: LoginCoordinator

    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginWebView")

    /// Hides WebAuthn from Google's sign-in pages so they offer the password challenge instead
    /// of a passkey.
    ///
    /// **Why.** iOS only lets Safari and apps holding the browser public-key-credential
    /// entitlement use passkeys inside a web view. Our `WKWebView` still *exposes*
    /// `PublicKeyCredential`, so Google picks the passkey path, finds no usable platform
    /// authenticator, falls through to the cross-device (hybrid) flow, and dead-ends on
    /// "Something went wrong — Make sure Bluetooth is on". With WebAuthn absent, Google treats
    /// the page like a browser without passkey support and goes straight to the password step.
    /// Injected at document start in every frame (Google's challenge UI runs in iframes too).
    private static let disablePasskeysScript = WKUserScript(
        source: """
        (() => {
          try {
            Object.defineProperty(window, 'PublicKeyCredential', {
              value: undefined, writable: false, configurable: false
            });
          } catch (e) {}
          try {
            if (navigator.credentials) {
              const unavailable = () => Promise.reject(
                new DOMException('Passkeys are unavailable in this browser.', 'NotAllowedError')
              );
              navigator.credentials.get = unavailable;
              navigator.credentials.create = unavailable;
            }
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    func makeCoordinator() -> Delegate { Delegate(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // **Ephemeral data store on purpose.** Reusing the shared `.default()` store made every
        // sign-in attempt instantly "succeed" by capturing stale cookies left over in WKWebView
        // from a previous (often half-completed) session — those cookies passed the name-set
        // check in `CookieStore.makeHeader` but were no longer valid, so YouTubeKit's
        // `AccountInfosResponse` came back `isDisconnected=true`. A nonPersistent store starts
        // cookie-empty, which forces Google to show the actual sign-in form and guarantees
        // every captured cookie comes from THIS session.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(Self.disablePasskeysScript)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: LoginCoordinator.startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No-op; the coordinator does the work.
    }

    final class Delegate: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        init(parent: LoginWebView) { self.parent = parent }

        /// WebKit's private `_WKNavigationActionPolicyAllowWithoutTryingAppLink`
        /// (`WKNavigationActionPolicyAllow + 2`): load the URL here and never hand it to an app
        /// that claims it as a universal link. Firefox for iOS uses the same value.
        private static let allowWithoutTryingAppLink =
            WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

        /// **Keeps the sign-in inside this web view.** After the password / 2-Step step, Google
        /// redirects to `www.youtube.com/signin`, which is the hop that mints YouTube's session
        /// cookies. With a plain `.allow`, iOS treats that redirect as a universal link and, when
        /// the YouTube app is installed, opens the app instead — the redirect leaves our web view,
        /// the cookies are never set here, and the sheet is stranded on the 2-Step page.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                decisionHandler(Self.allowWithoutTryingAppLink)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didStart: \(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didCommit: \(webView.url?.absoluteString ?? "?", privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didFinish: \(webView.url?.absoluteString ?? "?", privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            LoginWebView.log.error("[webview] didFail: \(error.localizedDescription, privacy: .public) url=\(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LoginWebView.log.error("[webview] didFailProvisional: \(error.localizedDescription, privacy: .public) url=\(webView.url?.absoluteString ?? "?", privacy: .public)")
        }
    }
}
