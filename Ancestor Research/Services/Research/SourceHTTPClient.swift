import Foundation

/// Production HTTP client with retry logic.
/// Conforms to HTTPClient protocol for injection.
actor SourceHTTPClient: HTTPClient {
    static let shared = SourceHTTPClient()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    // MARK: - HTTPClient Protocol

    func get(url: URL, headers: [String: String]) async throws -> Data {
        try await withRetry(retries: 3) {
            var request = URLRequest(url: url, timeoutInterval: 20)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await self.session.data(for: request)
            try Self.checkHTTPResponse(response)
            return data
        }
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        try await withRetry(retries: 3) {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                .joined(separator: "&")
            request.httpBody = body.data(using: .utf8)
            let (data, response) = try await self.session.data(for: request)
            try Self.checkHTTPResponse(response)
            return data
        }
    }

    // MARK: - Internal

    private func withRetry(retries: Int, operation: () async throws -> Data) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<retries {
            do {
                return try await operation()
            } catch let error as HTTPError where error.isRetryable {
                lastError = error
                let backoff = Duration.seconds(pow(2.0, Double(attempt)))
                try await Task.sleep(for: backoff)
            } catch {
                throw error
            }
        }
        throw lastError ?? HTTPError.status(code: 0, body: nil)
    }

    nonisolated private static func checkHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw HTTPError.unauthorized
        case 429: throw HTTPError.throttled
        case 500, 502, 503: throw HTTPError.status(code: http.statusCode, body: nil)
        default: throw HTTPError.status(code: http.statusCode, body: nil)
        }
    }
}
