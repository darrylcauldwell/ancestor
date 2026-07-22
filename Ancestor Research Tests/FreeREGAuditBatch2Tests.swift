import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Connector-audit batch 2 for FreeREG (CONNECTOR_AUDIT_2026-07 §2.3/§2.4):
///
/// - FT-17: the old maxSplits:1 name split pushed every middle name into
///   the surname ("Sarah Jane Kenworthy" → surname "Jane Kenworthy"),
///   corrupting the scorer's identity gates. Now: the site's own
///   Surname/Forenames columns are preferred; the combined-name fallback
///   takes the LAST token as surname (FreeCen's convention).
/// - FT-18: detail pages (parents for baptisms) are fetched with FreeCen's
///   cap-1 pattern; fatherName/motherName populate from the detail fields
///   and the record's identity (ID, name) never changes across enrichment.
/// - FT-20/FT-26: page-state triage ported from Python
///   (freereg_search.py:182-226) — Rails validation errors, login walls
///   and layout drift are `.unavailable`, never a cacheable [].
/// - FT-22 (fetching half): pagination walked to the shared conservative
///   budget with honest truncation.

// MARK: - Shared fixtures

private nonisolated enum FRFixtures {
    static let formURL = URL(string: "https://www.freereg.org.uk/search_queries/new")!
    static let postURL = URL(string: "https://www.freereg.org.uk/search_queries")!
    static let page2URL = URL(string: "https://www.freereg.org.uk/search_queries/xyz789?page=2")!
    static let detailURL1 = URL(string: "https://www.freereg.org.uk/search_records/abc123")!
    static let detailURL2 = URL(string: "https://www.freereg.org.uk/search_records/def456")!

    static let csrfHTML = #"<meta name="csrf-token" content="test-token">"#

    /// Combined Name column with a middle name — the FT-17 trap.
    static let combinedNameHTML = """
    We found 1 result
    <table>
    <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
    <tr><td><a href="/search_records/abc123">Sarah Jane Kenworthy</a></td><td>12 Mar 1850</td><td>Belper</td><td>Derbyshire</td><td>Baptism</td></tr>
    </table>
    """

    /// Explicit Surname / Forenames columns — the site's own split.
    static let explicitColumnsHTML = """
    We found 1 result
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
    <tr><td>Kenworthy</td><td>Sarah Jane</td><td>12 Mar 1850</td><td>Belper</td><td>Derbyshire</td><td>Baptism</td></tr>
    </table>
    """

    /// Two rows with detail links — for the cap-1 enrichment test.
    static let twoRowResultsHTML = """
    We found 2 results
    <table>
    <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
    <tr><td><a href="/search_records/abc123">Sarah Jane Kenworthy</a></td><td>12 Mar 1850</td><td>Belper</td><td>Derbyshire</td><td>Baptism</td></tr>
    <tr><td><a href="/search_records/def456">Thomas Kenworthy</a></td><td>3 Jun 1852</td><td>Belper</td><td>Derbyshire</td><td>Baptism</td></tr>
    </table>
    """

    /// Baptism detail page — dl-shaped, Python fetch_record_detail's
    /// first shape (freereg_search.py:308-315).
    static let baptismDetailHTML = """
    <dl>
    <dt>Forename</dt><dd>Sarah Jane</dd>
    <dt>Surname</dt><dd>KENWORTHY</dd>
    <dt>Baptism date</dt><dd>12 Mar 1850</dd>
    <dt>Parish</dt><dd>Belper</dd>
    <dt>County</dt><dd>Derbyshire</dd>
    <dt>Father's forename</dt><dd>John</dd>
    <dt>Father's surname</dt><dd>KENWORTHY</dd>
    <dt>Mother's forename</dt><dd>Mary</dd>
    </dl>
    """

    /// Table-shaped detail page — the second shape Python walks.
    static let tableDetailHTML = """
    <table>
    <tr><th>Father's forename</th><td>William</td></tr>
    <tr><th>Mother's forename</th><td>Ann</td></tr>
    <tr><th>Mother's surname</th><td>BROUGH</td></tr>
    </table>
    """

    /// Page 1 of 2 with a kaminari next link; rows carry no detail
    /// links so enrichment stays out of the pagination assertion.
    static let paginatedPage1 = """
    We found 2 results
    <table>
    <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
    <tr><td>Sarah Jane Kenworthy</td><td>12 Mar 1850</td><td>Belper</td><td>Derbyshire</td><td>Baptism</td></tr>
    </table>
    <nav class="pagination"><a rel="next" href="/search_queries/xyz789?page=2">Next</a></nav>
    """

    static let paginatedPage2 = """
    We found 2 results
    <table>
    <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
    <tr><td>Thomas Kenworthy</td><td>3 Jun 1852</td><td>Belper</td><td>Derbyshire</td><td>Baptism</td></tr>
    </table>
    """

    static let validationHTML = """
    <h2>1 error prohibited this search_query from being saved</h2>
    <ul class="errors"><li>First name is too short</li></ul>
    """

    static let noResultsHTML = "<html><body><p>Your search returned no results</p></body></html>"
    static let loginWallHTML = "<html><body><h1>Please sign in to continue</h1></body></html>"
    static let garbageHTML = "<html><body><h1>Gateway timeout</h1></body></html>"

    static func query() -> RecordQuery {
        RecordQuery(
            surname: "Kenworthy", givenName: "Sarah",
            recordType: .baptism,
            yearFrom: 1845, yearTo: 1855, gender: .female, region: nil,
            sourceParams: .freeREG(FreeREGParams(chapmanCode: "DBY")),
            strictness: .strict
        )
    }

    static func parish(_ record: SourceRecord?) -> ParishRecord? {
        guard case .parish(let parish)? = record else { return nil }
        return parish
    }
}

