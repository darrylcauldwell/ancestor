import Foundation
import CryptoKit
import Network
import Security
import AppKit
import os

/// FamilySearch official-API OAuth 2.0 (FAMILYSEARCH_READ_LEG_PLAN
/// #Change4; spec §15.2). Authorization-code + PKCE (S256) through the
/// system default browser and a loopback redirect — the flow FamilySearch
/// mandates for native apps (Unauthenticated Session and Client
/// Credentials are explicitly not available to our key).
///
/// The AppKey (client_id) is Confidential Information under the FSI
/// Developer Agreement: resolved at runtime from Keychain (Settings) with
/// a dev-only environment-variable fallback — never hardcoded, never
/// logged.
///
/// Security posture (hardened after the #Change4 adversarial review):
/// - Loopback listener binds 127.0.0.1 only, WITHOUT socket reuse, so a
///   port conflict is a hard visible failure, never silent co-binding
///   (redirect-hijack guard).
/// - Two-phase sign-in: the listener is confirmed bound-and-ready BEFORE
///   the browser opens; a bind failure aborts pre-browser.
/// - The listener completes only on a redirect carrying the matching
///   `state`; forged/garbage local requests are answered and ignored,
///   and the listener keeps waiting for the genuine redirect.
/// - Single-flight: a second concurrent sign-in is refused rather than
///   racing the first on the fixed port.

// MARK: - Environments

/// Spec §15.1 — environment is plugin config, not compile-time. Beta hosts
/// confirmed live 2026-07-14 (identbeta serves the OAuth error/login page;
/// apibeta routes /platform/records/personas to the search service).
/// Integration is omitted until its ident host is verified.
nonisolated enum FamilySearchEnvironment: String, CaseIterable, Sendable {
    case beta
    case production

    var identHost: String {
        switch self {
        case .beta: "identbeta.familysearch.org"
        case .production: "ident.familysearch.org"
        }
    }

    var apiHost: String {
        switch self {
        case .beta: "apibeta.familysearch.org"
        case .production: "api.familysearch.org"
        }
    }

    var authorizationEndpoint: URL {
        URL(string: "https://\(identHost)/cis-web/oauth2/v3/authorization")!
    }

    var tokenEndpoint: URL {
        URL(string: "https://\(identHost)/cis-web/oauth2/v3/token")!
    }
}

// MARK: - PKCE (RFC 7636)

nonisolated struct PKCEChallenge: Sendable, Equatable {
    let verifier: String
    let challenge: String
    static let method = "S256"

    /// Fresh random pair: 32 random bytes → 43-char base64url verifier.
    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        self.init(verifier: Data(bytes).fsBase64URLEncoded())
    }

    /// Deterministic pair from a known verifier (RFC 7636 appendix-B
    /// test vector exercisable in tests).
    init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).fsBase64URLEncoded()
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5), as PKCE requires.
    nonisolated func fsBase64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Token set

nonisolated struct FamilySearchTokenSet: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let obtainedAt: Date
    let expiresIn: Int?

    /// Conservative expiry: FS reportedly issues 24h access tokens but the
    /// spec flags the lifetime unverified (§15.2), so an absent
    /// `expires_in` is treated as one hour. 60s safety margin so a token
    /// isn't presented mid-flight at its exact expiry instant.
    func isExpired(now: Date = Date()) -> Bool {
        let lifetime = TimeInterval(expiresIn ?? 3600)
        return now >= obtainedAt.addingTimeInterval(lifetime - 60)
    }
}

// MARK: - Keychain-backed token + AppKey store

