import Testing
import Foundation
@testable import Ancestor_Research

/// T1-C2 — the Find a Grave WKWebView fetch retries a *transient* failure
/// (load timeout / load error) once, but never an unresolved Cloudflare
/// challenge (a retry re-pays the JS-challenge cost and lands on the same
/// wall) or an extraction failure (the page loaded). The policy is exercised
/// through `withTransientRetry` with an injected operation — no live browser.
@MainActor
struct FindAGraveRetryTests {

    typealias Fetcher = FindAGraveBrowserFetcher

    @Test func retriesOnceOnTransientThenSucceeds() async throws {
        var calls = 0
        let result = try await Fetcher.withTransientRetry(backoff: .zero) {
            calls += 1
            if calls == 1 { throw Fetcher.FetchError.timeout }
            return "ok"
        }
        #expect(result == "ok")
        #expect(calls == 2, "one transient timeout → exactly one retry")
    }

    @Test func doesNotRetryUnresolvedChallenge() async {
        var calls = 0
        do {
            _ = try await Fetcher.withTransientRetry(backoff: .zero) { () async throws -> String in
                calls += 1
                throw Fetcher.FetchError.challengeUnresolved(title: "Just a moment...")
            }
            Issue.record("expected the challenge error to propagate")
        } catch let error as Fetcher.FetchError {
            #expect(!error.isTransient)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(calls == 1, "an unresolved challenge must not be retried")
    }

    @Test func doesNotRetryExtractionFailure() async {
        var calls = 0
        do {
            _ = try await Fetcher.withTransientRetry(backoff: .zero) { () async throws -> String in
                calls += 1
                throw Fetcher.FetchError.extractionFailed
            }
            Issue.record("expected extraction failure to propagate")
        } catch { /* expected */ }
        #expect(calls == 1, "the page loaded — a retry won't help")
    }

    @Test func boundedByMaxAttempts() async {
        var calls = 0
        do {
            _ = try await Fetcher.withTransientRetry(maxAttempts: 2, backoff: .zero) { () async throws -> String in
                calls += 1
                throw Fetcher.FetchError.loadFailed("network down")
            }
            Issue.record("expected to give up and throw after the ceiling")
        } catch { /* expected */ }
        #expect(calls == 2, "no more than maxAttempts tries")
    }

    @Test func classifiesTransientVersusPermanent() {
        #expect(Fetcher.FetchError.timeout.isTransient)
        #expect(Fetcher.FetchError.loadFailed("x").isTransient)
        #expect(!Fetcher.FetchError.challengeUnresolved(title: "x").isTransient)
        #expect(!Fetcher.FetchError.extractionFailed.isTransient)
    }
}
