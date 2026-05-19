import Foundation
import Security
import os

/// Keychain-backed storage for FamilySearch session cookies.
///
/// Cookies are captured by `FamilySearchAuthView` after the user logs in
/// through the embedded WKWebView, persisted here, then attached to
/// subsequent search requests via the standard Cookie: header.
///
/// One generic-password keychain item per app:
///   service = "dev.dreamfold.Ancestor-Research.familysearch"
///   account = "session"
///   data    = JSON-encoded [StoredCookie]
actor FamilySearchCookieStore {
    static let shared = FamilySearchCookieStore()

    private let service = "dev.dreamfold.Ancestor-Research.familysearch"
    private let account = "session"
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearchCookieStore")

    private init() {}

    // MARK: - Public API

    func loadCookies() -> [HTTPCookie] {
        guard let data = readKeychain() else { return [] }
        do {
            let stored = try JSONDecoder().decode([StoredCookie].self, from: data)
            return stored.compactMap { $0.toHTTPCookie() }
        } catch {
            logger.error("Failed to decode stored cookies: \(error.localizedDescription)")
            return []
        }
    }

    func store(_ cookies: [HTTPCookie]) {
        let stored = cookies.map(StoredCookie.init)
        do {
            let data = try JSONEncoder().encode(stored)
            writeKeychain(data)
            logger.info("Stored \(cookies.count) FamilySearch cookies")
        } catch {
            logger.error("Failed to encode cookies: \(error.localizedDescription)")
        }
    }

    func clear() {
        deleteKeychain()
    }

    func hasCookies() -> Bool {
        !loadCookies().isEmpty
    }

    /// Composes a value for the HTTP `Cookie:` header, e.g.
    /// `"fssessionid=...; JSESSIONID=...; ..."`. Returns nil when nothing
    /// is stored so callers can short-circuit to a "requires auth" path.
    func cookieHeader() -> String? {
        let cookies = loadCookies()
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - Keychain primitives

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readKeychain() -> Data? {
        var query = baseQuery
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

    private func writeKeychain(_ data: Data) {
        // Replace rather than update so a corrupt or partial existing item
        // doesn't block fresh cookies from landing.
        deleteKeychain()
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain write failed with status \(status)")
        }
    }

    private func deleteKeychain() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed with status \(status)")
        }
    }
}

// MARK: - Codable bridge

/// HTTPCookie isn't Codable; this is the minimum subset we need to
/// reconstruct a valid cookie for outgoing requests.
nonisolated private struct StoredCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool

    init(_ cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path
        self.expiresDate = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
    }

    func toHTTPCookie() -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: isSecure ? "TRUE" : "FALSE",
        ]
        if let expires = expiresDate {
            props[.expires] = expires
        }
        return HTTPCookie(properties: props)
    }
}