/// Mirrors `FamilySearchCookieStore`'s single-generic-password-item
/// pattern; separate service suffix so the OAuth stack and the retiring
/// cookie stack never collide.
///
/// Tokens are keyed by environment (account suffix), so a beta and a
/// production session never overwrite each other or get cross-presented.
/// `service` is injectable so tests address a throwaway Keychain item and
/// can never clobber a real sign-in's tokens.
actor FamilySearchTokenStore {
    static let productionService = "dev.dreamfold.Ancestor-Research.familysearch.oauth"
    static let shared = FamilySearchTokenStore()

    private let service: String
    private let appKeyAccount = "appkey"
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearchTokenStore")

    init(service: String = FamilySearchTokenStore.productionService) {
        self.service = service
    }

    private func tokensAccount(_ environment: FamilySearchEnvironment) -> String {
        "tokens.\(environment.rawValue)"
    }

    // MARK: Tokens (environment-keyed)

    func save(_ tokens: FamilySearchTokenSet, environment: FamilySearchEnvironment) {
        do {
            let data = try JSONEncoder().encode(tokens)
            writeKeychain(data, account: tokensAccount(environment))
            logger.info("Stored FamilySearch OAuth tokens for \(environment.rawValue, privacy: .public) (refresh token: \(tokens.refreshToken != nil))")
        } catch {
            logger.error("Failed to encode token set: \(error.localizedDescription)")
        }
    }

    func load(environment: FamilySearchEnvironment) -> FamilySearchTokenSet? {
        guard let data = readKeychain(account: tokensAccount(environment)) else { return nil }
        return try? JSONDecoder().decode(FamilySearchTokenSet.self, from: data)
    }

    func clear(environment: FamilySearchEnvironment) {
        deleteKeychain(account: tokensAccount(environment))
    }

    /// Non-expired access token for `environment`, or nil when
    /// absent/expired (callers route to refresh or re-auth).
    func validAccessToken(environment: FamilySearchEnvironment, now: Date = Date()) -> String? {
        guard let tokens = load(environment: environment), !tokens.isExpired(now: now) else { return nil }
        return tokens.accessToken
    }

    // MARK: AppKey (client_id — Confidential per the FSI agreement)

    func saveAppKey(_ key: String) {
        writeKeychain(Data(key.utf8), account: appKeyAccount)
    }

    /// Keychain first; `FAMILYSEARCH_BETA_APPKEY` environment variable as
    /// the dev-only fallback (the repo-root `.env` exports it for CLI
    /// contexts). Never logged.
    func appKey() -> String? {
        if let data = readKeychain(account: appKeyAccount),
           let key = String(data: data, encoding: .utf8),
           !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["FAMILYSEARCH_BETA_APPKEY"],
           !env.isEmpty {
            return env
        }
        return nil
    }

    func clearAppKey() {
        deleteKeychain(account: appKeyAccount)
    }

    // MARK: Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readKeychain(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("Keychain read failed with status \(status)")
            }
            return nil
        }
        return result as? Data
    }

    private func writeKeychain(_ data: Data, account: String) {
        deleteKeychain(account: account)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain write failed with status \(status)")
        }
    }

    private func deleteKeychain(account: String) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed with status \(status)")
        }
    }
}

// MARK: - Single-flight gate

/// Refuses a second concurrent interactive sign-in — two flows would race
/// on the fixed loopback port and cross-deliver each other's redirects.
actor FamilySearchSignInCoordinator {
    static let shared = FamilySearchSignInCoordinator()
    private var inProgress = false

    func begin() throws {
        guard !inProgress else { throw FamilySearchOAuth.OAuthError.signInAlreadyInProgress }
        inProgress = true
    }

    func end() { inProgress = false }
}

// MARK: - OAuth flow

