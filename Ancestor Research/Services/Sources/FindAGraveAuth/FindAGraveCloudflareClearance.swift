import Foundation
import WebKit
import AppKit
import os

/// Non-interactive WKWebView that acquires a Cloudflare clearance cookie
/// for Find a Grave. WKWebView executes the JS challenge that Cloudflare
/// serves on memorial pages; once the challenge resolves, the
/// `cf_clearance` cookie lands in WKHTTPCookieStore and we extract it for
/// URLSession reuse. Spec §22.
///
/// Usage:
///     let cookies = try await FindAGraveCloudflareClearance.acquire()
///     // cookies includes cf_clearance + cf_bm + supporting Cloudflare cookies
///
/// **Implementation notes** (post-diagnostic, 2026-05-20):
///
/// - Entry URL hits `/memorial/search` not `/`. Only the `/memorial/*`
///   paths trigger Cloudflare's managed JS challenge — the homepage
///   serves a plain 200, so a WKWebView pointed there will navigate
///   successfully but never produce `cf_clearance` (the cookie exists
///   only as the answer to a passed challenge). Verified by direct curl:
///   `GET /` → 200 / no challenge; `GET /memorial/<id>` → 403 with
///   `cf-mitigated: challenge` and `<title>Just a moment...</title>`.
///
/// - `customUserAgent` is set to the same Safari UA URLSession uses for
///   downstream FAG requests. Cloudflare binds `cf_clearance` to
///   `(UA, IP)`; if WKWebView solves the challenge under WKWebView's
///   default UA, URLSession requests under the Safari UA constant would
///   re-challenge and the cookie would be useless.
///
/// - The WKWebView attaches to an offscreen `NSWindow` so JS challenge
///   environment checks (`document.visibilityState`, viewport metrics,
///   screen properties) see a real window-server surface. A purely
///   detached WKWebView has no surface and stumps some challenge
///   variants.
///
/// - 60s timeout. Cold WKWebView spin-up + managed challenge JS +
///   UA-CH negotiation can stack to 20-30s on slow networks; 30s was
///   too tight on the initial diagnostic.
///
/// Failure modes (acquire throws):
///   - timeout — Cloudflare took too long or escalated to Turnstile/CAPTCHA
///
/// Failure is recoverable: the source's `ensureCloudflareClearance` logs
/// and degrades to "no FAG results" — same as the pre-WKWebView baseline.
@MainActor
final class FindAGraveCloudflareClearance: NSObject, WKNavigationDelegate {

    enum AcquisitionError: Error {
        case timeout
        case noClearanceCookie
    }

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FindAGraveClearance")
    private var continuation: CheckedContinuation<[HTTPCookie], Error>?
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var pollTask: Task<Void, Never>?
    private var finished = false

    /// The `/memorial/search` path triggers Cloudflare's managed challenge
    /// reliably (the homepage `/` does not — see header comment).
    static let entryURL = URL(string: "https://www.findagrave.com/memorial/search?firstname=John&lastname=Smith")!
    /// Managed challenge + cold WebKit spin-up + UA-CH negotiation can
    /// stack to 20-30s on slow networks. 60s gives generous headroom.
    static let timeout: Duration = .seconds(60)
    /// Poll interval for cf_clearance cookie presence.
    static let pollInterval: Duration = .milliseconds(500)
    /// Diagnostic log throttle — print cookie names this often while
    /// polling so a stuck acquisition is visible without a debugger.
    static let diagnosticLogInterval: Duration = .seconds(5)
    /// Safari user-agent — kept in sync with `FindAGraveSource.userAgent`.
    /// Cloudflare binds `cf_clearance` to (UA, IP), so both surfaces must
    /// send the same UA or the cookie won't carry across.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15"

    /// Acquire a fresh set of Find a Grave Cloudflare cookies. Spawns a
    /// hidden WKWebView, waits for the JS challenge to complete, returns
    /// the cookies. Caller is responsible for persisting via
    /// `FindAGraveCookieStore`.
    static func acquire() async throws -> [HTTPCookie] {
        let runner = FindAGraveCloudflareClearance()
        return try await runner.run()
    }

    private func run() async throws -> [HTTPCookie] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            // Ephemeral store per acquisition — a leftover failed cookie
            // shouldn't masquerade as a successful clearance.
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
            let frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            let webView = WKWebView(frame: frame, configuration: config)
            webView.navigationDelegate = self
            // Same UA URLSession uses. Cloudflare binds cf_clearance to
            // (UA, IP); WKWebView's default UA differs from Safari's,
            // so without this override the captured cookie would fail
            // URLSession's later UA check and re-challenge.
            webView.customUserAgent = Self.userAgent

