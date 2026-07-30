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

/// DECISION_CORE_PAIR_SPEC Fix B — the geography gate derives the research
/// area from the SUBJECT's own places (not just tree home), walks the place
/// hierarchy when the district resolves, and never lets ABSENCE of geographic
/// knowledge veto a family-confirmed record.
struct DecisionCorePairGeographyTests {

    private func common(_ id: String, surname: String = "KEYWORTH", given: String = "WILLIAM") -> RecordCommon {
        RecordCommon(id: id, sourceID: "freebmd", name: nil,
                     surname: surname, givenName: given, detailURL: nil, rawFields: [:])
    }

    /// The Worksop specimen: a Nottinghamshire-born subject in a
    /// Derbyshire-home tree.
    private func nottsSubjectInDerbyshireTree() -> ResearchSubject {
        var s = ResearchSubject(
            surname: "KEYWORTH", givenName: "WILLIAM",
            birthYearFrom: 1873, birthYearTo: 1877,
            gender: .male, region: .county("Worksop, Nottinghamshire"), mode: .extend)
        s.homeChapmanCode = "DBY"
        return s
    }

    @Test func subjectsOwnCountyDistrictPassesDespiteForeignTreeHome() {
        // Worksop is NTT; tree home is DBY. Pre-fix: softFail "unknown
        // district: Worksop" → the subject's own home records demoted.
        let record = SourceRecord.birth(BirthRecord(
            common: common("worksop"), birthYear: 1875, birthDate: nil,
            birthPlace: nil, quarter: nil, district: "Worksop",
            volume: "7b", page: "23", mothersMaidenName: nil))
        let scored = RecordScorer.classify(
            record: record, subject: nottsSubjectInDerbyshireTree(), searchType: .birth)
        #expect(scored.gates.first { $0.gate == .geography }?.outcome == .pass)
        #expect(scored.verdict == .fact)
    }

    @Test func hierarchyResolvedDistrictInHomeCountyPasses() {
        // Chesterfield IS Derbyshire — the live WHK specimen soft-failed it
        // as "unknown district". The hierarchy walk settles it.
        var subject = ResearchSubject(
            surname: "KEYWORTH", givenName: "WILLIAM",
            birthYearFrom: 1873, birthYearTo: 1877,
            gender: .male, region: .county("Derbyshire"), mode: .extend)
        subject.homeChapmanCode = "DBY"
        let record = SourceRecord.birth(BirthRecord(
            common: common("chesterfield"), birthYear: 1875, birthDate: nil,
            birthPlace: nil, quarter: nil, district: "Chesterfield",
            volume: "7b", page: "600", mothersMaidenName: nil))
        let scored = RecordScorer.classify(record: record, subject: subject, searchType: .birth)
        #expect(scored.gates.first { $0.gate == .geography }?.outcome == .pass)
    }

    @Test func resolvedDistrictOutsideAcceptedCountiesStaysDemoted() {
        // Taunton resolves to Somerset — a real place that is genuinely NOT
        // in the subject's area must still demote (softFail → lead).
        var subject = ResearchSubject(
            surname: "KEYWORTH", givenName: "WILLIAM",
            birthYearFrom: 1873, birthYearTo: 1877,
            gender: .male, region: .county("Derbyshire"), mode: .extend)
        subject.homeChapmanCode = "DBY"
        let record = SourceRecord.birth(BirthRecord(
            common: common("taunton"), birthYear: 1875, birthDate: nil,
            birthPlace: nil, quarter: nil, district: "Taunton",
            volume: "5c", page: "1", mothersMaidenName: nil))
        let scored = RecordScorer.classify(record: record, subject: subject, searchType: .birth)
        #expect(scored.gates.first { $0.gate == .geography }?.outcome == .softFail)
        #expect(scored.verdict == .lead)
    }