// MARK: - FT-17: name split

@MainActor
struct FreeREGNameSplitTests {

    @Test func middleNamesStayInGivenNameNotSurname() {
        let records = FreeREGSource.parseResults(FRFixtures.combinedNameHTML, recordType: .baptism)
        guard let record = FRFixtures.parish(records.first) else {
            Issue.record("expected one parish record")
            return
        }
        #expect(record.common.surname == "Kenworthy",
                "last token is the surname — FreeCen's convention")
        #expect(record.common.givenName == "Sarah Jane",
                "middle names belong to the given name")
        #expect(record.common.name == "Sarah Jane Kenworthy")
    }

    @Test func explicitSurnameForenamesColumnsArePreferred() {
        let records = FreeREGSource.parseResults(FRFixtures.explicitColumnsHTML, recordType: .baptism)
        guard let record = FRFixtures.parish(records.first) else {
            Issue.record("expected one parish record")
            return
        }
        #expect(record.common.surname == "Kenworthy")
        #expect(record.common.givenName == "Sarah Jane")
        #expect(record.common.name == "Sarah Jane Kenworthy")
    }

    @Test func resolveRowNameStripsMatchingTrailingSurnameFromDisplay() {
        // Combined display alongside an explicit surname column.
        let resolved = FreeREGSource.resolveRowName([
            "name": "Sarah Jane Kenworthy", "surname": "Kenworthy",
        ])
        #expect(resolved?.surname == "Kenworthy")
        #expect(resolved?.givenName == "Sarah Jane")
        #expect(resolved?.name == "Sarah Jane Kenworthy")
    }

    @Test func singleTokenNameHasNoGivenName() {
        let resolved = FreeREGSource.resolveRowName(["name": "Kenworthy"])
        #expect(resolved?.surname == "Kenworthy")
        #expect(resolved?.givenName == nil)
    }

    // T1-C4 (parse half — the transport half rides the shared encoder, covered
    // by SourceHTTPClientEncodingTests). An apostrophe lives inside a name
    // token, so the space-split must keep it intact rather than truncating.
    @Test func apostropheSurnameSurvivesExplicitColumn() {
        let resolved = FreeREGSource.resolveRowName([
            "name": "Mary O'Brien", "surname": "O'Brien", "forenames": "Mary",
        ])
        #expect(resolved?.surname == "O'Brien")
        #expect(resolved?.givenName == "Mary")
    }

    @Test func apostropheSurnameSurvivesDisplayFallback() {
        // No explicit surname column — the last space-delimited token is the
        // surname and the apostrophe must not split it.
        let resolved = FreeREGSource.resolveRowName(["name": "Patrick O'Brien"])
        #expect(resolved?.surname == "O'Brien")
        #expect(resolved?.givenName == "Patrick")
        #expect(resolved?.name == "Patrick O'Brien")
    }
}

// MARK: - FT-18: detail fetching

@MainActor
struct FreeREGDetailFetchTests {

    @Test func parseDetailFieldsReadsDefinitionLists() {
        let fields = FreeREGSource.parseDetailFields(FRFixtures.baptismDetailHTML)
        #expect(fields["fathers_forename"] == "John")
        #expect(fields["fathers_surname"] == "KENWORTHY")
        #expect(fields["mothers_forename"] == "Mary")
        #expect(fields["baptism_date"] == "12 Mar 1850")
    }

