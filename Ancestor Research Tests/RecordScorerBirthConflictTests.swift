import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Review-layer guard: once a subject has a CONFIRMED birth, a `.fact` birth
/// record that contradicts it (different year, or same-ish year but a different
/// registration district) is a same-named different person and must not be
/// offered as "will apply". Mirrors the George Wheeldon case — b.1894
/// Chesterfield confirmed, yet re-research kept surfacing 1892 Bakewell and
/// 1895 Basford namesake births as facts.
struct RecordScorerBirthConflictTests {

    private func subject(birthYear: Int?, birthPlace: String?) -> Profile {
        Profile(
            id: "subject", externalIDs: [:], firstName: "George", middleName: nil,
            lastName: "Wheeldon", gender: .male, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: birthPlace,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func birthFact(year: Int, district: String?) -> ScoredRecord {
        ScoredRecord(
            id: "b-\(year)-\(district ?? "?")",
            record: .birth(BirthRecord(
                common: RecordCommon(
                    id: "b-\(year)", sourceID: "freebmd",
                    name: nil, surname: "Wheeldon", givenName: "George",
                    detailURL: nil, rawFields: [:]),
                birthYear: year, birthDate: nil, birthPlace: nil,
                quarter: nil, district: district, volume: nil, page: nil,
                mothersMaidenName: nil)),
            verdict: .fact, gates: [], summary: "")
    }

    @Test func corroboratingBirthStillApplies() {
        // Same year, same district as the confirmed birth → it IS him.
        let s = subject(birthYear: 1894, birthPlace: "Chesterfield")
        let rec = birthFact(year: 1894, district: "Chesterfield")
        #expect(RecordScorer.wouldApply(rec, subject: s))
        #expect(!RecordScorer.conflictsWithConfirmedBirth(rec, subject: s))
    }

    @Test func conflictingYearIsWithheld() {
        // 1892 vs confirmed 1894 (gap 2 > ±1) → namesake, do not apply.
        let s = subject(birthYear: 1894, birthPlace: "Chesterfield")
        let rec = birthFact(year: 1892, district: "Bakewell")
        #expect(RecordScorer.conflictsWithConfirmedBirth(rec, subject: s))
        #expect(!RecordScorer.wouldApply(rec, subject: s))
    }

    @Test func sameYearDifferentDistrictIsWithheld() {
        // 1895 is within ±1 of 1894, but Basford ≠ Chesterfield → different
        // birth event, different person.
        let s = subject(birthYear: 1894, birthPlace: "Chesterfield")
        let rec = birthFact(year: 1895, district: "Basford")
        #expect(RecordScorer.conflictsWithConfirmedBirth(rec, subject: s))
        #expect(!RecordScorer.wouldApply(rec, subject: s))
    }

    @Test func districtCompatibleWithFullerPlaceStillApplies() {
        // Record district "Chesterfield" vs stored "Chesterfield, Derbyshire".
        let s = subject(birthYear: 1894, birthPlace: "Chesterfield, Derbyshire")
        let rec = birthFact(year: 1894, district: "Chesterfield")
        #expect(RecordScorer.wouldApply(rec, subject: s))
    }

    @Test func noConfirmedBirthMeansNoConflict() {
        // Without a confirmed birth there's nothing to contradict — the guard
        // stays out of the way (behaviour matches the plain wouldApply).
        let s = subject(birthYear: nil, birthPlace: nil)
        let rec = birthFact(year: 1892, district: "Bakewell")
        #expect(!RecordScorer.conflictsWithConfirmedBirth(rec, subject: s))
        #expect(RecordScorer.wouldApply(rec, subject: s))
    }

    @Test func nilSubjectFallsBackToPlainGate() {
        let rec = birthFact(year: 1892, district: "Bakewell")
        #expect(RecordScorer.wouldApply(rec, subject: nil) == RecordScorer.wouldApply(rec))
    }

    @Test func nonBirthRecordIsNeverABirthConflict() {
        // A death record isn't judged against the confirmed BIRTH.
        let s = subject(birthYear: 1894, birthPlace: "Chesterfield")
        let death = ScoredRecord(
            id: "d1", record: .death(DeathRecord(
                common: RecordCommon(id: "d1", sourceID: "freebmd", name: nil,
                    surname: "Wheeldon", givenName: "George", detailURL: nil, rawFields: [:]),
                deathYear: 1971, deathDate: nil, deathPlace: nil, age: nil,
                quarter: nil, district: "Chesterfield", volume: nil, page: nil,
                spouseSurname: nil)),
            verdict: .fact, gates: [], summary: "")
        #expect(!RecordScorer.conflictsWithConfirmedBirth(death, subject: s))
    }
}
