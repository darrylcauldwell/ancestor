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
            try Self.checkHTTPResponse(response, data: data)
            return data
        }
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        // Ordering of a [String: String] is unspecified; the wire is
        // order-insensitive for distinct keys, so serialise as ordered pairs.
        try await postForm(url: url, multiFields: fields.map { ($0.key, $0.value) },
                           headers: headers, timeout: timeout)
    }

    /// FT-25 — repeated-key form transport. A `[String: String]` cannot encode
    /// the Rails `search_query[chapman_codes][]` idiom (repeated keys), so the
    /// multi-value primitive takes ordered `(key, value)` pairs and preserves
    /// duplicates on the wire. Batching multiple counties/districts into one
    /// request (the FT-28 use of this primitive) is a SearchDispatcher/connector
    /// change and is intentionally out of this transport-layer scope.
    func postForm(url: URL, multiFields: [(String, String)], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        try await withRetry(retries: 3) {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let body = Self.formURLEncodedBody(multiFields)
            request.httpBody = body.data(using: .utf8)
            let (data, response) = try await self.session.data(for: request)
            try Self.checkHTTPResponse(response, data: data)
            return data
        }
    }

    // MARK: - Internal

    /// FT-29 — `application/x-www-form-urlencoded` body serialisation.
    ///
    /// The prior encoder used `.urlQueryAllowed`, which permits `&`, `+`, and
    /// `=` *inside* a value — so a value like `"Clifton & Compton"` split the
    /// key/value pair on the wire and `+` decoded back to a space. This uses the
    /// form-safe unreserved set (`ALPHA / DIGIT / - . _ ~`), maps space to `+`,
    /// and percent-encodes everything else — including the three separators —
    /// per the WHATWG URL form-encoding algorithm. Both key and value are
    /// encoded so a `[]` array key survives literally while a `&`/`=` in a value
    /// cannot corrupt the body.
    nonisolated static func formURLEncodedBody(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&")
    }

    /// Percent-encode a single form key or value. Space → `+`; unreserved
    /// characters pass through; every other byte becomes `%HH` (uppercase hex)
    /// over the UTF-8 encoding, so apostrophes, `&`, `+`, `=`, and diacritics
    /// (é, ü, …) all round-trip through a conforming decoder.
    nonisolated static func formEncode(_ raw: String) -> String {
        // Unreserved per RFC 3986 §2.3 — the set every form decoder leaves alone.
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var out = ""
        out.reserveCapacity(raw.utf8.count)
        for byte in raw.utf8 {
            if byte == 0x20 { // space
                out.append("+")
            } else if unreserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out.append("%")
                out.append(Self.hexDigits[Int(byte >> 4)])
                out.append(Self.hexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    /// Transient network failures worth one bounded retry — never
    /// content-level errors (those are the server speaking).
    nonisolated private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    nonisolated private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    private func withRetry(retries: Int, operation: () async throws -> Data) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<retries {
            do {
                return try await operation()
            } catch let error as HTTPError where error.isRetryable {
                lastError = error
                let backoff = Duration.seconds(pow(2.0, Double(attempt)))
                try await Task.sleep(for: backoff)
            } catch let error as URLError where Self.isTransient(error) {
                // Connector audit 2026-07-30: transient transport blips
                // (timeout, connection reset, DNS hiccup) previously
                // aborted on the FIRST attempt — one TCP blip painted the
                // whole source unavailable and the card sticky-red, the
                // classic "flaky connector" signature. Same bounded
                // backoff as retryable HTTP statuses.
                lastError = error
                let backoff = Duration.seconds(pow(2.0, Double(attempt)))
                try await Task.sleep(for: backoff)
            } catch {
                throw error
            }
        }
        throw lastError ?? HTTPError.status(code: 0, body: nil)
    }

    nonisolated private static func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw HTTPError.unauthorized
        case 429: throw HTTPError.throttled
        default: throw HTTPError.status(code: http.statusCode, body: data)
        }
    }
}
