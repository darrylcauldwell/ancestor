import Testing
import Foundation
@testable import Ancestor_Research

/// Rejection-memory fix — a record the user has DISCARDED must not re-cluster
/// on a later research run (the "namesakes keep coming back" gap: George Herbert
/// Brooks's "George Brooks, Mar 1884" twin reappeared every run). The main pass
/// now filters cluster input through the rejection memory it already loads,
/// mirroring the §5.15.6 hunch-path rule.
@MainActor
struct ClusterInputRejectionTests {

    private func birth(_ id: String) -> ScoredRecord {
        let common = RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                  surname: "BROOKS", givenName: "GEORGE",
                                  detailURL: nil, rawFields: [:])
        let record = SourceRecord.birth(BirthRecord(
            common: common, birthYear: 1884, birthDate: nil, birthPlace: "Belper",
            quarter: "Mar", district: "Belper", volume: "7a", page: "602",
            mothersMaidenName: nil))
        return ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    @Test func discardedRecordIsExcludedFromClustering() {
        let keep = birth("keep")
        let enrichment = birth("enrichment")
        let discarded = birth("george_brooks_mar_1884")   // the namesake the user discarded
        let input = ResearchPipeline.clusterInput(
            from: [keep, enrichment, discarded],
            enrichmentIDs: ["enrichment"],
            rejectedIDs: ["george_brooks_mar_1884"])
        // Only the un-discarded, non-enrichment record reaches clustering — so
        // the discarded namesake cannot re-appear in the review.
        #expect(input.map(\.id) == ["keep"])
    }

    @Test func noRejectionsKeepsEveryNonEnrichmentRecord() {
        let a = birth("a"), b = birth("b")
        let input = ResearchPipeline.clusterInput(
            from: [a, b], enrichmentIDs: [], rejectedIDs: [])
        #expect(Set(input.map(\.id)) == ["a", "b"])
    }
}
