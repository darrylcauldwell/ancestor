import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the surname-probe widening logic on `ResearchSubject` — both the
/// married-axis path (existing) and the maiden-axis path (extended in
/// commit a0ea471's follow-up). The maiden-axis fires for female subjects
/// whose recorded surname is in fact their married name (inverted import,
/// where the maiden is recoverable as `familyContext.fatherSurname`).
struct SurnamesToProbeTests {

    // MARK: - Maiden-axis (inverted import)

    @Test func maidenAxisFiresOnBirthForInvertedImportedFemale() {
        let subject = invertedImportedFemale()
        let probes = subject.surnamesToProbe(for: .birth)
        #expect(probes == ["Beighton", "Cauldwell"])
    }

    @Test func maidenAxisFiresOnBaptismChristeningAndParish() {
        let subject = invertedImportedFemale()
        #expect(subject.surnamesToProbe(for: .baptism) == ["Beighton", "Cauldwell"])
        #expect(subject.surnamesToProbe(for: .christening) == ["Beighton", "Cauldwell"])
        #expect(subject.surnamesToProbe(for: .parish) == ["Beighton", "Cauldwell"])
    }

    @Test func maidenAxisFiresOnMarriage() {
        let subject = invertedImportedFemale()
        #expect(subject.surnamesToProbe(for: .marriage) == ["Beighton", "Cauldwell"])
    }

    @Test func maidenAxisFiresOnCensus() {
        let subject = invertedImportedFemale()
        #expect(subject.surnamesToProbe(for: .census) == ["Beighton", "Cauldwell"])
    }

    @Test func maidenAxisQuietOnPostMarriageRecords() {
        let subject = invertedImportedFemale()
        #expect(subject.surnamesToProbe(for: .death) == ["Beighton"])
        #expect(subject.surnamesToProbe(for: .burial) == ["Beighton"])
        #expect(subject.surnamesToProbe(for: .probate) == ["Beighton"])
        #expect(subject.surnamesToProbe(for: .military) == ["Beighton"])
    }

    @Test func maidenAxisQuietForMale() {
        let subject = wellImportedMale()
        #expect(subject.surnamesToProbe(for: .birth) == ["Cauldwell"])
        #expect(subject.surnamesToProbe(for: .marriage) == ["Cauldwell"])
    }

    @Test func maidenAxisQuietWhenFatherSurnameMatches() {
        // Well-imported female: surname is maiden, fatherSurname is the
        // same maiden. No duplicate probe should be emitted.
        let subject = wellImportedFemale()
        #expect(subject.surnamesToProbe(for: .birth) == ["Cauldwell"])
        #expect(subject.surnamesToProbe(for: .marriage) == ["Cauldwell"])
    }

    @Test func maidenAxisCaseInsensitive() {
        // surname "BEIGHTON" vs fatherSurname "Cauldwell" — still emits both.
        var subject = invertedImportedFemale()
        subject.surname = "BEIGHTON"
        #expect(subject.surnamesToProbe(for: .birth) == ["BEIGHTON", "Cauldwell"])

        // surname "Cauldwell" vs fatherSurname "cauldwell" — caseInsensitive
        // equality means we don't double-probe.
        let dupe = ResearchSubject(
            surname: "Cauldwell",
            givenName: "Elizabeth",
            gender: .female,
            mode: .extend,
            familyContext: contextWithFather("cauldwell")
        )
        #expect(dupe.surnamesToProbe(for: .birth) == ["Cauldwell"])
    }

    // MARK: - Married-axis (existing logic, regression-pinned)

    @Test func marriedAxisFiresOnDeathShapeRecords() {
        // Well-imported widow: surname=maiden, marriedSurname=married.
        let subject = wellImportedFemaleWithMarried()
        #expect(subject.surnamesToProbe(for: .death) == ["Cauldwell", "Beighton"])
        #expect(subject.surnamesToProbe(for: .burial) == ["Cauldwell", "Beighton"])
        #expect(subject.surnamesToProbe(for: .probate) == ["Cauldwell", "Beighton"])
        #expect(subject.surnamesToProbe(for: .military) == ["Cauldwell", "Beighton"])
    }

    @Test func bothAxesFireOnCensusForWellImportedWidow() {
        let subject = wellImportedFemaleWithMarried()
        // Surname is maiden; fatherSurname matches surname (no maiden
        // widening needed), but marriedSurname adds the post-marriage probe.
        #expect(subject.surnamesToProbe(for: .census) == ["Cauldwell", "Beighton"])
    }

    // MARK: - Edge cases

    @Test func nilSurnameReturnsEmpty() {
        let subject = ResearchSubject(surname: nil, mode: .extend)
        #expect(subject.surnamesToProbe(for: .birth) == [])
        #expect(subject.surnamesToProbe(for: .death) == [])
    }

    @Test func unknownGenderDoesNotProbeMaiden() {
        // Gender is required for the maiden-axis to fire — protects
        // against false-positive widening on ungendered manual leads.
        var subject = invertedImportedFemale()
        subject.gender = nil
        #expect(subject.surnamesToProbe(for: .birth) == ["Beighton"])
    }

