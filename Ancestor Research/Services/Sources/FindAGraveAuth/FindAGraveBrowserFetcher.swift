import Foundation
import WebKit
import AppKit
import os

/// Headless WKWebView-based fetcher for Find a Grave.
///
/// **Why this exists.** FAG is fronted by Cloudflare Bot Management with
/// risk-scoring that strongly favours Safari-shaped traffic:
/// - URLSession (different TLS fingerprint, no `Sec-CH-UA` client hints,
///   no JS engine) gets challenged frequently with 403s that URLSession
///   can't solve.
/// - WKWebView (Safari's WebKit engine — same TLS, same headers, same
///   JS, same cookie state) typically gets the real page directly. When
///   Cloudflare *does* challenge a WKWebView request, the JS challenge
///   resolves invisibly within seconds.
///
/// Mixing the two surfaces is structurally fragile (see commit 089d51c
/// header): a `cf_clearance` cookie captured by WKWebView doesn't reliably
/// carry over to URLSession because Cloudflare re-fingerprints TLS on each
/// request. So **all FAG fetches go through this fetcher** — search AJAX,
/// detail HTML, anything else FAG-related. Spec §22.
///
/// **Performance tradeoff.** Each fetch creates a fresh WKWebView, loads
/// the URL, waits for any post-load JS settling, extracts content, tears
/// down. Per-fetch cost is ~5-10s vs URLSession's ~500ms. FAG's existing
/// 500ms rate limit was generous for URLSession; with WKWebView the
/// effective throughput is ~1 fetch / 5-10s, which is fine for the
/// research workflow (a typical Ernest-style run does ~5-15 FAG fetches).
///
/// **Cookie persistence.** Uses `WKWebsiteDataStore.default()` so cookies
/// accumulate across fetches and across app launches. `__cf_bm` typically
/// lasts 30 min; `cf_clearance` (when minted) up to 30 days. Subsequent
/// fetches reuse them automatically — only the first fetch in a fresh
/// session pays the JS-challenge cost.
@MainActor
final class FindAGraveBrowserFetcher: NSObject, WKNavigationDelegate {

    enum FetchError: Error {
        case timeout
        case extractionFailed
        case loadFailed(String)
        case challengeUnresolved(title: String)
    }

    private enum Extract { case html, text }

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FindAGraveBrowserFetcher")
    private var continuation: CheckedContinuation<String, Error>?
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var finished = false
    private var extractMode: Extract = .html

    /// Real Safari UA — matches `FindAGraveSource.userAgent` and
    /// `FindAGraveCloudflareClearance.userAgent`. All three need the same
    /// UA so Cloudflare's UA-binding stays consistent.
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15"
    /// Total deadline including challenge resolution + settle.
    nonisolated static let defaultTimeout: Duration = .seconds(45)
    /// Pause after `didFinish` before extracting content. Cloudflare's JS
    /// challenge — when served — resolves AFTER the initial didFinish,
    /// then redirects to the real page (which fires its own didFinish).
    /// A short settle catches the redirect; without it we'd extract the
    /// challenge page's content.
    nonisolated static let settleAfterDidFinish: Duration = .seconds(3)

    /// Fetch a URL via WKWebView, returning `document.documentElement.outerHTML`.
    /// Use for HTML detail pages (memorials).
    static func fetchHTML(url: URL, timeout: Duration = defaultTimeout) async throws -> String {
        try await FindAGraveBrowserFetcher().run(url: url, extract: .html, timeout: timeout)
    }

    /// Fetch a URL via WKWebView, returning `document.body.innerText`.
    /// Use for AJAX/JSON endpoints — WKWebView's built-in JSON viewer
    /// puts the raw JSON in the body's text content.
    static func fetchText(url: URL, timeout: Duration = defaultTimeout) async throws -> String {
        try await FindAGraveBrowserFetcher().run(url: url, extract: .text, timeout: timeout)
    }

