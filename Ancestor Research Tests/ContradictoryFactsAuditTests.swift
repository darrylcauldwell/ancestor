import Testing
import Foundation
@testable import Ancestor_Research

// DECISION_CORE_PAIR_SPEC follow-up — the tree-wide static twin of the
// run-time exclusivity pass. The audit must agree EXACTLY with what a
// re-research run would do to the store: same slots, same registration-twin
// candidates, same discriminator, same ghost rivals.
struct ContradictoryFactsAuditTests {

    private func evidenceRow(
        _ recordID: String, record: SourceRecord, verdict: RecordVerdict,
        userStatus: UserReviewStatus = .unreviewed,
        gates: [GateResult] = [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")],
        citation: String? = nil
    ) -> EvidenceRecord {
        EvidenceRecord(
            id: "@P1@|\(recordID)", profileID: "@P1@", sourceID: "freebmd",
            sourceRecordID: recordID, recordType: record.recordType,
            verdict: verdict, record: record,
            citationFull: citation, citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: userStatus,
            gates: gates, summary: "test row")
    }

    private func probate(_ id: String, year: Int) -> SourceRecord {
        .probate(ProbateRecord(
            common: RecordCommon(id: id, sourceID: "probate", name: nil,
                                 surname: "MARSHALL", givenName: "HARRY",
                                 detailURL: nil, rawFields: [:]),
            deathYear: year, probateDate: "\(year)", address: "Derbyshire"))
    }

    private func census(_ id: String, year: Int = 1891) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", name: nil,
                                 surname: "SHAW", givenName: "ELIZABETH",
                                 detailURL: nil, rawFields: [:]),
            censusYear: year, age: 22, birthYear: 1869, district: "Belper"))
    }

    private func death(_ id: String, vol: String = "7b", page: String = "920") -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                 surname: "KEYWORTH", givenName: "ELIZABETH",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1916, deathDate: nil, deathPlace: nil, age: 46,
            quarter: "Dec", district: "Bakewell", volume: vol, page: page))
    }

    @Test func harryMarshallNamesakeProbatesAreFlagged() {
        // The founding specimen: two namesake probates both stored as fact.
        let evidence = [
            evidenceRow("probate_1999", record: probate("probate_1999", year: 1999), verdict: .fact),
            evidenceRow("probate_2006", record: probate("probate_2006", year: 2006), verdict: .fact),
        ]
        let demoted = ContradictoryFactsAudit.demotions(in: evidence)
        #expect(demoted.count == 2)
        #expect(demoted.allSatisfy { $0.verdict == .lead })
        let finding = ContradictoryFactsAudit.finding(
            profileID: "@P1@", profileName: "Harry Marshall", evidence: evidence)
        #expect(finding?.demotions.count == 2)
        #expect(finding?.slotSummary == "probate ×2")
    }

    @Test func consistentStoreProducesNoFinding() {
        // Elizabeth's verified end-state shape: one death (as twins) + one
        // corroborated marriage — internally consistent, nothing to flag.
        let marriageGates = [
            GateResult(gate: .name, outcome: .pass, reason: "surname=1.00"),
            GateResult(gate: .familyContext, outcome: .pass, reason: "KEYWORTH matches"),
        ]
        let marriage = SourceRecord.marriage(MarriageRecord(
            common: RecordCommon(id: "m1", sourceID: "freebmd", name: nil,
                                 surname: "WALLACE", givenName: "ELIZABETH",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: 1909, marriageDate: nil, marriagePlace: nil,
            quarter: nil, district: "Chesterfield", volume: "7b", page: "1518",
            spouseName: "KEYWORTH"))
        let evidence = [
            evidenceRow("death_a", record: death("death_a"), verdict: .fact),
            evidenceRow("death_b", record: death("death_b"), verdict: .fact),   // registration twin
            evidenceRow("m1", record: marriage, verdict: .fact, gates: marriageGates),
        ]
        #expect(ContradictoryFactsAudit.demotions(in: evidence).isEmpty)
        #expect(ContradictoryFactsAudit.finding(
            profileID: "@P1@", profileName: "Elizabeth", evidence: evidence) == nil)
    }

    @Test func discardedFactsNeitherRivalNorDemote() {
        // A human's "not them" on one probate resolves the contest — the
        // survivor stands unrivalled.
        let evidence = [
            evidenceRow("probate_1999", record: probate("probate_1999", year: 1999), verdict: .fact),
            evidenceRow("probate_2006", record: probate("probate_2006", year: 2006), verdict: .fact,
                        userStatus: .discarded),
        ]
        #expect(ContradictoryFactsAudit.demotions(in: evidence).isEmpty)
    }

    @Test func loneFactInGhostContestedSlotIsFlagged() {
        // Flip-flop legacy state: a census fact sits in a slot whose rivals
        // were exclusivity-demoted in an earlier run.
        let ghostGates = [
            GateResult(gate: .name, outcome: .pass, reason: "surname=1.00"),
            GateResult(gate: .exclusivity, outcome: .softFail, reason: "3 competing census-1891 candidates"),
        ]
        let evidence = [
            evidenceRow("census_eastwood", record: census("census_eastwood"), verdict: .fact),
            evidenceRow("census_hayfield", record: census("census_hayfield"), verdict: .lead, gates: ghostGates),
            evidenceRow("census_belper", record: census("census_belper"), verdict: .lead, gates: ghostGates),
        ]
        let demoted = ContradictoryFactsAudit.demotions(in: evidence)
        #expect(demoted.map(\.id) == ["census_eastwood"])
    }

    @Test func naturalLeadsDoNotContestTheSlot() {
        // Leads that failed gates on their own merits (no exclusivity marker)
        // prove nothing — the lone fact stands.
        let evidence = [
            evidenceRow("census_eastwood", record: census("census_eastwood"), verdict: .fact),
            evidenceRow("census_weak", record: census("census_weak"), verdict: .lead),
        ]
        #expect(ContradictoryFactsAudit.demotions(in: evidence).isEmpty)
    }

    @Test func findingCarriesCitationAndReason() {
        let evidence = [
            evidenceRow("probate_1999", record: probate("probate_1999", year: 1999), verdict: .fact,
                        citation: "Probate 1999, Harry Marshall"),
            evidenceRow("probate_2006", record: probate("probate_2006", year: 2006), verdict: .fact,
                        citation: "Probate 2006, Harry Marshall"),
        ]
        let finding = ContradictoryFactsAudit.finding(
            profileID: "@P1@", profileName: "Harry Marshall", evidence: evidence)
        let row = finding?.demotions.first { $0.sourceRecordID == "probate_1999" }
        #expect(row?.detail == "Probate 1999, Harry Marshall")
        #expect(row?.reason.contains("competing") == true)
        #expect(row?.slotLabel == "probate")
    }
}
