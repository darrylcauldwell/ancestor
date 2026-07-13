import Testing
import Foundation
@testable import FieldResearcherMCP

/// Unit tests for the §14.B.1 defensive hallucination re-check
/// (ENGINE_FOUNDATION #Change8), the MCP-side self-contained mirror of the
/// app's `HallucinationRecheck` + `EvidenceFirewall`/`SourceTierRegistry`
/// helpers. Pure decision logic against an injected `PageProvider` — no live
/// SQLite, no network. Mirrors `PromoteLeadExpansionBoundTests` (the #Change7
/// pattern) and the app's `HallucinationRecheckTests`.
///
/// The `SyncLock` section is the twin-literal lock: expected decisions/flags
/// for the same inputs the app-side rule produces, so the two deliberately
/// duplicated copies can't drift.
struct HallucinationRecheckTests {

    // A counting fake so we can assert cache-hit reuse (no fetch).
    final class FakePageProvider: PageProvider, @unchecked Sendable {
        let text: String
        let servedFromCache: Bool
        let throwsMiss: Bool
        let throwsError: Bool
        private(set) var callCount = 0

        init(text: String = "", servedFromCache: Bool = true, throwsMiss: Bool = false, throwsError: Bool = false) {
            self.text = text
            self.servedFromCache = servedFromCache
            self.throwsMiss = throwsMiss
            self.throwsError = throwsError
        }

        struct GenericError: Error {}

        func page(for url: String) async throws -> PageFetchResult {
            callCount += 1
            if throwsMiss { throw PageCacheMiss() }
            if throwsError { throw GenericError() }
            return PageFetchResult(text: text, servedFromCache: servedFromCache)
        }
    }

    private func claim(
        value: String = "1887",
        url: String = "https://www.freebmd.org.uk/cgi/search.pl",
        evidence: String = "Ernest Cauldwell born 1887"
    ) -> MCPHallucinationRecheck.Claim {
        MCPHallucinationRecheck.Claim(
            profileID: "P1", field: "birthDate",
            value: value, sourceURL: url, evidenceText: evidence
        )
    }

    // MARK: - Real claim → approved (+ commits, cache-hit reuse)

    @Test func realClaimOnPageApproves() async {
        // The value anchor (1887) AND the evidence excerpt both appear.
        let page = FakePageProvider(text: "Registration index: Ernest Cauldwell born 1887 in Belper district.")
        let entry = await MCPHallucinationRecheck.recheck(claim: claim(), pages: page)
        #expect(entry.decision == .approved)
        #expect(entry.approved)
        #expect(entry.servedFromCache)      // proves cache reuse
        #expect(page.callCount == 1)        // exactly one lookup, no double-fetch
    }

    // MARK: - Planted hallucination → bounced (claim not on page)

    @Test func plantedHallucinationBounces() async {
        // Evidence sentence present, but the claimed YEAR (1887) is not — the
        // extractor hallucinated a year the page never mentioned.
        let page = FakePageProvider(text: "Registration index: Ernest Cauldwell born 1901 in Belper district.")
        let entry = await MCPHallucinationRecheck.recheck(
            claim: claim(value: "1887", evidence: "Ernest Cauldwell born"),
            pages: page
        )
        #expect(entry.decision == .bounced(flag: .claimNotOnPage))
        #expect(!entry.approved)
        #expect(entry.flag == .claimNotOnPage)
    }

    @Test func evidenceNotOnPageBounces() async {
        // The year is present but the specific evidence excerpt is fabricated.
        let page = FakePageProvider(text: "Something unrelated mentioning 1887 only.")
        let entry = await MCPHallucinationRecheck.recheck(
            claim: claim(value: "1887", evidence: "Ernest Cauldwell married Ida Land"),
            pages: page
        )
        #expect(entry.flag == .claimNotOnPage)
    }

    // MARK: - Guards

    @Test func invalidURLBounces() async {
        let entry = await MCPHallucinationRecheck.recheck(
            claim: claim(url: ""), pages: FakePageProvider(text: "x")
        )
        #expect(entry.flag == .urlInvalid)
    }

    @Test func blockedURLBounces() async {
        let entry = await MCPHallucinationRecheck.recheck(
            claim: claim(url: "https://facebook.com/some/post"),
            pages: FakePageProvider(text: "1887 Ernest Cauldwell born")
        )
        #expect(entry.flag == .urlBlocked)
    }

    @Test func restrictedSourceBounces() async {
        let entry = await MCPHallucinationRecheck.recheck(
            claim: claim(url: "https://www.ancestry.co.uk/record/123"),
            pages: FakePageProvider(text: "1887 Ernest Cauldwell born")
        )
        #expect(entry.flag == .sourceRestricted)
    }

    @Test func noClaimAnchorBounces() async {
        let entry = await MCPHallucinationRecheck.recheck(
            claim: MCPHallucinationRecheck.Claim(
                profileID: "P1", field: "birthDate", value: "",
                sourceURL: "https://www.freebmd.org.uk/x", evidenceText: ""
            ),
            pages: FakePageProvider(text: "anything")
        )
        #expect(entry.flag == .noClaimAnchor)
    }