    @Test func unknownDistrictWithFamilyConfirmationReachesFact() {
        // Absence of geographic knowledge must not veto a record the family
        // gate confirmed (Fix B.3) — the WHK-1909 shape.
        var subject = nottsSubjectInDerbyshireTree()
        subject.deathYearFrom = 1943
        subject.deathYearTo = 1943
        subject.familyContext = FamilyContext(
            spouseName: "EMMA GLADWIN", spouseSurname: nil, spouseGivenName: nil,
            spouseFatherSurname: nil, childNames: [],
            fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
            motherName: nil, motherSurname: nil, motherGivenName: nil)
        let record = SourceRecord.marriage(MarriageRecord(
            common: common("m1896"), marriageYear: 1896, marriageDate: nil,
            marriagePlace: nil, quarter: nil, district: "Xxfordshire Hundred",
            volume: "7b", page: "74", spouseName: "EMMA GLADWIN"))
        let scored = RecordScorer.classify(record: record, subject: subject, searchType: .marriage)
        #expect(scored.gates.first { $0.gate == .geography }?.reason.hasPrefix("unknown district") == true)
        #expect(scored.gates.first { $0.gate == .familyContext }?.outcome == .pass)
        #expect(scored.verdict == .fact)
    }

    @Test func unknownDistrictWithoutFamilyConfirmationStaysLead() {
        var subject = nottsSubjectInDerbyshireTree()
        let record = SourceRecord.birth(BirthRecord(
            common: common("mystery"), birthYear: 1875, birthDate: nil,
            birthPlace: nil, quarter: nil, district: "Xxfordshire Hundred",
            volume: "7b", page: "23", mothersMaidenName: nil))
        let scored = RecordScorer.classify(record: record, subject: subject, searchType: .birth)
        #expect(scored.verdict == .lead)
    }

    @Test func foreignRecordsStillFailUnchanged() {
        var subject = nottsSubjectInDerbyshireTree()
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(
                id: "us", sourceID: "familysearch", name: nil,
                surname: "KEYWORTH", givenName: "WILLIAM", detailURL: nil,
                rawFields: ["collection.title": "United States Census, 1920"]),
            birthYear: 1875, birthDate: nil, birthPlace: nil, quarter: nil,
            district: nil, volume: nil, page: nil, mothersMaidenName: nil))
        let scored = RecordScorer.classify(record: record, subject: subject, searchType: .birth)
        #expect(scored.verdict == .impossible)
    }
}

/// DECISION_CORE_PAIR_SPEC Fix A, cross-RUN extension — the live 2026-07-31
/// screenshot specimen: a re-run re-promoted the 1891 Ilkeston census as an
/// "unrivalled" fact because its Hayfield/Belper rivals were cache-suppressed
/// from the batch and sat in the store as yesterday's facts.
struct DecisionCorePairCrossRunTests {

    private func common(_ id: String) -> RecordCommon {
        RecordCommon(id: id, sourceID: "freecen", name: nil,
                     surname: "SHAW", givenName: "ELIZABETH", detailURL: nil, rawFields: [:])
    }

    private func censusFact(_ id: String) -> ScoredRecord {
        ScoredRecord(
            id: id,
            record: .census(CensusRecord(common: common(id), censusYear: 1891, age: 22,
                                         birthYear: 1869, district: "Belper")),
            verdict: .fact,
            gates: [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")],
            summary: "census 1891")
    }

    @Test func batchFactDemotesAgainstStoredRivals() {
        // Today's batch: one census fact (Ilkeston). Store: yesterday's two
        // rival 1891 census facts. All three must end up leads.
        let cross = RecordScorer.applyExclusivityAcrossStore(
            batch: [censusFact("ilkeston")],
            storedFacts: [censusFact("hayfield"), censusFact("belper")])
        #expect(cross.batch.first?.verdict == .lead)
        #expect(cross.batch.first?.gates.contains { $0.gate == .exclusivity } == true)
        #expect(cross.demotedStored.count == 2)
        #expect(cross.demotedStored.allSatisfy { $0.verdict == .lead })
    }

    @Test func storedOnlyRivalriesHealWithoutBatchInvolvement() {
        // A run that fetches nothing new for the slot still heals the
        // store's stale contradiction (incremental cleanup on every run).
        let cross = RecordScorer.applyExclusivityAcrossStore(
            batch: [],
            storedFacts: [censusFact("hayfield"), censusFact("belper")])
        #expect(cross.demotedStored.count == 2)
    }

    @Test func unrivalledBatchFactSurvivesWithBenignStore() {
        // Store holds only the same record (already saved by this run's
        // earlier iteration) — no phantom rivalry with itself.
        let cross = RecordScorer.applyExclusivityAcrossStore(
            batch: [censusFact("ilkeston")],
            storedFacts: [censusFact("ilkeston")])
        #expect(cross.batch.first?.verdict == .fact)
        #expect(cross.demotedStored.isEmpty)
    }

    @Test func storedLeadsNeverResurrectAndOrderIsPreserved() {
        var storedLead = censusFact("old-lead")
        storedLead = ScoredRecord(id: storedLead.id, record: storedLead.record,
                                  verdict: .lead, gates: storedLead.gates, summary: storedLead.summary)
        let batch = [censusFact("a"), censusFact("b")]
        let cross = RecordScorer.applyExclusivityAcrossStore(
            batch: batch, storedFacts: [storedLead])
        #expect(cross.batch.map(\.id) == ["a", "b"])          // order preserved
        #expect(cross.batch.allSatisfy { $0.verdict == .lead }) // in-batch rivalry
        #expect(cross.demotedStored.isEmpty)                   // leads never touched
    }
}

/// Registration-identity grouping — the live 2026-07-31 regression: the death
/// fact demoted against its own registration TWIN (same GRO vol/page as two
/// FreeBMD index rows). Twins are one candidate, never rivals.
struct DecisionCorePairRegistrationTwinTests {