    // MARK: - Multi-marriage death-side fan-out

    /// Gillian Rose (maiden Rose) married twice, last to David Grant. Her
    /// death/burial/probate probe EVERY married surname (latest first) plus her
    /// stored surname, so records aren't missed under the wrong married name.
    @Test func deathShapeFansAcrossAllMarriedSurnames() {
        let subject = ResearchSubject(
            surname: "Rose",
            marriedSurnames: ["Grant", "Smith"],
            givenName: "Gillian",
            gender: .female,
            mode: .extend
        )
        #expect(subject.surnamesToProbe(for: .death) == ["Rose", "Grant", "Smith"])
        #expect(subject.surnamesToProbe(for: .burial) == ["Rose", "Grant", "Smith"])
        #expect(subject.surnamesToProbe(for: .probate) == ["Rose", "Grant", "Smith"])
    }

    /// Falls back to the single `marriedSurname` when the plural list is empty
    /// (subjects built the old way / other `fromX` paths).
    @Test func fallsBackToSingleMarriedSurnameWhenListEmpty() {
        let subject = ResearchSubject(
            surname: "Beighton",
            marriedSurname: "Cauldwell",
            givenName: "Elizabeth",
            gender: .female,
            mode: .extend
        )
        #expect(subject.surnamesToProbe(for: .death) == ["Beighton", "Cauldwell"])
    }

    /// A married surname that equals the stored surname isn't duplicated.
    @Test func doesNotDuplicateStoredSurname() {
        let subject = ResearchSubject(
            surname: "Grant",
            marriedSurnames: ["Grant", "Smith"],
            givenName: "Gillian",
            gender: .female,
            mode: .extend
        )
        #expect(subject.surnamesToProbe(for: .death) == ["Grant", "Smith"])
    }

    /// `fromProfile` orders married surnames latest-marriage-first — Gillian's
    /// last husband David Grant leads, ahead of her earlier Smith marriage.
    @Test func fromProfileOrdersMarriedSurnamesLatestFirst() {
        func person(_ id: String, _ first: String, _ last: String?, _ gender: Gender) -> Profile {
            Profile(id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
                    gender: gender, attributes: nil, birthDate: nil, birthLocation: nil,
                    deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
                    sources: [:], disputes: [:])
        }
        func marriage(_ a: String, _ b: String, _ year: String) -> Relationship {
            Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil, subtype: .unknown,
                         marriageDate: GenealogicalDate(parsing: year),
                         marriageLocation: nil, divorceDate: nil)
        }
        let gillian = person("g", "Gillian", "Rose", .female)
        let smith = person("s", "John", "Smith", .male)
        let grant = person("gr", "David", "Grant", .male)
        let snap = FamilyGraphSnapshot(
            profiles: ["g": gillian, "s": smith, "gr": grant],
            relationships: [marriage("g", "s", "1975"), marriage("g", "gr", "1998")])

        let subject = ResearchSubject.fromProfile(gillian, snapshot: snap)
        #expect(subject.marriedSurnames == ["Grant", "Smith"])
        #expect(subject.surnamesToProbe(for: .death) == ["Rose", "Grant", "Smith"])
    }

    // MARK: - Fixtures

    /// Inverted-import: surname carries the married name, fatherSurname
    /// holds the maiden. Models Elizabeth Cauldwell (twin lastName=Beighton,
    /// father=John Cauldwell) and Catherine Hannah Bown (twin lastName=Ward,
    /// father=Philip Bown).
    private func invertedImportedFemale() -> ResearchSubject {
        ResearchSubject(
            surname: "Beighton",
            givenName: "Elizabeth",
            gender: .female,
            mode: .extend,
            familyContext: contextWithFather("Cauldwell")
        )
    }

    /// Well-imported female: surname = maiden, fatherSurname = same maiden.
    /// The maiden-axis must no-op here.
    private func wellImportedFemale() -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Mabel",
            gender: .female,
            mode: .extend,
            familyContext: contextWithFather("Cauldwell")
        )
    }

    /// Well-imported female with an explicit marriedSurname set. Models
    /// the death-axis path the original behaviour was built for.
    private func wellImportedFemaleWithMarried() -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            marriedSurname: "Beighton",
            givenName: "Elizabeth",
            gender: .female,
            mode: .extend,
            familyContext: contextWithFather("Cauldwell")
        )
    }

    private func wellImportedMale() -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Ernest",
            gender: .male,
            mode: .extend,
            familyContext: contextWithFather("Cauldwell")
        )
    }

    private func contextWithFather(_ surname: String) -> FamilyContext {
        FamilyContext(
            spouseName: nil,
            spouseSurname: nil,
            spouseGivenName: nil,
            spouseFatherSurname: nil,
            childNames: [],
            fatherName: nil,
            fatherSurname: surname,
            fatherGivenName: nil,
            motherName: nil,
            motherSurname: nil,
            motherGivenName: nil
        )
    }
}
