import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Connector-audit batch 2 for FreeCen (CONNECTOR_AUDIT_2026-07 §2.2/§2.4):
///
/// - FT-11: `search_query[birth_chapman_codes][]` — the BIRTH-county axis,
///   distinct from the residence filter. One birth-county query reaches
///   subjects wherever they lived at census time; the dispatcher uses it
///   for `.adjacent`/`.national` (see ResearchScopeHierarchyTests for the
///   dispatcher shape; this file pins the wire emission).
/// - FT-14: `FreeCenParams.censusYear` was write-only and the `validYears`
///   guard dead — an off-year (MLX-suggested "FreeCen 1885") went on the
///   wire as a non-existent `record_type` option. Now: typed param
///   preferred, non-census years return `.outsideCoverage` naming the set
///   (Python parity: "Invalid census year", sources/freecen.py:165-166).
/// - FT-20/FT-26: page-state triage — only a positively identified results
///   page yields records, only positively identified empties are clean
///   negatives; anything else is `.unavailable`, never a cacheable [].
/// - FT-22 (fetching half): the pagination nav is walked through existing
///   pacing to a conservative budget (mirrors ProbateSource's 500 pattern),
///   with `truncated` recomputed honestly after paging.

// MARK: - Shared fixtures

private nonisolated enum FCFixtures {
    static let formURL = URL(string: "https://www.freecen.org.uk/search_records")!
    static let postURL = URL(string: "https://www.freecen.org.uk/search_queries")!
    static let page2URL = URL(string: "https://www.freecen.org.uk/search_queries/abc123?page=2")!

    static let csrfHTML = #"<meta name="csrf-token" content="test-token">"#

    /// Page 1 of a 4-hit answer: 2 rows + a kaminari next link.
    static let resultsPage1 = """
    We found 4 Results
    <table>
    <tr><th>View</th><th>Name</th><th>Birth County</th><th>Birth Place</th><th>Birth Year</th><th>Census Year</th><th>County</th><th>District</th></tr>
    <tr><td><a href="/search_records/aaa111">View</a></td><td>John Smith</td><td>Derbyshire</td><td>Belper</td><td>1850</td><td>1891</td><td>Derbyshire</td><td>Belper</td></tr>
    <tr><td><a href="/search_records/bbb222">View</a></td><td>John Smith</td><td>Derbyshire</td><td>Heage</td><td>1852</td><td>1891</td><td>Lancashire</td><td>Bolton</td></tr>
    </table>
    <nav class="pagination"><a rel="next" href="/search_queries/abc123?page=2">Next</a></nav>
    """

    /// Page 2: the remaining 2 rows, no further pages.
    static let resultsPage2 = """
    We found 4 Results
    <table>
    <tr><th>View</th><th>Name</th><th>Birth County</th><th>Birth Place</th><th>Birth Year</th><th>Census Year</th><th>County</th><th>District</th></tr>
    <tr><td><a href="/search_records/ccc333">View</a></td><td>John Smith</td><td>Derbyshire</td><td>Duffield</td><td>1849</td><td>1891</td><td>Yorkshire</td><td>Leeds</td></tr>
    <tr><td><a href="/search_records/ddd444">View</a></td><td>John Smith</td><td>Derbyshire</td><td>Ripley</td><td>1851</td><td>1891</td><td>Derbyshire</td><td>Ripley</td></tr>
    </table>
    """

    /// Page 1 claims 30 hits, shows 2, and its next page will 404 —
    /// the partial answer must survive with truncated == true.
    static let partialPage = resultsPage1.replacingOccurrences(
        of: "We found 4 Results", with: "We found 30 Results"
    )

    static let noResultsHTML = "<html><body><h2>No results found</h2></body></html>"
    static let zeroCountHTML = "<html><body>We found 0 Results</body></html>"
    static let maintenanceHTML = "<html><body><h1>Scheduled maintenance — back soon</h1></body></html>"

    static func query(
        yearFrom: Int? = 1891,
        params: FreeCenParams = FreeCenParams(chapmanCode: "DBY", censusYear: 1891, birthYearRange: nil)
    ) -> RecordQuery {
        RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .census,
            yearFrom: yearFrom, yearTo: yearFrom, gender: .male, region: nil,
            sourceParams: .freeCen(params),
            strictness: .strict
        )
    }
}

// MARK: - FT-11: birth-county axis emission

@MainActor
struct FreeCenBirthChapmanAxisTests {

