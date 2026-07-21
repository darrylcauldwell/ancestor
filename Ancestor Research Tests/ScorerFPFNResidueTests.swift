import Testing
import Foundation
@testable import Ancestor_Research

/// False-positive / false-negative gate residues from the 2026-07 sandwich
/// audit — the (3rd) repair batch.
///
/// - **DS-12** — a marriage record naming a DIFFERENT spouse fell through to
///   `.skip` (dropped from the verdict), so the strongest wrong-person signal
///   a marriage can carry silently reached `.fact`. It now soft-fails the
///   family-context gate → `.lead`.
/// - **DS-04** — a subject recorded under the name they went by (their middle
///   name) hard-failed the given gate → `.impossible`, dropping the record.
///   A middle-name match now soft-fails → reviewable `.lead`.
struct ScorerFPFNResidueTests {

    // MARK: - DS-12: marriage naming a different spouse

    @Test func marriageWithContradictingSpouseSoftFailsFamilyGate() {
        let result = RecordScorer.classify(
            record: marriage(surname: "Cauldwell", given: "Ernest", spouse: "Elizabeth Jones"),
            subject: subjectWithSpouse(spouseName: "Mary Smith", spouseSurname: "Smith"),
            searchType: .marriage
        )
        let family = result.gates.first { $0.gate == .familyContext }
        #expect(family?.outcome == .softFail,
                "a contradicting spouse must soft-fail the family gate — got \(String(describing: family?.outcome))")
        #expect(result.verdict != .fact,
                "a marriage naming a different spouse must not reach .fact — got \(result.verdict)")
    }

    @Test func marriageWithMatchingSpousePassesFamilyGate() {
        let result = RecordScorer.classify(
            record: marriage(surname: "Cauldwell", given: "Ernest", spouse: "Mary Smith"),
            subject: subjectWithSpouse(spouseName: "Mary Smith", spouseSurname: "Smith"),
            searchType: .marriage
        )
        #expect(result.gates.first { $0.gate == .familyContext }?.outcome == .pass)
    }

    @Test func marriageWithNoNamedSpouseDoesNotSoftFail() {
        // spouseName nil (pre-1912 FreeBMD) — no contradiction, so the gate
        // skips rather than soft-fails (it must remain fact-eligible via the
        // other gates / same-page inference).
        let result = RecordScorer.classify(
            record: marriage(surname: "Cauldwell", given: "Ernest", spouse: nil),
            subject: subjectWithSpouse(spouseName: "Mary Smith", spouseSurname: "Smith"),
            searchType: .marriage
        )
        #expect(result.gates.first { $0.gate == .familyContext }?.outcome != .softFail)
    }

    // MARK: - DS-04: recorded under the middle name

    @Test func middleNameRecordSoftFailsInsteadOfImpossible() {
        // Ernest Victor Cauldwell, recorded as "Victor Cauldwell".
        let result = RecordScorer.classify(
            record: birth(surname: "Cauldwell", given: "Victor"),
            subject: subjectNamed(given: "Ernest", middle: "Victor"),
            searchType: .birth
        )
        let name = result.gates.first { $0.gate == .name }
        #expect(name?.outcome == .softFail,
                "a middle-name record must soft-fail, not hard-fail — got \(String(describing: name?.outcome))")
        #expect(result.verdict != .impossible,
                "a middle-name record must be recoverable, not dropped — got \(result.verdict)")
    }

    @Test func givenNameRecordStillPasses() {
        let result = RecordScorer.classify(
            record: birth(surname: "Cauldwell", given: "Ernest"),
            subject: subjectNamed(given: "Ernest", middle: "Victor"),
            searchType: .birth
        )
        #expect(result.gates.first { $0.gate == .name }?.outcome == .pass)
    }

    @Test func unrelatedGivenNameStillImpossible() {
        // A name matching neither the given nor the middle must still fail.
        let result = RecordScorer.classify(
            record: birth(surname: "Cauldwell", given: "Herbert"),
            subject: subjectNamed(given: "Ernest", middle: "Victor"),
            searchType: .birth
        )
        #expect(result.gates.first { $0.gate == .name }?.outcome == .fail)
        #expect(result.verdict == .impossible)
    }

    // MARK: - DS-10: parish parent-name cross-check

    @Test func christeningWithContradictingFatherSoftFails() {
        // Subject's linked father is William Cauldwell; a baptism naming
        // father "John Cauldwell" (same surname, different given) is a
        // namesake-cousin baptism → soft-fail, not a silent .fact.
        let result = RecordScorer.classify(
            record: parish(surname: "Cauldwell", given: "Thomas", father: "John Cauldwell"),
            subject: subjectWithFather(given: "William"),
            searchType: .baptism
        )
        let family = result.gates.first { $0.gate == .familyContext }
        #expect(family?.outcome == .softFail,
                "a contradicting baptism father must soft-fail — got \(String(describing: family?.outcome))")
        #expect(result.verdict != .fact)
    }

    @Test func christeningWithMatchingFatherCorroborates() {
        let result = RecordScorer.classify(
            record: parish(surname: "Cauldwell", given: "Thomas", father: "William Cauldwell"),
            subject: subjectWithFather(given: "William"),
            searchType: .baptism
        )
        #expect(result.gates.first { $0.gate == .familyContext }?.outcome == .pass)
    }

    @Test func christeningWithNoParentDataSkips() {
        let result = RecordScorer.classify(
            record: parish(surname: "Cauldwell", given: "Thomas", father: nil),
            subject: subjectWithFather(given: "William"),
            searchType: .baptism
        )
        // No comparable parent data → gate skips (absent from result.gates).
        #expect(result.gates.first { $0.gate == .familyContext } == nil)
    }

    // MARK: - DS-15: death contradicted by the tree's own alive-evidence

    @Test func deathBeforeKnownAliveYearIsImpossible() {
        // Subject recorded alive in a 1911 census (aliveAsOf), no known death
        // year yet. A "died 1905" record is a same-name namesake.
        var subject = subjectNamed(given: "William", middle: nil)
        subject.aliveAsOf = 1911
        let result = RecordScorer.classify(
            record: death(given: "William", year: 1905, age: 62),
            subject: subject, searchType: .death
        )
        #expect(result.gates.first { $0.gate == .date }?.outcome == .impossible,
                "a death before a known-alive year must be impossible")
        #expect(result.verdict == .impossible)
    }

    @Test func deathInSameYearAsAliveEvidenceIsAllowed() {
        // Died the same year as the last alive-event — compatible (died later
        // that year); the guard is strictly-earlier only.
        var subject = subjectNamed(given: "William", middle: nil)
        subject.aliveAsOf = 1911
        let result = RecordScorer.classify(
            record: death(given: "William", year: 1911, age: 68),
            subject: subject, searchType: .death
        )
        #expect(result.gates.first { $0.gate == .date }?.outcome != .impossible)
    }

    @Test func deathAfterAliveEvidenceIsAllowed() {
        var subject = subjectNamed(given: "William", middle: nil)
        subject.aliveAsOf = 1911
        let result = RecordScorer.classify(
            record: death(given: "William", year: 1915, age: 72),
            subject: subject, searchType: .death
        )
        #expect(result.gates.first { $0.gate == .date }?.outcome != .impossible)
    }

    @Test func noAliveEvidenceLeavesDeathGateUnchanged() {
        // aliveAsOf nil (default) → DS-15 doesn't fire; the 1905 death is
        // scored by the normal age logic (age 62 vs birth 1843–47 is fine).
        let subject = subjectNamed(given: "William", middle: nil)
        let result = RecordScorer.classify(
            record: death(given: "William", year: 1905, age: 62),
            subject: subject, searchType: .death
        )
        #expect(result.gates.first { $0.gate == .date }?.outcome != .impossible)
    }

    // MARK: - Fixtures

    private func subjectNamed(given: String, middle: String?) -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: given,
            middleName: middle,
            birthYearFrom: 1843,
            birthYearTo: 1847,
            gender: .male,
            region: .englandAndWales,
            mode: .extend,
            familyContext: emptyContext()
        )
    }

    private func subjectWithSpouse(spouseName: String, spouseSurname: String) -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Ernest",
            birthYearFrom: 1843,
            birthYearTo: 1847,
            gender: .male,
            region: .englandAndWales,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: spouseName, spouseSurname: spouseSurname, spouseGivenName: nil,
                spouseFatherSurname: nil, childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil
            )
        )
    }

    private func subjectWithFather(given: String) -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Thomas",
            birthYearFrom: 1843,
            birthYearTo: 1847,
            gender: .male,
            region: .englandAndWales,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
                spouseFatherSurname: nil, childNames: [],
                fatherName: "\(given) Cauldwell", fatherSurname: "Cauldwell", fatherGivenName: given,
                motherName: nil, motherSurname: nil, motherGivenName: nil
            )
        )
    }

    private func parish(surname: String, given: String, father: String?) -> SourceRecord {
        .parish(ParishRecord(
            common: RecordCommon(
                id: "p-\(surname)-\(given)", sourceID: "freereg", name: nil,
                surname: surname, givenName: given, detailURL: nil, rawFields: [:]
            ),
            eventType: "baptism", eventDate: nil, eventYear: 1845,
            parish: "Duffield", county: "DBY",
            fatherName: father, motherName: nil
        ))
    }

    private func emptyContext() -> FamilyContext {
        FamilyContext(
            spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
            spouseFatherSurname: nil, childNames: [],
            fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
            motherName: nil, motherSurname: nil, motherGivenName: nil
        )
    }

    private func birth(surname: String, given: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: "b-\(surname)-\(given)", sourceID: "freebmd", name: nil,
                surname: surname, givenName: given, detailURL: nil, rawFields: [:]
            ),
            birthYear: 1845, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "Belper", volume: "19", page: "438",
            mothersMaidenName: nil
        ))
    }

    private func death(given: String, year: Int, age: Int) -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(
                id: "d-\(given)-\(year)", sourceID: "freebmd", name: nil,
                surname: "Cauldwell", givenName: given, detailURL: nil, rawFields: [:]
            ),
            deathYear: year, deathDate: nil, deathPlace: nil, age: age,
            quarter: "Mar", district: "Belper", volume: "7b", page: "412",
            spouseSurname: nil
        ))
    }

    private func marriage(surname: String, given: String, spouse: String?) -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(
                id: "m-\(surname)-\(given)", sourceID: "freebmd", name: nil,
                surname: surname, givenName: given, detailURL: nil, rawFields: [:]
            ),
            marriageYear: 1867, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "112",
            spouseName: spouse
        ))
    }
}
