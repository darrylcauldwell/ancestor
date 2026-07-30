import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research


/// The LIVE results table that produced the "FreeREG: 0 of 2 results"
/// silent miss (stream capture 2026-07-30): headers are "Details |
/// Person or persons | Record type | Event date | County | Place :
/// Church : Register type", marriage rows carry BOTH principals
/// <br>-separated. The row parser must extract every row.
@MainActor
struct FreeREGLiveResultsTableTests {

    static let liveResultsPage = #"""
We found 2  Results
<table class="table--bordered table--striped table--data ">
  <thead>
    <tr>
        <th >Details</th>
      <th>
        <a href="/search_queries/6a6b022db96866ecab59ea19/reorder?order_field=transcript_names">Person or persons</a>
        
      </th>
      <th>
        <a href="/search_queries/6a6b022db96866ecab59ea19/reorder?order_field=record_type">Record type</a>
        
      </th>
      <th>
        <a href="/search_queries/6a6b022db96866ecab59ea19/reorder?order_field=search_date">Event date</a>
        
      </th>
      <th>
        <a href="/search_queries/6a6b022db96866ecab59ea19/reorder?order_field=chapman_code">County</a>
        
      </th>
      <th>
        <a href="/search_queries/6a6b022db96866ecab59ea19/reorder?order_field=location">Place : Church : Register type</a>
        
      </th>
    </tr>
  </thead>
  <tbody>
        <tr id="684f4ee4865574398b041940">
            <td>
              <a rel="nofollow" class="btn  btn--small" href="/search_records/684f4ee4865574398b041940/william-henry-keyworth-emma-gladwin-marriage-nottinghamshire-worksop-1896-03-22">View 1</a>
              <i><br>
                </i>
            </td>
          <td>

                
                William Henry KEYWORTH
                <br>
                Emma GLADWIN

          </td>
          <td  >
            Marriage
          </td>
          <td  >
            22 Mar 1896
          </td>
          <td  >
            Nottinghamshire
          </td>
          <td  >
            Worksop : St John :  Parish Register
          </td>
        </tr>
        <tr id="5dcae8a9f493fd07ddf369f9">
            <td>
              <a rel="nofollow" class="btn  btn--small" href="/search_records/5dcae8a9f493fd07ddf369f9/william-keyworth-mary-lane-marriage-nottinghamshire-north-wheatley-1898-08-15">View 2</a>
              <i><br>
                </i>
            </td>
          <td>

                
                William KEYWORTH
                <br>
                Mary LANE

          </td>
          <td  >
            Marriage
          </td>
          <td  >
            15 Aug 1898
          </td>
          <td  >
            Nottinghamshire
          </td>
          <td  >
            North Wheatley : St Peter :  Parish Register
          </td>
        </tr>
  </tbody>
</table>
"""#

    @Test func liveResultsTableYieldsBothRecords() {
        let records = FreeREGSource.parseResults(Self.liveResultsPage, recordType: .parish)
        #expect(records.count == 2, "the page says 2 results — the parser must extract 2, not 0")
        guard case .parish(let first)? = records.first else { Issue.record("expected parish record"); return }
        #expect(first.common.name == "William Henry KEYWORTH", "the FIRST <br>-separated person is the principal")
        #expect(first.common.surname == "KEYWORTH")
        #expect(first.common.givenName == "William Henry")
        #expect(first.eventType == "marriage")
        #expect(first.eventDate == "22 Mar 1896")
        #expect(first.parish == "Worksop", "composite Place : Church : Register type splits")
        #expect(first.common.rawFields["church_name"] == "St John")
        #expect(first.common.rawFields["register_type"] == "Parish Register")
        #expect(first.common.rawFields["co_persons"] == "Emma GLADWIN", "the marriage co-principal survives")
        #expect(first.common.detailURL?.contains("/search_records/684f4ee4865574398b041940") == true)
        #expect(first.common.id == "freereg_william-henry-keyworth-emma-gladwin-marriage-nottinghamshire-worksop-1896-03-22"
                || first.common.id.hasPrefix("freereg_"), "stable URL-derived id")
    }

    @Test func classifierReadsTheLivePageAsResults() {
        #expect(FreeREGSource.classifyResultsPage(Self.liveResultsPage) == .results)
        #expect(FreeREGSource.parseResultCount(Self.liveResultsPage) == 2)
    }
}
