import Foundation

/// Injectable HTTP client protocol. Sources depend on this, not on the concrete SourceHTTPClient.
/// Tests inject FixtureHTTPClient; production injects SourceHTTPClient.shared.
protocol HTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> Data
    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data

    /// FT-25 — repeated-key form transport. `[String: String]` cannot encode the
    /// Rails `search_query[chapman_codes][]` idiom (multiple values under one
    /// key), so this ordered-pairs primitive preserves duplicate keys on the
    /// wire. A protocol-extension default (below) funnels into the single-value
    /// method, so existing conformers (test fixtures, doubles) need no change;
    /// the production `SourceHTTPClient` overrides it to keep duplicates.
    func postForm(url: URL, multiFields: [(String, String)], headers: [String: String], timeout: TimeInterval) async throws -> Data
}

extension HTTPClient {
    // Default timeout parameter.
    func postForm(url: URL, fields: [String: String], headers: [String: String]) async throws -> Data {
        try await postForm(url: url, fields: fields, headers: headers, timeout: 20)
    }

    /// Default multi-value implementation for conformers that only implement the
    /// `[String: String]` method (test doubles, fixtures). Repeated keys collapse
    /// to the last value — a lossy but non-crashing fallback; only production
    /// `SourceHTTPClient` preserves duplicates on the wire.
    func postForm(url: URL, multiFields: [(String, String)], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        var merged: [String: String] = [:]
        for (key, value) in multiFields { merged[key] = value }
        return try await postForm(url: url, fields: merged, headers: headers, timeout: timeout)
    }

    func postForm(url: URL, multiFields: [(String, String)], headers: [String: String]) async throws -> Data {
        try await postForm(url: url, multiFields: multiFields, headers: headers, timeout: 20)
    }
}

/// HTTP errors with semantic meaning for source error handling.
enum HTTPError: Error, LocalizedError {
    case status(code: Int, body: Data?)
    case unauthorized
    case throttled
    case timeout
    case transport(Error)

    var isThrottled: Bool {
        if case .throttled = self { return true }
        if case .status(let code, _) = self, code == 429 { return true }
        return false
    }

    var isRetryable: Bool {
        switch self {
        case .status(let code, _): return [500, 502, 503].contains(code)
        case .throttled: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .status(let code, let body):
            let excerpt = body
                .flatMap { String(data: $0.prefix(200), encoding: .utf8) }?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces) ?? ""
            return excerpt.isEmpty
                ? "HTTP \(code)"
                : "HTTP \(code): \(excerpt)"
        case .unauthorized: return "HTTP 401/403 (unauthorized)"
        case .throttled: return "HTTP 429 (throttled)"
        case .timeout: return "request timed out"
        case .transport(let err): return "transport error: \(err.localizedDescription)"
        }
    }
}

#if DEBUG
/// Test-only HTTP client that returns pre-recorded responses.
struct FixtureHTTPClient: HTTPClient {
    let getFixtures: [URL: Data]
    let postFixtures: [URL: Data]

    init(getFixtures: [URL: Data] = [:], postFixtures: [URL: Data] = [:]) {
        self.getFixtures = getFixtures
        self.postFixtures = postFixtures
    }

    func get(url: URL, headers: [String: String]) async throws -> Data {
        guard let data = getFixtures[url] else {
            throw HTTPError.status(code: 404, body: nil)
        }
        return data
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        guard let data = postFixtures[url] else {
            throw HTTPError.status(code: 404, body: nil)
        }
        return data
    }
}
#endif

#if DEBUG
/// Test-only client that records the exact ordered form pairs it was asked to
/// POST (for FT-25/FT-29 wire-shape assertions) and returns empty bytes so a
/// connector's parser yields zero results without touching the network.
final class RecordingFormHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastSingleFields: [String: String]?
    private var _lastMultiFields: [(String, String)]?

    /// The pairs handed to the single-value `postForm(fields:)`, if that path ran.
    var lastSingleFields: [String: String]? { lock.withLock { _lastSingleFields } }
    /// The ordered pairs handed to `postForm(multiFields:)`, if that path ran.
    var lastMultiFields: [(String, String)]? { lock.withLock { _lastMultiFields } }

    func get(url: URL, headers: [String: String]) async throws -> Data { Data() }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        lock.withLock { _lastSingleFields = fields }
        return Data()
    }

    func postForm(url: URL, multiFields: [(String, String)], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        lock.withLock { _lastMultiFields = multiFields }
        return Data()
    }
}
#endif