    @Test func emptyPageBounces() async {
        let entry = await MCPHallucinationRecheck.recheck(
            claim: claim(), pages: FakePageProvider(text: "   \n\t  ")
        )
        #expect(entry.flag == .emptyPage)
    }

    // MARK: - Cache-miss → conservative bounce (MCP has no network layer)

    @Test func cacheMissBouncesConservatively() async {
        let page = FakePageProvider(throwsMiss: true)
        let entry = await MCPHallucinationRecheck.recheck(claim: claim(), pages: page)
        #expect(entry.decision == .bounced(flag: .pageNotCached))
        #expect(!entry.approved)
        #expect(!entry.servedFromCache)
    }

    @Test func fetchErrorBounces() async {
        let page = FakePageProvider(throwsError: true)
        let entry = await MCPHallucinationRecheck.recheck(claim: claim(), pages: page)
        #expect(entry.flag == .fetchFailed)
    }

    // MARK: - Non-date value anchors on the full normalised value

    @Test func nonDateValueRequiresFullValue() async {
        // Location value: anchor is the full normalised string, not a year.
        let onPage = FakePageProvider(text: "Born in Cromford, Derbyshire, 1887.")
        let hit = await MCPHallucinationRecheck.recheck(
            claim: MCPHallucinationRecheck.Claim(
                profileID: "P1", field: "birthLocation", value: "Cromford",
                sourceURL: "https://www.freebmd.org.uk/x", evidenceText: "Born in Cromford"
            ),
            pages: onPage
        )
        #expect(hit.decision == .approved)

        let offPage = FakePageProvider(text: "Born in Wirksworth, Derbyshire, 1887.")
        let miss = await MCPHallucinationRecheck.recheck(
            claim: MCPHallucinationRecheck.Claim(
                profileID: "P1", field: "birthLocation", value: "Cromford",
                sourceURL: "https://www.freebmd.org.uk/x", evidenceText: "Born in"
            ),
            pages: offPage
        )
        #expect(miss.flag == .claimNotOnPage)
    }

    // MARK: - SyncLock: twin-literal parity with the app-side rule
    //
    // The app's `HallucinationRecheck.claimAppears` uses the SAME normalise +
    // year-anchor / full-value semantics. These literal expectations pin the
    // MCP copy against that rule. If the app rule changes, these must change in
    // lockstep — that is the intended failure signal (mirrors how
    // PromoteLeadExpansionBoundTests mirrors AncestorKit's ExpansionBoundsTests).

    @Test func syncLock_dateAnchorsOnYearToken() {
        // Date value: only the YEAR token must appear; day/month formatting
        // differences between page and value do NOT matter.
        let c = claim(value: "21 Mar 1887", evidence: "born 1887")
        #expect(MCPHallucinationRecheck.claimAppears(c, onPageText: "record: born 1887, spring quarter"))
        #expect(!MCPHallucinationRecheck.claimAppears(c, onPageText: "record: born 1888, spring quarter"))
    }

    @Test func syncLock_normalisationIsLowercaseWhitespaceCollapse() {
        let c = MCPHallucinationRecheck.Claim(
            profileID: "P1", field: "birthLocation", value: "Cromford Derbyshire",
            sourceURL: "https://www.freebmd.org.uk/x", evidenceText: ""
        )
        // Extra whitespace + mixed case on the page still matches.
        #expect(MCPHallucinationRecheck.claimAppears(c, onPageText: "  CROMFORD    Derbyshire  parish  "))
    }

    @Test func syncLock_bothEvidenceAndValueRequired() {
        // Stricter than evidence-only: evidence present but value absent → fail.
        let c = claim(value: "1887", evidence: "Ernest Cauldwell born")
        #expect(!MCPHallucinationRecheck.claimAppears(c, onPageText: "Ernest Cauldwell born 1999"))
    }

    @Test func syncLock_helperParityWithAppEvidenceFirewall() {
        // The ported helpers reproduce the app's EvidenceFirewall outputs.
        #expect(EvidenceMatch.normalise("  Hello   WORLD ") == "hello world")
        #expect(EvidenceMatch.extractYear(from: "21 Dec 1820") == 1820)
        #expect(EvidenceMatch.extractYear(from: "December") == nil)
        // idempotencyKey: SHA256 of "|||<url>" first 16 bytes hex — same key the
        // app's PendingFactsProcessor.cachePageData uses for the cache filename.
        let key = EvidenceMatch.idempotencyKey(
            profileID: "", field: "", value: "",
            sourceURL: "https://www.freebmd.org.uk/cgi/search.pl"
        )
        #expect(key.count == 32)                       // 16 bytes → 32 hex chars
        #expect(key.allSatisfy { $0.isHexDigit })
        // Deterministic: same URL → same key.
        let key2 = EvidenceMatch.idempotencyKey(
            profileID: "", field: "", value: "",
            sourceURL: "https://www.freebmd.org.uk/cgi/search.pl"
        )
        #expect(key == key2)
    }
}
