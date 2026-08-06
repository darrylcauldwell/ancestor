import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// `ResearchResult.replacingRecord` — the in-memory swap behind the review's
/// "Load household from FreeCen" refresh (owner report 2026-08-06: the fetch
/// enriched the DB but the review card, which renders `currentResult`, never
/// showed the roster — the button seemed to do nothing).
struct ResearchResultReplacingRecordTests {

    private func censusRecord(id: String, household: [HouseholdMember]? = nil) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen",
                                 name: "George R WARD", surname: "WARD", givenName: "George R",
                                 detailURL: "https://freecen.example/\(id)", rawFields: [:]),
            censusYear: 1861, birthYear: 1852, household: household))
    }

    private func scored(_ record: SourceRecord, verdict: RecordVerdict = .fact) -> ScoredRecord {
        ScoredRecord(id: record.id, record: record, verdict: verdict, gates: [], summary: "s")
    }

    @Test func swapsRecordEverywhereKeepingVerdictAndGates() {
        let thin = censusRecord(id: "c1")
        let other = censusRecord(id: "c2")
        let cluster = LifeCluster(id: "cl", records: [scored(thin), scored(other)],
                                  lifespanStart: 1852, lifespanEnd: 1920, mergeCandidate: nil)
        let result = ResearchResult(
            confirmedFacts: [scored(thin)], leads: [scored(other, verdict: .lead)],
            allScoredRecords: [scored(thin), scored(other, verdict: .lead)],
            clusters: [cluster], discrepancies: [], householdMembers: [], searchHistory: [])

        let roster = [HouseholdMember(name: "George R WARD", relationship: "Son", age: 9, isTarget: true)]
        let enriched = censusRecord(id: "c1", household: roster)
        let updated = result.replacingRecord(enriched)

        // Swapped in the cluster — the household is now visible.
        guard case .census(let c)? = updated.clusters.first?.records.first?.record else {
            Issue.record("expected census record"); return
        }
        #expect(c.household?.count == 1)
        // Verdict/summary survive the swap.
        #expect(updated.clusters.first?.records.first?.verdict == .fact)
        #expect(updated.confirmedFacts.first.map { r -> Bool in
            if case .census(let cc) = r.record { return cc.household?.isEmpty == false }
            return false
        } == true)
        // The OTHER record is untouched.
        guard case .census(let o)? = updated.clusters.first?.records.last?.record else {
            Issue.record("expected census record"); return
        }
        #expect(o.household == nil)
        #expect(updated.leads.first?.verdict == .lead)
    }
}
