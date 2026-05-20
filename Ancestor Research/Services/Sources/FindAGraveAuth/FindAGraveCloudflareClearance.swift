import Foundation
import WebKit
import os

/// Non-interactive WKWebView that acquires a Cloudflare clearance cookie
/// for Find a Grave. WKWebView executes the JS challenge that Cloudflare
/// serves on first contact; once the challenge resolves, the
/// `cf_clearance` cookie lands in WKHTTPCookieStore and we extract it for
/// URLSession reuse. Spec §22.
///
/// Usage:
///     let cookies = try await FindAGraveCloudflareClearance.acquire()
///     // cookies includes cf_clearance + cf_bm + supporting Cloudflare cookies
///
/// Failure modes (acquire throws):
///   - timeout (30s) — Cloudflare took too long or didn't resolve
///   - challenge — the page never finished loading
///
/// Failure is recoverable: callers should clear the cookie store and try
/// again on the next research run. Worst case is "Find a Grave produces no
/// results" which is the pre-WKWebView baseline.
@MainActor
final class FindAGraveCloudflareClearance: NSObject, WKNavigationDelegate {

    enum AcquisitionError: Error {
        case timeout
        case noClearanceCookie
    }

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FindAGraveClearance")
    private var continuation: CheckedContinuation<[HTTPCookie], Error>?
    private var webView: WKWebView?
    private var pollTask: Task<Void, Never>?
    private var finished = false

    static let entryURL = URL(string: "https://www.findagrave.com/")!
    /// Cloudflare's JS challenge typically resolves in 3–5 seconds; allow
    /// generous headroom for slow networks. Beyond 30s it's probably stuck.
    static let timeout: Duration = .seconds(30)
    /// Poll interval for cf_clearance cookie presence. WKHTTPCookieStore is
    /// queried this often while the challenge runs.
    static let pollInterval: Duration = .milliseconds(500)

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
            // Use a non-default data store so we start fresh — a leftover
            // cookie from a prior failed attempt shouldn't masquerade as a
            // successful clearance. New ephemeral store per acquisition.
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
            // Offscreen frame — Cloudflare's JS reads viewport metrics, so
            // give it a plausible desktop size rather than zero.
            let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: config)
            webView.navigationDelegate = self
            self.webView = webView
            logger.info("Acquiring Find a Grave Cloudflare clearance via WKWebView")
            webView.load(URLRequest(url: Self.entryURL))
            pollTask = Task { [weak self] in
                await self?.pollUntilClearanceOrTimeout()
            }
        }
    }

    private func pollUntilClearanceOrTimeout() async {
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { return }
            if await checkForClearance() { return }
        }
        // Deadline passed.
        finish(.failure(AcquisitionError.timeout))
    }

    /// Returns true if cf_clearance is now present (and finish has been
    /// called); false to keep polling.
    private func checkForClearance() async -> Bool {
        guard let webView else { return false }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let fagCookies = cookies.filter { $0.domain.contains("findagrave.com") }
        guard fagCookies.contains(where: { $0.name == "cf_clearance" }) else { return false }
        logger.info("Captured \(fagCookies.count) Find a Grave cookies (including cf_clearance)")
        finish(.success(fagCookies))
        return true
    }

    private func finish(_ result: Result<[HTTPCookie], Error>) {
        guard !finished else { return }
        finished = true
        pollTask?.cancel()
        let continuation = self.continuation
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation?.resume(with: result)
    }

    // WKNavigationDelegate — used purely for diagnostic logging; the
    // cookie polling above is what actually drives completion.

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.logger.info("WKWebView finished navigating; polling continues for cf_clearance")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.logger.warning("WKWebView navigation failed: \(error.localizedDescription)")
        }
    }
}
