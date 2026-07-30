import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research


/// LIVE-PAGE fixture: the actual freereg.org.uk detail page for William
/// Henry Keyworth's baptism (21 Mar 1875, Worksop Our Lady and St Cuthbert
/// (Priory)), captured from a browser HAR on 2026-07-30 — byte-real ERB
/// output, ads and disclaimer chrome included. The typed model must parse
/// THIS, not just hand-written fixtures.
@MainActor
struct FreeREGLivePageTests {

    static let liveBaptismTable = #"""
<table class='table--bordered table--data push--bottom t90' >
        <caption class='beta'>Baptism entry
          <span  class='additional'>While we have made all efforts to correctly record the information in the original document there may be different interpretations of the written words. <b>If you have access to the original document</b> and believe we have made a mistake you are encouraged to report this to us.
            <a class="btn btn--natural" href="/contacts/684f4472865574398b00ba27/report_error?query=6a6b034b0bf581173590e11f">Report an Error in this Data</a></span>
      </caption>
      <thead>
        <tr>
            <th >Field <br>
              (only fields with a value are shown)</th>
          <th >Value </th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>County</td>
          <td>Nottinghamshire</td>
        </tr>
        <tr>
          <td>Place</td>
            <td ><a href="/freereg_contents/53cd4975eca9ebee4f00797b/place">Worksop</a></td>
        </tr>
          <tr>
            <td >Church name
              <small> (Links to more information)</small></td>
              <td ><a href="/freereg_contents/54081400eca9eb02489d0bda/church">Our Lady and St Cuthbert (Priory)</a></td>
          </tr>
          <tr>
            <td >Register type
              <small> (Links to more information)</small></td>
              <td ><a href="/freereg_contents/54081400eca9eb02489d0bdc/register">Unspecified</a></td>
          </tr>
              <tr>
                <td >Baptism date</td>
                <td >21 Mar 1875</td>
              </tr>
              <tr>
                <td >Person forename</td>
                <td >William Henry</td>
              </tr>
              <tr>
                <td >Person sex</td>
                <td >M</td>
              </tr>
              <tr>
                <td >Father forename</td>
                <td >George</td>
              </tr>
              <tr>
                <td >Father surname</td>
                <td >KEYWORTH</td>
              </tr>
              <tr>
                <td >Person abode</td>
                <td >Worksop</td>
              </tr>
              <tr>
                <td >Father occupation</td>
                <td >Woodman</td>
              </tr>
            <tr>
              <td >Transcribed by</td>
              <td >John Turton</td>
            </tr>
            <tr>
              <td >Credit</td>
              <td >David Newbury</td>
            </tr>
              <tr>
                <td >File line number</td>
                <td >3549</td>
              </tr>
          <td  colspan=2><a class="btn btn--natural" href="/contacts/684f4472865574398b00ba27/report_error?query=6a6b034b0bf581173590e11f">Report an Error in this Data</a></td>
      </tbody>
    </table>
"""#

    @Test func realWorksopBaptismPageParsesIntoTypedModel() {
        let pairs = FreeREGSource.parseDetailPairs(Self.liveBaptismTable)
        #expect(!pairs.isEmpty, "the live table must yield labelled pairs")
        let detail = FreeREGDetailMapper.detail(fromLabelledPairs: pairs, typeHint: nil)
        guard case .baptism(let b)? = detail?.event else {
            Issue.record("expected a baptism from the live page, got \(String(describing: detail))")
            return
        }
        #expect(b.child.forename == "William Henry")
        #expect(b.child.sex == "M")
        #expect(b.child.abode == "Worksop")
        #expect(b.baptismDate == "21 Mar 1875")
        #expect(b.father?.forename == "George")
        #expect(b.father?.surname == "KEYWORTH")
        #expect(b.father?.occupation == "Woodman", "the father's occupation is the typed model's flagship gain")
        #expect(b.mother == nil, "original-format entry names no mother — never invent one")
        #expect(detail?.churchName == "Our Lady and St Cuthbert (Priory)",
                "label note stripped, VALUE parenthetical preserved")
        #expect(detail?.register?.registerType == "Unspecified")
        #expect(detail?.provenance?.transcribedBy == "John Turton")
        #expect(detail?.provenance?.credit == "David Newbury", "volunteer attribution must survive to citations")
    }

    @Test func realPageMergesIntoParishRecordWithBaptismParents() {
        let pairs = FreeREGSource.parseDetailPairs(Self.liveBaptismTable)
        let fields = FreeREGSource.detailFields(fromPairs: pairs)
        let base = ParishRecord(
            common: RecordCommon(
                id: "freereg_684f4472865574398b00ba27", sourceID: "freereg",
                name: "William Henry Keyworth", surname: "Keyworth", givenName: "William Henry",
                detailURL: "https://www.freereg.org.uk/search_records/684f4472865574398b00ba27",
                rawFields: [:]),
            eventType: "baptism", eventYear: 1875, parish: "Worksop", county: "Nottinghamshire")
        let merged = FreeREGSource.mergedDetailRecord(base: base, detailFields: fields, pairs: pairs)
        guard case .parish(let p) = merged else { Issue.record("expected parish"); return }
        #expect(p.fatherName == "George KEYWORTH", "flat projection carries the baptism father for the DS-10 gate")
        #expect(p.detail != nil)
    }
}
