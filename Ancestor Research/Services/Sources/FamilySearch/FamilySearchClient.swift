import Foundation
import os

// FamilySearch Platform-API transport client (Slice 3).
//
// An `actor` that executes authenticated requests and applies the platform's
// documented client responsibilities — bearer attach, Accept negotiation,
// `X-FS-Feature-Tag`, 429/`Retry-After` bounded retry, one-shot 401 refresh,
// and typed surfacing of 301 merges / 410 tombstones / `X-PROCESSING-TIME`.
// It reuses the shipped `FamilySearchOAuth` token stack via a small
// `FamilySearchTokenSource` seam (so tests inject a fake, and the client never
// opens a browser — interactive sign-in stays the app's job).
//
// HTTP status is DATA, not an error: `execute` returns a `FamilySearchResponse`
// for any 2xx/3xx/4xx and throws only on no-auth / transport / retry-exhaustion.
// See `AncestorApp/FAMILYSEARCH_CLIENT_SPEC.md`.

// MARK: - Media types

nonisolated enum FSMediaType: String, Sendable, Equatable {
    case json = "application/json"
    case fsV1 = "application/x-fs-v1+json"
    case gedcomxAtom = "application/x-gedcomx-atom+json"
    case gedcomxV1 = "application/x-gedcomx-v1+json"
}

// MARK: - Request / response

nonisolated struct FamilySearchRequest: Sendable {
    var method: String = "GET"
    var url: URL
    var accept: FSMediaType = .json
    var contentType: FSMediaType?
    var featureTags: [String] = []
    /// ETag for a conditional GET (`If-None-Match`); a 304 comes back as a
    /// normal response with an empty body.
    var ifNoneMatch: String?
    var body: Data?

    init(url: URL, method: String = "GET", accept: FSMediaType = .json,
         contentType: FSMediaType? = nil, featureTags: [String] = [],
         ifNoneMatch: String? = nil, body: Data? = nil) {
        self.url = url
        self.method = method
        self.accept = accept
        self.contentType = contentType
        self.featureTags = featureTags
        self.ifNoneMatch = ifNoneMatch
        self.body = body
    }
}

nonisolated struct FamilySearchResponse: Sendable {
    let statusCode: Int
    /// Header names lowercased for case-insensitive lookup (a case-sensitive
    /// `Retry-After` lookup is a latent hammer-the-server bug in the PHP SDK).
    let headers: [String: String]
    let body: Data

    var etag: String? { headers["etag"] }
    /// `Location` on a 301/302 (merged-person survivor / ARK resolution).
    var location: String? { headers["location"] }
    /// `X-Entity-Forwarded-Id` — the survivor entity on a 301 merge.
    var forwardedEntityId: String? { headers["x-entity-forwarded-id"] }
    /// `X-PROCESSING-TIME` in milliseconds (present on every response).
    var processingTimeMillis: Int? { headers["x-processing-time"].flatMap { Int($0) } }
    /// `Retry-After` seconds on a 429 (integer-seconds form).
    var retryAfterSeconds: TimeInterval? { headers["retry-after"].flatMap { TimeInterval($0) } }

    var isMerged: Bool { statusCode == 301 }
    var isDeleted: Bool { statusCode == 410 }
    var isNoResults: Bool { statusCode == 204 }

    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: body)
    }
}

nonisolated enum FamilySearchClientError: Error, Sendable, Equatable {
    /// No valid bearer and a refresh could not produce one — the app must
    /// re-authenticate interactively.
    case notAuthenticated
    case transport(String)
    case tooManyThrottleRetries
}

// MARK: - Token source seam

/// Supplies (and refreshes) the OAuth bearer. Abstracted so the client is
/// testable without the Keychain, and so interactive sign-in stays outside the
/// transport layer.
nonisolated protocol FamilySearchTokenSource: Sendable {
    /// A currently-valid bearer, or nil when signed out / expired.
    func currentBearer() async -> String?
    /// Attempt a silent refresh after a 401; nil ⇒ interactive re-auth needed.
    func refreshBearer() async -> String?
}

