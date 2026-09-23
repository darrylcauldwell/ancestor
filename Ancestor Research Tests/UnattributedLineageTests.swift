import Testing
import Foundation
@testable import Ancestor_Research

/// A transcription whose original we cannot name must not be counted as an
/// independent lineage.
///
/// FamilySearch republishes 2,000+ collections. Before this, it declared
/// `.independentTranscription(of: "various")`, which is a distinct value from
/// FreeBMD's `"GRO-indexes"` — so one GRO index page, transcribed by both and
/// read back as two records, counted as two independent lineages. Two is the
/// auto-promote gate (`hypothesisVerdict` → `.stronglySupported`), so the same
/// original read twice could be accepted unattended as corroborated.
struct UnattributedLineageTests {

    @Test func familySearchPlusFreeBMDIsOneLineageNotTwo() {
        let sourcing = ConvergenceEngine.sourcingStrength(
            records: [freeBMDBirth(id: "a").record, familySearchBirth(id: "b").record],
            sourceInfoMap: infoMap
        )
        #expect(sourcing.sourceCount == 2, "both records are still present")
        #expect(sourcing.independentLineageCount == 1,
                "FamilySearch cannot be shown to transcribe a different original from FreeBMD")
        #expect(!sourcing.isCrossReferenced)
    }

    /// The harm, stated as behaviour: this pair must not clear the auto-promote gate.
    @Test func familySearchPlusFreeBMDDoesNotReachStronglySupported() {
        let cluster = LifeCluster(
            id: "c1",
            records: [freeBMDBirth(id: "a", verdict: .fact),
                      familySearchBirth(id: "b", verdict: .fact)],
            lifespanStart: 1900, lifespanEnd: 1980
        )
        let verdict = cluster.hypothesisVerdict(sourceInfoMap: infoMap)
        #expect(verdict != .stronglySupported,
                "one original transcribed twice is not two independent witnesses")
    }

    @Test func familySearchAloneContributesNoLineage() {
        let sourcing = ConvergenceEngine.sourcingStrength(
            records: [familySearchBirth(id: "a").record],
            sourceInfoMap: infoMap
        )
        #expect(sourcing.independentLineageCount == 0)
        #expect(!sourcing.isCrossReferenced)
    }

    /// Guard against over-correcting: genuinely distinct originals still count.
    @Test func freeBMDPlusCWGCRemainsTwoLineages() {
        let sourcing = ConvergenceEngine.sourcingStrength(
            records: [freeBMDBirth(id: "a").record, cwgcDeath(id: "b").record],
            sourceInfoMap: infoMap
        )
        #expect(sourcing.independentLineageCount == 2)
        #expect(sourcing.isCrossReferenced)
    }

    @Test func twoFreeBMDRecordsRemainOneLineage() {
        let sourcing = ConvergenceEngine.sourcingStrength(
            records: [freeBMDBirth(id: "a").record, freeBMDBirth(id: "b").record],
            sourceInfoMap: infoMap
        )
        #expect(sourcing.independentLineageCount == 1)
    }

    // MARK: - Fixtures

    private let infoMap: [String: SourceInfo] = [
        "freebmd": SourceInfo(sourceID: "freebmd",
                              lineage: .independentTranscription(of: "GRO-indexes"),
                              trustTier: .transcription,
                              directness: .directTranscription),
        "familysearch": SourceInfo(sourceID: "familysearch",
                                   lineage: .unattributedTranscription,
                                   trustTier: .transcription,
                                   directness: .directTranscription),
        "cwgc": SourceInfo(sourceID: "cwgc",
                           lineage: .primaryRecord,
                           trustTier: .primary,
                           directness: .primary),
    ]

    private func birth(id: String, sourceID: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: id, sourceID: sourceID,
                                 name: nil, surname: "CAULDWELL", givenName: "Ernest",
                                 detailURL: nil, rawFields: [:]),
            birthYear: 1887, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "BELPER",
            volume: "7b", page: "512", mothersMaidenName: "HOLMES"
        ))
    }

    private func freeBMDBirth(id: String, verdict: RecordVerdict = .fact) -> ScoredRecord {
        ScoredRecord(id: id, record: birth(id: id, sourceID: "freebmd"),
                     verdict: verdict, gates: [], summary: "")
    }

    private func familySearchBirth(id: String, verdict: RecordVerdict = .fact) -> ScoredRecord {
        ScoredRecord(id: id, record: birth(id: id, sourceID: "familysearch"),
                     verdict: verdict, gates: [], summary: "")
    }

    private func cwgcDeath(id: String, verdict: RecordVerdict = .fact) -> ScoredRecord {
        ScoredRecord(id: id, record: birth(id: id, sourceID: "cwgc"),
                     verdict: verdict, gates: [], summary: "")
    }
}
