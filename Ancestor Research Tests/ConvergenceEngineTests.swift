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
            sourceID: "", sourceTier: .primary, recordType: nil, absDelta: 0, convergence: .singleSource
        )
        #expect(result.severity == .none)
    }

    @Test func transcriptionLargeDeltaIsConflict() {
        let result = DiscrepancySeverityTable.severity(
            sourceID: "", sourceTier: .transcription, recordType: nil, absDelta: 5, convergence: .singleSource
        )
        #expect(result.severity >= .conflict)
    }

    @Test func severityNeverDowngrades() {
        let base = DiscrepancySeverityTable.severity(
            sourceID: "", sourceTier: .community, recordType: nil, absDelta: 3, convergence: .singleSource
        )
        let upgraded = DiscrepancySeverityTable.severity(
            sourceID: "", sourceTier: .community, recordType: nil, absDelta: 3, convergence: .confirmed
        )
        #expect(upgraded.severity >= base.severity)
    }

    // MARK: - Per-source discrepancy tolerances (§10.3)

    @Test func cwgcAnyDisagreementIsCorrection() {
        // CWGC ±0 — a one-year gap is a correction, not the refinement the
        // old primary-tier band would have graded it.
        #expect(sev("cwgc", nil, 0) == DiscrepancySeverity.none)
        #expect(sev("cwgc", nil, 1) == .correction)
    }

    @Test func freeBMDBirthTolerancesTwoYearsThenConflicts() {
        #expect(sev("freebmd", .birth, 1) == DiscrepancySeverity.none)
        #expect(sev("freebmd", .birth, 2) == .refinement)  // edge of the ±2 quarter slip
        #expect(sev("freebmd", .birth, 3) == .conflict)
    }

    @Test func freeBMDDeathIsTighterThanBirth() {
        // Death is informant-reported (±1), so a 2-year gap already conflicts
        // where the same gap on a birth would only be a refinement.
        #expect(sev("freebmd", .death, 1) == .refinement)
        #expect(sev("freebmd", .death, 2) == .conflict)
    }

    @Test func freeCenAllowsThreeYears() {
        #expect(sev("freecen", .census, 2) == DiscrepancySeverity.none)
        #expect(sev("freecen", .census, 3) == .refinement)
        #expect(sev("freecen", .census, 4) == .conflict)
    }

    @Test func unknownSourceFallsBackToTierBand() {
        // A source without a §10.3 entry uses the trust-tier band unchanged.
        #expect(sev("freereg", .parish, 1, tier: .transcription) == DiscrepancySeverity.none)
        #expect(sev("freereg", .parish, 5, tier: .transcription) == .conflict)
    }

    private func sev(_ id: String, _ rt: RecordType?, _ delta: Int,
                     tier: SourceTrustTier = .primary) -> DiscrepancySeverity {
        DiscrepancySeverityTable.severity(
            sourceID: id, sourceTier: tier, recordType: rt,
            absDelta: delta, convergence: .singleSource).severity
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
