import Testing
import Foundation
@testable import Ancestor_Research
@testable import AncestorKit

/// DECISION_CORE_PAIR_SPEC — characterization corpus from the 2026-07-30/31
/// live specimens (Elizabeth Shaw's 11 mutually exclusive birth "facts" and
/// 3 simultaneous 1891 censuses; Harry Marshall's namesake probates; Mary E
/// Land's namesake marriages; WHK's genuinely corroborated pair). Fix A: the
/// cross-record exclusivity pass.
struct DecisionCorePairExclusivityTests {

    // MARK: - Builders (all records constructed to PASS the per-record gates)

    private func common(_ id: String, given: String = "ELIZABETH", surname: String = "SHAW") -> RecordCommon {
        RecordCommon(id: id, sourceID: "freebmd", name: nil,
                     surname: surname, givenName: given, detailURL: nil, rawFields: [:])
    }

    /// Elizabeth-class subject: rich (given name + tight window) so the
    /// thin-subject cap does NOT apply — exactly how 11 births became facts.
    private func subject(
        familyContext: FamilyContext? = nil,
        deathFrom: Int? = nil, deathTo: Int? = nil
    ) -> ResearchSubject {
        var s = ResearchSubject(
            surname: "SHAW", givenName: "ELIZABETH",
            birthYearFrom: 1867, birthYearTo: 1871,
            gender: .female, region: .county("Derbyshire"), mode: .extend)
        s.deathYearFrom = deathFrom
        s.deathYearTo = deathTo
        s.familyContext = familyContext
        s.homeChapmanCode = "DBY"
        return s
    }

    private func contextWithChild(_ name: String) -> FamilyContext {
        FamilyContext(
            spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
            spouseFatherSurname: nil, childNames: [name],
            fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
            motherName: nil, motherSurname: nil, motherGivenName: nil)
    }

    private func contextWithSpouse(_ name: String) -> FamilyContext {
        FamilyContext(
            spouseName: name, spouseSurname: nil, spouseGivenName: nil,
            spouseFatherSurname: nil, childNames: [],
            fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
            motherName: nil, motherSurname: nil, motherGivenName: nil)
    }

    private func birth(_ id: String, year: Int, district: String = "Belper") -> SourceRecord {
        .birth(BirthRecord(common: common(id), birthYear: year, birthDate: nil,
                           birthPlace: nil, quarter: nil, district: district,
                           volume: "7b", page: "449", mothersMaidenName: nil))
    }

    private func census(_ id: String, household: [HouseholdMember]? = nil) -> SourceRecord {
        .census(CensusRecord(common: common(id), censusYear: 1891, age: 22,
                             birthYear: 1869, birthPlace: "Belper", district: "Belper",
                             household: household))
    }

    private func marriage(_ id: String, year: Int, spouseName: String?) -> SourceRecord {
        .marriage(MarriageRecord(
            common: common(id), marriageYear: year, marriageDate: nil,
            marriagePlace: nil, quarter: nil, district: "Belper",
            volume: "7b", page: "1518", spouseName: spouseName))
    }

    private func probate(_ id: String, year: Int) -> SourceRecord {
        .probate(ProbateRecord(common: common(id), deathYear: year,
                               probateDate: "\(year)", address: "Derbyshire"))
    }

    private func classifyAll(_ records: [SourceRecord], subject s: ResearchSubject) -> [ScoredRecord] {
        records.map { RecordScorer.classify(record: $0, subject: s, searchType: $0.recordType) }
    }

    private func verdicts(_ scored: [ScoredRecord]) -> [String: RecordVerdict] {
        Dictionary(uniqueKeysWithValues: scored.map { ($0.id, $0.verdict) })
    }

    // MARK: - Singular slots

