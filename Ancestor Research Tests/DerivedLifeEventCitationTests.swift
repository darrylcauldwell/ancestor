import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV16 (2026-08-26) — a derived life event must carry the SAME citation as the
/// event it was derived from.
///
/// `projectToLifeEvents` fans a record out into a primary event plus the typed
/// events its fields imply (EVIDENCE_ABSORPTION_SPEC Change 2 / Change 3,
/// PARISH_ABSORPTION_SPEC §6). The primary was built with `sources:`; all three
/// derived builders — `censusDerivedEvents`, `parishDerivedEvents`,
/// `probateDerivedEvents` — omitted the argument entirely, so it defaulted to
/// `[]` and the derived rows rendered with no citation badge beside a fully
/// cited event stating the identical fact.
///
/// Observed live on William Gladwin: life events 8DEBEAC0 ("Sawyer", 1881,
/// Handsworth) and B0A6E31A ("Wood Sawyer", 1891, Beighton) both held an empty
/// sources array, alongside four other profiles. An occupation nobody can trace
/// back to its census is an occupation the reader has to take on trust.
///
/// The tier is never asserted here — it stays URL-derived through
/// `SourceTierRegistry`. All these events do is carry the record's own URL.
struct DerivedLifeEventCitationTests {

    private let censusURL = "https://www.freecen.org.uk/search_records/6a2f/gladwin-1881"
    private let registerURL = "https://www.freereg.org.uk/search_records/682f9727/x"
    private let probateURL = "https://probatesearch.service.gov.uk/search-results?grant=1902-4471"

    // MARK: Fixtures

