import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the surname-axis widening in `RecordScorer.checkName`.
///
/// Mirrors `SurnamesToProbeTests` on the scorer side. Every surname the
/// dispatcher puts on the wire (via `subject.surnamesToProbe`) must be
/// accepted back here — otherwise legitimate records returned under the
/// alternate form (maiden / married) fail the name gate and get scored
/// `.impossible`.
///
/// Anchored to the Elizabeth Cauldwell case: FreeBMD returned her birth
/// as "Elizabeth CALDWELL Mar 1845 Belper vol 19/438", but before this
/// fix the scorer rejected it because `subject.surname` was "Beighton"
/// (married name, from the inverted twin import).
struct RecordScorerSurnameAxisTests {

    // MARK: - Maiden-axis acceptance

    @Test func acceptsMaidenSurnameOnBirthForInvertedImportedFemale() {
        let result = RecordScorer.classify(
            record: birthRecord(surname: "Caldwell", givenName: "Elizabeth"),
            subject: invertedImportedFemale(),
            searchType: .birth
        )
        #expect(result.verdict != .impossible,
                "Inverted-import female birth under maiden surname must not be impossible — got \(result.verdict)")
    }

    @Test func acceptsMaidenOnMarriage() {
        let result = RecordScorer.classify(
            record: marriageRecord(surname: "Caldwell", givenName: "Elizabeth"),
            subject: invertedImportedFemale(),
            searchType: .marriage
        )
        #expect(result.verdict != .impossible)
    }

    @Test func acceptsMaidenOnParish() {
        // ParishRecord covers .baptism / .christening / .parish searchTypes —
        // SourceRecord doesn't carve those out separately.
        let result = RecordScorer.classify(
            record: parishRecord(surname: "Caldwell", givenName: "Elizabeth", eventType: "baptism"),
            subject: invertedImportedFemale(),
            searchType: .baptism
        )
        #expect(result.verdict != .impossible)
    }

    @Test func acceptsMaidenOnCensus() {
        let result = RecordScorer.classify(
            record: censusRecord(surname: "Caldwell", givenName: "Elizabeth"),
            subject: invertedImportedFemale(),
            searchType: .census
        )
        #expect(result.verdict != .impossible)
    }

    @Test func rejectsMaidenSurnameOnDeathAxis() {
        // Death-axis records (death, burial, probate, military) should
        // continue to require the married surname for an inverted female.
        // The maiden-axis widening only fires for pre-marriage types.
        let deathResult = RecordScorer.classify(
            record: deathRecord(surname: "Caldwell", givenName: "Elizabeth"),
            subject: invertedImportedFemale(),
            searchType: .death
        )
        #expect(deathResult.verdict == .impossible,
                "Maiden surname must be rejected for death of an inverted-import female — got \(deathResult.verdict)")

        let burialResult = RecordScorer.classify(
            record: burialRecord(surname: "Caldwell", givenName: "Elizabeth"),
            subject: invertedImportedFemale(),
            searchType: .burial
        )
        #expect(burialResult.verdict == .impossible)
    }

    @Test func maidenAxisQuietForMale() {
        let result = RecordScorer.classify(
            record: birthRecord(surname: "Ward", givenName: "Ernest"),
            subject: maleWithFatherSurname("Cauldwell"),
            searchType: .birth
        )
        // Ernest Cauldwell subject; record says Ernest WARD. Maiden-axis
        // must not fire for males — record name-fails as expected.
        #expect(result.verdict == .impossible)
    }

    @Test func maidenAxisQuietWhenFatherSurnameMatches() {
        // Well-imported female: surname=maiden, fatherSurname=same.
        // Birth record under a third surname must still name-fail.
        let result = RecordScorer.classify(
            record: birthRecord(surname: "Beighton", givenName: "Mabel"),
            subject: wellImportedFemale(),
            searchType: .birth
        )
        #expect(result.verdict == .impossible)
    }

    // MARK: - Existing married-axis behaviour (regression pins)

    @Test func acceptsMarriedSurnameOnDeath() {
        let result = RecordScorer.classify(
            record: deathRecord(surname: "Beighton", givenName: "Elizabeth"),
            subject: wellImportedFemaleWithMarried(),
            searchType: .death
        )
        #expect(result.verdict != .impossible)
    }

    @Test func rejectsMarriedSurnameOnBirth() {
        // Married surname is not an acceptable match for a birth record.
        // (Death-axis only — birth would be under maiden.)
        let result = RecordScorer.classify(
            record: birthRecord(surname: "Beighton", givenName: "Elizabeth"),
            subject: wellImportedFemaleWithMarried(),
            searchType: .birth
        )
        #expect(result.verdict == .impossible)
    }

    // MARK: - Fixtures

    /// Inverted-import: surname=married, fatherSurname=maiden, no
    /// explicit marriedSurname. Models Elizabeth Cauldwell (twin
    /// lastName="Beighton", father=John Cauldwell).
    private func invertedImportedFemale() -> ResearchSubject {
        ResearchSubject(
            surname: "Beighton",
            givenName: "Elizabeth",
            birthYearFrom: 1843,
            birthYearTo: 1845,
            deathYearFrom: 1905,
            deathYearTo: 1907,
            gender: .female,
            region: .englandAndWales,
            mode: .extend,
            familyContext: contextWithFather("Cauldwell")
        )
    }

    private func wellImportedFemale() -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Mabel",
            birthYearFrom: 1896,
            birthYearTo: 1898,
            gender: .female,
            region: .englandAndWales,
            mode: .extend,
            familyContext: contextWithFather("Cauldwell")
        )
    }

    private func wellImportedFemaleWithMarried() -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            marriedSurname: "Beighton",
            givenName: "Elizabeth",
            birthYearFrom: 1843,
            birthYearTo: 1845,
            deathYearFrom: 1905,
            deathYearTo: 1907,
            gender: .female,
            region: .englandAndWales,
            mode: .extend,
            familyContext: contextWithFather("Cauldwell")
        )
    }

    private func maleWithFatherSurname(_ surname: String) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: "Ernest",
            birthYearFrom: 1886,
            birthYearTo: 1888,
            gender: .male,
            region: .englandAndWales,
            mode: .extend,
            familyContext: contextWithFather(surname)
        )
    }

    private func contextWithFather(_ surname: String) -> FamilyContext {
        FamilyContext(
            spouseName: nil,
            spouseSurname: nil,
            spouseGivenName: nil,
            childNames: [],
            fatherName: nil,
            fatherSurname: surname,
            fatherGivenName: nil,
            motherName: nil,
            motherSurname: nil,
            motherGivenName: nil
        )
    }

    private func commonFields(_ id: String, surname: String, givenName: String) -> RecordCommon {
        RecordCommon(
            id: id,
            sourceID: "freebmd",
            name: nil,
            surname: surname,
            givenName: givenName,
            detailURL: nil,
            rawFields: [:]
        )
    }

    private func birthRecord(surname: String, givenName: String, year: Int = 1844) -> SourceRecord {
        .birth(BirthRecord(
            common: commonFields("rec-birth-\(surname)-\(givenName)", surname: surname, givenName: givenName),
            birthYear: year,
            birthDate: nil,
            birthPlace: nil,
            quarter: "Mar",
            district: "Belper",
            volume: "19",
            page: "438",
            mothersMaidenName: nil
        ))
    }

    private func deathRecord(surname: String, givenName: String, year: Int = 1906) -> SourceRecord {
        .death(DeathRecord(
            common: commonFields("rec-death-\(surname)-\(givenName)", surname: surname, givenName: givenName),
            deathYear: year,
            deathDate: nil,
            deathPlace: nil,
            age: 62,
            quarter: "Mar",
            district: "Belper",
            volume: "7b",
            page: "412",
            spouseSurname: nil
        ))
    }

    private func marriageRecord(surname: String, givenName: String, year: Int = 1867) -> SourceRecord {
        .marriage(MarriageRecord(
            common: commonFields("rec-marriage-\(surname)-\(givenName)", surname: surname, givenName: givenName),
            marriageYear: year,
            marriageDate: nil,
            marriagePlace: nil,
            quarter: "Dec",
            district: "Belper",
            volume: "7b",
            page: "112",
            spouseName: nil
        ))
    }

    private func parishRecord(surname: String, givenName: String, eventType: String) -> SourceRecord {
        .parish(ParishRecord(
            common: commonFields("rec-parish-\(surname)-\(givenName)", surname: surname, givenName: givenName),
            eventType: eventType,
            eventDate: nil,
            eventYear: 1844,
            parish: "Alderwasley",
            county: "DBY",
            fatherName: nil,
            motherName: nil
        ))
    }

    private func censusRecord(surname: String, givenName: String, year: Int = 1861) -> SourceRecord {
        .census(CensusRecord(
            common: commonFields("rec-census-\(surname)-\(givenName)", surname: surname, givenName: givenName),
            censusYear: year,
            age: 16,
            birthYear: 1845,
            birthPlace: "Alderwasley",
            birthCounty: "DBY",
            relationship: nil,
            occupation: nil,
            address: nil,
            parish: nil,
            district: "Belper",
            household: nil
        ))
    }

    private func burialRecord(surname: String, givenName: String, year: Int = 1906) -> SourceRecord {
        .burial(BurialRecord(
            common: commonFields("rec-burial-\(surname)-\(givenName)", surname: surname, givenName: givenName),
            deathDate: nil,
            deathYear: year,
            birthDate: nil,
            birthYear: 1844,
            birthPlace: nil,
            deathPlace: nil,
            burialLocation: "Eckington Cemetery",
            cemetery: "Eckington",
            memorialID: 123,
            inscription: nil,
            bio: nil,
            isVeteran: false
        ))
    }
}