    @Test func birthAxisEmitsBirthChapmanCodesAndOmitsResidenceFilter() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = FCFixtures.query(params: FreeCenParams(
            chapmanCode: nil, censusYear: 1891, birthYearRange: nil, birthChapmanCode: "DBY"
        ))
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[birth_chapman_codes][]=DBY"),
                "birth axis must reach the wire; body was \(body)")
        #expect(!body.contains("search_query[chapman_codes][]"),
                "residence filter must be OMITTED entirely on the birth axis (absent Rails array param = no filter); body was \(body)")
    }

    @Test func residenceAxisUnchangedAndOmitsBirthChapman() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        _ = await source.search(FCFixtures.query())
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[chapman_codes][]=DBY"),
                "residence axis is the historical behaviour for .county; body was \(body)")
        #expect(!body.contains("birth_chapman_codes"),
                "no birth filter unless the param is set; body was \(body)")
    }

    @Test func bothAxesCanCoexistOnTheWire() async {
        // Not a dispatcher shape today (exactly one axis per query), but
        // the connector must not silently drop one if a future focused
        // query sets both.
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = FCFixtures.query(params: FreeCenParams(
            chapmanCode: "LAN", censusYear: 1891, birthYearRange: nil, birthChapmanCode: "DBY"
        ))
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[chapman_codes][]=LAN"))
        #expect(body.contains("search_query[birth_chapman_codes][]=DBY"))
    }

    @Test func neitherAxisIsOutsideCoverageWithoutTouchingTheWire() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = FCFixtures.query(params: FreeCenParams(
            chapmanCode: nil, censusYear: 1891, birthYearRange: nil, birthChapmanCode: nil
        ))
        let envelope = await source.searchWithOutcome(query)
        guard case .outsideCoverage = envelope.result else {
            Issue.record("expected .outsideCoverage, got \(envelope.result)")
            return
        }
        #expect(captured.lastFormBody == nil, "no POST may fire without a geographic axis")
    }
}

// MARK: - FT-14: census-year guard

@MainActor
struct FreeCenCensusYearGuardTests {

    @Test func nonCensusYearIsOutsideCoverageNamingTheValidSet() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = FCFixtures.query(
            yearFrom: 1885,
            params: FreeCenParams(chapmanCode: "DBY", censusYear: nil, birthYearRange: nil)
        )
        let envelope = await source.searchWithOutcome(query)
        guard case .outsideCoverage(let reason) = envelope.result else {
            Issue.record("expected .outsideCoverage, got \(envelope.result)")
            return
        }
        #expect(reason.contains("1885"), "reason should name the rejected year")
        #expect(reason.contains("1881") && reason.contains("1891"),
                "reason should name the valid census years")
        #expect(captured.lastFormBody == nil,
                "an off-year must never reach the wire as a non-existent record_type option")
        #expect(!envelope.outcome.isCleanNegative,
                "nothing was searched — must not read as a negative")
    }

    @Test func typedCensusYearParamOverridesQueryYearFrom() async {
        // The strategist's FocusedQuery path sets only yearFrom; the main
        // dispatcher sets both. When the typed param IS present it wins —
        // the previously write-only field is now the source of truth.
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = FCFixtures.query(
            yearFrom: 1885,
            params: FreeCenParams(chapmanCode: "DBY", censusYear: 1881, birthYearRange: nil)
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[record_type]=1881"),
                "typed censusYear must win over an off-year yearFrom; body was \(body)")
    }

    @Test func validCensusYearPassesTheGuard() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        _ = await source.search(FCFixtures.query(yearFrom: 1911, params: FreeCenParams(
            chapmanCode: "DBY", censusYear: 1911, birthYearRange: nil
        )))
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[record_type]=1911"))
    }

    @Test func nilYearSearchesAllYearsUnguarded() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        _ = await source.search(FCFixtures.query(yearFrom: nil, params: FreeCenParams(
            chapmanCode: "DBY", censusYear: nil, birthYearRange: nil
        )))
        #expect(captured.lastFormBody != nil,
                "nil year = all-years search, still dispatched")
    }
}

// MARK: - FT-20 / FT-26: page-state triage

@MainActor
struct FreeCenPageTriageTests {

    @Test func countMarkerClassifiesAsResults() {
        #expect(FreeCenSource.classifyResultsPage(FCFixtures.resultsPage1) == .results)
    }

    @Test func zeroCountClassifiesAsEmpty() {
        #expect(FreeCenSource.classifyResultsPage(FCFixtures.zeroCountHTML) == .empty)
    }

    @Test func noResultsCopyClassifiesAsEmpty() {
        #expect(FreeCenSource.classifyResultsPage(FCFixtures.noResultsHTML) == .empty)
    }

    @Test func maintenancePageIsUnparseableNotEmpty() {
        guard case .unparseable = FreeCenSource.classifyResultsPage(FCFixtures.maintenanceHTML) else {
            Issue.record("a page with neither marker must be unparseable")
            return
        }
    }

    @Test func validationBannerIsUnparseableWithSpecificReason() {
        let html = "<h2>1 error prohibited this search_query from being saved</h2>"
        guard case .unparseable(let reason) = FreeCenSource.classifyResultsPage(html) else {
            Issue.record("validation error must not classify as results/empty")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("validation"))
    }

