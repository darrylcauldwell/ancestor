import Testing
import Foundation
@testable import Ancestor_Research

/// §14.B.1 defensive hallucination re-check (ENGINE_FOUNDATION #Change8).
///
/// Security-sensitive: this is the guard that stops the local MLX model's
/// hallucinated facts from auto-writing to the tree. These tests exercise the
/// four acceptance criteria:
///  1. Planted hallucination (a claim NOT on the cited page) → bounce fires,
///     hallucination flag set, fact stays in pending_facts (never approved).
///  2. Real claim (the fact IS on the page) → approve fires.
///  3. Re-fetch hits the page cache when available — no double-fetch
///     (asserted via a counting fake).
///  4. Audit log records the decision per claim.
struct HallucinationRecheckTests {

    // MARK: - Fixtures

    /// A page fixture whose text really does contain the claim.
    static let realPage = """
        <html><body>
        Baptism register — Wirksworth, Derbyshire.
        Thomas, son of William Land, baptised 6 April 1834.
        </body></html>
        """

    /// A page fixture that does NOT contain the planted (hallucinated) claim.
    /// It talks about a different person and a different year.
    static let unrelatedPage = """
        <html><body>
        Baptism register — Wirksworth, Derbyshire.
        Mary, daughter of John Smith, baptised 2 May 1799.
        </body></html>
        """

    let realURL = "https://www.freereg.org.uk/search_records/thomas-land"

    func makeFinding(
        field: String = "birthDate",
        value: String = "6 April 1834",
        sourceURL: String? = nil,
        evidenceText: String = "Thomas, son of William Land, baptised 6 April 1834"
    ) -> PendingFact {
        PendingFact(
            id: "test-\(UUID().uuidString.prefix(8))",
            profileID: "profile-thomas-land",
            field: field, value: value,
            sourceURL: sourceURL ?? realURL, sourceTitle: "FreeREG baptism",
            evidenceText: evidenceText,
            reasoning: "test", confidence: "high",
            agentID: "field-researcher", submittedAt: Date(),
            verificationStatus: .pending
        )
    }

    // MARK: - Counting fake PageProvider

    /// A page provider that (a) serves from a warm in-memory cache when primed,
    /// counting cache hits with zero fetches, and (b) counts every network fetch
    /// so tests can assert no double-fetch. Actor-isolated so concurrent access
    /// to the counters is safe.
    actor CountingPageProvider: PageProvider {
        private let pagesByURL: [String: String]
        /// URLs pre-populated in the page-cache (served without a fetch).
        private var warmCacheURLs: Set<String>
        private(set) var fetchCount = 0
        private(set) var cacheHitCount = 0

        init(pages: [String: String], warmCache: Set<String> = []) {
            self.pagesByURL = pages
            self.warmCacheURLs = warmCache
        }

        func page(for url: String) async throws -> PageFetchResult {
            guard let text = pagesByURL[url] else {
                throw HallucinationRecheckError.badStatus(404)
            }
            if warmCacheURLs.contains(url) {
                cacheHitCount += 1
                return PageFetchResult(text: text, servedFromCache: true)
            }
            fetchCount += 1
            // Simulate write-back: subsequent reads are cache hits.
            warmCacheURLs.insert(url)
            return PageFetchResult(text: text, servedFromCache: false)
        }

        func counts() -> (fetches: Int, cacheHits: Int) { (fetchCount, cacheHitCount) }
    }

    /// A provider that fails every fetch — for the fetch-failure bounce path.
    struct FailingPageProvider: PageProvider {
        func page(for url: String) async throws -> PageFetchResult {
            throw HallucinationRecheckError.badStatus(503)
        }
    }

    // MARK: - Acceptance 1: planted hallucination bounces

    @Test func plantedHallucinationBounces() async {
        // The extraction claims a fact that is NOT on the cited page.
        let finding = makeFinding(
            value: "6 April 1834",
            evidenceText: "Thomas, son of William Land, baptised 6 April 1834"
        )
        // …but the page served is unrelated (different person, year 1799).
        let provider = CountingPageProvider(pages: [realURL: Self.unrelatedPage])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(!audit.approved)                                   // never approved
        #expect(audit.flag == .claimNotOnPage)                     // hallucination flag set
        #expect(audit.decision == .bounced(flag: .claimNotOnPage)) // bounce fired
    }

    @Test func hallucinatedYearBouncesEvenWhenEvidenceAbsent() async {
        // Value asserts a year the page never mentions; evidence text also absent.
        let finding = makeFinding(value: "1901", evidenceText: "")
        let provider = CountingPageProvider(pages: [realURL: Self.realPage])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(!audit.approved)
        #expect(audit.flag == .claimNotOnPage)
    }

    // MARK: - Acceptance 2: real claim approves

    @Test func realClaimApproves() async {
        let finding = makeFinding(
            value: "6 April 1834",
            evidenceText: "Thomas, son of William Land, baptised 6 April 1834"
        )
        let provider = CountingPageProvider(pages: [realURL: Self.realPage])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(audit.approved)
        #expect(audit.decision == .approved)
        #expect(audit.flag == nil)
    }

    @Test func realClaimApprovesWhenValueYearPresentAndEvidenceMatches() async {
        // Evidence excerpt matches and year 1834 is on the page.
        let finding = makeFinding(
            value: "1834",
            evidenceText: "baptised 6 April 1834"
        )
        let provider = CountingPageProvider(pages: [realURL: Self.realPage])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(audit.approved)
    }

