import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_CONFIDENCE_SPEC.md Change 2 — wiring the
/// three confidence axes through `ConvergenceEngine`, `ParentInferenceEngine`,
/// and `LifeCluster`. No behaviour change observable from existing UI; the
/// new properties simply become available.
struct EvidenceConfidenceWiringTests {

    // MARK: - AC2.1 — sourcingStrength matches cluster record count

    @Test func ac2_1_sourcingCountEqualsClusterRecordCount() {
        let info = makeSourceInfoMap()
        let cluster = makeCluster(records: [
            makeFreeBMDRecord(id: "a", verdict: .fact),
            makeFreeBMDRecord(id: "b", verdict: .fact),
        ])
        let sourcing = ConvergenceEngine.sourcingStrength(for: cluster, sourceInfoMap: info)
        #expect(sourcing.sourceCount == cluster.records.count)
        #expect(sourcing.sourceCount == 2)
    }

    // MARK: - AC2.2 — independent-lineage count groups by SourceLineage

    @Test func ac2_2_twoFreeBMDRecordsAreOneLineage() {
        let info = makeSourceInfoMap()
        let cluster = makeCluster(records: [
            makeFreeBMDRecord(id: "a", verdict: .fact),
            makeFreeBMDRecord(id: "b", verdict: .fact),
        ])
        let sourcing = ConvergenceEngine.sourcingStrength(for: cluster, sourceInfoMap: info)
        #expect(sourcing.independentLineageCount == 1,
                "Two FreeBMD records share lineage; count must be 1")
        #expect(!sourcing.isCrossReferenced)
    }

    @Test func ac2_2_freeBMDPlusCWGCAreTwoLineages() {
        let info = makeSourceInfoMap()
        let cluster = makeCluster(records: [
            makeFreeBMDRecord(id: "a", verdict: .fact),
            makeCWGCRecord(id: "b", verdict: .fact),
        ])
        let sourcing = ConvergenceEngine.sourcingStrength(for: cluster, sourceInfoMap: info)
        #expect(sourcing.independentLineageCount == 2)
        #expect(sourcing.isCrossReferenced)
    }

    @Test func ac2_2_topTrustTierIsMaxAcrossSources() {
        let info = makeSourceInfoMap()
        let cluster = makeCluster(records: [
            makeFreeBMDRecord(id: "a", verdict: .fact),   // .transcription
            makeCWGCRecord(id: "b", verdict: .fact),      // .primary
        ])
        let sourcing = ConvergenceEngine.sourcingStrength(for: cluster, sourceInfoMap: info)
        #expect(sourcing.topTrustTier == .primary)
    }

    // MARK: - AC2.3 — parent-inference proposals carry InferenceDepth.steps == 1

    @Test func ac2_3_parentInferenceProposalIsDepthOne() {
        let info = makeSourceInfoMap()
        let birth = makeFreeBMDBirthRecord(
            id: "subject-birth",
            verdict: .fact,
            mothersMaidenName: "HOLMES"
        )
        let subject = ResearchSubject(
            profileID: "darryl",
            surname: "CAULDWELL",
            givenName: "Darryl",
            birthYearFrom: 1976, birthYearTo: 1976,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
        let proposals = ParentInferenceEngine.infer(
            from: [birth],
            subject: subject,
            existingParents: [],
            sourceInfoMap: info
        )
        #expect(proposals.count == 2, "expected mother + father proposals")
        for proposal in proposals {
            #expect(proposal.inferenceDepth.steps == 1,
                    "parent inference must be one derivational step")
            #expect(proposal.inferenceDepth.isInferred)
            #expect(!proposal.inferenceDepth.chain.isEmpty,
                    "chain should describe the provenance")
        }
    }

    // MARK: - AC2.4 — LifeCluster.matchQuality / evidenceConfidence aggregation

    @Test func ac2_4_clusterMatchQualityTakesStrongestAcrossMembers() {
        let info = makeSourceInfoMap()
        let cluster = makeCluster(records: [
            makeFreeBMDRecord(id: "a", verdict: .lead),
            makeFreeBMDRecord(id: "b", verdict: .fact),
            makeFreeBMDRecord(id: "c", verdict: .lead),
        ])
        #expect(cluster.matchQuality == .confirmed,
                "fact in the cluster should promote match to .confirmed")

        let conf = cluster.evidenceConfidence(sourceInfoMap: info)
        #expect(conf.matchQuality == .confirmed)
        #expect(conf.sourcing.sourceCount == 3)
        #expect(conf.inference == .direct, "cluster evidence is always direct")
    }

    @Test func ac2_4_clusterMatchQualityIsNilForEmptyCluster() {
        let empty = makeCluster(records: [])
        #expect(empty.matchQuality == nil)
    }

    // MARK: - AC2.5 — full suite stays green (covered by the broader test run)

    // MARK: - Helpers

    private func makeSourceInfoMap() -> [String: SourceInfo] {
        [
            "freebmd": SourceInfo(
                sourceID: "freebmd",
                lineage: .independentTranscription(of: "GRO-indexes"),
                trustTier: .transcription,
                directness: .directTranscription
            ),
            "cwgc": SourceInfo(
                sourceID: "cwgc",
                lineage: .primaryRecord,
                trustTier: .primary,
                directness: .primary
            ),
        ]
    }

    private func makeCluster(records: [ScoredRecord]) -> LifeCluster {
        LifeCluster(
            id: "cluster-x",
            records: records,
            
            lifespanStart: 1900,
            lifespanEnd: 1980
        )
    }

    private func makeFreeBMDRecord(id: String, verdict: RecordVerdict) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd",
            name: nil, surname: "CAULDWELL", givenName: "Darryl",
            detailURL: nil, rawFields: [:]
        )
        let record = SourceRecord.birth(BirthRecord(
            common: common,
            birthYear: 1976, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "BELPER",
            volume: "6", page: "129", mothersMaidenName: "HOLMES"
        ))
        return ScoredRecord(id: id, record: record, verdict: verdict, gates: [], summary: "")
    }

    private func makeFreeBMDBirthRecord(id: String, verdict: RecordVerdict, mothersMaidenName: String) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd",
            name: nil, surname: "CAULDWELL", givenName: "Darryl",
            detailURL: nil, rawFields: [:]
        )
        let record = SourceRecord.birth(BirthRecord(
            common: common,
            birthYear: 1976, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "BELPER",
            volume: "6", page: "129", mothersMaidenName: mothersMaidenName
        ))
        return ScoredRecord(id: id, record: record, verdict: verdict, gates: [], summary: "")
    }

    private func makeCWGCRecord(id: String, verdict: RecordVerdict) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "cwgc",
            name: nil, surname: "CAULDWELL", givenName: "Robert",
            detailURL: nil, rawFields: [:]
        )
        let record = SourceRecord.military(MilitaryRecord(
            common: common,
            rank: "Corporal", regiment: "West Yorkshire", unit: "1st Bn.",
            serviceNumber: "41876",
            dateOfDeath: nil, deathYear: 1918, age: 31,
            cemetery: "Lijssenthoek", graveRef: "XXVIII. G. 3A.",
            additionalInfo: nil
        ))
        return ScoredRecord(id: id, record: record, verdict: verdict, gates: [], summary: "")
    }
}