    @Test func parseDetailFieldsReadsTwoCellTableRows() {
        let fields = FreeREGSource.parseDetailFields(FRFixtures.tableDetailHTML)
        #expect(fields["fathers_forename"] == "William")
        #expect(fields["mothers_surname"] == "BROUGH")
    }

    @Test func extractParentAssemblesForenamePlusSurname() {
        let fields = FreeREGSource.parseDetailFields(FRFixtures.baptismDetailHTML)
        #expect(FreeREGSource.extractParent(fields, role: "father") == "John KENWORTHY")
        #expect(FreeREGSource.extractParent(fields, role: "mother") == "Mary")
    }

    @Test func mergedDetailRecordPreservesIdentityAndAddsParents() {
        let searchRecords = FreeREGSource.parseResults(FRFixtures.combinedNameHTML, recordType: .baptism)
        guard let base = FRFixtures.parish(searchRecords.first) else {
            Issue.record("expected a search-row record")
            return
        }
        let fields = FreeREGSource.parseDetailFields(FRFixtures.baptismDetailHTML)
        let merged = FRFixtures.parish(FreeREGSource.mergedDetailRecord(base: base, detailFields: fields))
        #expect(merged?.common.id == base.common.id,
                "enrichment must never flip a record's ID (FT-12/FT-16 lesson)")
        #expect(merged?.common.name == base.common.name)
        #expect(merged?.fatherName == "John KENWORTHY")
        #expect(merged?.motherName == "Mary")
        #expect(merged?.common.rawFields["fathers_forename"] == "John",
                "detail fields land in rawFields")
        #expect(merged?.common.rawFields["parish"] == "Belper",
                "search-row rawFields keys win on collision")
    }

    @Test func searchEnrichesTopHitOnlyCapOne() async {
        // Detail fixtures exist for BOTH rows — only the first may be
        // fetched (FreeCen's cap-1 volunteer-budget pattern).
        let http = FixtureHTTPClient(
            getFixtures: [
                FRFixtures.formURL: Data(FRFixtures.csrfHTML.utf8),
                FRFixtures.detailURL1: Data(FRFixtures.baptismDetailHTML.utf8),
                FRFixtures.detailURL2: Data(FRFixtures.baptismDetailHTML.utf8),
            ],
            postFixtures: [FRFixtures.postURL: Data(FRFixtures.twoRowResultsHTML.utf8)]
        )
        let source = FreeREGSource(http: http)
        let envelope = await source.searchWithOutcome(FRFixtures.query())
        guard case .results(let records) = envelope.result, records.count == 2 else {
            Issue.record("expected 2 records, got \(envelope.result)")
            return
        }
        let first = FRFixtures.parish(records[0])
        let second = FRFixtures.parish(records[1])
        #expect(first?.fatherName == "John KENWORTHY",
                "top hit must be detail-enriched with parent names")
        #expect(first?.common.id == "freereg_abc123",
                "enriched record keeps the URL-derived stable ID")
        #expect(second?.fatherName == nil,
                "second hit must NOT be fetched — cap is 1")
    }

    @Test func detailFailureFallsBackToSearchRow() async {
        // No detail fixture: the GET 404s and the un-enriched search
        // row must survive.
        let http = FixtureHTTPClient(
            getFixtures: [FRFixtures.formURL: Data(FRFixtures.csrfHTML.utf8)],
            postFixtures: [FRFixtures.postURL: Data(FRFixtures.combinedNameHTML.utf8)]
        )
        let source = FreeREGSource(http: http)
        let envelope = await source.searchWithOutcome(FRFixtures.query())
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 1)
        #expect(FRFixtures.parish(records.first)?.fatherName == nil)
    }

    @Test func fetchDetailBuildsStandaloneRecord() async {
        let http = FixtureHTTPClient(
            getFixtures: [FRFixtures.detailURL1: Data(FRFixtures.baptismDetailHTML.utf8)]
        )
        let source = FreeREGSource(http: http)
        let result = await source.fetchDetail(recordID: FRFixtures.detailURL1.absoluteString)
        guard case .results(let records) = result,
              let record = FRFixtures.parish(records.first) else {
            Issue.record("expected one parish record, got \(result)")
            return
        }
        #expect(record.common.name == "Sarah Jane KENWORTHY")
        #expect(record.common.id == "freereg_abc123")
        #expect(record.eventType == "baptism")
        #expect(record.eventYear == 1850)
        #expect(record.fatherName == "John KENWORTHY")
        #expect(record.motherName == "Mary")
    }
}

