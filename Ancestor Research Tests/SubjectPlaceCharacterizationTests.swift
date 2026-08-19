import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// SUBJECT_PLACE_MODEL_SPEC Slice 1 — characterization.
///
/// `ResearchSubject` flattens one uniform storage shape (`text` + `code`, on
/// every location the model holds) into five ad-hoc ones: `region`,
/// `deathLocation`, `homeChapmanCode`, `residenceAxes`, and
/// `burialPlace`/`burialChapmanCode`. Each source then reads whichever of those
/// someone remembered to wire to it, which is why FreeCen honours residence
/// counties, FreeREG honours a burial county, FreeBMD honours a death county
/// (added 2026-08-18), and NOTHING honours a census residence.
///
/// These tests pin what the subject looks like TODAY, for each shape of profile,
/// so the PlaceRef refactor is judged against recorded behaviour rather than
/// against anyone's reading of the code. They are deliberately assertions about
/// the CURRENT design, including the parts the refactor intends to change —
/// where that is so, the test says which way it is expected to move.
@MainActor
struct SubjectPlaceCharacterizationTests {

    // MARK: - Fixtures

    private func profile(
        birth: String? = nil, birthCode: String? = nil,
        death: String? = nil, deathCode: String? = nil,
        birthRD: String? = nil
    ) -> Profile {
        Profile(id: "subject", firstName: "Test", lastName: "Person", gender: .male,
                birthDate: GenealogicalDate(parsing: "1861"),
                birthLocation: birth, birthLocationCode: birthCode,
                birthRegistrationDistrict: birthRD,
                deathDate: GenealogicalDate(parsing: "1921"),
                deathLocation: death, deathLocationCode: deathCode,
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func subject(
        _ p: Profile, events: [LifeEvent] = [], projectHome: String = ""
    ) -> ResearchSubject {
        let snapshot = FamilyGraphSnapshot(
            profiles: [p.id: p], relationships: [], lifeEvents: [p.id: events])
        return ResearchSubject.fromProfile(p, snapshot: snapshot, homeChapmanCode: projectHome)
    }

    private func residence(_ place: String, code: String? = nil, year: Int) -> LifeEvent {
        LifeEvent(id: UUID(), profileID: "subject", type: .residence,
                  date: GenealogicalDate(parsing: String(year)),
                  location: place, locationCode: code)
    }

    private func census(_ place: String, code: String? = nil, year: Int) -> LifeEvent {
        LifeEvent(id: UUID(), profileID: "subject", type: .census,
                  date: GenealogicalDate(parsing: String(year)),
                  location: place, locationCode: code)
    }

    // MARK: - The anchor, shape by shape

    @Test func birthPlaceAnchorsTheSubject() {
        #expect(subject(profile(birth: "Wirksworth, Derbyshire")).homeChapmanCode == "DBY")
    }

    @Test func aCodedBirthPlaceWinsOverItsText() {
        let s = subject(profile(birth: "Leek, Staffordshire", birthCode: "DBY:Wirksworth"))
        #expect(s.homeChapmanCode == "DBY", "the code is the more precise statement")
    }

    /// Added 2026-08-18: the subject's own death county now outranks a project
    /// default. Before that, this returned the project's county.
    @Test func deathAnchorsWhenThereIsNoBirthPlace() {
        let s = subject(profile(death: "Leek, Staffordshire"), projectHome: "DBY")
        #expect(s.homeChapmanCode == "STS")
    }

    @Test func birthStillOutranksDeath() {
        let s = subject(profile(birth: "Wirksworth, Derbyshire", death: "Leek, Staffordshire"))
        #expect(s.homeChapmanCode == "DBY")
    }

    /// THE GAP THIS REFACTOR EXISTS TO CLOSE. A profile whose only locations are
    /// census residences anchors on the PROJECT DEFAULT — the person's own
    /// recorded counties are not consulted at all.
    ///
    /// Under PlaceRef this must become "STS". Until then, this test records the
    /// wrong answer deliberately, so the change is visible when it happens.
    @Test func censusResidencesDoNotAnchorTodayAndShould() {
        let s = subject(profile(), events: [
            residence("Leek, Staffordshire", year: 1881),
            census("Leek, Staffordshire", year: 1891),
        ], projectHome: "DBY")

        #expect(s.homeChapmanCode == "DBY",
                "TODAY: the project default wins over the subject's own counties")
        #expect(s.residenceAxes.contains { $0.chapmanCode == "STS" },
                "…even though the county IS derived, into a field only FreeCen reads")
    }

