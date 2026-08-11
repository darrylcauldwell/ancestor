import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// LOCATION_MODEL_SPEC Part II, Slice B(i) — the review-layer birth-conflict
/// guard now resolves BOTH the subject's birthplace and the record's district
/// to registration-district ids and compares by identity. A subject born in a
/// hamlet (Hognaston → Ashbourne RD) accepts its RD's birth registration and
/// rejects a different-district namesake (Bakewell/Basford). Regression driver:
/// Mary Ward — 11 undiscriminated "Mary Ward" births collapse to the Ashbourne one.
struct LocationBirthDistrictTests {

    private func subject(birthLocation: String?, year: String) -> Profile {
        Profile(id: "s", externalIDs: [:], firstName: "Mary", lastName: "Ward",
                gender: .female, attributes: nil,
                birthDate: GenealogicalDate(parsing: year),
                birthLocation: birthLocation, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func birth(district: String, year: Int, given: String = "Mary Lizzie") -> ScoredRecord {
        let rec = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b_\(district)_\(year)", sourceID: "freebmd",
                                 name: "\(given) Ward", surname: "Ward", givenName: given, rawFields: [:]),
            birthYear: year, birthDate: nil, birthPlace: nil,
            quarter: "Dec", district: district, volume: "7b", page: "662",
            mothersMaidenName: nil))
        return ScoredRecord(id: rec.id, record: rec, verdict: .fact, gates: [], summary: "")
    }

    @Test func hognastonAcceptsAshbourneRejectsOtherDistricts() {
        let subj = subject(birthLocation: "Hognaston, Derbyshire (DBY)", year: "1886")
        // Ashbourne = Hognaston's registration district → NOT a conflict.
        #expect(RecordScorer.conflictsWithConfirmedBirth(birth(district: "Ashbourne", year: 1885), subject: subj) == false)
        // Different districts → conflict (namesakes).
        #expect(RecordScorer.conflictsWithConfirmedBirth(birth(district: "Bakewell", year: 1886), subject: subj) == true)
        #expect(RecordScorer.conflictsWithConfirmedBirth(birth(district: "Basford", year: 1886), subject: subj) == true)
    }

    @Test func toleratesFreeBMDAshborneSpelling() {
        let subj = subject(birthLocation: "Hognaston, Derbyshire (DBY)", year: "1886")
        // FreeBMD indexes the district as "Ashborne" (no 'u') — must still resolve
        // to the same RD as Hognaston, or the whole discrimination misses.
        #expect(RecordScorer.conflictsWithConfirmedBirth(birth(district: "Ashborne", year: 1885), subject: subj) == false)
    }

    /// Data-integrity guard: the catalogue must place Hognaston in Ashbourne
    /// (the whole discrimination rests on it).
    @Test func hognastonIsAnAshbourneParish() {
        #expect(FreeBMDDistrictCatalogue.shared.district(forParish: "Hognaston", inChapman: "DBY")?.name == "Ashbourne")
    }

    @Test func noBirthplaceMeansNoDistrictConflict() {
        // Regression / ADR-004 fallback: with no birthplace to resolve, the guard
        // must not manufacture a district conflict.
        let subj = subject(birthLocation: nil, year: "1886")
        #expect(RecordScorer.conflictsWithConfirmedBirth(birth(district: "Bakewell", year: 1886), subject: subj) == false)
    }
}