/// Real token source backed by the shipped `FamilySearchTokenStore` +
/// `FamilySearchOAuth.refresh`. (FamilySearch currently issues no refresh token
/// to our key, so `refreshBearer` will usually return nil → `.notAuthenticated`
/// → interactive re-auth, which is correct.)
nonisolated struct KeychainFamilySearchTokenSource: FamilySearchTokenSource {
    let environment: FamilySearchEnvironment
    let store: FamilySearchTokenStore

    init(environment: FamilySearchEnvironment, store: FamilySearchTokenStore = .shared) {
        self.environment = environment
        self.store = store
    }

    func currentBearer() async -> String? {
        await store.validAccessToken(environment: environment)
    }

    func refreshBearer() async -> String? {
        guard let tokens = await store.load(environment: environment),
              let refreshToken = tokens.refreshToken,
              let clientID = await store.appKey() else { return nil }
        guard let refreshed = try? await FamilySearchOAuth.refresh(
            refreshToken: refreshToken, clientID: clientID, environment: environment) else { return nil }
        await store.save(refreshed, environment: environment)
        return refreshed.accessToken
    }
}

// MARK: - Client

actor FamilySearchClient {
    let environment: FamilySearchEnvironment
    private let tokenSource: any FamilySearchTokenSource
    private let session: URLSession
    private let maxThrottleRetries: Int
    /// Undocumented HTTP 409: a request caught mid-token-refresh. There is no
    /// refresh token, so a fresh sign-in rotates the bearer while a fan-out of
    /// requests is in flight — the ones that raced the rotation come back 409 and
    /// succeed once retried with the settled token. Bounded so a genuine
    /// persistent 409 still surfaces. (Memory: reference_familysearch_409_token_race.)
    private let maxConflictRetries: Int
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let redirectBlocker = FamilySearchRedirectBlocker()
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearchClient")

    init(
        environment: FamilySearchEnvironment = .beta,
        tokenSource: any FamilySearchTokenSource,
        session: URLSession = .shared,
        maxThrottleRetries: Int = 5,
        maxConflictRetries: Int = 3,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.environment = environment
        self.tokenSource = tokenSource
        self.session = session
        self.maxThrottleRetries = maxThrottleRetries
        self.maxConflictRetries = maxConflictRetries
        self.sleeper = sleeper
    }

    /// Execute a request end-to-end. Never throws on an HTTP status — 2xx/3xx
    /// (301/410 surfaced, not followed) / 4xx all return a response the caller
    /// inspects. Throws only `.notAuthenticated`, `.transport`, or
    /// `.tooManyThrottleRetries`.
    func execute(_ request: FamilySearchRequest) async throws -> FamilySearchResponse {
        guard var bearer = await tokenSource.currentBearer() else {
            throw FamilySearchClientError.notAuthenticated
        }
        var didRefresh = false
        var throttleRetries = 0
        var conflictRetries = 0

        while true {
            let response = try await send(request, bearer: bearer)
            switch response.statusCode {
            case 401 where !didRefresh:
                didRefresh = true
                guard let refreshed = await tokenSource.refreshBearer() else {
                    throw FamilySearchClientError.notAuthenticated
                }
                bearer = refreshed

            case 409 where conflictRetries < maxConflictRetries:
                // Token-rotation race (see `maxConflictRetries`): back off briefly
                // to let the new bearer settle, then re-read it — the rotation is
                // usually done by the time the first retry fires.
                conflictRetries += 1
                await sleeper(TimeInterval(conflictRetries))   // 1s, 2s, 3s
                if let settled = await tokenSource.currentBearer() { bearer = settled }

            case 429 where throttleRetries < maxThrottleRetries:
                throttleRetries += 1
                // Honour Retry-After exactly; default to 1s when absent so we
                // never hot-loop the throttle endpoint.
                await sleeper(response.retryAfterSeconds ?? 1)

            case 429:
                throw FamilySearchClientError.tooManyThrottleRetries

            default:
                return response
            }
        }
    }

    private func send(_ request: FamilySearchRequest, bearer: String) async throws -> FamilySearchResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(request.accept.rawValue, forHTTPHeaderField: "Accept")
        if let contentType = request.contentType {
            urlRequest.setValue(contentType.rawValue, forHTTPHeaderField: "Content-Type")
        }
        if !request.featureTags.isEmpty {
            urlRequest.setValue(request.featureTags.joined(separator: ","), forHTTPHeaderField: "X-FS-Feature-Tag")
        }
        if let ifNoneMatch = request.ifNoneMatch {
            urlRequest.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: redirectBlocker)
            guard let http = response as? HTTPURLResponse else {
                throw FamilySearchClientError.transport("non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            if let ms = headers["x-processing-time"] {
                logger.debug("FamilySearch \(request.method, privacy: .public) → \(http.statusCode) (\(ms, privacy: .public)ms)")
            }
            return FamilySearchResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as FamilySearchClientError {
            throw error
        } catch {
            throw FamilySearchClientError.transport(error.localizedDescription)
        }
    }
}

