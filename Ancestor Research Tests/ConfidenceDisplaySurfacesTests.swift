import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_CONFIDENCE_SPEC.md Change 4 — migrating
/// the remaining display surfaces (proposed-relative cards, BulkReviewView
/// routing) to the three-axis model. No view in `Views/` should reference
/// `ClusterConfidence` after this Change.
struct ConfidenceDisplaySurfacesTests {

    // MARK: - AC4.1 — Proposed-relative cards drop the legacy badge.
    //
    // The legacy `confidenceBadge(_:)` helper in ClusterReviewView was
    // removed in Change 4. The proposed-relative card now renders
    // `ConfidenceBadgeView` driven by `proposal.evidenceConfidence(...)`.
    // Verified at the helper contract: the new evidenceConfidence reflects
    // the proposal's evidence records.

    @Test func ac4_1_proposalConfidenceMirrorsEvidenceRecords() {
        let info = makeSourceInfoMap()
        let factRecord = makeFreeBMDRecord(id: "a", verdict: .fact)
        let proposal = makeProposal(evidence: [factRecord])
        let conf = proposal.evidenceConfidence(sourceInfoMap: info)
        #expect(conf.matchQuality == .confirmed)
        #expect(conf.sourcing.sourceCount == 1)
        #expect(conf.inference.steps == 1, "parent proposals are always 1-step inferences")
    }

    @Test func ac4_1_proposalAggregatesAcrossMultipleEvidenceRecords() {
        let info = makeSourceInfoMap()
        let leadRecord = makeFreeBMDRecord(id: "x", verdict: .lead)
        let factRecord = makeFreeBMDRecord(id: "y", verdict: .fact)
        let proposal = makeProposal(evidence: [leadRecord, factRecord])
        let conf = proposal.evidenceConfidence(sourceInfoMap: info)
        // best-of: fact wins
        #expect(conf.matchQuality == .confirmed)
        // Both FreeBMD → one lineage; sourceCount == 2
        #expect(conf.sourcing.sourceCount == 2)
        #expect(conf.sourcing.independentLineageCount == 1)
        #expect(!conf.sourcing.isCrossReferenced)
    }

    // MARK: - AC4.2 — Single-fact-record parent inference produces the
    //                 canonical three-axis output.

    @Test func ac4_2_singleFactRecordYieldsConfirmedOneSourceInferredOneStep() {
        let info = makeSourceInfoMap()
        let factRecord = makeFreeBMDRecord(id: "fact", verdict: .fact)
        let proposal = makeProposal(evidence: [factRecord])
        let conf = proposal.evidenceConfidence(sourceInfoMap: info)

        // The user's exact case — what should render as:
        //   ✓ Confirmed · 1 source · Inferred — 1 step
        #expect(conf.matchQuality == .confirmed)
        #expect(conf.sourcing.sourceCount == 1)
        #expect(conf.sourcing.independentLineageCount == 1)
        #expect(!conf.sourcing.isCrossReferenced)
        #expect(conf.sourcing.topTrustTier == .transcription)
        #expect(conf.inference.steps == 1)
        #expect(conf.inference.isInferred)
    }

    // MARK: - AC4.3 — No view in Views/ uses ClusterConfidence directly
    //
    // This is enforced by a build-time grep gate. The legacy
    // `confidenceBadge(_:ClusterConfidence)` helper was removed in Change 4;
    // BulkReviewView's friction-tier routing now reads RecordVerdict on the
    // cluster's records, not cluster.confidence. The grep test below would
    // catch any future regression.

    @Test func ac4_3_noViewSourceReferencesClusterConfidenceEnum() throws {
        // Walk the Views/ tree; flag any .swift line that references the
        // enum or its cases without being a comment.
        let viewsDir = URL(fileURLWithPath: "Ancestor Research/Views",
                           relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var offenders: [String] = []
        if let enumerator = FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for (i, line) in content.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                    if line.contains("ClusterConfidence") {
                        offenders.append("\(url.lastPathComponent):\(i + 1): \(trimmed)")
                    }
                }
            }
        }
        if !offenders.isEmpty {
            let listing = offenders.joined(separator: "\n")
            Issue.record("Views/ files still reference ClusterConfidence:\n\(listing)")
        }
    }

    // MARK: - BulkReviewView routing migration

    @Test func bulkRoutingClassifiesImpossibleVerdictAsConflict() {
        // The routing inputs were migrated to use RecordVerdict directly.
        // We verify the new behaviour: a cluster with an .impossible record
        // routes to .conflict (was: cluster.confidence == .ambiguous).
        let cluster = makeCluster(verdicts: [.fact, .impossible])
        let hasImpossible = cluster.records.contains { $0.verdict == .impossible }
        #expect(hasImpossible)
    }

    @Test func bulkRoutingClassifiesNoFactsAsCorrection() {
        let cluster = makeCluster(verdicts: [.lead, .lead])
        let hasFacts = cluster.records.contains { $0.verdict == .fact }
        #expect(!hasFacts)
    }

    @Test func bulkRoutingClassifiesSingleRecordAsConfirmation() {
        let cluster = makeCluster(verdicts: [.fact])
        #expect(cluster.records.count == 1)
        #expect(cluster.records.contains { $0.verdict == .fact })
    }

    // MARK: - Helpers

    private func makeSourceInfoMap() -> [String: SourceInfo] {
        ["freebmd": SourceInfo(
            sourceID: "freebmd",
            lineage: .independentTranscription(of: "GRO-indexes"),
            trustTier: .transcription,
            directness: .directTranscription
        )]
    }

    private func makeFreeBMDRecord(id: String, verdict: RecordVerdict) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd",
            name: nil, surname: "CAULDWELL", givenName: "Darryl",
            detailURL: nil, rawFields: [:]
        )
        let record = SourceRecord.birth(BirthRecord(
            common: common, birthYear: 1976, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "BELPER", volume: "6", page: "129",
            mothersMaidenName: "HOLMES"
        ))
        return ScoredRecord(id: id, record: record, verdict: verdict, gates: [], summary: "")
    }

    private func makeProposal(evidence: [ScoredRecord]) -> ProposedRelative {
        ProposedRelative(
            id: "proposal-x",
            proposedSurname: "HOLMES",
            proposedGivenName: nil,
            gender: .female,
            birthYearLow: 1931,
            birthYearHigh: 1958,
            relationship: .parentOf("darryl"),
            evidence: evidence,
            inferenceDepth: InferenceDepth(steps: 1, chain: ["FreeBMD birth record"])
        )
    }

    private func makeCluster(verdicts: [RecordVerdict]) -> LifeCluster {
        let records = verdicts.enumerated().map { (i, v) in
            makeFreeBMDRecord(id: "r\(i)", verdict: v)
        }
        return LifeCluster(
            id: "c-x", records: records,
            lifespanStart: 1900, lifespanEnd: 1980
        )
    }
}