    private func census(detailURL: String?) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: "freecen_gladwin_1881", sourceID: "freecen",
                name: "William Gladwin", surname: "Gladwin", givenName: "William",
                detailURL: detailURL, rawFields: [:]),
            censusYear: 1881,
            occupation: "Sawyer", address: "12 Bramley Row", parish: "Handsworth"))
    }

    /// The Ernest Cauldwell × Mary Ward 1915 marriage — a parish MARRIAGE has
    /// no primary life event at all (it belongs on `Relationship`), so its
    /// occupation/abode rows are the ONLY events it produces. Uncited, the
    /// register URL reached the tree nowhere.
    private func parishMarriage(detailURL: String?) -> SourceRecord {
        let marriage = FreeREGMarriage(
            groom: FreeREGPerson(forename: "Ernest", surname: "Cauldwell", age: "26",
                                 condition: "bachelor", occupation: "Collier",
                                 abode: "Loscoe, Heanor"),
            bride: FreeREGPerson(forename: "Mary", surname: "Ward", age: "25",
                                 condition: "spinster"),
            marriageDate: "30 Jan 1915")
        return .parish(ParishRecord(
            common: RecordCommon(
                id: "freereg_cauldwell_ward_1915", sourceID: "freereg",
                name: "Ernest Cauldwell", surname: "Cauldwell", givenName: "Ernest",
                detailURL: detailURL, rawFields: [:]),
            eventType: "marriage", eventDate: "30 Jan 1915", eventYear: 1915,
            parish: "Kirk Ireton", county: "Derbyshire",
            detail: FreeREGDetail(event: .marriage(marriage), churchName: "Holy Trinity")))
    }

    private func parishBaptism(detailURL: String?) -> SourceRecord {
        .parish(ParishRecord(
            common: RecordCommon(
                id: "freereg_wheeldon_baptism_1848", sourceID: "freereg",
                name: "John Wheeldon", surname: "Wheeldon", givenName: "John",
                detailURL: detailURL, rawFields: [:]),
            eventType: "baptism", eventDate: "25 Dec 1848", eventYear: 1848,
            parish: "Cromford", county: "Derbyshire"))
    }

    private func probate(detailURL: String?) -> SourceRecord {
        .probate(ProbateRecord(
            common: RecordCommon(
                id: "probate_gladwin_1902", sourceID: "probate",
                name: "William Gladwin", surname: "Gladwin", givenName: "William",
                detailURL: detailURL, rawFields: [:]),
            deathDate: "3 Feb 1902", deathYear: 1902,
            probateDate: "14 Mar 1902",
            address: "12 Bramley Row, Handsworth",
            grantType: "Probate", registry: "Derby"))
    }

    private func urls(_ event: LifeEvent?) -> [String] {
        (event?.sources ?? []).compactMap { $0.citation?.url }
    }

    // MARK: - Census

    @Test func censusDerivedOccupationAndResidenceCarryTheCensusURL() throws {
        let events = census(detailURL: censusURL).projectToLifeEvents(profileID: "@P1@")
        #expect(Set(events.map(\.type)) == [.census, .occupation, .residence])
        for event in events {
            #expect(urls(event) == [censusURL],
                    "\(event.type.displayName) landed uncited")
            #expect(event.sources.first?.origin.identifier == "freecen")
        }
    }

    /// The primary must be untouched by the fix — exactly the one citation it
    /// already carried, not a second stacked copy.
    @Test func censusPrimaryCitationIsUnchanged() throws {
        let events = census(detailURL: censusURL).projectToLifeEvents(profileID: "@P1@")
        let primary = try #require(events.first { $0.type == .census })
        #expect(primary.sources.count == 1)
        #expect(primary.sources.first?.citation?.url == censusURL)
        // …and identical to what the single-event path produces on its own.
        let solo = try #require(census(detailURL: censusURL).projectToLifeEvent(profileID: "@P1@"))
        #expect(solo.sources.map { $0.citation?.url } == primary.sources.map { $0.citation?.url })
    }

    /// A record with no URL must still produce NO citation. An empty citation
    /// badge on an untraceable fact is worse than no badge (same rule as
    /// `LifeEventCitationTests.anUnsourcedSubmissionGetsNoFabricatedCitation`).
    @Test func anUncitedCensusFabricatesNoCitation() {
        let events = census(detailURL: nil).projectToLifeEvents(profileID: "@P1@")
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.sources.isEmpty })
    }

    @Test func anEmptyCensusURLIsTreatedAsNoURL() {
        let events = census(detailURL: "").projectToLifeEvents(profileID: "@P1@")
        #expect(events.allSatisfy { $0.sources.isEmpty })
    }

    // MARK: - Parish

    @Test func parishMarriageDerivedEventsCarryTheRegisterURL() throws {
        let events = parishMarriage(detailURL: registerURL).projectToLifeEvents(profileID: "subj")
        // A marriage yields NO primary — only the derived pair.
        #expect(Set(events.map(\.type)) == [.occupation, .residence])
        let occ = try #require(events.first { $0.type == .occupation })
        let res = try #require(events.first { $0.type == .residence })
        #expect(occ.description == "Collier")
        #expect(res.location == "Loscoe, Heanor")
        #expect(urls(occ) == [registerURL])
        #expect(urls(res) == [registerURL])
        #expect(occ.sources.first?.origin.identifier == "freereg")
    }

    @Test func anUncitedParishMarriageFabricatesNoCitation() {
        let events = parishMarriage(detailURL: nil).projectToLifeEvents(profileID: "subj")
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.sources.isEmpty })
    }

    /// #29's baptism citation must survive this pass untouched — a baptism has
    /// no derived events, so its single primary is the whole projection.
    @Test func parishBaptismPrimaryCitationIsUnchanged() throws {
        let events = parishBaptism(detailURL: registerURL).projectToLifeEvents(profileID: "subj")
        #expect(events.map(\.type) == [.baptism])
        #expect(urls(events.first) == [registerURL])
        #expect(events.first?.sources.count == 1)
    }

    // MARK: - Probate

    @Test func probateDerivedResidenceCarriesTheGrantURL() throws {
        let events = probate(detailURL: probateURL).projectToLifeEvents(profileID: "@P1@")
        #expect(Set(events.map(\.type)) == [.probate, .residence])
        let res = try #require(events.first { $0.type == .residence })
        #expect(res.location == "12 Bramley Row, Handsworth")
        #expect(urls(res) == [probateURL], "the \"late of …\" residence landed uncited")
        // Window closed at the death year, unchanged by this fix.
        #expect(res.date?.bestYear == 1902)
        #expect(res.endDate?.bestYear == 1902)
    }

    /// EV16 also cited the probate PRIMARY, which had never carried a source.
    /// Leaving it bare would have put an uncited "Probate 1902" immediately
    /// above a cited "Residence 1902" derived from the same grant.
    @Test func probatePrimaryIsNowCitedToo() throws {
        let events = probate(detailURL: probateURL).projectToLifeEvents(profileID: "@P1@")
        let primary = try #require(events.first { $0.type == .probate })
        #expect(urls(primary) == [probateURL])
        #expect(primary.sources.first?.origin.identifier == "probate")
    }

    @Test func anUncitedProbateFabricatesNoCitation() {
        let events = probate(detailURL: nil).projectToLifeEvents(profileID: "@P1@")
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.sources.isEmpty })
    }

    // MARK: - Idempotence

    /// The citation must not disturb the deterministic IDs the INSERT OR IGNORE
    /// dedup relies on — a re-projection has to land on the same rows.
    @Test func citingDerivedEventsLeavesTheirIDsStable() {
        let cited = census(detailURL: censusURL).projectToLifeEvents(profileID: "@P1@")
        let bare = census(detailURL: nil).projectToLifeEvents(profileID: "@P1@")
        #expect(cited.map(\.id) == bare.map(\.id))
        #expect(Set(cited.map(\.id)).count == 3)
    }
}