    @Test func unparseablePageBecomesUnavailableNeverCacheableEmpty() async {
        let http = FixtureHTTPClient(
            getFixtures: [FCFixtures.formURL: Data(FCFixtures.csrfHTML.utf8)],
            postFixtures: [FCFixtures.postURL: Data(FCFixtures.maintenanceHTML.utf8)]
        )
        let source = FreeCenSource(http: http)
        let envelope = await source.searchWithOutcome(FCFixtures.query())
        guard case .unavailable = envelope.result else {
            Issue.record("expected .unavailable, got \(envelope.result)")
            return
        }
        #expect(!envelope.outcome.isCleanNegative)
        guard case .error = envelope.outcome.availability else {
            Issue.record("availability must be .error")
            return
        }
    }

    @Test func genuineEmptyPageIsACleanNegative() async {
        let http = FixtureHTTPClient(
            getFixtures: [FCFixtures.formURL: Data(FCFixtures.csrfHTML.utf8)],
            postFixtures: [FCFixtures.postURL: Data(FCFixtures.noResultsHTML.utf8)]
        )
        let source = FreeCenSource(http: http)
        let envelope = await source.searchWithOutcome(FCFixtures.query())
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.isEmpty)
        #expect(envelope.outcome.isCleanNegative,
                "a positively identified no-results page is the ONLY empty that counts as negative evidence")
    }
}

// MARK: - FT-22: multi-page fetching

@MainActor
struct FreeCenPaginationTests {

    @Test func nextPageURLParsesRelNext() {
        let url = FreeCenSource.nextPageURL(FCFixtures.resultsPage1)
        #expect(url == "https://www.freecen.org.uk/search_queries/abc123?page=2")
    }

    @Test func nextPageURLParsesWillPaginateClass() {
        let html = #"<div class="pagination"><a class="next_page" href="/search_queries/x?page=3">Next</a></div>"#
        #expect(FreeCenSource.nextPageURL(html) == "https://www.freecen.org.uk/search_queries/x?page=3")
    }

    @Test func nextPageURLUnescapesAmpersands() {
        let html = #"<a rel="next" href="/search_queries/x?page=2&amp;per_page=50">Next</a>"#
        #expect(FreeCenSource.nextPageURL(html) == "https://www.freecen.org.uk/search_queries/x?page=2&per_page=50")
    }

    @Test func disabledNextSpanYieldsNoURL() {
        let html = #"<div class="pagination"><span class="next_page disabled">Next</span></div>"#
        #expect(FreeCenSource.nextPageURL(html) == nil)
    }

    @Test func noNavYieldsNoURL() {
        #expect(FreeCenSource.nextPageURL(FCFixtures.resultsPage2) == nil)
    }

    @Test func fetchesAllPagesAndReportsComplete() async {
        let http = FixtureHTTPClient(
            getFixtures: [
                FCFixtures.formURL: Data(FCFixtures.csrfHTML.utf8),
                FCFixtures.page2URL: Data(FCFixtures.resultsPage2.utf8),
            ],
            postFixtures: [FCFixtures.postURL: Data(FCFixtures.resultsPage1.utf8)]
        )
        let source = FreeCenSource(http: http)
        let envelope = await source.searchWithOutcome(FCFixtures.query())
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 4, "both pages' rows must be returned")
        #expect(envelope.outcome.totalAvailable == 4)
        #expect(envelope.outcome.truncated == false,
                "all claimed rows fetched — the answer is complete")
        #expect(envelope.outcome.isConclusive)
    }

    @Test func failedFollowUpPageKeepsPartialAnswerWithHonestTruncation() async {
        // Page 2 GET will 404 (no fixture): page 1's rows must survive
        // and the envelope must say the answer is partial — never an
        // error that discards data, never a silently complete answer.
        let http = FixtureHTTPClient(
            getFixtures: [FCFixtures.formURL: Data(FCFixtures.csrfHTML.utf8)],
            postFixtures: [FCFixtures.postURL: Data(FCFixtures.partialPage.utf8)]
        )
        let source = FreeCenSource(http: http)
        let envelope = await source.searchWithOutcome(FCFixtures.query())
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 2, "page-1 rows survive the failed page-2 fetch")
        #expect(envelope.outcome.totalAvailable == 30)
        #expect(envelope.outcome.truncated == true)
        #expect(!envelope.outcome.isConclusive)
    }

    @Test func recordBudgetMirrorsProbatePattern() {
        // The audit's instruction: conservative budget mirroring the
        // Probate 500 pattern (T1-24 port). Pin the mirror so the
        // constants can't drift apart silently.
        #expect(FreeCenSource.maxResults == ProbateSource.maxResults)
        #expect(FreeREGSource.maxResults == ProbateSource.maxResults)
        #expect(FreeCenSource.maxPages == 10)
        #expect(FreeREGSource.maxPages == 10)
    }
}
