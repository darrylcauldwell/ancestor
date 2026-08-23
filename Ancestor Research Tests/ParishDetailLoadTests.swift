import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// The parish "Details" affordance — the census Household pattern, parish-side.
///
/// Owner dogfood 2026-08-23. Mary Stevenson's 1823 Youlgreave baptism applied
/// cleanly, but no "add her parents" offer could ever form: FreeREG
/// results-table rows carry NO kin at all — John STEPHENSON and Lydia live
/// only on the register-entry page. The census side had the identical hole
/// (FreeCen enriches only the top search hit) and got `loadCensusHousehold`;
/// this is its parish twin: a pure needs-detail predicate, a kin line so a
/// CANDIDATE entry's family is readable before deciding, and an
/// identity-preserving merge of the fetched page onto the search row.
@MainActor
struct ParishDetailLoadTests {

    /// A parish record exactly as FreeREG returns it from a results-table
    /// row: no typed detail, optionally no flat parents either.
    private func searchRow(
        id: String = "row",
        eventType: String = "baptism",
        father: String? = nil,
        mother: String? = nil,
        detailURL: String? = "https://www.freereg.org.uk/search_records/abc123",
        detail: FreeREGDetail? = nil,
        rawFields: [String: String] = [:]
    ) -> ParishRecord {
        ParishRecord(
            common: RecordCommon(id: id, sourceID: "freereg", name: "Mary STEPHENSON",
                                 surname: "STEPHENSON", givenName: "Mary",
                                 detailURL: detailURL, rawFields: rawFields),
            eventType: eventType, eventDate: "28 Dec 1823", eventYear: 1823,
            parish: "Youlgreave", county: "Derbyshire",
            fatherName: father, motherName: mother, detail: detail)
    }

    private func typedBaptism(father: String? = "John", mother: String? = "Lydia") -> FreeREGDetail {
        FreeREGDetail(event: .baptism(FreeREGBaptism(
            child: FreeREGPerson(forename: "Mary", surname: "STEPHENSON"),
            baptismDate: "28 Dec 1823",
            father: father.map { FreeREGPerson(forename: $0, surname: "STEPHENSON") },
            mother: mother.map { FreeREGMother(person: FreeREGPerson(forename: $0, surname: nil)) })))
    }

    // MARK: - The needs-detail predicate

    @Test func searchRowWithURLNeedsDetail() {
        #expect(ProfileSourcesLedger.parishNeedsDetail(.parish(searchRow())))
    }

    @Test func typedDetailMeansNoFetchNeeded() {
        let rec = searchRow(detail: typedBaptism())
        #expect(!ProfileSourcesLedger.parishNeedsDetail(.parish(rec)))
    }

    @Test func noDetailURLMeansNothingToFetch() {
        #expect(!ProfileSourcesLedger.parishNeedsDetail(.parish(searchRow(detailURL: nil))))
        #expect(!ProfileSourcesLedger.parishNeedsDetail(.parish(searchRow(detailURL: ""))))
    }

