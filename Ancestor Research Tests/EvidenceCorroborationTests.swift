import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EVIDENCE_ABSORPTION_SPEC Change 3 — records that carry a birth/death signal
/// off-agenda (an age, a FindAGrave date, a probate age) must corroborate the
/// profile's date fields, not vanish. The implied date is routed through the
/// existing directional policy, so it fills empty / corroborates compatible /
/// disputes incompatible, but never overwrites a precise value.
struct EvidenceCorroborationTests {

    private func common(_ id: String, _ src: String) -> RecordCommon {
        RecordCommon(id: id, sourceID: src, rawFields: [:])
    }

    // MARK: birthDateFromAge

    @Test func ageDerivesTwoYearCalculatedSpan() {
        // Harry Marshall: died 1951 aged 24 → born 1926 or 1927.
        let d = ApplyEngine.birthDateFromAge(age: 24, at: 1951)
        #expect(d?.earliest == 1926)
        #expect(d?.latest == 1927)
        #expect(d?.qualifier == .calculated)
        #expect(d?.isApproximate == true)
    }

    @Test func nonsenseAgesRejected() {
        #expect(ApplyEngine.birthDateFromAge(age: -1, at: 1900) == nil)
        #expect(ApplyEngine.birthDateFromAge(age: 200, at: 1900) == nil)
        // A ref year that would push birth before year 1 is rejected.
        #expect(ApplyEngine.birthDateFromAge(age: 50, at: 10) == nil)
    }

    // MARK: impliedBirthDate

    @Test func censusPrefersExplicitBirthYearOverAge() {
        let rec = SourceRecord.census(CensusRecord(
            common: common("c", "freecen"), censusYear: 1891, age: 3, birthYear: 1888))
        let d = ApplyEngine.impliedBirthDate(for: rec)
        #expect(d?.earliest == 1888 && d?.latest == 1888)  // explicit year, not 1887–1888 from age
    }

    @Test func censusFallsBackToAgeWhenNoBirthYear() {
        let rec = SourceRecord.census(CensusRecord(
            common: common("c", "freecen"), censusYear: 1891, age: 3))
        let d = ApplyEngine.impliedBirthDate(for: rec)
        #expect(d?.earliest == 1887 && d?.latest == 1888)
    }

    @Test func deathAgeImpliesBirthYear() {
        let rec = SourceRecord.death(DeathRecord(
            common: common("d", "freebmd"), deathYear: 1951, age: 24))
        let d = ApplyEngine.impliedBirthDate(for: rec)
        #expect(d?.earliest == 1926 && d?.latest == 1927)
    }

    @Test func burialPrefersExplicitBirthDate() {
        let rec = SourceRecord.burial(BurialRecord(
            common: common("b", "findagrave"),
            birthDate: "15 March 1888", birthYear: 1888, isVeteran: false))
        let d = ApplyEngine.impliedBirthDate(for: rec)
        #expect(d?.earliest == 1888)
        #expect(d?.original.contains("1888") == true)
    }

    @Test func probateAgeAtDeathImpliesBirthYear() {
        let rec = SourceRecord.probate(ProbateRecord(
            common: common("p", "probate"), deathYear: 1970, ageAtDeath: 82))
        let d = ApplyEngine.impliedBirthDate(for: rec)
        #expect(d?.earliest == 1887 && d?.latest == 1888)
    }

    @Test func birthRecordImpliesNothingToAvoidDoubleWrite() {
        // The .birth case writes birthDate itself; corroboration must not fire.
        let rec = SourceRecord.birth(BirthRecord(
            common: common("bi", "freebmd"), birthYear: 1888))
        #expect(ApplyEngine.impliedBirthDate(for: rec) == nil)
    }

    // MARK: impliedDeathDate

    @Test func findAGraveDeathDateCorroborates() {
        let rec = SourceRecord.burial(BurialRecord(
            common: common("b", "findagrave"),
            deathDate: "3 January 1951", deathYear: 1951, isVeteran: false))
        #expect(ApplyEngine.impliedDeathDate(for: rec)?.earliest == 1951)
    }

    @Test func deathRecordImpliesNoDeathDateToAvoidDoubleWrite() {
        let rec = SourceRecord.death(DeathRecord(
            common: common("d", "freebmd"), deathYear: 1951, age: 24))
        #expect(ApplyEngine.impliedDeathDate(for: rec) == nil)
    }

    // MARK: probate address → residence fan-out

    @Test func probateAddressFansOutToResidenceEvent() {
        let rec = SourceRecord.probate(ProbateRecord(
            common: common("p", "probate"), deathYear: 1970, address: "3 Mill Lane, Bakewell"))
        let events = rec.projectToLifeEvents(profileID: "p")
        #expect(events.contains { $0.type == .probate })
        let residence = events.first { $0.type == .residence }
        #expect(residence?.location == "3 Mill Lane, Bakewell")
        #expect(residence?.date?.earliest == 1970)
    }

    @Test func probateWithoutAddressYieldsNoResidence() {
        let rec = SourceRecord.probate(ProbateRecord(
            common: common("p", "probate"), deathYear: 1970))
        let events = rec.projectToLifeEvents(profileID: "p")
        #expect(events.allSatisfy { $0.type != .residence })
    }
}