    // MARK: - Acceptance 3: cache hit, no double-fetch

    @Test func recheckHitsPageCacheNoDoubleFetch() async {
        // The URL is already warm in the page-cache (fetched during original
        // extraction). The re-check must serve from cache with zero fetches.
        let provider = CountingPageProvider(
            pages: [realURL: Self.realPage],
            warmCache: [realURL]
        )
        let finding = makeFinding()

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(audit.approved)
        #expect(audit.servedFromCache)                    // audit proves cache reuse
        let counts = await provider.counts()
        #expect(counts.fetches == 0)                      // no network fetch
        #expect(counts.cacheHits == 1)
    }

    @Test func secondRecheckReusesWriteBackCacheNoSecondFetch() async {
        // Cold cache: first re-check fetches once and writes back; a second
        // re-check of the same URL must be a cache hit (no double-fetch).
        let provider = CountingPageProvider(pages: [realURL: Self.realPage])
        let finding = makeFinding()

        let first = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)
        #expect(!first.servedFromCache)                   // first was a real fetch

        let second = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)
        #expect(second.servedFromCache)                   // second reused the cache

        let counts = await provider.counts()
        #expect(counts.fetches == 1)                      // exactly one fetch total
        #expect(counts.cacheHits == 1)
    }

    /// End-to-end cache proof through the real `CachingPageProvider` against a
    /// temp on-disk cache directory: a page written to the cache is reused with
    /// no fetch, and the injected fetch closure is never called.
    @Test func cachingPageProviderReadsOnDiskCacheWithoutFetching() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recheck-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-write the page-cache file using the exact key scheme the firewall uses.
        let key = EvidenceFirewall.idempotencyKey(profileID: "", field: "", value: "", sourceURL: realURL)
        let cacheFile = tmpDir.appendingPathComponent("\(key).html")
        try Data(Self.realPage.utf8).write(to: cacheFile)

        // A fetch closure that FAILS the test if ever called.
        let fetchCalled = FetchFlag()
        let provider = CachingPageProvider(cacheDirectory: tmpDir) { _ in
            await fetchCalled.mark()
            return Data()
        }

        let finding = makeFinding()
        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(audit.approved)
        #expect(audit.servedFromCache)
        #expect(!(await fetchCalled.wasCalled))           // fetch closure never ran
    }

    actor FetchFlag {
        private(set) var wasCalled = false
        func mark() { wasCalled = true }
    }

    // MARK: - Acceptance 4: audit records the decision per claim

    @Test func auditRecordsApproveDecision() async {
        let finding = makeFinding()
        let provider = CountingPageProvider(pages: [realURL: Self.realPage])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(audit.profileID == finding.profileID)
        #expect(audit.field == finding.field)
        #expect(audit.value == finding.value)
        #expect(audit.sourceURL == finding.sourceURL)
        #expect(audit.approved)
        #expect(audit.flag == nil)
        #expect(audit.summary.contains("APPROVED"))
        #expect(audit.checkedAt.timeIntervalSinceNow < 5)
    }

    @Test func auditRecordsBounceDecisionWithFlag() async {
        let finding = makeFinding()
        let provider = CountingPageProvider(pages: [realURL: Self.unrelatedPage])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(!audit.approved)
        #expect(audit.flag == .claimNotOnPage)
        #expect(audit.summary.contains("BOUNCED"))
        #expect(audit.summary.contains("claim_not_on_page"))
    }

    // MARK: - Conservative bounces (when in doubt, bounce)

    @Test func blockedURLBounces() async {
        let finding = makeFinding(sourceURL: "https://chatgpt.com/share/abc")
        // Provider would serve a matching page, but the URL is blocked first.
        let provider = CountingPageProvider(pages: ["https://chatgpt.com/share/abc": Self.realPage])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(!audit.approved)
        #expect(audit.flag == .urlBlocked)
        let counts = await provider.counts()
        #expect(counts.fetches == 0)                      // never even fetched
    }

    @Test func emptyURLBounces() async {
        let finding = makeFinding(sourceURL: "")
        let provider = CountingPageProvider(pages: [:])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(!audit.approved)
        #expect(audit.flag == .urlInvalid)
    }

    @Test func fetchFailureBounces() async {
        let finding = makeFinding()
        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: FailingPageProvider())

        #expect(!audit.approved)
        #expect(audit.flag == .fetchFailed)
    }

    @Test func emptyPageBounces() async {
        let finding = makeFinding()
        let provider = CountingPageProvider(pages: [realURL: "   \n  "])

        let audit = await EvidenceFirewall.recheckForAutoApproval(finding: finding, pages: provider)

        #expect(!audit.approved)
        #expect(audit.flag == .emptyPage)
    }

    // MARK: - Deterministic re-extraction unit checks

    @Test func claimAppearsIsPureContentMatch() {
        let claim = HallucinationRecheck.Claim(
            profileID: "p", field: "birthDate", value: "6 April 1834",
            sourceURL: realURL,
            evidenceText: "baptised 6 April 1834"
        )
        #expect(HallucinationRecheck.claimAppears(claim, onPageText: Self.realPage))
        #expect(!HallucinationRecheck.claimAppears(claim, onPageText: Self.unrelatedPage))
        #expect(!HallucinationRecheck.claimAppears(claim, onPageText: ""))
    }
}