    @Test func withNothingAtAllThereIsNoAnchor() {
        #expect(subject(profile()).homeChapmanCode.isEmpty,
                "an absent anchor must stay absent — it drives a visible scope-skip")
    }

    // MARK: - The five flattened shapes

    /// The residence county is derived and stored — just somewhere only one
    /// source looks.
    @Test func residenceCountiesLandInTheirOwnShape() {
        let s = subject(profile(birth: "Wirksworth, Derbyshire"),
                        events: [residence("Leek, Staffordshire", year: 1881)])
        #expect(s.residenceAxes.count == 1)
        #expect(s.residenceAxes.first?.chapmanCode == "STS")
        #expect(s.homeChapmanCode == "DBY", "and it does not disturb the anchor")
    }

    /// A CENSUS event is not a residence event, so it produces no axis at all —
    /// even though it carries the same `location` + `locationCode` pair.
    @Test func censusEventsProduceNoResidenceAxisToday() {
        let s = subject(profile(birth: "Wirksworth, Derbyshire"),
                        events: [census("Leek, Staffordshire", year: 1891)])
        #expect(s.residenceAxes.isEmpty,
                "TODAY: only .residence events become axes; census locations are inert")
    }

    /// Sensitive events are excluded, and must stay excluded under any
    /// collection-shaped replacement.
    @Test func sensitiveResidencesAreExcluded() {
        var event = residence("Leek, Staffordshire", year: 1881)
        event.sensitive = true
        #expect(subject(profile(), events: [event]).residenceAxes.isEmpty)
    }

    @Test func deathLocationIsCarriedAsTextWithNoCode() {
        let s = subject(profile(death: "Leek, Staffordshire", deathCode: "STS:Leek"))
        #expect(s.deathLocation == "Leek, Staffordshire")
        // There is nowhere on the subject for the death CODE to live — it is
        // consumed into homeChapmanCode and otherwise discarded.
        #expect(s.homeChapmanCode == "STS")
    }

    // MARK: - What each source is handed

    /// FreeBMD sees the anchor county, plus (since 2026-08-18) the death county
    /// for death-shaped records. It never sees a residence county.
    @Test func freeBMDSeesTheAnchorAndDeathCountyOnly() {
        let anchorOnly = SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "DBY", countyQueriesEnabled: true,
            surname: "Person")
        let withDeath = SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "DBY", countyQueriesEnabled: true,
            surname: "Person", extraCounties: ["STS"])

        #expect(!anchorOnly.isEmpty)
        #expect(withDeath.count == anchorOnly.count + 1, "additive, never replacing")
    }

    /// Parish and district emit exactly what county emits — the collapse the
    /// config sheet now states plainly.
    @Test func parishAndDistrictAreCountyToday() {
        let county = SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "DBY", countyQueriesEnabled: true, surname: "P")
        let district = SearchDispatcher.freeBMDGeoAxes(
            scope: .district, homeChapmanCode: "DBY", countyQueriesEnabled: true, surname: "P")
        #expect(district.map(\.countyCode) == county.map(\.countyCode))

        #expect(SearchDispatcher.freeBMDGeoAxes(
            scope: .parish, homeChapmanCode: "DBY", countyQueriesEnabled: true, surname: "P")
            .isEmpty, "FreeBMD is skipped entirely at parish scope")
    }

    /// An anchor-less subject emits nothing rather than sweeping nationally by
    /// accident. The refactor must not manufacture an anchor here.
    @Test func anAnchorlessSubjectEmitsNoAxes() {
        #expect(SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "", countyQueriesEnabled: true, surname: "P")
            .allSatisfy { ($0.countyCode ?? "").isEmpty })
    }
}
