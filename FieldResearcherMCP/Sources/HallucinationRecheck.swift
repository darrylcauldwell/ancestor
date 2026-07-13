import Foundation
import CryptoKit

// MARK: - §14.B.1 Defensive Hallucination Re-check (MCP-side self-contained mirror)
//
// This is a DELIBERATE DUPLICATE of the app-side
// `Ancestor Research/Services/Research/HallucinationRecheck.swift` (+ the
// `EvidenceFirewall.normalise` / `.extractYear` / `.idempotencyKey` helpers and
// the `SourceTierRegistry.isBlocked` / `.isRestricted` classifications it
// consults). Same pattern as `MCPHandler.decideExpansionBound` (#Change7): the
// MCP is a standalone package with a Foundation + GRDB-only boundary — it does
// NOT depend on AncestorKit or the app target — so the rule is copied here and a
// twin-literal test (`HallucinationRecheckSyncTests`) pins the two copies in
// step for the same inputs.
//
// The check is deterministic — it never invokes any model. It re-fetches the
// cited source (page-cache first, reusing the app's on-disk cache) and
// deterministically re-extracts the specific claim. A confirmed claim is
// `.approved`; anything else `.bounced(flag:)`. Conservative by construction:
// fetch failure, restricted/blocked source, empty page, cache-miss, or
// claim-not-found all bounce.

/// Minimal mirror of the app's `SourceTierRegistry` — only the two
/// classifications the re-check consults (`isBlocked` / `isRestricted`).
/// Host lists are copied verbatim from
/// `Ancestor Research/Services/Research/SourceTierRegistry.swift`; keep them in
/// step when the app-side lists change.
enum MCPSourceTierRegistry {

    /// Hosts whose content is paywalled/licenced and cannot be independently
    /// re-fetched (commercial providers). Mirrors the `restricted: true`
    /// entries in the app registry.
    static let restrictedHosts: Set<String> = [
        "ancestry.co.uk",
        "ancestry.com",
        "findmypast.co.uk",
        "britishnewspaperarchive.co.uk",
        "thegenealogist.co.uk",
    ]

    /// Social-media hosts — not a genealogical source.
    static let blockedSocialHosts = [
        "facebook.com", "twitter.com", "x.com", "reddit.com",
        "instagram.com", "tiktok.com", "youtube.com",
    ]

    /// AI content-generator hosts — not a primary source.
    static let blockedAIHosts = [
        "chatgpt.com", "claude.ai", "perplexity.ai", "bard.google.com",
    ]

    static func normalisedHost(_ urlString: String) -> String? {
        let host: String?
        if let url = URL(string: urlString), let h = url.host {
            host = h
        } else {
            var s = urlString
            if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
            if let range = s.range(of: "/") { s = String(s[..<range.lowerBound]) }
            host = s.isEmpty ? nil : s
        }
        return host?.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    /// URLs that should never be accepted as evidence sources. Mirrors
    /// `SourceTierRegistry.isBlocked`.
    static func isBlocked(url: String) -> (blocked: Bool, reason: String) {
        guard let host = normalisedHost(url) else {
            return (true, "invalid URL")
        }
        if blockedSocialHosts.contains(where: { host.hasSuffix($0) }) {
            return (true, "social media is not a genealogical source")
        }
        if blockedAIHosts.contains(where: { host.hasSuffix($0) }) {
            return (true, "AI-generated content is not a primary source")
        }
        return (false, "")
    }

    /// Restricted (paywalled/licenced) source. Mirrors
    /// `SourceTierRegistry.isRestricted`: a host is restricted when it (or a
    /// parent domain) is in the commercial-provider list.
    static func isRestricted(url: String) -> Bool {
        guard let host = normalisedHost(url) else { return false }
        return restrictedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }
}

/// Content-matching helpers mirroring the app's `EvidenceFirewall`.
enum EvidenceMatch {
    /// Cap on stored/compared evidence excerpts (app: `maxEvidenceTextLength`).
    static let maxEvidenceTextLength = 200

