import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Parish records are date-gated by their own EVENT kind (2026-07-30,
/// first live FreeREG run): previously every parish event was checked
/// against the subject's BIRTH window, so William Henry Keyworth's own
/// 1896 marriage (married at 21) scored `impossible` while a namesake's
/// 1875 infant burial sat in his cluster as a lead. A parish marriage now
/// routes through the marriage-age arm and a parish burial through the
/// death-shape arm (where `aliveAsOf` and the reached-adulthood floor
/// apply); baptisms stay on the birth window.
struct ParishEventDateGateTests {

    private func parish(event: String, year: Int, name: String = "William Henry KEYWORTH") -> SourceRecord {
        .parish(ParishRecord(
            common: RecordCommon(
                id: "freereg_test_\(event)_\(year)", sourceID: "freereg",
                name: name, surname: "KEYWORTH", givenName: "William Henry",
                rawFields: [:]),
            eventType: event, eventYear: year,
            parish: "Worksop", county: "Nottinghamshire"))
    }

    /// William-shaped subject: b. 1874–1876, married with children,
    /// recorded alive 1881 (his childhood census).
    private func william(aliveAsOf: Int? = 1881) -> ResearchSubject {
        ResearchSubject(
            profileID: "wm", surname: "Keyworth", givenName: "William",
            birthYearFrom: 1874, birthYearTo: 1876,
            deathYearFrom: 1943, deathYearTo: 1943,
            aliveAsOf: aliveAsOf,
            gender: .male, region: .englandAndWales,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: "Emma Gladwin", spouseSurname: "Gladwin", spouseGivenName: "Emma",
                spouseFatherSurname: nil,
                childNames: ["Florence Keyworth"],
                fatherName: "George Keyworth", fatherSurname: "Keyworth", fatherGivenName: "George",
                motherName: nil, motherSurname: nil, motherGivenName: nil),
            homeChapmanCode: "NTT")
    }

    @Test func parishMarriageAtTwentyOnePassesTheDateGate() {
        // THE live regression: his real 1896 Worksop marriage.
        let result = RecordScorer.classify(
            record: parish(event: "marriage", year: 1896),
            subject: william(),
            searchType: .parish)
        let date = result.gates.first { $0.gate == .date }
        #expect(date?.outcome == .pass,
                "married 1896 at ~21 (b.1874–76) is typical — got \(String(describing: date))")
        #expect(result.verdict != .impossible)
    }

    @Test func parishMarriageBeforeBirthIsStillImpossible() {
        let result = RecordScorer.classify(
            record: parish(event: "marriage", year: 1870),
            subject: william(),
            searchType: .parish)
        #expect(result.verdict == .impossible, "married before birth stays impossible")
    }

    @Test func namesakeInfantParishBurialIsImpossibleForAnAdultSubject() {
        // The Feb 1875 Sutton-cum-Lound burial that previously clustered
        // with him as a lead: an infant burial for a subject who married
        // and had children — and who the tree records alive in 1881.
        let result = RecordScorer.classify(
            record: parish(event: "burial", year: 1875, name: "William KEYWORTH"),
            subject: william(),
            searchType: .parish)
        #expect(result.verdict == .impossible,
                "an 1875 burial cannot be a man recorded alive in 1881 who married in 1896")
    }

    @Test func parishBurialInTheDeathWindowPasses() {
        let result = RecordScorer.classify(
            record: parish(event: "burial", year: 1943),
            subject: william(),
            searchType: .parish)
        let date = result.gates.first { $0.gate == .date }
        #expect(date?.outcome == .pass || date?.outcome == .softFail,
                "a burial matching the known death year must not be birth-window-dated — got \(String(describing: date))")
        #expect(result.verdict != .impossible)
    }

    @Test func parishBaptismStaysOnTheBirthWindow() {
        let inWindow = RecordScorer.classify(
            record: parish(event: "baptism", year: 1875),
            subject: william(),
            searchType: .parish)
        #expect(inWindow.gates.first { $0.gate == .date }?.outcome == .pass)

        let outOfWindow = RecordScorer.classify(
            record: parish(event: "baptism", year: 1914),
            subject: william(),
            searchType: .parish)
        #expect(outOfWindow.verdict == .impossible,
                "a 1914 baptism is not a man born ~1875 — birth-window logic unchanged for baptisms")
    }

    @Test func untypedParishEventKeepsLegacyBirthWindowBehaviour() {
        let result = RecordScorer.classify(
            record: parish(event: "", year: 1875),
            subject: william(),
            searchType: .parish)
        #expect(result.gates.first { $0.gate == .date }?.outcome == .pass,
                "an event-less parish record falls back to the birth window as before")
    }
}
