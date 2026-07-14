import Testing
import Foundation
@testable import Ancestor_Research

/// FAMILYSEARCH_READ_LEG_PLAN #Change4 — OAuth foundation. Everything here
/// is offline: PKCE vectors, URL construction, callback grammar, token
/// parsing, expiry arithmetic, form encoding, and a fully-local loopback
/// round-trip. The live sign-in is exercised manually once FamilySearch
/// registers the redirect URI (§19 acceptance A1).
struct FamilySearchOAuthTests {

    // MARK: - PKCE (RFC 7636)

    @Test func pkceMatchesRFC7636TestVector() {
        // RFC 7636 appendix B: the canonical verifier/challenge pair.
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomVerifierIsBase64URLAndLongEnough() {
        let pkce = PKCEChallenge()
        // 32 random bytes → 43 base64url chars, RFC 7636's minimum length.
        #expect(pkce.verifier.count == 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        // Two generations never collide.
        #expect(PKCEChallenge().verifier != pkce.verifier)
    }

    // MARK: - Authorization URL

    @Test func authorizationURLCarriesAllRequiredParameters() throws {
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = FamilySearchOAuth.authorizationURL(
            environment: .beta,
            clientID: "test-app-key",
            redirectURI: "http://127.0.0.1:49877/familysearch-auth",
            pkce: pkce,
            state: "abc123"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "identbeta.familysearch.org")
        #expect(components.path == "/cis-web/oauth2/v3/authorization")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "test-app-key")
        #expect(items["redirect_uri"] == "http://127.0.0.1:49877/familysearch-auth")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "abc123")
    }

    @Test func environmentsResolveDocumentedHosts() {
        #expect(FamilySearchEnvironment.beta.apiHost == "apibeta.familysearch.org")
        #expect(FamilySearchEnvironment.production.identHost == "ident.familysearch.org")
        #expect(FamilySearchEnvironment.production.tokenEndpoint.absoluteString
            == "https://ident.familysearch.org/cis-web/oauth2/v3/token")
    }

    // MARK: - Callback grammar

    @Test func parseCallbackExtractsCodeAndState() {
        let cb = FamilySearchOAuth.parseCallback("/familysearch-auth?code=AUTH123&state=xyz")
        #expect(cb.code == "AUTH123")
        #expect(cb.state == "xyz")
        #expect(cb.error == nil)
    }

    @Test func parseCallbackSurfacesOAuthErrors() {
        let cb = FamilySearchOAuth.parseCallback(
            "/familysearch-auth?error=access_denied&error_description=User%20declined")
        #expect(cb.code == nil)
        #expect(cb.error == "access_denied: User declined")
    }

    // MARK: - Token response parsing + expiry

    @Test func parsesTokenResponseJSON() throws {
        let json = """
        {"access_token":"AT-1","token_type":"family_search","refresh_token":"RT-1","expires_in":86400}
        """
        let now = Date()
        let tokens = try FamilySearchOAuth.parseTokenResponse(Data(json.utf8), now: now)
        #expect(tokens.accessToken == "AT-1")
        #expect(tokens.refreshToken == "RT-1")
        #expect(tokens.expiresIn == 86400)
        #expect(!tokens.isExpired(now: now))
        // Expired one minute before the stated lifetime elapses (margin).
        #expect(tokens.isExpired(now: now.addingTimeInterval(86400)))
        #expect(!tokens.isExpired(now: now.addingTimeInterval(86400 - 120)))
    }

    @Test func missingExpiryTreatedAsOneConservativeHour() throws {
        let json = #"{"access_token":"AT-2","token_type":"family_search"}"#
        let now = Date()
        let tokens = try FamilySearchOAuth.parseTokenResponse(Data(json.utf8), now: now)
        #expect(tokens.refreshToken == nil)
        #expect(!tokens.isExpired(now: now.addingTimeInterval(1800)))
        #expect(tokens.isExpired(now: now.addingTimeInterval(3600)))
    }

    // MARK: - Form encoding

    @Test func formEncodingPercentEncodesReservedCharacters() {
        let body = FamilySearchOAuth.formURLEncoded([
            ("grant_type", "authorization_code"),
            ("redirect_uri", "http://127.0.0.1:49877/familysearch-auth"),
            ("code", "a+b/c=d&e f"),
        ])
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A49877%2Ffamilysearch-auth"))
        #expect(body.contains("code=a%2Bb%2Fc%3Dd%26e%20f"))
    }

    // MARK: - Request decision (CSRF guard — pure, deterministic)

    @Test func decideCapturesOnlyMatchingStateRedirect() {
        // The genuine redirect: GET, expected path, exact state → capture.
        let d = FamilySearchOAuth.decide(
            requestLine: "GET /familysearch-auth?code=REAL&state=real-state HTTP/1.1",
            expectedPath: "/familysearch-auth", expectedState: "real-state")
        #expect(d == .capture(FamilySearchOAuth.Callback(code: "REAL", state: "real-state", error: nil)))
    }

    @Test func decideIgnoresForgedState() {
        // CSRF guard: a local request (drive-by browser hit, another
        // process) without the expected state must NOT complete the flow —
        // even one carrying a plausible error message an attacker would use
        // to scare the user.
        let d = FamilySearchOAuth.decide(
            requestLine: "GET /familysearch-auth?error=Account%20locked&state=attacker HTTP/1.1",
            expectedPath: "/familysearch-auth", expectedState: "real-state")
        #expect(d == .ignore)
    }