    private func run(url: URL, extract: Extract, timeout: Duration) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.extractMode = extract

            // Persistent data store — cookies accumulate across fetches
            // and survive app launches. This is what makes the second
            // FAG fetch fast: `__cf_bm` is still valid, no challenge.
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.default()
            let frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            let webView = WKWebView(frame: frame, configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = Self.userAgent

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.contentView = webView
            window.alphaValue = 0.0
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.orderBack(nil)
            self.hostWindow = window
            self.webView = webView

            logger.info("FAG fetch: \(url.absoluteString) (extract=\(extract == .html ? "html" : "text"))")
            webView.load(URLRequest(url: url))

            // Overall deadline.
            timeoutTask = Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return }
                await self?.handleTimeout()
            }
        }
    }

    private func handleTimeout() async {
        guard !finished else { return }
        // Try to extract whatever we have — sometimes we get a real page
        // but didFinish-via-redirect didn't fire and our settle window
        // never opened.
        if let webView, await isLikelyRealPage(webView) {
            await extractAndFinish()
            return
        }
        let title = (try? await webView?.evaluateJavaScript("document.title") as? String) ?? "<unavailable>"
        logger.warning("FAG fetch timeout. Title='\(title)'")
        finish(.failure(FetchError.timeout))
    }

    /// True when title indicates a real FAG page is loaded (not a
    /// challenge interstitial). Used as the post-load gate before
    /// extraction.
    private func isLikelyRealPage(_ webView: WKWebView) async -> Bool {
        let title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
        let lower = title.lowercased()
        // "Just a moment..." is Cloudflare's challenge title. Anything
        // else with FAG branding is the real page.
        if lower.contains("just a moment") { return false }
        return lower.contains("find a grave")
    }

    private func extractAndFinish() async {
        guard let webView else {
            finish(.failure(FetchError.extractionFailed))
            return
        }
        let script: String
        switch extractMode {
        case .html: script = "document.documentElement.outerHTML"
        case .text: script = "document.body.innerText"
        }
        let result: String? = try? await webView.evaluateJavaScript(script) as? String
        if let result, !result.isEmpty {
            logger.info("FAG fetch extracted \(result.count) chars (mode=\(self.extractMode == .html ? "html" : "text"))")
            finish(.success(result))
        } else {
            finish(.failure(FetchError.extractionFailed))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        settleTask?.cancel()
        let cont = self.continuation
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        hostWindow?.orderOut(nil)
        hostWindow?.contentView = nil
        hostWindow = nil
        webView = nil
        cont?.resume(with: result)
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await self.handleDidFinish()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.logger.warning("FAG fetch navigation failed: \(error.localizedDescription)")
            self.finish(.failure(FetchError.loadFailed(error.localizedDescription)))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.logger.warning("FAG fetch provisional navigation failed: \(error.localizedDescription)")
            self.finish(.failure(FetchError.loadFailed(error.localizedDescription)))
        }
    }

    private func handleDidFinish() async {
        guard !finished, let webView else { return }
        // Two cases at didFinish:
        // (a) The real page loaded directly (no challenge served). We can
        //     extract immediately.
        // (b) Cloudflare's challenge page loaded. We need to wait for the
        //     JS to redirect to the real page.
        //
        // The settle period handles both — if (a), the extra wait is
        // harmless; if (b), it gives the challenge time to resolve before
        // we try extracting.
        if await isLikelyRealPage(webView) {
            await extractAndFinish()
            return
        }
        // Looks like a challenge or non-final page. Wait for settle,
        // then try again. If still not the real page, the timeout will
        // eventually fire.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleAfterDidFinish)
            if Task.isCancelled { return }
            guard let self else { return }
            await self.checkAfterSettle()
        }
    }

    private func checkAfterSettle() async {
        guard !finished, let webView else { return }
        if await isLikelyRealPage(webView) {
            await extractAndFinish()
        }
        // Otherwise: keep waiting for didFinish-after-redirect or timeout.
    }
}