nonisolated enum FamilySearchOAuth {

    /// The redirect URI registered with FamilySearch (loopback, fixed
    /// port — FS pre-registers the exact string, so this and the
    /// registration must always agree).
    static let redirectPort: UInt16 = 49877
    static let redirectPath = "/familysearch-auth"
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)\(redirectPath)" }

    enum OAuthError: Error, LocalizedError, Equatable {
        case noAppKey
        case authorizationDenied(String)
        case stateMismatch
        case missingCode
        case tokenExchangeFailed(status: Int, detail: String)
        case listenerFailed(String)
        case browserLaunchFailed
        case signInAlreadyInProgress
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noAppKey:
                "No FamilySearch AppKey configured — set it in Settings"
            case .authorizationDenied(let reason):
                "FamilySearch declined the sign-in: \(reason)"
            case .stateMismatch:
                "Sign-in state mismatch — possible interception; try again"
            case .missingCode:
                "FamilySearch returned no authorization code"
            case .tokenExchangeFailed(let status, let detail):
                "Token exchange failed (HTTP \(status)): \(detail)"
            case .listenerFailed(let reason):
                "Could not listen for the sign-in redirect: \(reason)"
            case .browserLaunchFailed:
                "Could not open the browser for FamilySearch sign-in"
            case .signInAlreadyInProgress:
                "A FamilySearch sign-in is already in progress"
            case .timedOut:
                "Timed out waiting for the FamilySearch sign-in"
            }
        }
    }

    // MARK: URL construction

    static func authorizationURL(
        environment: FamilySearchEnvironment,
        clientID: String,
        redirectURI: String,
        pkce: PKCEChallenge,
        state: String
    ) -> URL {
        var components = URLComponents(url: environment.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCEChallenge.method),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).fsBase64URLEncoded()
    }

    // MARK: Callback parsing (pure, testable)

    struct Callback: Equatable, Sendable {
        let code: String?
        let state: String?
        let error: String?
    }

    /// Parse the redirect's path+query ("/familysearch-auth?code=…&state=…"
    /// or "…?error=access_denied&error_description=…") into its OAuth
    /// parts. Pure so tests can pin the grammar without a socket.
    static func parseCallback(_ pathAndQuery: String) -> Callback {
        guard let components = URLComponents(string: pathAndQuery) else {
            return Callback(code: nil, state: nil, error: "unparseable redirect")
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        let explicitError = value("error").map { err in
            [err, value("error_description")].compactMap { $0 }.joined(separator: ": ")
        }
        return Callback(code: value("code"), state: value("state"), error: explicitError)
    }

    /// The receiver's decision for one HTTP request line — pure, so the
    /// security-critical rules (only GET, only the expected path, only a
    /// callback carrying our exact `state`) are deterministically testable
    /// without a live socket. `.capture` completes the flow; `.ignore`
    /// answers benignly and keeps listening.
    enum RequestDecision: Equatable, Sendable {
        case capture(Callback)
        case ignore
    }

    static func decide(requestLine: String, expectedPath: String, expectedState: String) -> RequestDecision {
        let parts = requestLine.split(separator: " ")
        guard requestLine.hasPrefix("GET "), parts.count >= 2 else { return .ignore }
        let pathAndQuery = String(parts[1])
        guard pathAndQuery.hasPrefix(expectedPath) else { return .ignore }
        let callback = parseCallback(pathAndQuery)
        // Only the genuine redirect carries our exact state (RFC 6749
        // returns state on both success and error responses). Forged or
        // stray local requests are ignored — keep listening.
        guard callback.state == expectedState else { return .ignore }
        return .capture(callback)
    }

    // MARK: Token exchange

    /// POST the authorization code + PKCE verifier to the token endpoint.
    /// The response body is never logged (it carries the tokens).
    static func exchangeCode(
        _ code: String,
        verifier: String,
        clientID: String,
        redirectURI: String,
        environment: FamilySearchEnvironment,
        session: URLSession = .shared
    ) async throws -> FamilySearchTokenSet {
        let form = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("code_verifier", verifier),
        ]
        return try await postTokenRequest(form: form, environment: environment, session: session)
    }

    /// Exchange a refresh token for a fresh access token.
    static func refresh(
        refreshToken: String,
        clientID: String,
        environment: FamilySearchEnvironment,
        session: URLSession = .shared
    ) async throws -> FamilySearchTokenSet {
        let form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]
        var tokens = try await postTokenRequest(form: form, environment: environment, session: session)
        // FS may omit the refresh token on refresh responses — keep the
        // one we already hold rather than dropping re-auth capability.
        if tokens.refreshToken == nil {
            tokens = FamilySearchTokenSet(
                accessToken: tokens.accessToken,
                refreshToken: refreshToken,
                obtainedAt: tokens.obtainedAt,
                expiresIn: tokens.expiresIn
            )
        }
        return tokens
    }

    private static func postTokenRequest(
        form: [(String, String)],
        environment: FamilySearchEnvironment,
        session: URLSession
    ) async throws -> FamilySearchTokenSet {
        var request = URLRequest(url: environment.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncoded(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // Error bodies are safe to surface (no tokens are issued on a
            // failure response); cap the length so an HTML error page
            // doesn't flood the log.
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8 body>"
            throw OAuthError.tokenExchangeFailed(status: status, detail: detail)
        }
        return try parseTokenResponse(data)
    }

    /// Parse the token endpoint's JSON. Testable against fixtures.
    static func parseTokenResponse(_ data: Data, now: Date = Date()) throws -> FamilySearchTokenSet {
        struct Wire: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return FamilySearchTokenSet(
            accessToken: wire.access_token,
            refreshToken: wire.refresh_token,
            obtainedAt: now,
            expiresIn: wire.expires_in
        )
    }

    /// application/x-www-form-urlencoded body encoding. Alphanumerics plus
    /// "-._~" stay literal; everything else percent-encodes (spaces as
    /// %20 — FS's endpoint accepts both forms).
    static func formURLEncoded(_ form: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    // MARK: Full sign-in flow

    /// End-to-end interactive sign-in. Order matters for security:
    /// single-flight gate → bind-and-confirm the listener (fails here,
    /// pre-browser, if the port is taken) → open the browser → await the
    /// redirect that carries our exact `state` → exchange with the PKCE
    /// verifier → persist tokens keyed by environment.
    static func signIn(
        environment: FamilySearchEnvironment,
        store: FamilySearchTokenStore = .shared,
        coordinator: FamilySearchSignInCoordinator = .shared,
        timeout: Duration = .seconds(300)
    ) async throws -> FamilySearchTokenSet {
        guard let clientID = await store.appKey() else { throw OAuthError.noAppKey }

        try await coordinator.begin()
        do {
            let tokens = try await runSignIn(
                environment: environment, clientID: clientID,
                store: store, timeout: timeout)
            await coordinator.end()
            return tokens
        } catch {
            await coordinator.end()
            throw error
        }
    }

    private static func runSignIn(
        environment: FamilySearchEnvironment,
        clientID: String,
        store: FamilySearchTokenStore,
        timeout: Duration
    ) async throws -> FamilySearchTokenSet {
        let pkce = PKCEChallenge()
        let state = randomState()
        let receiver = LoopbackRedirectReceiver()

        // Phase 1 — bind and confirm ready BEFORE the browser opens. A
        // port conflict throws .listenerFailed here, so the user is never
        // sent to authenticate against a doomed (or hijacked) listener.
        do {
            _ = try await receiver.startListening(
                port: redirectPort, expectedPath: redirectPath, expectedState: state)
        } catch {
            await receiver.cancel()
            throw error
        }

        // Phase 2 — open the browser; abort immediately (releasing the
        // port) if it can't be launched, rather than waiting out the
        // timeout.
        let url = authorizationURL(
            environment: environment, clientID: clientID,
            redirectURI: redirectURI, pkce: pkce, state: state)
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            await receiver.cancel()
            throw OAuthError.browserLaunchFailed
        }

        // Phase 3 — await the genuine redirect (state already verified by
        // the receiver; re-checked here defensively before use).
        let callback = try await receiver.awaitCallback(timeout: timeout)
        guard callback.state == state else { throw OAuthError.stateMismatch }
        if let error = callback.error { throw OAuthError.authorizationDenied(error) }
        guard let code = callback.code else { throw OAuthError.missingCode }

        let tokens = try await exchangeCode(
            code, verifier: pkce.verifier, clientID: clientID,
            redirectURI: redirectURI, environment: environment)
        await store.save(tokens, environment: environment)
        return tokens
    }
}

