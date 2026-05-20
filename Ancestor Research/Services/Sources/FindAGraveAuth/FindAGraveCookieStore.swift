import Foundation
import Security
import os

/// Keychain-backed storage for Find a Grave Cloudflare clearance cookies.
///
/// Find a Grave is fronted by Cloudflare Bot Management — a plain URLSession
/// request gets the "Just a moment..." JS challenge interstitial instead of
/// the real page. WKWebView (real Safari engine) can execute that JS and
/// produces a `cf_clearance` cookie. Once captured here, URLSession reuses
/// it for direct fetches until it expires (~30 days). Spec §22.
///
/// One generic-password keychain item per app:
///   service = "dev.dreamfold.Ancestor-Research.findagrave"
///   account = "cloudflare"
///   data    = JSON-encoded [StoredCookie]
actor FindAGraveCookieStore {
    static let shared = FindAGraveCookieStore()

    private let service = "dev.dreamfold.Ancestor-Research.findagrave"
    private let account = "cloudflare"
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FindAGraveCookieStore")

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
            logger.info("Stored \(cookies.count) Find a Grave cookies")
        } catch {
            logger.error("Failed to encode cookies: \(error.localizedDescription)")
        }
    }

    func clear() {
        deleteKeychain()
    }

    /// True when a non-expired cf_clearance cookie is present. Expired
    /// cookies imply Cloudflare will re-challenge; callers should treat
    /// this as a signal to refresh via WKWebView.
    func hasValidClearance() -> Bool {
        let cookies = loadCookies()
        guard let cf = cookies.first(where: { $0.name == "cf_clearance" }) else { return false }
        if let expires = cf.expiresDate, expires < Date() { return false }
        return true
    }

    /// Composes a value for the HTTP `Cookie:` header. Returns nil when
    /// nothing is stored — callers should treat that as "need to acquire
    /// clearance via WKWebView first".
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