// MARK: - FT-20 / FT-26: page-state triage

@MainActor
struct FreeREGPageTriageTests {

    @Test func validationBannerClassifiesWithExtractedMessage() {
        guard case .validationError(let reason) = FreeREGSource.classifyResultsPage(FRFixtures.validationHTML) else {
            Issue.record("expected .validationError")
            return
        }
        #expect(reason.contains("First name is too short"),
                "the Rails error <li> should surface in the reason")
    }

    @Test func noResultsCopyClassifiesAsEmpty() {
        #expect(FreeREGSource.classifyResultsPage(FRFixtures.noResultsHTML) == .empty)
    }

    @Test func resultsTableClassifiesAsResults() {
        #expect(FreeREGSource.classifyResultsPage(FRFixtures.combinedNameHTML) == .results)
    }

    @Test func loginWallIsUnparseableWithLoginReason() {
        guard case .unparseable(let reason) = FreeREGSource.classifyResultsPage(FRFixtures.loginWallHTML) else {
            Issue.record("expected .unparseable")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("login"))
    }

    @Test func garbagePageIsUnparseable() {
        guard case .unparseable = FreeREGSource.classifyResultsPage(FRFixtures.garbageHTML) else {
            Issue.record("expected .unparseable")
            return
        }
    }

    @Test func emptyBodyIsUnparseable() {
        guard case .unparseable = FreeREGSource.classifyResultsPage("") else {
            Issue.record("expected .unparseable for an empty body")
            return
        }
    }

    @Test func validationErrorBecomesUnavailableNeverCacheableEmpty() async {
        let http = FixtureHTTPClient(
            getFixtures: [FRFixtures.formURL: Data(FRFixtures.csrfHTML.utf8)],
            postFixtures: [FRFixtures.postURL: Data(FRFixtures.validationHTML.utf8)]
        )
        let source = FreeREGSource(http: http)
        let envelope = await source.searchWithOutcome(FRFixtures.query())
        guard case .unavailable(let reason) = envelope.result else {
            Issue.record("a rejected POST must be .unavailable, got \(envelope.result)")
            return
        }
        #expect(reason.contains("First name is too short"))
        #expect(!envelope.outcome.isCleanNegative,
                "a validation error must never flow into negative-evidence reasoning")
    }

    @Test func genuineEmptyPageIsACleanNegative() async {
        let http = FixtureHTTPClient(
            getFixtures: [FRFixtures.formURL: Data(FRFixtures.csrfHTML.utf8)],
            postFixtures: [FRFixtures.postURL: Data(FRFixtures.noResultsHTML.utf8)]
        )
        let source = FreeREGSource(http: http)
        let envelope = await source.searchWithOutcome(FRFixtures.query())
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.isEmpty)
        #expect(envelope.outcome.isCleanNegative)
    }
}

// MARK: - FT-22: multi-page fetching

@MainActor
struct FreeREGPaginationTests {

    @Test func fetchesAllPagesAndReportsComplete() async {
        let http = FixtureHTTPClient(
            getFixtures: [
                FRFixtures.formURL: Data(FRFixtures.csrfHTML.utf8),
                FRFixtures.page2URL: Data(FRFixtures.paginatedPage2.utf8),
            ],
            postFixtures: [FRFixtures.postURL: Data(FRFixtures.paginatedPage1.utf8)]
        )
        let source = FreeREGSource(http: http)
        let envelope = await source.searchWithOutcome(FRFixtures.query())
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 2, "both pages' rows must be returned")
        #expect(envelope.outcome.totalAvailable == 2)
        #expect(envelope.outcome.truncated == false)
        #expect(envelope.outcome.isConclusive)
    }

    @Test func failedFollowUpPageKeepsPartialAnswerWithHonestTruncation() async {
        // Page 2 GET 404s: page-1 rows survive, truncated == true.
        let http = FixtureHTTPClient(
            getFixtures: [FRFixtures.formURL: Data(FRFixtures.csrfHTML.utf8)],
            postFixtures: [FRFixtures.postURL: Data(FRFixtures.paginatedPage1.utf8)]
        )
        let source = FreeREGSource(http: http)
        let envelope = await source.searchWithOutcome(FRFixtures.query())
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 1)
        #expect(envelope.outcome.truncated == true)
        #expect(!envelope.outcome.isConclusive)
    }

    @Test func nextPageURLSharedMechanicsUseFreeREGHost() {
        let url = FreeREGSource.nextPageURL(FRFixtures.paginatedPage1)
        #expect(url == "https://www.freereg.org.uk/search_queries/xyz789?page=2")
    }
}
