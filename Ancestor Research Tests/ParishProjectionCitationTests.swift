import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// #29 — the projected parish life event must carry its citation and its
/// register content. Owner dogfood 2026-08-24: John Wheeldon jr's Cromford
/// 1848 baptism applied as a bare event — `sources: []`, no parents, and the
/// register's "Birth date 09 Sep 1848" nowhere — while the FreeREG URL sat
/// only in profile-level provenance.
struct ParishProjectionCitationTests {

    private func parish(
        detail: FreeREGDetail?,
        fatherName: String? = nil,
        motherName: String? = nil
    ) -> ParishRecord {
        ParishRecord(
            common: RecordCommon(
                id: "freereg_john-wheeldon-baptism-1848", sourceID: "freereg",
                name: "John Wheeldon", surname: "Wheeldon", givenName: "John",
                detailURL: "https://www.freereg.org.uk/search_records/682f9727/x",
                rawFields: [:]),
            eventType: "baptism",
            eventDate: "25 Dec 1848", eventYear: 1848,
            parish: "Cromford", county: "Derbyshire",
            fatherName: fatherName, motherName: motherName,
            detail: detail)
    }

    @Test func projectedBaptismCarriesItsCitation() throws {
        let event = try #require(
            SourceRecord.parish(parish(detail: nil)).projectToLifeEvent(profileID: "p1"))
        #expect(event.type == .baptism)
        #expect(event.sources.count == 1, "the event row itself is cited")
        #expect(event.sources.first?.citation?.url?.contains("freereg.org.uk") == true)
        #expect(event.sources.first?.origin.identifier == "freereg")
    }

    @Test func enrichedBaptismDescribesParentsOccupationAndRecordedBirth() throws {
        let detail = FreeREGDetail(event: .baptism(FreeREGBaptism(
            child: FreeREGPerson(forename: "John", surname: "Wheeldon"),
            birthDate: "09 Sep 1848",
            baptismDate: "25 Dec 1848",
            father: FreeREGPerson(forename: "John", surname: "Wheeldon",
                                  occupation: "Hatter"),
            mother: FreeREGMother(person: FreeREGPerson(forename: "Ruth", surname: "Wheeldon")))))
        let event = try #require(
            SourceRecord.parish(parish(detail: detail)).projectToLifeEvent(profileID: "p1"))
        let desc = try #require(event.description)
        #expect(desc.contains("child of"))
        #expect(desc.localizedCaseInsensitiveContains("John Wheeldon"))
        #expect(desc.contains("(hatter)"))
        #expect(desc.localizedCaseInsensitiveContains("Ruth"))
        #expect(desc.contains("born 09 Sep 1848"),
                "the register's recorded birth date is content, not discardable")
    }

    @Test func flatOnlyBaptismStillNamesFlatParents() throws {
        let event = try #require(
            SourceRecord.parish(parish(detail: nil, fatherName: "John Wheeldon",
                                       motherName: "Ruth Wheeldon"))
                .projectToLifeEvent(profileID: "p1"))
        #expect(event.description == "child of John Wheeldon and Ruth Wheeldon")
    }

    @Test func burialDescriptionShapeIsUnchanged() throws {
        var rec = parish(detail: FreeREGDetail(event: .burial(FreeREGBurial(
            deceased: FreeREGPerson(forename: "John", surname: "Wheeldon"),
            causeOfDeath: "fever"))))
        rec = ParishRecord(
            common: rec.common, eventType: "burial", eventDate: rec.eventDate,
            eventYear: rec.eventYear, parish: rec.parish, county: rec.county,
            fatherName: nil, motherName: nil, detail: rec.detail)
        let event = try #require(
            SourceRecord.parish(rec).projectToLifeEvent(profileID: "p1"))
        #expect(event.type == .burial)
        #expect(event.description == "fever")
        #expect(!event.sources.isEmpty)
    }
}
