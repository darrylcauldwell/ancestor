import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-24 (fetch half): the Probate paging loop, ported
/// faithfully from Python (sources/probate.py:163-191). Page 0 first,
/// read resultsCount/pageCount, loop pages 1..<pageCount accumulating
/// entries until the 500-record budget or an empty page; a mid-loop
/// error returns the partial answer (never `.unavailable`). The honesty
/// envelope reports truncated=false only when the accumulated records
/// match the server's own claimed total.
struct ProbatePagingTests {

    @MainActor
    @Test func multiPageResultsAccumulateAcrossPages() async {
        let http = PagedHTTPClient(pages: [
            0: Self.page(uids: 0..<3, resultsCount: 7, pageCount: 3),
            1: Self.page(uids: 3..<6, resultsCount: 7, pageCount: 3),
            2: Self.page(uids: 6..<7, resultsCount: 7, pageCount: 3),
        ])
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .results(let records) = envelope.result else {
            Issue.record("Expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 7)
        #expect(Set(records.map(\.id)).count == 7, "each page's entries survive accumulation distinctly")
        #expect(envelope.outcome.resultCount == 7)
        #expect(envelope.outcome.totalAvailable == 7)
        #expect(!envelope.outcome.truncated, "all pages fetched within budget — complete answer")
        #expect(envelope.outcome.isConclusive)

        // Python page_size parity (probate.py:163-164, 180-182): page 0
        // asks for min(max_results, cap); later pages ask for the
        // remaining budget.
        let requests = await http.requests
        #expect(requests.map(\.pageIndex) == [0, 1, 2])
        #expect(requests.map(\.pageSize) == [500, 497, 494])
    }

    @MainActor
    @Test func budgetCutoffSetsTruncatedWithTotalAvailable() async {
        // Server claims 1400 hits over 5 pages; the 500 budget must cut
        // the loop short, clamp to 500, and flag truncation.
        let http = PagedHTTPClient(pages: [
            0: Self.page(uids: 0..<300, resultsCount: 1400, pageCount: 5),
            1: Self.page(uids: 300..<550, resultsCount: 1400, pageCount: 5),
        ])
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .results(let records) = envelope.result else {
            Issue.record("Expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == ProbateSource.maxResults, "accumulated records clamp to the 500 budget (probate.py:191)")
        #expect(envelope.outcome.truncated)
        #expect(envelope.outcome.totalAvailable == 1400)
        #expect(!envelope.outcome.isConclusive)

        let requests = await http.requests
        #expect(requests.map(\.pageIndex) == [0, 1], "budget reached after page 1 — pages 2-4 never requested")
    }

    @MainActor
    @Test func emptyPageTerminatesLoop() async {
        // pageCount claims 4 pages, but page 1 comes back empty — the
        // loop must stop there (probate.py:184-185) and never request
        // page 2 (which is poisoned with entries to catch overrun).
        let http = PagedHTTPClient(pages: [
            0: Self.page(uids: 0..<2, resultsCount: 10, pageCount: 4),
            1: Self.page(uids: 0..<0, resultsCount: 10, pageCount: 4),
            2: Self.page(uids: 2..<4, resultsCount: 10, pageCount: 4),
        ])
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .results(let records) = envelope.result else {
            Issue.record("Expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 2)
        #expect(envelope.outcome.truncated, "2 of a claimed 10 is a partial answer — stays flagged")
        #expect(envelope.outcome.totalAvailable == 10)

        let requests = await http.requests
        #expect(requests.map(\.pageIndex) == [0, 1], "empty page 1 terminates — page 2 never requested")
    }

    @MainActor
    @Test func singlePageIsOneRequestWithUnchangedBehaviour() async {
        let http = PagedHTTPClient(pages: [
            0: Self.page(uids: 0..<2, resultsCount: 2, pageCount: 1),
        ])
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .results(let records) = envelope.result else {
            Issue.record("Expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 2)
        #expect(envelope.outcome.totalAvailable == 2)
        #expect(!envelope.outcome.truncated)
        #expect(envelope.outcome.isConclusive)

        let requests = await http.requests
        #expect(requests.count == 1, "pageCount 1 — no follow-up requests")
        #expect(requests.first == PagedHTTPClient.PageRequest(pageIndex: 0, pageSize: 500))
    }

    @MainActor
    @Test func missingPageCountDefaultsToSinglePage() async {
        // Python parity: data.get("pageCount", 1) — no pageCount key
        // means no paging loop, and the shortfall stays flagged.
        let body = Data(#"""
        {"entries": [{"uid": "uid-0", "properties": {
            "hmctsgrant:surname": "CAULDWELL",
            "hmctsgrant:firstnames": "ROBERT",
            "hmctsgrant:dateofdeath": "2005-03-01T00:00:00.000Z"
        }}], "resultsCount": 9}
        """#.utf8)
        let http = PagedHTTPClient(pages: [0: body])
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .results(let records) = envelope.result else {
            Issue.record("Expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 1)
        #expect(envelope.outcome.truncated)

        let requests = await http.requests
        #expect(requests.map(\.pageIndex) == [0])
    }

    @MainActor
    @Test func midLoopErrorReturnsPartialResultsNotUnavailable() async {
        // Python parity (probate.py:187-188): an exception on a
        // follow-up page breaks with what was accumulated — only a
        // page-0 failure maps to .unavailable. No fixture for page 1,
        // so the stub throws.
        let http = PagedHTTPClient(pages: [
            0: Self.page(uids: 0..<2, resultsCount: 6, pageCount: 3),
        ])
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery())
        guard case .results(let records) = envelope.result else {
            Issue.record("Mid-pagination failure must return partial .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 2)
        #expect(envelope.outcome.truncated, "partial answer stays flagged against the claimed total")
        #expect(envelope.outcome.totalAvailable == 6)
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

    /// One Nuxeo page body. `uids` gives each entry a distinct uid so
    /// cross-page accumulation is observable in record IDs.
    private static func page(uids: Range<Int>, resultsCount: Int, pageCount: Int) -> Data {
        let entryJSON = uids.map { i in
            #"""
            {"uid": "uid-\#(i)", "properties": {
                "hmctsgrant:surname": "CAULDWELL",
                "hmctsgrant:firstnames": "ROBERT",
                "hmctsgrant:dateofdeath": "2005-03-01T00:00:00.000Z"
            }}
            """#
        }.joined(separator: ",")
        return Data(#"{"entries": [\#(entryJSON)], "resultsCount": \#(resultsCount), "pageCount": \#(pageCount)}"#.utf8)
    }
}

/// Stub HTTP client keyed on the request's `currentPageIndex` query
/// param, recording every (pageIndex, pageSize) it is asked for. A page
/// with no fixture throws — standing in for a network failure on that
/// page. An actor so the recorded request log is race-free under the
/// connector's sequential-but-async loop.
private actor PagedHTTPClient: HTTPClient {
    struct PageRequest: Equatable, Sendable {
        let pageIndex: Int
        let pageSize: Int
    }

    private let pages: [Int: Data]
    private(set) var requests: [PageRequest] = []

    init(pages: [Int: Data]) {
        self.pages = pages
    }

    func get(url: URL, headers: [String: String]) async throws -> Data {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pageIndex = items.first { $0.name == "currentPageIndex" }?.value.flatMap(Int.init) ?? -1
        let pageSize = items.first { $0.name == "pageSize" }?.value.flatMap(Int.init) ?? -1
        requests.append(PageRequest(pageIndex: pageIndex, pageSize: pageSize))
        guard let data = pages[pageIndex] else {
            throw HTTPError.status(code: 404, body: nil)
        }
        return data
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        throw HTTPError.status(code: 405, body: nil)
    }
}
