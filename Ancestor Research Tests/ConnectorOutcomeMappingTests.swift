import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit availability/truncation mapping instances of T1-01:
/// T1-25 (Probate hasError/malformed → unavailable), T1-24 honesty slice
/// (Probate resultsCount → truncated), T1-15 (FindAGrave block page /
/// API error → unavailable, incl. the fetchDetail marker guard),
/// T1-16 honesty slice (FAG total/tooMany → truncated), FT-23 (FreeCen
/// "We found N Results" / FreeREG count text / FreeBMD overflow entry
/// count), FT-22 (pagination-nav truncation detection).
struct ConnectorOutcomeMappingTests {

    // MARK: - Probate (T1-25 / T1-24)

    @Test func probateHasErrorBodyIsNotZeroResults() {
        let body = Data(#"{"hasError": true, "errorMessage": "index offline"}"#.utf8)
        let reason = ProbateSource.parseError(body)
        #expect(reason?.contains("index offline") == true)
        #expect(ProbateSource.parseJSON(body, surname: "SMITH").isEmpty,
                "records-only parse still returns [] — the error is surfaced separately")
    }

    @Test func probateHasErrorWithoutMessageStillErrors() {
        let body = Data(#"{"hasError": true}"#.utf8)
        #expect(ProbateSource.parseError(body)?.contains("unknown") == true)
    }

    @Test func probateNonJSONBodyIsMalformed() {
        let body = Data("<html>maintenance page</html>".utf8)
        #expect(ProbateSource.parseError(body) != nil)
    }

    @Test func probateMissingEntriesIsMalformed() {
        let body = Data(#"{"something": 1}"#.utf8)
        #expect(ProbateSource.parseError(body) != nil)
    }

    @Test func probateWellFormedEmptyIsNotAnError() {
        let body = Data(#"{"entries": [], "resultsCount": 0}"#.utf8)
        #expect(ProbateSource.parseError(body) == nil)
        #expect(ProbateSource.parseTotalCount(body) == 0)
    }

    @Test func probateResultsCountParsed() {
        let body = Data(Self.probateFixture(entries: 1, resultsCount: 3000).utf8)
        #expect(ProbateSource.parseTotalCount(body) == 3000)
    }

    @MainActor
    @Test func probateSearchMapsErrorBodyToUnavailable() async {
        let http = AnyURLHTTPClient(data: Data(#"{"hasError": true, "errorMessage": "boom"}"#.utf8))
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .unavailable(let reason) = envelope.result else {
            Issue.record("Expected .unavailable, got \(envelope.result)")
            return
        }
        #expect(reason.contains("boom"))
        #expect(!envelope.outcome.isCleanNegative)
    }

    @MainActor
    @Test func probateSearchSinglePageShortfallIsTruncated() async {
        // Server claims 50 hits but serves 2 entries with pageCount 1 —
        // the paging loop (T1-24) has nothing more to fetch, so the
        // shortfall must stay flagged as truncation, not read as a
        // complete answer. (Multi-page accumulation and the 500 budget
        // are covered in ProbatePagingTests.)
        let http = AnyURLHTTPClient(data: Data(Self.probateFixture(entries: 2, resultsCount: 50, pageCount: 1).utf8))
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .results(let records) = envelope.result else {
            Issue.record("Expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 2)
        #expect(envelope.outcome.totalAvailable == 50)
        #expect(envelope.outcome.truncated)
        #expect(!envelope.outcome.isConclusive)
    }

    @MainActor
    @Test func probateSearchCleanZeroIsCleanNegative() async {
        let http = AnyURLHTTPClient(data: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        #expect(envelope.outcome.isCleanNegative)
    }

    // MARK: - FindAGrave search parse (T1-15 / T1-16)

    @Test func fagBlockPageIsNotZeroResults() {
        let body = Data("<html><title>Just a moment...</title></html>".utf8)
        guard case .blockPage = FindAGraveSource.parseSearchResponse(body) else {
            Issue.record("Expected .blockPage")
            return
        }
        // Records-only shim collapses to [] — but search() maps the
        // typed outcome to .unavailable, never a clean negative.
        #expect(FindAGraveSource.parseSearchResults(body).isEmpty)
    }

    @Test func fagApiErrorCodeIsNotZeroResults() {
        let body = Data(#"{"responseCode": 500}"#.utf8)
        guard case .apiError(let code) = FindAGraveSource.parseSearchResponse(body) else {
            Issue.record("Expected .apiError")
            return
        }
        #expect(code == 500)
    }

    @Test func fagSuccessCarriesTotalAndTooMany() {
        let body = Data(#"""
        {"responseCode": 200, "total": 4123, "tooMany": true,
         "records": [{"memorialId": 12345, "titleName": "Robert Cauldwell"}]}
        """#.utf8)
        guard case .success(let records, let total, let tooMany) = FindAGraveSource.parseSearchResponse(body) else {
            Issue.record("Expected .success")
            return
        }
        #expect(records.count == 1)
        #expect(total == 4123)
        #expect(tooMany)
    }

    @Test func fagMissingRecordsOn200IsGenuineEmpty() {
        // Python parity: data.get("records", []) — a 200 payload without
        // a records key is an empty result set, not an error.
        let body = Data(#"{"responseCode": 200, "total": 0}"#.utf8)
        guard case .success(let records, let total, let tooMany) = FindAGraveSource.parseSearchResponse(body) else {
            Issue.record("Expected .success")
            return
        }
        #expect(records.isEmpty)
        #expect(total == 0)
        #expect(!tooMany)
    }

    // MARK: - FindAGrave detail classification (T1-15 detail half)

    @Test func fagDetailBlockShellIsUnavailableNotEmpty() {
        let html = """
        <html>
          <head><title>Find a Grave - Millions of Cemetery Records</title></head>
          <body><div>Please verify you are human</div></body>
        </html>
        """
        guard case .unavailable = FindAGraveSource.classifyMemorialDetail(html, memorialID: 12345) else {
            Issue.record("A block shell must classify as .unavailable, not an empty result")
            return
        }
    }

    @Test func fagDetailGenuineNotFoundIsEmptyResults() {
        let html = """
        <html>
          <head><title>Page Not Found - Find a Grave</title></head>
          <body><p>The memorial you are looking for does not exist or may have been removed.</p></body>
        </html>
        """
        guard case .results(let records) = FindAGraveSource.classifyMemorialDetail(html, memorialID: 12345) else {
            Issue.record("A genuine not-found page is an honest empty")
            return
        }
        #expect(records.isEmpty)
    }

    @Test func fagDetailRealMemorialStillParses() {
        let html = """
        <html>
          <head><title>Ernest Cauldwell - Find a Grave Memorial</title></head>
          <body>
            <span itemprop="birthDate">1919</span>
            <span itemprop="deathDate">2017</span>
          </body>
        </html>
        """
        guard case .results(let records) = FindAGraveSource.classifyMemorialDetail(html, memorialID: 12345),
              records.count == 1 else {
            Issue.record("A real memorial page must still parse to one record")
            return
        }
    }

    // MARK: - FreeCen hit count (FT-23) + pagination nav (FT-22)

    @Test func freeCenParsesWeFoundCount() {
        #expect(FreeCenSource.parseResultCount("<p>We found 3 Results</p>") == 3)
        #expect(FreeCenSource.parseResultCount("<p>We found 1 Result</p>") == 1)
        #expect(FreeCenSource.parseResultCount("<p>We found 1,234 Results</p>") == 1234)
        #expect(FreeCenSource.parseResultCount("<p>We found 0 Results</p>") == 0)
    }

    @Test func freeCenNoCountMarkerParsesNil() {
        #expect(FreeCenSource.parseResultCount("<html>No results found</html>") == nil)
    }

    @Test func freeCenDetectsPaginationNav() {
        #expect(FreeCenSource.hasPaginationNav(#"<div class="pagination"><a rel="next" href="?page=2">Next</a></div>"#))
        #expect(FreeCenSource.hasPaginationNav(#"<a rel="next" href="?page=2">Next</a>"#))
        #expect(!FreeCenSource.hasPaginationNav("<table><tr><td>row</td></tr></table>"))
    }

    // MARK: - FreeREG hit count (FT-23) + pagination nav (FT-22)

    @Test func freeREGParsesResultCountText() {
        #expect(FreeREGSource.parseResultCount("<p>Your search returned 250 results</p>") == 250)
        #expect(FreeREGSource.parseResultCount("<p>1,024 Results</p>") == 1024)
    }

    @Test func freeREGNoCountTextParsesNil() {
        #expect(FreeREGSource.parseResultCount("<html>No records found</html>") == nil)
    }

    @Test func freeREGDetectsPaginationNav() {
        #expect(FreeREGSource.hasPaginationNav(#"<ul class="pagination"><li>1</li><li>2</li></ul>"#))
        #expect(!FreeREGSource.hasPaginationNav("<table></table>"))
    }

    // MARK: - FreeBMD overflow entry count (FT-23 / FT-05)

    @Test func freeBMDParsesOverflowEntryCount() {
        let interstitial = "<html><body>Your search returned 12,345 entries which is too many to display.</body></html>"
        #expect(FreeBMDSource.parseOverflowEntryCount(interstitial) == 12345)
    }

    @Test func freeBMDOverflowCountAbsentParsesNil() {
        #expect(FreeBMDSource.parseOverflowEntryCount("<html>No entries message here</html>") == nil)
    }

    // MARK: - Helpers

    private static func probateQuery() -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .probate,
            yearFrom: 2000, yearTo: 2010,
            gender: .male, region: .englandAndWales,
            sourceParams: .generic
        )
    }

    private static func probateFixture(entries: Int, resultsCount: Int, pageCount: Int = 1) -> String {
        let entryJSON = (0..<entries).map { i in
            #"""
            {"uid": "uid-\#(i)", "properties": {
                "hmctsgrant:surname": "CAULDWELL",
                "hmctsgrant:firstnames": "ROBERT",
                "hmctsgrant:dateofdeath": "2005-03-01T00:00:00.000Z"
            }}
            """#
        }.joined(separator: ",")
        return #"{"entries": [\#(entryJSON)], "resultsCount": \#(resultsCount), "pageCount": \#(pageCount)}"#
    }
}

/// Stub HTTP client that returns the same canned body for ANY URL —
/// connector search URLs carry query-dependent params, so exact-URL
/// fixtures (FixtureHTTPClient) don't fit search-path tests.
private struct AnyURLHTTPClient: HTTPClient {
    let data: Data

    func get(url: URL, headers: [String: String]) async throws -> Data { data }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data { data }
}
