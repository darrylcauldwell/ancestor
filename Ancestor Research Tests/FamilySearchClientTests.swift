import Testing
import Foundation
@testable import Ancestor_Research

/// FamilySearch client — Slice 3. Exercises the transport `actor` against a
/// mock `URLProtocol` + a fake token source: bearer flow, 401→refresh-once,
/// 429/Retry-After bounded retry, and typed surfacing of 301/410/processing
/// time. Serialized because the mock uses process-global response state.
@Suite(.serialized)
struct FamilySearchClientTests {

    private let url = URL(string: "https://apibeta.familysearch.org/platform/users/current")!

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FSMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func returns200BodyAndNegotiatesAccept() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 200, body: Data(#"{"ok":true}"#.utf8))
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        let response = try await client.execute(
            FamilySearchRequest(url: url, accept: .fsV1))
        #expect(response.statusCode == 200)
        #expect(String(data: response.body, encoding: .utf8) == #"{"ok":true}"#)
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == "application/x-fs-v1+json")
    }

    @Test func notSignedInThrowsBeforeAnyRequest() async {
        FSMockURLProtocol.reset()
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: nil),
                                        session: mockSession(), sleeper: { _ in })
        await #expect(throws: FamilySearchClientError.notAuthenticated) {
            try await client.execute(FamilySearchRequest(url: self.url))
        }
        #expect(FSMockURLProtocol.recordedRequests.isEmpty)
    }

    @Test func refreshesOnceOn401ThenSucceeds() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 401)
        FSMockURLProtocol.enqueue(status: 200, body: Data("ok".utf8))
        let token = FakeFSTokenSource(bearer: "OLD", refreshResult: "NEW")
        let client = FamilySearchClient(tokenSource: token, session: mockSession(), sleeper: { _ in })
        let response = try await client.execute(FamilySearchRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(token.refreshCallCount == 1)
        #expect(FSMockURLProtocol.recordedRequests.count == 2)
    }

    @Test func on401WithNoRefreshThrowsNotAuthenticated() async {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 401)
        let token = FakeFSTokenSource(bearer: "OLD", refreshResult: nil)
        let client = FamilySearchClient(tokenSource: token, session: mockSession(), sleeper: { _ in })
        await #expect(throws: FamilySearchClientError.notAuthenticated) {
            try await client.execute(FamilySearchRequest(url: self.url))
        }
        #expect(token.refreshCallCount == 1)
    }

    @Test func retriesOn429HonouringRetryAfterThenSucceeds() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 429, headers: ["Retry-After": "3"])
        FSMockURLProtocol.enqueue(status: 200, body: Data("ok".utf8))
        let slept = SleepRecorder()
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { slept.record($0) })
        let response = try await client.execute(FamilySearchRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(FSMockURLProtocol.recordedRequests.count == 2)
        #expect(slept.values == [3])   // Retry-After honoured exactly
    }

    @Test func exhaustsThrottleRetriesThenThrows() async {
        FSMockURLProtocol.reset()
        for _ in 0..<5 { FSMockURLProtocol.enqueue(status: 429, headers: ["Retry-After": "0"]) }
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), maxThrottleRetries: 2, sleeper: { _ in })
        await #expect(throws: FamilySearchClientError.tooManyThrottleRetries) {
            try await client.execute(FamilySearchRequest(url: self.url))
        }
        #expect(FSMockURLProtocol.recordedRequests.count == 3)   // initial + 2 retries
    }

    @Test func retriesOn409TokenRaceThenSucceeds() async throws {
        // The undocumented post-sign-in token-rotation race: first request 409s,
        // the retry (with the settled bearer) succeeds.
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 409)
        FSMockURLProtocol.enqueue(status: 200, body: Data("ok".utf8))
        let slept = SleepRecorder()
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { slept.record($0) })
        let response = try await client.execute(FamilySearchRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(FSMockURLProtocol.recordedRequests.count == 2)
        #expect(slept.values == [1])   // first backoff = 1s
    }

    @Test func exhausts409RetriesThenSurfacesTheConflict() async throws {
        // A persistent 409 (not a transient race) must still surface, not loop.
        FSMockURLProtocol.reset()
        for _ in 0..<4 { FSMockURLProtocol.enqueue(status: 409) }
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), maxConflictRetries: 2, sleeper: { _ in })
        let response = try await client.execute(FamilySearchRequest(url: url))
        #expect(response.statusCode == 409)                      // surfaced, not thrown into a loop
        #expect(FSMockURLProtocol.recordedRequests.count == 3)   // initial + 2 retries
    }

    @Test func surfaces301MergeWithForwardedId() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 301, headers: [
            "Location": "https://apibeta.familysearch.org/platform/tree/persons/NEW",
            "X-Entity-Forwarded-Id": "NEW",
        ])
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        let response = try await client.execute(FamilySearchRequest(url: url))
        #expect(response.statusCode == 301)
        #expect(response.isMerged)
        #expect(response.location == "https://apibeta.familysearch.org/platform/tree/persons/NEW")
        #expect(response.forwardedEntityId == "NEW")
    }

    @Test func surfaces410TombstoneAndProcessingTime() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 410, headers: ["X-PROCESSING-TIME": "42"],
                                  body: Data(#"{"tombstone":true}"#.utf8))
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        let response = try await client.execute(FamilySearchRequest(url: url))
        #expect(response.statusCode == 410)
        #expect(response.isDeleted)
        #expect(response.processingTimeMillis == 42)
        #expect(String(data: response.body, encoding: .utf8)?.contains("tombstone") == true)
    }

    @Test func attachesFeatureTagsHeader() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 200)
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        _ = try await client.execute(FamilySearchRequest(url: url, featureTags: ["a", "b"]))
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-FS-Feature-Tag") == "a,b")
    }

    // MARK: - Slice 4: typed endpoint methods

    @Test func recordsPersonaSearchDecodesFeedAndTargetsPersonasEndpoint() async throws {
        FSMockURLProtocol.reset()
        let body = #"{"results":42,"index":0,"entries":[{"score":9.1,"content":{"gedcomx":{"persons":[{"names":[{"nameForms":[{"fullText":"Ernest Cauldwell"}]}]}]}}}]}"#
        FSMockURLProtocol.enqueue(status: 200, body: Data(body.utf8))
        let client = FamilySearchClient(environment: .beta, tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        var query = FamilySearchQuery(); query.surname = "Cauldwell"
        let feed = try await client.recordsPersonaSearch(query)
        #expect(feed.results == 42)
        #expect(feed.entries?.first?.score == 9.1)
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/records/personas")
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == "application/x-gedcomx-atom+json")
    }

    @Test func noResults204ReturnsCleanEmptyFeed() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 204)
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        var query = FamilySearchQuery(); query.surname = "Nonesuch"; query.offset = 20
        let feed = try await client.recordsPersonaSearch(query)
        #expect(feed.results == 0)
        #expect(feed.entries?.isEmpty == true)
        #expect(feed.index == 20)
    }

    @Test func personMatchesTargetsRecordsCollection() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 200, body: Data(#"{"entries":[]}"#.utf8))
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        _ = try await client.personMatches(pid: "LZ8X-ABC", collection: .records)
        let requested = FSMockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(requested.contains("/platform/tree/persons/LZ8X-ABC/matches"))
        #expect(requested.contains("collection=https"))
    }

    @Test func treePersonSearchTargetsTreeSearchWithStructuredQuery() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 200, body: Data(#"{"entries":[]}"#.utf8))
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        var query = FamilySearchQuery(); query.givenName = "William"; query.surname = "Heaton"
        _ = try await client.treePersonSearch(query)
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/tree/search")
        #expect((FSMockURLProtocol.lastRequest?.url?.query ?? "").contains("q.surname=Heaton"))
    }

    @Test func readPersonDecodesPlatformBody() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 200, body: Data(#"{"persons":[{"id":"P1","gender":{"type":"http://gedcomx.org/Female"}}]}"#.utf8))
        let client = FamilySearchClient(tokenSource: FakeFSTokenSource(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        let gx = try await client.readPerson(pid: "P1")
        #expect(gx.persons?.first?.id == "P1")
        #expect(gx.persons?.first?.gender?.type == "http://gedcomx.org/Female")
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/tree/persons/P1")
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == "application/x-fs-v1+json")
    }
}

