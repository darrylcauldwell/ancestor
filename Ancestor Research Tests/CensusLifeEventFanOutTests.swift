import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Evidence absorption Change 2 — a census must fan out into every typed
/// LifeEvent its fields imply (census + occupation + residence), not collapse
/// the occupation/address nuggets into a single catch-all census entry. The
/// dedicated `.occupation` / `.residence` event types existed but were never
/// populated from any record until this slice.
struct CensusLifeEventFanOutTests {

    /// `detailURL` defaults to nil so the pre-EV16 assertions below are
    /// untouched; the citation tests pass the household-page URL explicitly.
    private func census(occupation: String?, address: String?, parish: String? = "Youlgreave",
                        detailURL: String? = nil) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: "cen-1", sourceID: "freecen",
                                 detailURL: detailURL, rawFields: [:]),
            censusYear: 1891,
            occupation: occupation, address: address, parish: parish))
    }

    private let householdURL = "https://www.freecen.org.uk/search_records/6a2f/household"

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

    /// EV16 (2026-08-26) — the fan-out shipped without carrying the census's
    /// citation onto the derived rows, so an occupation and a residence
    /// rendered with no source badge beside the fully-cited census stating the
    /// identical fact (live: William Gladwin's 1881 "Sawyer" and 1891 "Wood
    /// Sawyer", both `sources: []`). All three events come off one household
    /// page, so all three carry that page's URL.
    @Test func everyFannedOutEventCarriesTheCensusCitation() throws {
        let events = census(occupation: "Wood sawyer", address: "Beighton Road",
                            detailURL: householdURL)
            .projectToLifeEvents(profileID: "p")
        #expect(events.count == 3)
        for event in events {
            #expect(event.sources.compactMap { $0.citation?.url } == [householdURL],
                    "\(event.type.displayName) landed uncited")
        }
    }

    /// The primary's citation is exactly what it always was — one source, not a
    /// second copy stacked on by the derived pass.
    @Test func theCensusPrimaryCitationIsUnchangedByTheFix() throws {
        let events = census(occupation: "Wood sawyer", address: "Beighton Road",
                            detailURL: householdURL)
            .projectToLifeEvents(profileID: "p")
        let primary = try #require(events.first { $0.type == .census })
        #expect(primary.sources.count == 1)
        #expect(primary.sources.first?.citation?.url == householdURL)
        #expect(primary.sources.first?.origin.identifier == "freecen")
    }

    /// A census with no detail URL must still cite nothing — an empty badge on
    /// an untraceable fact is worse than no badge at all.
    @Test func aURLlessCensusStillFabricatesNoCitation() {
        let events = census(occupation: "Lead miner", address: "Church Street")
            .projectToLifeEvents(profileID: "p")
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.sources.isEmpty })
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