    /// Normalise text for content matching: lowercase + whitespace-collapsed.
    /// Byte-for-byte the app's `EvidenceFirewall.normalise`.
    static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// First 4-digit year token in `text`, else nil. Mirrors
    /// `EvidenceFirewall.extractYear`.
    static func extractYear(from text: String) -> Int? {
        let pattern = #"\b(\d{4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    /// Deterministic idempotency/cache key. Byte-for-byte the app's
    /// `EvidenceFirewall.idempotencyKey`: SHA256 of "profileID|field|value|url",
    /// first 16 bytes as lowercase hex. The page-cache filename uses
    /// (profileID: "", field: "", value: "", sourceURL: url), so the MCP finds
    /// the app's cached page for the same URL.
    static func idempotencyKey(profileID: String, field: String, value: String, sourceURL: String) -> String {
        let input = "\(profileID)|\(field)|\(value)|\(sourceURL)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// §14.B.1 deterministic re-check — self-contained MCP mirror of the app's
/// `HallucinationRecheck`.
enum MCPHallucinationRecheck {

    /// The specific claim being re-verified against its cited source. Mirrors
    /// the `pending_facts` columns that matter for content matching.
    struct Claim: Sendable, Equatable {
        let profileID: String
        let field: String
        let value: String
        let sourceURL: String
        /// The <=200-char excerpt the original extraction said it saw.
        let evidenceText: String

        init(profileID: String, field: String, value: String, sourceURL: String, evidenceText: String) {
            self.profileID = profileID
            self.field = field
            self.value = value
            self.sourceURL = sourceURL
            self.evidenceText = String(evidenceText.prefix(EvidenceMatch.maxEvidenceTextLength))
        }
    }

    /// The outcome of a single claim re-check.
    enum Decision: Equatable, Sendable {
        case approved
        case bounced(flag: HallucinationFlag)

        var isApproved: Bool {
            if case .approved = self { return true }
            return false
        }
    }

    /// Why a claim was bounced. Every non-approval maps to exactly one flag so
    /// the reason is auditable and testable. Superset of the app's flags: the
    /// MCP has no network layer, so it adds `.pageNotCached` for the
    /// conservative cache-miss bounce (the app's `CachingPageProvider` fetches
    /// on a miss instead).
    enum HallucinationFlag: String, Equatable, Sendable {
        case claimNotOnPage = "claim_not_on_page"
        case urlBlocked = "url_blocked"
        case urlInvalid = "url_invalid"
        case sourceRestricted = "source_restricted"
        case fetchFailed = "fetch_failed"
        case emptyPage = "empty_page"
        case noClaimAnchor = "no_claim_anchor"
        /// Cited page is not in the app's on-disk page-cache, and the MCP has
        /// no app network layer to fetch it. Can't verify → don't auto-approve.
        case pageNotCached = "page_not_cached"
    }

    /// A per-claim audit entry recording the re-check decision and whether the
    /// page came from cache. Mirrors the app's `AuditEntry`.
    struct AuditEntry: Sendable, Equatable {
        let profileID: String
        let field: String
        let value: String
        let sourceURL: String
        let decision: Decision
        let servedFromCache: Bool
        let checkedAt: Date

        var approved: Bool { decision.isApproved }

        var flag: HallucinationFlag? {
            if case .bounced(let flag) = decision { return flag }
            return nil
        }

        var summary: String {
            switch decision {
            case .approved:
                return "recheck APPROVED \(field)=\(value) [\(servedFromCache ? "cache" : "fetch")] \(sourceURL)"
            case .bounced(let flag):
                return "recheck BOUNCED(\(flag.rawValue)) \(field)=\(value) [\(servedFromCache ? "cache" : "fetch")] \(sourceURL)"
            }
        }
    }

    // MARK: - Re-check entry point

    /// Re-check a single auto-approval candidate against its cited source.
    ///
    /// Guard order and semantics are identical to the app's
    /// `HallucinationRecheck.recheck`: url-invalid → url-blocked → restricted →
    /// no-anchor → fetch → empty-page → deterministic claim match. The only
    /// divergence is the page-provider's cache-miss handling (see
    /// `PageProvider`), which the MCP maps to `.pageNotCached`.
    static func recheck(
        claim: Claim,
        pages: any PageProvider
    ) async -> AuditEntry {
        let now = Date()

        // Guard 1: URL must be present and well-formed.
        guard !claim.sourceURL.isEmpty, URL(string: claim.sourceURL) != nil else {
            return audit(claim, .bounced(flag: .urlInvalid), servedFromCache: false, at: now)
        }

        // Guard 2: blocked URLs never re-verify.
        let (blocked, _) = MCPSourceTierRegistry.isBlocked(url: claim.sourceURL)
        if blocked {
            return audit(claim, .bounced(flag: .urlBlocked), servedFromCache: false, at: now)
        }

        // Guard 3: restricted / paywalled sources can't be independently re-fetched.
        if MCPSourceTierRegistry.isRestricted(url: claim.sourceURL) {
            return audit(claim, .bounced(flag: .sourceRestricted), servedFromCache: false, at: now)
        }

        // Guard 4: we need something to anchor the re-extraction on.
        if claim.evidenceText.isEmpty && claim.value.isEmpty {
            return audit(claim, .bounced(flag: .noClaimAnchor), servedFromCache: false, at: now)
        }

        // Step 1: re-fetch — page-cache first. The MCP bounces on cache-miss.
        let fetched: PageFetchResult
        do {
            fetched = try await pages.page(for: claim.sourceURL)
        } catch is PageCacheMiss {
            // Conservative: can't verify without the app's cached page → bounce.
            return audit(claim, .bounced(flag: .pageNotCached), servedFromCache: false, at: now)
        } catch {
            return audit(claim, .bounced(flag: .fetchFailed), servedFromCache: false, at: now)
        }

        // A page that carries no meaningful content once normalised can't
        // corroborate anything.
        let normalisedPage = EvidenceMatch.normalise(fetched.text)
        guard !normalisedPage.isEmpty else {
            return audit(claim, .bounced(flag: .emptyPage), servedFromCache: fetched.servedFromCache, at: now)
        }

        // Step 2 + 3: deterministic re-extraction — the claim must appear.
        let confirmed = claimAppears(claim, onPageText: fetched.text)
        let decision: Decision = confirmed ? .approved : .bounced(flag: .claimNotOnPage)
        return audit(claim, decision, servedFromCache: fetched.servedFromCache, at: now)
    }

    // MARK: - Deterministic re-extraction

    /// Deterministically re-extract the claim. Byte-for-byte the app's
    /// `HallucinationRecheck.claimAppears`: the evidence excerpt (if any) AND a
    /// value anchor (year token for date-like values, full normalised value
    /// otherwise) must both appear on the normalised page.
    static func claimAppears(_ claim: Claim, onPageText pageText: String) -> Bool {
        let page = EvidenceMatch.normalise(pageText)
        guard !page.isEmpty else { return false }

        // Evidence excerpt must appear (when present).
        if !claim.evidenceText.isEmpty {
            let evidence = EvidenceMatch.normalise(claim.evidenceText)
            if !evidence.isEmpty, !page.contains(evidence) {
                return false
            }
        }

        // Value anchor must appear. Date-like values anchor on the year token;
        // non-date values require the full normalised value.
        if !claim.value.isEmpty {
            if let year = EvidenceMatch.extractYear(from: claim.value) {
                if !page.contains(String(year)) { return false }
            } else {
                let value = EvidenceMatch.normalise(claim.value)
                if !value.isEmpty, !page.contains(value) { return false }
            }
        }

        return true
    }

    // MARK: - Helpers

    private static func audit(
        _ claim: Claim,
        _ decision: Decision,
        servedFromCache: Bool,
        at date: Date
    ) -> AuditEntry {
        AuditEntry(
            profileID: claim.profileID,
            field: claim.field,
            value: claim.value,
            sourceURL: claim.sourceURL,
            decision: decision,
            servedFromCache: servedFromCache,
            checkedAt: date
        )
    }
}

// MARK: - Page provider

/// Result of asking a `PageProvider` for a page.
struct PageFetchResult: Sendable {
    let text: String
    /// True when served from the on-disk page-cache with no fetch.
    let servedFromCache: Bool
}

/// Thrown by a `PageProvider` when the page is not in the cache and the
/// provider will not fetch. The re-check maps this to `.pageNotCached`.
struct PageCacheMiss: Error {}

/// Abstraction over page retrieval so the re-check can prefer the page-cache
/// and tests can inject fakes.
protocol PageProvider: Sendable {
    func page(for url: String) async throws -> PageFetchResult
}

/// Production `PageProvider` for the MCP. Reads the SAME on-disk page-cache the
/// app writes (`PendingFactsProcessor.cachePageData` / the app's
/// `CachingPageProvider`): `<appSupport>/dev.dreamfold.Ancestor-Research/
/// page-cache/<idempotencyKey>.html`, key computed identically.
///
/// CACHE-MISS POLICY (conservative, ENGINE_FOUNDATION #Change8): the MCP has no
/// app network layer and re-fetching from a bare CLI risks hammering volunteer
/// sources (FreeBMD circuit-breaker). On a miss it throws `PageCacheMiss`, which
/// the re-check turns into a `.bounced(flag: .pageNotCached)` — can't verify, so
/// don't auto-approve. (The app's provider fetches on a miss; the MCP does not.)
struct CachingPageProvider: PageProvider {
    /// The page-cache directory (the app's Application Support page-cache).
    let cacheDirectory: URL

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    /// Derive the app's page-cache directory from the project DB path.
    ///
    /// The app is sandboxed: its projects live at
    /// `…/Application Support/AncestorResearch/projects/*.sqlite`, and the
    /// page-cache is a sibling under the same Application Support root at
    /// `Application Support/dev.dreamfold.Ancestor-Research/page-cache/`. The
    /// MCP (unsandboxed) can't use its own `applicationSupportDirectory` — it
    /// must walk up from the DB path to the `Application Support` ancestor.
    static func cacheDirectory(forProjectDBPath dbPath: String) -> URL? {
        var dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        // Walk up to the "Application Support" ancestor.
        while dir.lastPathComponent != "Application Support" {
            let parent = dir.deletingLastPathComponent()
            if parent == dir { return nil }   // reached filesystem root
            dir = parent
        }
        return dir
            .appendingPathComponent("dev.dreamfold.Ancestor-Research", isDirectory: true)
            .appendingPathComponent("page-cache", isDirectory: true)
    }

    func cacheFileURL(for url: String) -> URL {
        let key = EvidenceMatch.idempotencyKey(profileID: "", field: "", value: "", sourceURL: url)
        return cacheDirectory.appendingPathComponent("\(key).html")
    }

    func page(for url: String) async throws -> PageFetchResult {
        let file = cacheFileURL(for: url)
        guard let cached = try? Data(contentsOf: file) else {
            throw PageCacheMiss()
        }
        return PageFetchResult(text: decode(cached), servedFromCache: true)
    }

    private func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
