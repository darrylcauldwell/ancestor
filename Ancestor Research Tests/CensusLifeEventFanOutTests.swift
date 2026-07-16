import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EVIDENCE_ABSORPTION_SPEC Change 2 — a census must fan out into every typed
/// LifeEvent its fields imply (census + occupation + residence), not collapse
/// the occupation/address nuggets into a single catch-all census entry. The
/// dedicated `.occupation` / `.residence` event types existed but were never
/// populated from any record until this slice.
struct CensusLifeEventFanOutTests {

    private func census(occupation: String?, address: String?, parish: String? = "Youlgreave") -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: "cen-1", sourceID: "freecen", rawFields: [:]),
            censusYear: 1891,
            occupation: occupation, address: address, parish: parish))
    }

    @Test func occupationAndAddressEachSpawnTheirOwnEvent() {
        let events = census(occupation: "Colliery electrician", address: "3 Mill Lane")
            .projectToLifeEvents(profileID: "p")
        let types = Set(events.map(\.type))
        #expect(types == [.census, .occupation, .residence])

        let occ = events.first { $0.type == .occupation }
        #expect(occ?.description == "Colliery electrician")
        #expect(occ?.date?.earliest == 1891)

        let res = events.first { $0.type == .residence }
        #expect(res?.location == "3 Mill Lane")
        #expect(res?.date?.earliest == 1891)
    }

    @Test func derivedEventIDsAreDistinctAndStable() {
        let a = census(occupation: "Farmer", address: "Manor Farm").projectToLifeEvents(profileID: "p")
        let b = census(occupation: "Farmer", address: "Manor Farm").projectToLifeEvents(profileID: "p")
        // Distinct across the three events...
        #expect(Set(a.map(\.id)).count == 3)
        // ...and idempotent across runs (INSERT OR IGNORE dedup relies on this).
        #expect(a.map(\.id) == b.map(\.id))
    }

    @Test func occupationOnlyDoesNotInventAResidence() {
        let events = census(occupation: "Lead miner", address: nil).projectToLifeEvents(profileID: "p")
        #expect(Set(events.map(\.type)) == [.census, .occupation])
    }

    @Test func addressOnlyDoesNotInventAnOccupation() {
        let events = census(occupation: nil, address: "Church Street").projectToLifeEvents(profileID: "p")
        #expect(Set(events.map(\.type)) == [.census, .residence])
    }

    @Test func blankNuggetsYieldOnlyTheCensusEvent() {
        let events = census(occupation: "   ", address: "").projectToLifeEvents(profileID: "p")
        #expect(events.map(\.type) == [.census])
    }

    @Test func nonCensusRecordIsUnchangedByFanOut() {
        // A burial still projects to exactly its single event — the fan-out is
        // census-only and must not perturb other record types.
        let burial = SourceRecord.burial(BurialRecord(
            common: RecordCommon(id: "b-1", sourceID: "findagrave", rawFields: [:]),
            burialLocation: "Youlgreave", isVeteran: false))
        let events = burial.projectToLifeEvents(profileID: "p")
        let single = burial.projectToLifeEvent(profileID: "p")
        #expect(events.count == 1)
        #expect(events.first?.id == single?.id)
        #expect(events.first?.type == .burial)
    }
}