// MARK: - Test doubles

/// In-memory token source. Serial-suite use only.
private final class FakeFSTokenSource: FamilySearchTokenSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bearer: String?
    private let refreshResult: String?
    private var refreshCalls = 0

    init(bearer: String?, refreshResult: String? = nil) {
        self.bearer = bearer
        self.refreshResult = refreshResult
    }

    var refreshCallCount: Int { lock.withLock { refreshCalls } }

    func currentBearer() async -> String? { lock.withLock { bearer } }

    func refreshBearer() async -> String? {
        lock.withLock {
            refreshCalls += 1
            bearer = refreshResult
            return refreshResult
        }
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { lock.withLock { _values.append(seconds) } }
    var values: [TimeInterval] { lock.withLock { _values } }
}

/// Mock `URLProtocol` serving a FIFO queue of canned responses and recording
/// the requests it saw. Process-global state → the suite is `.serialized`.
final class FSMockURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub { let status: Int; let headers: [String: String]; let body: Data }

    nonisolated(unsafe) private static var queue: [Stub] = []
    nonisolated(unsafe) private(set) static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { queue = []; recordedRequests = [] }
    }
    static func enqueue(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        lock.withLock { queue.append(Stub(status: status, headers: headers, body: body)) }
    }
    static var lastRequest: URLRequest? { lock.withLock { recordedRequests.last } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub = FSMockURLProtocol.lock.withLock {
            FSMockURLProtocol.recordedRequests.append(request)
            return FSMockURLProtocol.queue.isEmpty
                ? Stub(status: 200, headers: [:], body: Data())
                : FSMockURLProtocol.queue.removeFirst()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                   httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