    @Test func elizabethClassCompetingBirthsAllDemote() {
        // The live specimen: mutually exclusive birth registrations, each
        // individually gate-clean, all promoted to fact. A person has ONE
        // birth — with no discriminator, every one demotes to lead.
        let scored = classifyAll([
            birth("b1867", year: 1867), birth("b1869", year: 1869, district: "Bakewell"),
            birth("b1870", year: 1870), birth("b1871", year: 1871, district: "Bakewell"),
        ], subject: subject())
        #expect(scored.allSatisfy { $0.verdict == .fact }, "precondition: the over-acceptance being fixed")

        let passed = RecordScorer.applyExclusivity(scored)
        #expect(passed.allSatisfy { $0.verdict == .lead })
        #expect(passed.allSatisfy { record in
            record.gates.contains { $0.gate == .exclusivity && $0.outcome == .softFail }
        })
    }

    @Test func singleBirthFactIsUntouched() {
        let scored = classifyAll([birth("only", year: 1869)], subject: subject())
        let passed = RecordScorer.applyExclusivity(scored)
        #expect(passed.first?.verdict == .fact)
        #expect(passed.first?.gates.contains { $0.gate == .exclusivity } == false)
    }

    @Test func oneDiscriminatedCensusKeepsFactRivalsDemote() {
        // Three 1891 households (the live 3-censuses specimen) — but one
        // contains the subject's known child: the family-corroborated record
        // outranks the namesakes.
        let child = HouseholdMember(name: "Florence", relationship: "Daughter", age: 2)
        let scored = classifyAll([
            census("withChild", household: [child]),
            census("namesake1"), census("namesake2"),
        ], subject: subject(familyContext: contextWithChild("Florence")))
        let passed = RecordScorer.applyExclusivity(scored)
        let v = verdicts(passed)
        #expect(v["withChild"] == .fact)
        #expect(v["namesake1"] == .lead && v["namesake2"] == .lead)
    }

    @Test func twoDiscriminatedCensusesAreAContradictionAllDemote() {
        // Two households BOTH containing the known child cannot both be true
        // — genuine evidential contradiction, human judgement required.
        let child = HouseholdMember(name: "Florence", relationship: "Daughter", age: 2)
        let scored = classifyAll([
            census("claimA", household: [child]),
            census("claimB", household: [child]),
        ], subject: subject(familyContext: contextWithChild("Florence")))
        let passed = RecordScorer.applyExclusivity(scored)
        #expect(passed.allSatisfy { $0.verdict == .lead })
        #expect(passed.first?.gates.last?.reason.contains("contradiction") == true)
    }

    @Test func harryClassCompetingProbatesBothDemote() {
        // Harry Marshall's specimen: death year unknown → wide window → two
        // namesake probates both scored fact. One person, one grant.
        let scored = classifyAll([
            probate("p1999", year: 1949), probate("p2006", year: 1951),
        ], subject: subject(deathFrom: 1948, deathTo: 1952))
        #expect(scored.allSatisfy { $0.verdict == .fact }, "precondition")
        let passed = RecordScorer.applyExclusivity(scored)
        #expect(passed.allSatisfy { $0.verdict == .lead })
    }

    // MARK: - Marriage (non-singular slot)

    @Test func maryClassUndiscriminatedMarriagesBothDemote() {
        // Mary E Land's specimen: unmarried subject (no family context — the
        // gate skips, nothing discriminates), two namesake marriages as fact.
        let scored = classifyAll([
            marriage("m1919", year: 1890, spouseName: nil),
            marriage("m1941", year: 1896, spouseName: nil),
        ], subject: subject(deathFrom: 1950, deathTo: 1960))
        #expect(scored.allSatisfy { $0.verdict == .fact }, "precondition")
        let passed = RecordScorer.applyExclusivity(scored)
        #expect(passed.allSatisfy { $0.verdict == .lead })
    }

    @Test func corroboratedMarriagesBothKeepFact() {
        // WHK's specimen: two marriages, EACH identified via the known
        // spouse — remarriage is legitimate; corroborated facts coexist.
        let scored = classifyAll([
            marriage("m1896", year: 1896, spouseName: "EMMA GLADWIN"),
            marriage("m1909", year: 1909, spouseName: "EMMA GLADWIN"),
        ], subject: subject(familyContext: contextWithSpouse("EMMA GLADWIN"), deathFrom: 1943, deathTo: 1943))
        #expect(scored.allSatisfy { $0.verdict == .fact }, "precondition: both corroborated")
        let passed = RecordScorer.applyExclusivity(scored)
        #expect(passed.allSatisfy { $0.verdict == .fact })
    }

    @Test func loneUndiscriminatedMarriageIsUnrivalledAndKeeps() {
        let scored = classifyAll(
            [marriage("only", year: 1893, spouseName: nil)],
            subject: subject(deathFrom: 1950, deathTo: 1960))
        let passed = RecordScorer.applyExclusivity(scored)
        #expect(passed.first?.verdict == .fact)
    }

    // MARK: - Pass mechanics

    @Test func leadsAndImpossibleAreNeverTouchedAndPassIsIdempotent() {
        let child = HouseholdMember(name: "Florence", relationship: "Daughter", age: 2)
        let scored = classifyAll([
            birth("b1", year: 1869), birth("b2", year: 1870),
            census("c1", household: [child]),
        ], subject: subject(familyContext: contextWithChild("Florence")))
        let once = RecordScorer.applyExclusivity(scored)
        let twice = RecordScorer.applyExclusivity(once)
        #expect(verdicts(once) == verdicts(twice))              // idempotent
        #expect(verdicts(once)["c1"] == .fact)                  // lone census slot untouched
        // Demoted records keep their original gate history plus exclusivity.
        let demoted = once.first { $0.id == "b1" }
        #expect(demoted?.gates.contains { $0.gate == .name && $0.outcome == .pass } == true)
    }
}