// MARK: - Loopback redirect receiver

/// Single-shot loopback HTTP receiver for the OAuth redirect. Binds
/// 127.0.0.1 only (never an external interface) and WITHOUT socket reuse,
/// so a port conflict fails loudly instead of co-binding. It completes
/// ONLY for a redirect carrying the matching `state`; any other local
/// request (favicon probes, forged callbacks, drive-by browser hits) gets
/// a benign response and the listener keeps waiting for the real redirect.
actor LoopbackRedirectReceiver {

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]

    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var readyResolved = false
    private var callbackContinuation: CheckedContinuation<FamilySearchOAuth.Callback, Error>?
    private var callbackResolved = false
    /// Buffers a result that arrives BEFORE `awaitCallback` has registered
    /// its continuation — the redirect connection can be fully handled
    /// before the caller suspends, and without this the callback would be
    /// silently dropped (the flake the #Change4 review's tests caught).
    private var pendingResult: Result<FamilySearchOAuth.Callback, Error>?

    private var expectedPath = ""
    private var expectedState = ""

    /// Phase 1: bind and wait until the socket is actually listening.
    /// Throws `.listenerFailed` (before the caller opens any browser) when
    /// the port is unavailable. Returns the bound port (useful for tests
    /// that request an ephemeral port 0).
    func startListening(
        port: UInt16, expectedPath: String, expectedState: String
    ) async throws -> UInt16 {
        self.expectedPath = expectedPath
        self.expectedState = expectedState

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        // No allowLocalEndpointReuse: a bind conflict must be a hard,
        // visible failure, never silent SO_REUSEPORT co-binding (which is
        // the macOS local redirect-hijack primitive).

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw FamilySearchOAuth.OAuthError.listenerFailed(error.localizedDescription)
        }
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation
            listener.stateUpdateHandler = { state in
                Task { await self.onState(state) }
            }
            listener.newConnectionHandler = { connection in
                Task { await self.accept(connection) }
            }
            listener.start(queue: DispatchQueue(label: "fs-oauth-loopback"))
        }
    }

    private func onState(_ state: NWListener.State) {
        switch state {
        case .ready:
            resolveReady(.success(listener?.port?.rawValue ?? 0))
        case .failed(let error):
            let e = FamilySearchOAuth.OAuthError.listenerFailed(error.localizedDescription)
            resolveReady(.failure(e))
            failCallback(e)
        case .waiting(let error):
            // A loopback bind that's "waiting" is a port conflict that
            // would retry indefinitely — for an OAuth listener that's a
            // hard failure, not something to wait out.
            let e = FamilySearchOAuth.OAuthError.listenerFailed("port unavailable: \(error.localizedDescription)")
            resolveReady(.failure(e))
            failCallback(e)
            listener?.cancel()
        default:
            break
        }
    }

    private func resolveReady(_ result: Result<UInt16, Error>) {
        guard !readyResolved else { return }
        readyResolved = true
        readyContinuation?.resume(with: result)
        readyContinuation = nil
    }

    /// The listener's actual bound port (for tests using an ephemeral
    /// port request).
    var boundPort: UInt16? { listener?.port?.rawValue }

    /// Phase 2: wait for the genuine redirect or time out. A standalone
    /// timeout task resumes the callback continuation with `.timedOut`
    /// (rather than a task group, which would deadlock: the group awaits
    /// the suspended callback child before teardown could resume it). The
    /// listener is always torn down on exit — success, timeout, or
    /// cancellation — so the fixed port is released for the next attempt.
    func awaitCallback(timeout: Duration) async throws -> FamilySearchOAuth.Callback {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.deliver(.failure(FamilySearchOAuth.OAuthError.timedOut))
        }
        defer { timeoutTask.cancel() }
        do {
            let callback = try await withCheckedThrowingContinuation { continuation in
                // Both this closure and `deliver` run on the actor, so the
                // check-and-store is atomic against delivery. If the result
                // already arrived, hand it back immediately; otherwise park.
                if let pending = self.pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pending)
                } else {
                    self.callbackContinuation = continuation
                }
            }
            shutdown()
            return callback
        } catch {
            shutdown()
            throw error
        }
    }

    /// Explicit teardown for the caller (e.g. browser launch failed after
    /// a successful bind).
    func cancel() { shutdown() }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: DispatchQueue(label: "fs-oauth-conn"))
        receiveMore(connection)
    }

    private func receiveMore(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, _ in
            Task { await self.onData(data, isComplete: isComplete, connection: connection) }
        }
    }

    /// Accumulate until the HTTP request line (first CRLF) is complete —
    /// TCP gives no read atomicity even on loopback, so a split request
    /// must not be misparsed into a dropped or truncated code.
    private func onData(_ data: Data?, isComplete: Bool, connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = buffers[key] ?? Data()
        if let data { buffer.append(data) }
        buffers[key] = buffer

        guard let text = String(data: buffer, encoding: .utf8) else {
            // Not valid UTF-8 (yet). Keep reading unless the peer is done.
            if isComplete { finishConnection(connection, respondBody: "ok", callback: nil) }
            else { receiveMore(connection) }
            return
        }
        guard let lineEnd = text.range(of: "\r\n") else {
            if isComplete { finishConnection(connection, respondBody: "ok", callback: nil) }
            else if buffer.count < 16384 { receiveMore(connection) }
            else { finishConnection(connection, respondBody: "ok", callback: nil) }
            return
        }

        let requestLine = String(text[text.startIndex..<lineEnd.lowerBound])
        switch FamilySearchOAuth.decide(requestLine: requestLine, expectedPath: expectedPath, expectedState: expectedState) {
        case .ignore:
            finishConnection(connection, respondBody: "ok", callback: nil)
        case .capture(let callback):
            finishConnection(
                connection,
                respondBody: "<html><body style='font-family:sans-serif'><h2>Ancestor Research: FamilySearch sign-in captured.</h2><p>You can close this tab and return to the app.</p></body></html>",
                callback: callback)
        }
    }

    private func finishConnection(
        _ connection: NWConnection, respondBody body: String,
        callback: FamilySearchOAuth.Callback?
    ) {
        let key = ObjectIdentifier(connection)
        let payload = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        // `.finalMessage` + isComplete performs a graceful half-close
        // (FIN after the bytes flush) so the client reliably receives the
        // whole body before the socket tears down — an abrupt cancel()
        // here can truncate the response under load.
        connection.send(
            content: Data(payload.utf8),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
                Task { await self.forget(key) }
            })
        if let callback { complete(with: callback) }
    }

    private func forget(_ key: ObjectIdentifier) {
        connections[key] = nil
        buffers[key] = nil
    }

    private func complete(with callback: FamilySearchOAuth.Callback) {
        deliver(.success(callback))
    }

    private func failCallback(_ error: FamilySearchOAuth.OAuthError) {
        deliver(.failure(error))
    }

    /// Single point of callback resolution: resume a waiting continuation,
    /// or buffer the result for a not-yet-registered waiter. First result
    /// wins; later ones are ignored.
    private func deliver(_ result: Result<FamilySearchOAuth.Callback, Error>) {
        guard !callbackResolved else { return }
        callbackResolved = true
        if let continuation = callbackContinuation {
            continuation.resume(with: result)
            callbackContinuation = nil
        } else {
            pendingResult = result
        }
    }

    private func shutdown() {
        if !callbackResolved {
            callbackResolved = true
            callbackContinuation?.resume(throwing: CancellationError())
            callbackContinuation = nil
        }
        resolveReady(.failure(CancellationError()))
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        buffers.removeAll()
    }
}