    private func deathFact(_ id: String, vol: String = "7b", page: String = "920") -> ScoredRecord {
        ScoredRecord(
            id: id,
            record: .death(DeathRecord(
                common: RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                     surname: "KEYWORTH", givenName: "ELIZABETH",
                                     detailURL: nil, rawFields: [:]),
                deathYear: 1916, deathDate: nil, deathPlace: nil, age: 46,
                quarter: "Dec", district: "Bakewell", volume: vol, page: page)),
            verdict: .fact,
            gates: [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")],
            summary: "death 1916")
    }

    @Test func registrationTwinsAreOneCandidateAndKeepFact() {
        // Two index rows, one registration — the exact death-record shape
        // that wrongly demoted in live use.
        let passed = RecordScorer.applyExclusivity([
            deathFact("freebmd_death_7b_920_137442739"),
            deathFact("freebmd_death_7b_920_137435711"),
        ])
        #expect(passed.allSatisfy { $0.verdict == .fact })
        #expect(passed.allSatisfy { record in
            !record.gates.contains { $0.gate == .exclusivity }
        })
    }

    @Test func twinsPlusADistinctRegistrationStillRival() {
        // Two twins + one genuinely different registration = TWO candidates,
        // neither discriminated → all demote.
        let passed = RecordScorer.applyExclusivity([
            deathFact("twin1"), deathFact("twin2"),
            deathFact("rival", vol: "7b", page: "111"),
        ])
        #expect(passed.allSatisfy { $0.verdict == .lead })
    }

    @Test func crossRunTwinInStoreIsNoPhantomRival() {
        // Today's batch row vs the SAME registration stored under a different
        // index-row id from an earlier run — must stay fact.
        let cross = RecordScorer.applyExclusivityAcrossStore(
            batch: [deathFact("freebmd_death_7b_920_137442739")],
            storedFacts: [deathFact("freebmd_death_7b_920_137435711")])
        #expect(cross.batch.first?.verdict == .fact)
        #expect(cross.demotedStored.isEmpty)
    }

    @Test func recordsWithoutVolPageFallBackToRowIdentity() {
        // No vol/page (e.g. parish rows) → per-row candidates, prior
        // behaviour preserved.
        let a = ScoredRecord(
            id: "pa",
            record: .parish(ParishRecord(common: RecordCommon(
                id: "pa", sourceID: "freereg", name: nil, surname: "SHAW",
                givenName: "ELIZABETH", detailURL: nil, rawFields: [:]),
                eventType: "baptism", eventYear: 1869)),
            verdict: .fact, gates: [], summary: "baptism")
        let b = ScoredRecord(
            id: "pb",
            record: .parish(ParishRecord(common: RecordCommon(
                id: "pb", sourceID: "freereg", name: nil, surname: "SHAW",
                givenName: "ELIZABETH", detailURL: nil, rawFields: [:]),
                eventType: "baptism", eventYear: 1870)),
            verdict: .fact, gates: [], summary: "baptism")
        let passed = RecordScorer.applyExclusivity([a, b])
        #expect(passed.allSatisfy { $0.verdict == .lead })   // two distinct rites → rivalry
    }
}
