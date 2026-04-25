import Foundation

/// Injectable HTTP client protocol. Sources depend on this, not on the concrete SourceHTTPClient.
/// Tests inject FixtureHTTPClient; production injects SourceHTTPClient.shared.
protocol HTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> Data
    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data
}

// Default timeout parameter
extension HTTPClient {
    func postForm(url: URL, fields: [String: String], headers: [String: String]) async throws -> Data {
        try await postForm(url: url, fields: fields, headers: headers, timeout: 20)
    }
}

/// HTTP errors with semantic meaning for source error handling.
enum HTTPError: Error {
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
