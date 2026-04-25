import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for ConvergenceEngine, DiscrepancySeverityTable, and CitationRenderer.
struct ConvergenceEngineTests {

    private let freebmdInfo = SourceInfo(
        sourceID: "freebmd", lineage: .independentTranscription(of: "GRO-indexes"),
        trustTier: .transcription, directness: .directTranscription
    )
    private let findagraveInfo = SourceInfo(
        sourceID: "findagrave", lineage: .communityEdited,
        trustTier: .community, directness: .derivative
    )
    private let cwgcInfo = SourceInfo(
        sourceID: "cwgc", lineage: .primaryRecord,
        trustTier: .primary, directness: .primary
    )

    private func makeRecord(id: String, sourceID: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: id, sourceID: sourceID, name: nil,
                surname: "TEST", givenName: "PERSON", detailURL: nil, rawFields: [:]),
            birthYear: 1834, birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        ))
    }

    // MARK: - Convergence

    @Test func singleRecordIsSingleSource() {
        let records = [makeRecord(id: "1", sourceID: "freebmd")]
        let result = ConvergenceEngine.score(records: records, sourceInfoMap: ["freebmd": freebmdInfo])
        #expect(result == .singleSource)
    }

    @Test func twoIndependentLineagesIsPossible() {
        let records = [
            makeRecord(id: "1", sourceID: "freebmd"),
            makeRecord(id: "2", sourceID: "findagrave"),
        ]
        let map = ["freebmd": freebmdInfo, "findagrave": findagraveInfo]
        let result = ConvergenceEngine.score(records: records, sourceInfoMap: map)
        #expect(result >= .possible)
    }

    @Test func threeIndependentLineagesIsConfirmed() {
        let records = [
            makeRecord(id: "1", sourceID: "freebmd"),
            makeRecord(id: "2", sourceID: "findagrave"),
            makeRecord(id: "3", sourceID: "cwgc"),
        ]
        let map = ["freebmd": freebmdInfo, "findagrave": findagraveInfo, "cwgc": cwgcInfo]
        let result = ConvergenceEngine.score(records: records, sourceInfoMap: map)
        #expect(result == .confirmed)
    }

    @Test func derivativeOnlyCappedAtPossible() {
        let records = [
            makeRecord(id: "1", sourceID: "findagrave"),
            makeRecord(id: "2", sourceID: "findagrave"),
        ]
        let map = ["findagrave": findagraveInfo]
        let result = ConvergenceEngine.score(records: records, sourceInfoMap: map)
        #expect(result <= .possible)
    }

    // MARK: - Discrepancy Severity

    @Test func primarySourceZeroDeltaIsNone() {
        let result = DiscrepancySeverityTable.severity(
            sourceTier: .primary, absDelta: 0, convergence: .singleSource
        )
        #expect(result.severity == .none)
    }

    @Test func transcriptionLargeDeltaIsConflict() {
        let result = DiscrepancySeverityTable.severity(
            sourceTier: .transcription, absDelta: 5, convergence: .singleSource
        )
        #expect(result.severity >= .conflict)
    }

    @Test func severityNeverDowngrades() {
        let base = DiscrepancySeverityTable.severity(
            sourceTier: .community, absDelta: 3, convergence: .singleSource
        )
        let upgraded = DiscrepancySeverityTable.severity(
            sourceTier: .community, absDelta: 3, convergence: .confirmed
        )
        #expect(upgraded.severity >= base.severity)
    }

    // MARK: - Citation Renderer

    @Test func birthRecordProducesCitation() {
        let record = makeRecord(id: "test", sourceID: "freebmd")
        let citation = CitationRenderer.cite(record)
        #expect(!citation.full.isEmpty)
        #expect(!citation.short.isEmpty)
        #expect(citation.sourceID == "freebmd")
    }

    // MARK: - Name Equivalence

    @Test func learnedEquivalenceIsUsedInScoring() {
        ScoringRules.addLearnedEquivalence("ROBERT", "BOB")
        let score = ScoringRules.nameSimilarity("ROBERT", "BOB")
        #expect(score >= 0.7)
        // Clean up
        ScoringRules.learnedEquivalences.removeAll()
    }
}