    @Test func nonParishRecordsNeverNeedParishDetail() {
        let census = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "c", sourceID: "freecen", name: "Mary HOLMES",
                                 detailURL: "https://freecen/x", rawFields: [:]),
            censusYear: 1861))
        #expect(!ProfileSourcesLedger.parishNeedsDetail(census))
    }

    // MARK: - The kin line

    @Test func flatBaptismParentsMakeTheKinLine() {
        let rec = searchRow(father: "John STEPHENSON", mother: "Lydia")
        #expect(ProfileSourcesLedger.parishKinLine(.parish(rec))
                == "Father John STEPHENSON · Mother Lydia")
    }

    @Test func typedDetailOutranksFlatProjection() {
        let rec = searchRow(father: "Wrong FLAT", detail: typedBaptism())
        #expect(ProfileSourcesLedger.parishKinLine(.parish(rec))
                == "Father John STEPHENSON · Mother Lydia")
    }

    @Test func marriageDetailNamesBothFathers() {
        // Jacob × Mary, 19 Jan 1846 Youlgreave — the keystone record: TWO
        // generations from one entry, both fathers named.
        let detail = FreeREGDetail(event: .marriage(FreeREGMarriage(
            groom: FreeREGPerson(forename: "Jacob", surname: "HOLMES"),
            bride: FreeREGPerson(forename: "Mary", surname: "STEVENSON"),
            groomFather: FreeREGPerson(forename: "John", surname: "HOLMES"),
            brideFather: FreeREGPerson(forename: "John", surname: "STEVENSON"),
            marriageDate: "19 Jan 1846")))
        let rec = searchRow(eventType: "marriage", detail: detail)
        #expect(ProfileSourcesLedger.parishKinLine(.parish(rec))
                == "Groom's father John HOLMES · Bride's father John STEVENSON")
    }

    @Test func burialRelativeIsNamedWithItsRelationship() {
        let detail = FreeREGDetail(event: .burial(FreeREGBurial(
            deceased: FreeREGPerson(forename: "Mary", surname: "HOLMES"),
            burialDate: "1883",
            relationship: "wife of",
            relative: FreeREGPerson(forename: "Jacob", surname: "HOLMES"))))
        let rec = searchRow(eventType: "burial", detail: detail)
        #expect(ProfileSourcesLedger.parishKinLine(.parish(rec))
                == "Wife of Jacob HOLMES")
    }

    @Test func kinFreeRecordHasNoLine() {
        #expect(ProfileSourcesLedger.parishKinLine(.parish(searchRow())) == nil)
    }

    // MARK: - The identity-preserving merge

    @Test func mergeKeepsTheBaseRecordsIdentity() {
        // FT-12/FT-16: user_status and rejections are keyed on the record id —
        // enrichment flipping the identity would orphan review decisions.
        let base = searchRow(id: "base-id", rawFields: ["surname": "STEPHENSON"])
        let fetched = ParishRecord(
            common: RecordCommon(id: "detail-id", sourceID: "freereg",
                                 name: "Mary Stephenson", surname: "Stephenson",
                                 givenName: "Mary", detailURL: "https://other",
                                 rawFields: ["surname": "Stephenson", "father_forename": "John"]),
            eventType: "baptism", detail: typedBaptism())
        let merged = AppState.enrichedParishRecord(base: base, fetched: fetched)
        #expect(merged.common.id == "base-id")
        #expect(merged.common.name == "Mary STEPHENSON")
        #expect(merged.common.detailURL == base.common.detailURL)
        // Search-row keys win collisions; entry-page keys fill the gaps.
        #expect(merged.common.rawFields["surname"] == "STEPHENSON")
        #expect(merged.common.rawFields["father_forename"] == "John")
    }

    @Test func mergeGraftsTheTypedDetailAndFetchedParents() {
        let base = searchRow()
        let fetched = ParishRecord(
            common: RecordCommon(id: "d", sourceID: "freereg", name: "Mary STEPHENSON",
                                 rawFields: [:]),
            eventType: "baptism",
            fatherName: "John STEPHENSON", motherName: "Lydia",
            detail: typedBaptism())
        let merged = AppState.enrichedParishRecord(base: base, fetched: fetched)
        #expect(merged.detail == typedBaptism())
        #expect(merged.fatherName == "John STEPHENSON")
        #expect(merged.motherName == "Lydia")
        // Base's event framing survives.
        #expect(merged.eventYear == 1823)
        #expect(merged.parish == "Youlgreave")
    }

    @Test func mergeKeepsBaseFlatParentsWhenTheFetchReadsNone() {
        // An unparseable entry page must not ERASE the kin the search row had.
        let base = searchRow(father: "John STEPHENSON", mother: "Lydia")
        let fetched = ParishRecord(
            common: RecordCommon(id: "d", sourceID: "freereg", name: "Mary STEPHENSON",
                                 rawFields: [:]),
            eventType: "baptism", detail: nil)
        let merged = AppState.enrichedParishRecord(base: base, fetched: fetched)
        #expect(merged.fatherName == "John STEPHENSON")
        #expect(merged.motherName == "Lydia")
    }

    // MARK: - The ledger row carries the affordance

    @Test func ledgerRowOffersDetailsAndShowsKin() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let bare = searchRow(id: "bare")
        let scored = ScoredRecord(
            id: "bare", record: .parish(bare), verdict: .lead,
            gates: [GateResult(gate: .name, outcome: .pass, reason: "t")],
            summary: "Mary STEPHENSON, baptism 1823")
        try db.saveEvidence(profileID: "p1", scored: scored,
                            citationFull: "FreeREG, Youlgreave, 1823",
                            citationURL: bare.common.detailURL)
        let rows = try ProfileSourcesLedger.allRecords(for: "p1", db: db)
        let row = try #require(rows.first)
        #expect(row.canLoadParishDetail)
        #expect(row.parishKinLine == nil)

        // After the fetch is folded on, the affordance retires and the kin
        // line appears — same row, same identity.
        let enriched = AppState.enrichedParishRecord(
            base: bare,
            fetched: ParishRecord(
                common: RecordCommon(id: "d", sourceID: "freereg",
                                     name: "Mary STEPHENSON", rawFields: [:]),
                eventType: "baptism", detail: typedBaptism()))
        try db.updateEvidenceRecordJSON(
            evidenceID: EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "bare"),
            record: .parish(enriched))
        let after = try #require(try ProfileSourcesLedger.allRecords(for: "p1", db: db).first)
        #expect(!after.canLoadParishDetail)
        #expect(after.parishKinLine == "Father John STEPHENSON · Mother Lydia")
    }
}
