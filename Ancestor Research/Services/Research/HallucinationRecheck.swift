import Foundation
import os
import CryptoKit

/// §14.B.1 — Defensive hallucination re-check.
///
/// Security-sensitive. This is the guard that stops the local MLX model's
/// hallucinated facts from auto-writing to the tree. Before an auto-approval
/// candidate is allowed to commit, the engine must independently re-fetch the
/// cited source and confirm the specific claim actually appears on the page.
///
/// The check is **deterministic** — it never invokes the MLX model. It reuses
/// the Evidence Firewall's normalised content-matching (`EvidenceFirewall`'s
/// `normalise` + substring `contains`) so the re-extraction is a pure text
/// operation. The trust tier is still derived from the URL by
/// `SourceTierRegistry`; this re-check asserts no tier and never upgrades one.
/// This keeps the deterministic sandwich intact: AI proposes, rules decide.
///
/// Re-check flow (spec §14.B.1 / ENGINE_FOUNDATION #Change8):
/// 1. Re-fetch the cited URL — **page-cache first**, so a page already fetched
///    during the original extraction incurs no extra rate cost.
/// 2. Re-extract the specific claim from the re-fetched page (deterministic
///    content match of the claimed value and evidence text).
/// 3. If the claim is confirmed on the page → `.approved`.
/// 4. Otherwise → `.bounced` with a hallucination flag; the caller keeps the
///    fact in `pending_facts` for human review.
///
/// **Conservative by construction.** Anything that isn't a clean confirmation
/// (fetch failure, restricted/paywalled source, empty page, blocked URL,
/// evidence-not-found) bounces. When in doubt, bounce to pending_facts.
nonisolated enum HallucinationRecheck {

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "HallucinationRecheck"
    )

    // MARK: - Claim under re-check

    /// The specific claim being re-verified against its cited source. Mirrors
    /// the fields of a `pending_facts` row that matter for content matching.
    struct Claim: Sendable, Equatable {
        let profileID: String
        let field: String
        let value: String
        let sourceURL: String
        /// The <=200-char excerpt the original extraction said it saw on the page.
        let evidenceText: String

        init(profileID: String, field: String, value: String, sourceURL: String, evidenceText: String) {
            self.profileID = profileID
            self.field = field
            self.value = value
            self.sourceURL = sourceURL
            self.evidenceText = String(evidenceText.prefix(EvidenceFirewall.maxEvidenceTextLength))
        }

        /// Build a claim from an in-flight firewall finding.
        init(finding: PendingFact) {
            self.init(
                profileID: finding.profileID,
                field: finding.field,
                value: finding.value,
                sourceURL: finding.sourceURL,
                evidenceText: finding.evidenceText
            )
        }
    }

    // MARK: - Decision

    /// The outcome of a single claim re-check.
    enum Decision: Equatable, Sendable {
        /// Re-extraction matched the original claim — safe to proceed to approval.
        case approved
        /// Re-extraction did not confirm the claim — bounce to `pending_facts`
        /// with a hallucination flag. Carries the machine-readable flag reason.
        case bounced(flag: HallucinationFlag)

        var isApproved: Bool {
            if case .approved = self { return true }
            return false
        }
    }

    /// Why a claim was bounced. Every non-approval maps to exactly one flag so
    /// the reason is auditable and testable.
    enum HallucinationFlag: String, Equatable, Sendable {
        /// The claimed value / evidence text was not found on the re-fetched page.
        case claimNotOnPage = "claim_not_on_page"
        /// The cited URL is blocked (social media, AI-generated, etc.).
        case urlBlocked = "url_blocked"
        /// The URL is malformed or empty — cannot re-verify.
        case urlInvalid = "url_invalid"
        /// Paywalled / restricted source — content cannot be independently re-fetched.
        case sourceRestricted = "source_restricted"
        /// Network / HTTP failure re-fetching the page.
        case fetchFailed = "fetch_failed"
        /// The re-fetched page was empty — nothing to match against.
        case emptyPage = "empty_page"
        /// The original extraction carried no evidence text and no value to anchor on.
        case noClaimAnchor = "no_claim_anchor"
    }

    // MARK: - Audit record

    /// A per-claim audit entry the caller logs / persists. Records the re-check
    /// decision and the inputs that produced it (§14.B.1: "Audit log records the
    /// re-check decision per claim").
    struct AuditEntry: Sendable, Equatable {
        let profileID: String
        let field: String
        let value: String
        let sourceURL: String
        let decision: Decision
        /// Whether the page came from the on-disk page-cache (no network fetch)
        /// or was fetched fresh. Proves cache reuse for auditing/testing.
        let servedFromCache: Bool
        let checkedAt: Date

        var approved: Bool { decision.isApproved }

        /// Machine-readable flag when bounced, else nil.
        var flag: HallucinationFlag? {
            if case .bounced(let flag) = decision { return flag }
            return nil
        }

        /// One-line, log-safe summary.
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
    /// - Parameters:
    ///   - claim: the claim to re-verify.
    ///   - pages: the page provider — checks the page-cache first, only fetches
    ///     on a miss. Inject a counting fake in tests to prove no double-fetch.
    /// - Returns: an audit entry carrying the decision. The caller approves only
    ///   on `.approved`; on `.bounced` the fact stays in `pending_facts`.
    static func recheck(
        claim: Claim,
        pages: any PageProvider
    ) async -> AuditEntry {
        let now = Date()

        // Guard 1: URL must be present and well-formed.
        guard !claim.sourceURL.isEmpty, URL(string: claim.sourceURL) != nil else {
            return audit(claim, .bounced(flag: .urlInvalid), servedFromCache: false, at: now)
        }

        // Guard 2: blocked URLs never re-verify (social media, AI-generated, …).
        let (blocked, reason) = SourceTierRegistry.isBlocked(url: claim.sourceURL)
        if blocked {
            logger.info("Recheck bounced (blocked URL: \(reason, privacy: .public))")
            return audit(claim, .bounced(flag: .urlBlocked), servedFromCache: false, at: now)
        }

        // Guard 3: restricted / paywalled sources can't be independently re-fetched.
        // The trust tier is URL-derived; we never assert it. A restricted source
        // means we cannot prove the claim, so — conservatively — we bounce.
        if SourceTierRegistry.isRestricted(url: claim.sourceURL) {
            logger.info("Recheck bounced (restricted source — cannot re-verify content)")
            return audit(claim, .bounced(flag: .sourceRestricted), servedFromCache: false, at: now)
        }

        // Guard 4: we need something to anchor the re-extraction on.
        if claim.evidenceText.isEmpty && claim.value.isEmpty {
            return audit(claim, .bounced(flag: .noClaimAnchor), servedFromCache: false, at: now)
        }

        // Step 1: re-fetch — page-cache first.
        let fetched: PageFetchResult
        do {
            fetched = try await pages.page(for: claim.sourceURL)
        } catch {
            logger.info("Recheck bounced (fetch failed: \(error.localizedDescription, privacy: .public))")
            return audit(claim, .bounced(flag: .fetchFailed), servedFromCache: false, at: now)
        }

        // A page that carries no meaningful content once normalised (empty,
        // or whitespace/markup-only) can't corroborate anything — bounce it
        // distinctly from "content present but claim absent".
        let normalisedPage = EvidenceFirewall.normalise(fetched.text)
        guard !normalisedPage.isEmpty else {
            return audit(claim, .bounced(flag: .emptyPage), servedFromCache: fetched.servedFromCache, at: now)
        }

        // Step 2 + 3: deterministic re-extraction — the claim must appear on the
        // re-fetched page. Both the evidence excerpt (what the extractor said it
        // saw) and the claimed value must be present.
        let confirmed = claimAppears(claim, onPageText: fetched.text)
        let decision: Decision = confirmed ? .approved : .bounced(flag: .claimNotOnPage)

        let entry = audit(claim, decision, servedFromCache: fetched.servedFromCache, at: now)
        logger.info("\(entry.summary, privacy: .public)")
        return entry
    }

    // MARK: - Deterministic re-extraction

    /// Deterministically re-extract the claim: is it present on the page text?
    ///
    /// Reuses `EvidenceFirewall.normalise` (lowercase, whitespace-collapsed) so
    /// this matches the firewall's original content-matching semantics exactly.
    ///
    /// A claim is confirmed only if BOTH hold:
    /// - the evidence excerpt (if any) appears on the page, AND
    /// - a content anchor for the claimed value appears on the page.
    ///
    /// This is intentionally stricter than the firewall's original
    /// evidence-only check: a page that no longer contains the specific value
    /// the fact asserts (e.g. the extractor hallucinated a year the page never
    /// mentioned) must fail even if some generic evidence sentence still matches.
    static func claimAppears(_ claim: Claim, onPageText pageText: String) -> Bool {
        let page = EvidenceFirewall.normalise(pageText)
        guard !page.isEmpty else { return false }

        // Evidence excerpt must appear (when present).
        if !claim.evidenceText.isEmpty {
            let evidence = EvidenceFirewall.normalise(claim.evidenceText)
            if !evidence.isEmpty, !page.contains(evidence) {
                return false
            }
        }

        // Value anchor must appear. For date-like values we anchor on the year,
        // which is the load-bearing token the fact commits (day/month formatting
        // varies between the source page and the normalised fact value). For
        // non-date values we require the full normalised value string.
        if !claim.value.isEmpty {
            if let year = EvidenceFirewall.extractYear(from: claim.value) {
                if !page.contains(String(year)) { return false }
            } else {
                let value = EvidenceFirewall.normalise(claim.value)
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
nonisolated struct PageFetchResult: Sendable {
    /// The decoded page text (empty if the page could not be decoded).
    let text: String
    /// True when the page was served from the on-disk page-cache with no
    /// network fetch — the audit proof that re-check reuses the cache.
    let servedFromCache: Bool
}

/// Abstraction over page retrieval so the re-check can prefer the page-cache
/// and so tests can inject a counting fake to assert no double-fetch.
nonisolated protocol PageProvider: Sendable {
    /// Return the page for `url`. Implementations must consult the page-cache
    /// first and only fetch on a miss.
    func page(for url: String) async throws -> PageFetchResult
}

/// Production `PageProvider`. Reads the on-disk page-cache written by the
/// Evidence Firewall / `PendingFactsProcessor` (same key + location), and only
/// fetches on a cache miss. A fetched page is written back to the cache so the
/// next re-check is free.
///
/// The cache key and directory match `PendingFactsProcessor.cachePageData`
/// exactly: `Application Support/dev.dreamfold.Ancestor-Research/page-cache/`
/// with filename `idempotencyKey(profileID:"", field:"", value:"", sourceURL:).html`.
nonisolated struct CachingPageProvider: PageProvider {
    /// Fetches a URL on a cache miss. Injected so tests can supply a fake.
    let fetch: @Sendable (URL) async throws -> Data
    /// The page-cache directory. Defaults to the shared Application Support path.
    let cacheDirectory: URL

    init(
        cacheDirectory: URL = CachingPageProvider.defaultCacheDirectory,
        fetch: @escaping @Sendable (URL) async throws -> Data = CachingPageProvider.liveFetch
    ) {
        self.cacheDirectory = cacheDirectory
        self.fetch = fetch
    }

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.dreamfold.Ancestor-Research/page-cache", isDirectory: true)
    }

    /// Live network fetch with the same polite User-Agent the firewall uses.
    @Sendable static func liveFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("AncestorResearch/1.0 (genealogy research)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HallucinationRecheckError.notHTTP
        }
        guard http.statusCode == 200 else {
            throw HallucinationRecheckError.badStatus(http.statusCode)
        }
        return data
    }

    func cacheFileURL(for url: String) -> URL {
        let key = EvidenceFirewall.idempotencyKey(profileID: "", field: "", value: "", sourceURL: url)
        return cacheDirectory.appendingPathComponent("\(key).html")
    }

    func page(for url: String) async throws -> PageFetchResult {
        // Cache-first: a page fetched during the original extraction is reused
        // with no network cost.
        let file = cacheFileURL(for: url)
        if let cached = try? Data(contentsOf: file) {
            return PageFetchResult(text: decode(cached), servedFromCache: true)
        }

        guard let requestURL = URL(string: url) else {
            throw HallucinationRecheckError.invalidURL
        }
        let data = try await fetch(requestURL)

        // Write back so subsequent re-checks are free.
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: file)

        return PageFetchResult(text: decode(data), servedFromCache: false)
    }

    private func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

nonisolated enum HallucinationRecheckError: Error, Equatable {
    case invalidURL
    case notHTTP
    case badStatus(Int)
}