    @Test func decideIgnoresWrongPathAndNonGET() {
        #expect(FamilySearchOAuth.decide(
            requestLine: "GET /favicon.ico HTTP/1.1",
            expectedPath: "/familysearch-auth", expectedState: "s") == .ignore)
        #expect(FamilySearchOAuth.decide(
            requestLine: "POST /familysearch-auth?code=X&state=s HTTP/1.1",
            expectedPath: "/familysearch-auth", expectedState: "s") == .ignore)
        #expect(FamilySearchOAuth.decide(
            requestLine: "garbage",
            expectedPath: "/familysearch-auth", expectedState: "s") == .ignore)
    }

    @Test func decideCapturesGenuineErrorRedirect() {
        // A real user-denied response carries our state too (RFC 6749) →
        // captured, so signIn can surface .authorizationDenied.
        let d = FamilySearchOAuth.decide(
            requestLine: "GET /familysearch-auth?error=access_denied&state=s HTTP/1.1",
            expectedPath: "/familysearch-auth", expectedState: "s")
        #expect(d == .capture(FamilySearchOAuth.Callback(code: nil, state: "s", error: "access_denied")))
    }

    // MARK: - Loopback receiver (fully local, two-phase API)
    //
    // These drive a real socket round-trip; run them serially so parallel
    // CPU contention can't confound the send/receive timing.
    @Suite(.serialized)
    struct LoopbackReceiver {

    /// Bind on an ephemeral port and return the receiver + bound port.
    private func boundReceiver(expectedState: String) async throws -> (LoopbackRedirectReceiver, UInt16) {
        let receiver = LoopbackRedirectReceiver()
        let port = try await receiver.startListening(
            port: 0, expectedPath: "/familysearch-auth", expectedState: expectedState)
        return (receiver, port)
    }

    /// A GET on a FRESH ephemeral session so requests never share a pooled
    /// connection — production redirects come from independent clients, and
    /// pooling forged+real onto one socket is a test-only artifact.
    private func freshGet(_ url: URL) async throws -> (Data, HTTPURLResponse?) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        return (data, response as? HTTPURLResponse)
    }

    @Test func loopbackReceiverDeliversMatchingRedirectOverRealSocket() async throws {
        // End-to-end wire plumbing: a genuine redirect to the bound port
        // is delivered to `awaitCallback`. The state-matching RULES are
        // covered deterministically by the pure `decide(...)` tests above;
        // this asserts only the socket→actor delivery, which the
        // pendingResult buffer makes order-independent. The response's HTTP
        // status/body is intentionally not asserted (browser-facing cosmetic
        // + TCP-timing sensitive).
        let (receiver, port) = try await boundReceiver(expectedState: "st9")
        async let callbackFuture = receiver.awaitCallback(timeout: .seconds(10))

        let url = URL(string: "http://127.0.0.1:\(port)/familysearch-auth?code=LOCAL1&state=st9")!
        _ = try? await freshGet(url)

        let callback = try await callbackFuture
        #expect(callback.code == "LOCAL1")
        #expect(callback.state == "st9")
    }

    @Test func loopbackReceiverTimesOutWhenNothingArrives() async throws {
        let (receiver, _) = try await boundReceiver(expectedState: "s")
        do {
            _ = try await receiver.awaitCallback(timeout: .milliseconds(150))
            Issue.record("Expected timeout")
        } catch let error as FamilySearchOAuth.OAuthError {
            #expect(error == .timedOut)
        }
    }
    } // end LoopbackReceiver suite

    // MARK: - Token store roundtrip (isolated Keychain item — never the
    // production one, so a test run can't clobber a real sign-in's tokens)

    private func testStore() -> FamilySearchTokenStore {
        FamilySearchTokenStore(service: "dev.dreamfold.Ancestor-Research.familysearch.oauth.tests")
    }

    @Test func tokenStoreRoundTripsExpiryGatesAndIsEnvironmentKeyed() async {
        let store = testStore()
        defer {
            Task { await store.clear(environment: .beta); await store.clear(environment: .production) }
        }
        let beta = FamilySearchTokenSet(
            accessToken: "AT-beta", refreshToken: "RT-beta",
            obtainedAt: Date(), expiresIn: 86400)
        await store.save(beta, environment: .beta)
        #expect(await store.load(environment: .beta) == beta)
        #expect(await store.validAccessToken(environment: .beta) == "AT-beta")
        // Environment isolation: beta tokens are invisible under production.
        #expect(await store.load(environment: .production) == nil)
        #expect(await store.validAccessToken(environment: .production) == nil)

        let stale = FamilySearchTokenSet(
            accessToken: "AT-old", refreshToken: nil,
            obtainedAt: Date(timeIntervalSinceNow: -90_000), expiresIn: 86400)
        await store.save(stale, environment: .beta)
        #expect(await store.validAccessToken(environment: .beta) == nil)

        await store.clear(environment: .beta)
        #expect(await store.load(environment: .beta) == nil)
    }

    @Test func refreshPreservesRefreshTokenWhenResponseOmitsIt() throws {
        // FS may omit refresh_token on a refresh response; parse keeps it
        // nil, and the refresh() wrapper re-attaches the prior one. Here we
        // pin the parse half (the wrapper is exercised live in A2).
        let json = #"{"access_token":"AT-new","token_type":"family_search","expires_in":3600}"#
        let parsed = try FamilySearchOAuth.parseTokenResponse(Data(json.utf8))
        #expect(parsed.refreshToken == nil)
        #expect(parsed.accessToken == "AT-new")
    }

    // MARK: - Single-flight gate

    @Test func signInCoordinatorRefusesConcurrentAttempts() async throws {
        let coordinator = FamilySearchSignInCoordinator()
        try await coordinator.begin()
        await #expect(throws: FamilySearchOAuth.OAuthError.signInAlreadyInProgress) {
            try await coordinator.begin()
        }
        await coordinator.end()
        // After end(), a fresh begin() succeeds.
        try await coordinator.begin()
        await coordinator.end()
    }
}