            // Attach to an offscreen NSWindow so JS challenge environment
            // checks (visibilityState, viewport, screen) see a real
            // window-server surface. The window is set far offscreen and
            // alpha 0 so it's never visible to the user.
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
            window.orderBack(nil)   // not makeKeyAndOrderFront — never steal focus
            self.hostWindow = window
            self.webView = webView

            logger.info("Acquiring Find a Grave Cloudflare clearance via WKWebView (entry=\(Self.entryURL.absoluteString))")
            webView.load(URLRequest(url: Self.entryURL))
            pollTask = Task { [weak self] in
                await self?.pollUntilClearanceOrTimeout()
            }
        }
    }

    private func pollUntilClearanceOrTimeout() async {
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        var nextDiagnostic = ContinuousClock.now.advanced(by: Self.diagnosticLogInterval)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { return }
            if await checkForClearance() { return }
            // Throttled diagnostic — what's actually in the cookie jar
            // right now? Helps distinguish "challenge running but not
            // finished" from "page never engaged Cloudflare at all".
            if ContinuousClock.now >= nextDiagnostic {
                nextDiagnostic = ContinuousClock.now.advanced(by: Self.diagnosticLogInterval)
                await logCookieDiagnostic()
            }
        }
        // Deadline passed — emit a full diagnostic before failing so the
        // unified log captures what state we ended in. Distinguishes
        // "stuck on challenge" (title="Just a moment…"), "Turnstile
        // escalation" (Turnstile widget HTML), and "IP block" (different
        // Cloudflare error page).
        await logTimeoutDiagnostic()
        finish(.failure(AcquisitionError.timeout))
    }

    /// Returns true if acquisition succeeded (and finish has been called);
    /// false to keep polling.
    ///
    /// Two success paths:
    ///   1. **Challenge served and passed** — Cloudflare issued a JS
    ///      challenge, WKWebView solved it, `cf_clearance` cookie present.
    ///   2. **No challenge served** — Cloudflare risk-scored this request
    ///      as low risk and served the real page directly. No
    ///      `cf_clearance` minted because there was nothing to solve, but
    ///      `__cf_bm` (bot-management) cookie present + page title
    ///      indicates the real Find a Grave page. This is the common case
    ///      when WKWebView's Safari fingerprint passes silently.
    ///
    /// Path 2 was missing from the original implementation, which only
    /// looked for `cf_clearance` and timed out forever when Cloudflare
    /// didn't bother challenging — a real-world observed case.
    private func checkForClearance() async -> Bool {
        guard let webView else { return false }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let fagCookies = cookies.filter { $0.domain.contains("findagrave.com") }

        // Path 1: challenge passed.
        if fagCookies.contains(where: { $0.name == "cf_clearance" }) {
            logger.info("Captured \(fagCookies.count) Find a Grave cookies (challenge passed; cf_clearance present)")
            finish(.success(fagCookies))
            return true
        }

        // Path 2: no challenge served. Need __cf_bm (Cloudflare engaged
        // at all) AND the page actually loaded (title contains
        // "find a grave" but not "just a moment...").
        guard fagCookies.contains(where: { $0.name == "__cf_bm" }) else { return false }
        let titleResult = try? await webView.evaluateJavaScript("document.title") as? String
        let title = titleResult ?? ""
        let lowerTitle = title.lowercased()
        if lowerTitle.contains("find a grave") && !lowerTitle.contains("just a moment") {
            logger.info("Captured \(fagCookies.count) Find a Grave cookies (no challenge served; title='\(title)')")
            finish(.success(fagCookies))
            return true
        }
        return false
    }

    private func logCookieDiagnostic() async {
        guard let webView else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let fagCookies = cookies.filter { $0.domain.contains("findagrave.com") }
        let names = fagCookies.map(\.name).sorted().joined(separator: ", ")
        logger.debug("Cloudflare clearance still pending; FAG cookies so far: [\(names.isEmpty ? "<none>" : names)]")
    }

    private func logTimeoutDiagnostic() async {
        guard let webView else { return }
        let title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? "<unavailable>"
        let html: String = await {
            let snippet = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
            return String(snippet.prefix(400)).replacingOccurrences(of: "\n", with: " ")
        }()
        logger.warning("Cloudflare clearance timeout. Document title: '\(title)'. HTML prefix: \(html)")
    }

    private func finish(_ result: Result<[HTTPCookie], Error>) {
        guard !finished else { return }
        finished = true
        pollTask?.cancel()
        let continuation = self.continuation
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        hostWindow?.orderOut(nil)
        hostWindow?.contentView = nil
        hostWindow = nil
        webView = nil
        continuation?.resume(with: result)
    }

    // WKNavigationDelegate — diagnostic logging only; the cookie polling
    // above is what drives completion.

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let url = webView.url?.absoluteString ?? "<no url>"
            self.logger.info("WKWebView didFinish url=\(url); polling continues for cf_clearance")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.logger.warning("WKWebView navigation failed: \(error.localizedDescription)")
        }
    }
}