/// Blocks automatic redirect following so 301 merges are surfaced (with their
/// `Location` / `X-Entity-Forwarded-Id`) rather than silently chased. Stateless.
/// Uses the completion-handler delegate form (the `async` variant crashes the
/// SIL lowerer under `-default-isolation=MainActor`).
private nonisolated final class FamilySearchRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)   // do not follow — surface the 3xx response
    }
}

// MARK: - Typed endpoint methods (Slice 4)

extension FamilySearchClient {

    /// Historical-record persona search — `GET /platform/records/personas`
    /// (records certification). 204 ⇒ a clean empty feed (a genuine negative).
    func recordsPersonaSearch(_ query: FamilySearchQuery) async throws -> RecordsSearchFeed {
        try await feed(FamilySearchEndpoints.recordsPersonaSearch(environment, query), offset: query.offset)
    }

    /// Family Tree person search — `GET /platform/tree/search`.
    func treePersonSearch(_ query: FamilySearchQuery) async throws -> RecordsSearchFeed {
        try await feed(FamilySearchEndpoints.treeSearch(environment, query), offset: query.offset)
    }

    /// Record/duplicate hints for a tree person —
    /// `GET /platform/tree/persons/{pid}/matches` (record-hinting certification
    /// for `collection: .records`). 204 ⇒ no hints yet.
    func personMatches(pid: String, collection: FamilySearchMatchCollection = .records) async throws -> RecordsSearchFeed {
        try await feed(FamilySearchEndpoints.personMatches(environment, pid: pid, collection: collection), offset: 0)
    }

    /// Read one tree person — `GET /platform/tree/persons/{pid}` (x-fs-v1+json).
    func readPerson(pid: String) async throws -> FSGedcomx {
        let response = try await execute(FamilySearchRequest(url: FamilySearchEndpoints.readPerson(environment, pid: pid), accept: .fsV1))
        try ensureSuccess(response)
        return try response.decode(FSGedcomx.self)
    }

    // MARK: helpers

    private func feed(_ url: URL, offset: Int) async throws -> RecordsSearchFeed {
        let response = try await execute(FamilySearchRequest(url: url, accept: .gedcomxAtom))
        if response.isNoResults { return RecordsSearchFeed(results: 0, index: offset, entries: []) }
        try ensureSuccess(response)
        return try response.decode(RecordsSearchFeed.self)
    }

    private func ensureSuccess(_ response: FamilySearchResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw FamilySearchClientError.transport("HTTP \(response.statusCode)")
        }
    }
}
