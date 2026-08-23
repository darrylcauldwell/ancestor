import Testing
import Foundation
import os
@testable import Ancestor_Research
import AncestorKit

/// The FreeREG "Could not parse results page" failure, finally diagnosed.
///
/// MyopicVicar — the Rails engine behind FreeREG, and the connectors'
/// documented source of truth — has NO waiting page and NO rate limiter. A
/// query that exceeds the server's time budget raises, flashes "Your search
/// exceeded the maximum permitted time…" and 302s back to the SEARCH FORM.
/// Our client follows the redirect and lands on the form: a page with no
/// results table, no no-results copy and no login wall, which fell through to
/// the generic "Could not parse FreeREG results page".
///
/// Owner dogfood 2026-08-23: in a 21-probe variant burst, the one query whose
/// results page actually had content — Mary STEPHENSON's 1823 Youlgreave
/// baptism, the record naming both her parents — was also the heaviest, timed
/// out server-side, and bounced. The IDENTICAL query re-run in isolation
/// returned a clean 4-row page. Both pages were captured live on 2026-08-23
/// and are reproduced below; the fixtures are REAL, not invented.
struct FreeREGBouncedSearchTests {

    // MARK: - Fixtures (captured live, 2026-08-23)

    /// The results table exactly as FreeREG served it for the app's own query
    /// (last_name=stephenson, first_name=Mary, DBY, record_type=ba,
    /// 1816–1833) — 4 rows, including her baptism.
    static let liveResultsPage = #"""
    <html><body><h2>Results</h2>
    <table class="table--bordered table--striped table--data ">
      <thead>
        <tr>
            <th >Details</th>
          <th><a href="/search_queries/6a8ab3f85be18fc0ba091bf5/reorder?order_field=transcript_names">Person or persons</a></th>
          <th><a href="/search_queries/6a8ab3f85be18fc0ba091bf5/reorder?order_field=record_type">Record type</a></th>
          <th><a href="/search_queries/6a8ab3f85be18fc0ba091bf5/reorder?order_field=search_date">Event date</a></th>
          <th><a href="/search_queries/6a8ab3f85be18fc0ba091bf5/reorder?order_field=chapman_code">County</a></th>
          <th><a href="/search_queries/6a8ab3f85be18fc0ba091bf5/reorder?order_field=location">Place : Church : Register type</a></th>
        </tr>
      </thead>
      <tbody>
        <tr id="683052168655746c655cedb2">
          <td><a rel="nofollow" class="btn  btn--small" href="/search_records/683052168655746c655cedb2/mary-ann-stephenson-baptism-derbyshire-youlgreave-1822-02-03">View 1</a><i><br></i></td>
          <td>Mary Ann STEPHENSON</td>
          <td  >Baptism</td>
          <td  >03 Feb 1822</td>
          <td  >Derbyshire</td>
          <td  >Youlgreave : All Saints :  Other Transcript</td>
        </tr>
        <tr id="682f646a8655746c65f9ba65">
          <td><a rel="nofollow" class="btn  btn--small" href="/search_records/682f646a8655746c65f9ba65/mary-stephenson-baptism-derbyshire-baslow-1823-06-13">View 2</a><i><br></i></td>
          <td>Mary STEPHENSON</td>
          <td  >Baptism</td>
          <td  >13 Jun 1823</td>
          <td  >Derbyshire</td>
          <td  >Baslow : St Anne :  Parish Register</td>
        </tr>
        <tr id="683052198655746c655cef5d">
          <td><a rel="nofollow" class="btn  btn--small" href="/search_records/683052198655746c655cef5d/mary-stephenson-baptism-derbyshire-youlgreave-1823-12-28">View 3</a><i><br></i></td>
          <td>Mary STEPHENSON</td>
          <td  >Baptism</td>
          <td  >28 Dec 1823</td>
          <td  >Derbyshire</td>
          <td  >Youlgreave : All Saints :  Other Transcript</td>
        </tr>
        <tr id="682fc2858655746c6520be7b">
          <td><a rel="nofollow" class="btn  btn--small" href="/search_records/682fc2858655746c6520be7b/mary-ann-stephenson-baptism-derbyshire-eckington-1831-04-17">View 4</a><i><br></i></td>
          <td>Mary Ann STEPHENSON</td>
          <td  >Baptism</td>
          <td  >17 Apr 1831</td>
          <td  >Derbyshire</td>
          <td  >Eckington : St Peter and St Paul :  Parish Register</td>
        </tr>
      </tbody>
    </table></body></html>
    """#

    /// The SEARCH FORM as served live — what a timed-out POST bounces back to.
    /// It carries the form's own input field, which is the bounce fingerprint,
    /// and a fresh authenticity token for the retry.
    static let bouncedFormPage = #"""
    <html><body>
    <form action="/search_queries" method="post">
    <input type="hidden" name="authenticity_token" value="FreshTokenFromBounce123==" autocomplete="off">
    <input id="last_name" name="search_query[last_name]" type="text" class="text-input" placeholder="Optional" autocomplete="off">
    </form></body></html>
    """#

    static let timedOutFormPage = #"""
    <html><body>
    <div class="flash">Your search exceeded the maximum permitted time. Please review your search criteria. Advice is contained in the Help pages.</div>
    <form action="/search_queries" method="post">
    <input type="hidden" name="authenticity_token" value="FreshTokenFromBounce123==" autocomplete="off">
    <input id="last_name" name="search_query[last_name]" type="text" class="text-input" placeholder="Optional" autocomplete="off">
    </form></body></html>
    """#

    // MARK: - The page that was never the problem

    /// The live results page classifies as results and parses — proving the
    /// failure was never the parser, and pinning the 2026 table layout.
    @Test func theLiveResultsPageClassifiesAndParses() {
        #expect(FreeREGSource.classifyResultsPage(Self.liveResultsPage) == .results)
        let records = FreeREGSource.parseResults(Self.liveResultsPage, recordType: .baptism)
        #expect(records.count == 4, "four real rows; got \(records.count)")
    }

    /// THE record — Mary's baptism — must come out of the page intact.
    @Test func marysBaptismRowSurvivesParsing() throws {
        let records = FreeREGSource.parseResults(Self.liveResultsPage, recordType: .baptism)
        let mary = try #require(records.first { rec in
            rec.detailURL?.contains("mary-stephenson-baptism-derbyshire-youlgreave-1823-12-28") == true
        }, "the row this whole hunt was for must parse")
        #expect(mary.surname?.uppercased() == "STEPHENSON")
        if case .parish(let p) = mary {
            #expect(p.eventYear == 1823)
            #expect(p.parish == "Youlgreave")
        } else {
            Issue.record("expected a parish record, got \(mary)")
        }
    }

    // MARK: - The bounce

    /// THE SPECIMEN: the bounced form is recognised as a bounce, not as the
    /// generic unparseable it fell through to for a month.
    @Test func theBouncedFormClassifiesAsSearchBounced() {
        let state = FreeREGSource.classifyResultsPage(Self.bouncedFormPage)
        guard case .searchBounced = state else {
            Issue.record("expected .searchBounced, got \(state)"); return
        }
    }

    /// With the engine's own flash copy present, the reason names the timeout.
    @Test func theTimeoutFlashYieldsAPreciseReason() {
        let state = FreeREGSource.classifyResultsPage(Self.timedOutFormPage)
        guard case .searchBounced(let reason) = state else {
            Issue.record("expected .searchBounced, got \(state)"); return
        }
        #expect(reason.localizedCaseInsensitiveContains("timed out"))
    }

    /// The bounced form's fresh token is extractable for the retry.
    @Test func theBouncedFormYieldsAFreshToken() {
        #expect(MyopicVicarParsing.csrfToken(fromHTML: Self.bouncedFormPage) == "FreshTokenFromBounce123==")
    }

    // MARK: - Ordering guarantees

    /// A results page that happens to mention the form field name (a Revise
    /// Search link, an inline script) is still results — the <th> table check
    /// outranks the bounce fingerprint.
    @Test func aResultsPageCanNeverBeMisreadAsABounce() {
        let page = Self.liveResultsPage.replacingOccurrences(
            of: "</body>", with: #"<a href="/search_queries/new">search_query[last_name]</a></body>"#)
        #expect(FreeREGSource.classifyResultsPage(page) == .results)
    }

    /// A genuine validation rejection keeps its precise reason — the banner
    /// check outranks the bounce fingerprint even though both render the form.
    @Test func aValidationErrorOutranksTheBounce() {
        let page = #"""
        <html><body><div id="errorExplanation"><h2>1 error prohibited this search from being saved</h2><ul><li>Surname too short</li></ul></div>
        <input id="last_name" name="search_query[last_name]" type="text"></body></html>
        """#
        let state = FreeREGSource.classifyResultsPage(page)
        guard case .validationError = state else {
            Issue.record("expected .validationError, got \(state)"); return
        }
    }

    /// A no-results page is still a clean empty, never a bounce.
    @Test func aNoResultsPageIsStillEmpty() {
        let page = "<html><body>Your search returned no results. <input name=\"search_query[last_name]\"></body></html>"
        #expect(FreeREGSource.classifyResultsPage(page) == .empty)
    }

    /// The generic unparseable fallthrough still exists for truly unknown
    /// shapes — the bounce detection must not swallow everything.
    @Test func unknownShapesAreStillUnparseable() {
        let state = FreeREGSource.classifyResultsPage("<html><body>Totally unexpected page</body></html>")
        guard case .unparseable = state else {
            Issue.record("expected .unparseable, got \(state)"); return
        }
    }

    // MARK: - Diagnostics capture

    /// An unknown page shape is captured to disk so the next flood is
    /// diagnosable — and the capture is bounded.
    @Test func unparseablePagesAreCapturedAndBounded() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logger = Logger(subsystem: "test", category: "capture")
        FreeREGSource.captureUnparseablePage("<html>weird</html>", surname: "Test", logger: logger, baseDirectory: base)
        let dir = base.appendingPathComponent("AncestorResearch/diagnostics")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        #expect(files[0].hasPrefix("freereg-unparseable"))
        // Bound: after 25 captures, further pages are dropped silently.
        for i in 0..<30 {
            FreeREGSource.captureUnparseablePage("<html>\(i)</html>", surname: "T\(i)", logger: logger, baseDirectory: base)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(after.count <= 25, "capture must be bounded; got \(after.count)")
    }
}
