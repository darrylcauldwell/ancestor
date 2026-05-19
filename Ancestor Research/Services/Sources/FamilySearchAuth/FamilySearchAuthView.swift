import SwiftUI
import WebKit
import os

/// Sheet that embeds a WKWebView for the user to sign in to FamilySearch.
///
/// FamilySearch's auth runs entirely in the web view — the app never sees
/// the username or password. On successful login, session cookies (including
/// `fssessionid`) appear in the WKHTTPCookieStore; we extract them and hand
/// off to FamilySearchCookieStore for persistence.
struct FamilySearchAuthView: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to FamilySearch")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    onComplete(false)
                    dismiss()
                }
            }
            .padding()
            .background(.regularMaterial)

            Divider()

            FamilySearchWebView(onCapture: {
                onComplete(true)
                dismiss()
            })
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 700, idealHeight: 760)
    }
}

private struct FamilySearchWebView: NSViewRepresentable {
    let onCapture: () -> Void

    // Hits the standard FamilySearch sign-in flow. After successful auth
    // FamilySearch redirects through several intermediate URLs before
    // landing on the homepage; we detect completion by the presence of
    // the fssessionid cookie rather than by URL pattern, since the cookie
    // is the authoritative signal for whether the API will authorise us.
    private static let loginURL = URL(string: "https://www.familysearch.org/auth/familysearch?returnUrl=https%3A%2F%2Fwww.familysearch.org%2Fen%2F")!

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Default (persistent) data store so the user is auto-recognised
        // on subsequent re-auth presentations rather than re-typing
        // password every 1–2h when session cookies expire.
        config.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCapture: () -> Void
        private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearchAuth")
        private var captured = false

        init(onCapture: @escaping () -> Void) {
            self.onCapture = onCapture
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                guard !self.captured else { return }
                self.checkForLoginCompletion(webView)
            }
        }

        private func checkForLoginCompletion(_ webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !self.captured else { return }
                    let fsCookies = cookies.filter { $0.domain.contains("familysearch.org") }
                    guard fsCookies.contains(where: { $0.name == "fssessionid" }) else { return }
                    self.captured = true
                    self.logger.info("Captured \(fsCookies.count) FamilySearch cookies; signalling login complete")
                    let callback = self.onCapture
                    Task {
                        await FamilySearchCookieStore.shared.store(fsCookies)
                        await MainActor.run {
                            callback()
                        }
                    }
                }
            }
        }
    }
}
