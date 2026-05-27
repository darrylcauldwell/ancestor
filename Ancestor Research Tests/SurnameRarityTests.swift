import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 7 — surname rarity registry + ConvergenceEngine demotion.
/// Mirrors Python `agent/rules.py:310` (`RARE_SURNAME_THRESHOLD = 1000`):
/// common-surname matches need more corroboration than rare-surname
/// matches because the signal-to-noise ratio is genuinely lower.
@MainActor
struct SurnameRarityTests {

    // MARK: - Registry classification

    @Test func registry_classifiesTopOnsAsCommon() {
        #expect(SurnameRarityRegistry.rarity(of: "Smith") == .common)
        #expect(SurnameRarityRegistry.rarity(of: "Jones") == .common)
        #expect(SurnameRarityRegistry.rarity(of: "Holmes") == .common)
    }

    @Test func registry_classifiesOffListAsUncommon() {
        // The user's tree centres on these — they should NOT be common.
        #expect(SurnameRarityRegistry.rarity(of: "Brooks") == .uncommon)
        #expect(SurnameRarityRegistry.rarity(of: "Land") == .uncommon)
        #expect(SurnameRarityRegistry.rarity(of: "Cauldwell") == .uncommon)
        #expect(SurnameRarityRegistry.rarity(of: "Wheeldon") == .uncommon)
    }

    @Test func registry_caseInsensitive() {
        #expect(SurnameRarityRegistry.rarity(of: "smith") == .common)
        #expect(SurnameRarityRegistry.rarity(of: "SMITH") == .common)
        #expect(SurnameRarityRegistry.rarity(of: "  Smith  ") == .common)
    }

    @Test func registry_emptyTreatedAsNeutral() {
        // Empty surname = no information; don't bias scoring.
        #expect(SurnameRarityRegistry.rarity(of: "") == .uncommon)
        #expect(SurnameRarityRegistry.rarity(of: "   ") == .uncommon)
    }

    // MARK: - Predominant rarity across records

    @Test func predominantRarity_singleSurname() {
        let rarity = SurnameRarityRegistry.predominantRarity(among: ["Cauldwell", "Cauldwell", "Cauldwell"])
        #expect(rarity == .uncommon)
    }

    @Test func predominantRarity_conservativeOnTie() {
        // 2 Smiths + 2 Cauldwells — tie. Conservative tie-break: classify
        // as common (the cautious choice).
        let rarity = SurnameRarityRegistry.predominantRarity(
            among: ["Smith", "Smith", "Cauldwell", "Cauldwell"]
        )
        #expect(rarity == .common, "conservative tie-break: treat as common when any tied surname is common")
    }

    @Test func predominantRarity_emptyDefaultUncommon() {
        #expect(SurnameRarityRegistry.predominantRarity(among: []) == .uncommon)
        #expect(SurnameRarityRegistry.predominantRarity(among: ["", "  "]) == .uncommon)
    }

    // MARK: - ConvergenceEngine demotion

    private func makeBirthRecord(id: String, sourceID: String, surname: String) -> SourceRecord {
        let common = RecordCommon(
            id: id, sourceID: sourceID, name: nil,
            surname: surname, givenName: "Test",
            detailURL: nil, rawFields: [:]
        )
        let birth = BirthRecord(
            common: common,
            birthYear: 1885, birthDate: nil, birthPlace: nil,
            quarter: nil, district: "Belper",
            volume: nil, page: nil, mothersMaidenName: nil
        )
        return .birth(birth)
    }

    private func makeSourceInfoMap(
        sources: [(id: String, lineage: SourceLineage, tier: SourceTrustTier, directness: EvidenceDirectness)]
    ) -> [String: SourceInfo] {
        Dictionary(uniqueKeysWithValues: sources.map { src in
            (src.id, SourceInfo(
                sourceID: src.id, lineage: src.lineage,
                trustTier: src.tier, directness: src.directness
            ))
        })
    }

    @Test func convergence_uncommonSurnameKeepsBaseLevel() {
        // 3 independent lineages on Cauldwell → .confirmed (no demotion).
        let records = [
            makeBirthRecord(id: "r1", sourceID: "freebmd", surname: "Cauldwell"),
            makeBirthRecord(id: "r2", sourceID: "freecen", surname: "Cauldwell"),
            makeBirthRecord(id: "r3", sourceID: "familysearch", surname: "Cauldwell"),
        ]
        let map = makeSourceInfoMap(sources: [
            ("freebmd", .independentTranscription(of: "GRO"), .transcription, .directTranscription),
            ("freecen", .independentTranscription(of: "Census"), .transcription, .directTranscription),
            ("familysearch", .communityEdited, .primary, .primary),
        ])
        let convergence = ConvergenceEngine.score(records: records, sourceInfoMap: map)
        #expect(convergence == .confirmed, "uncommon-surname 3-lineage = confirmed (no demotion)")
    }

    @Test func convergence_commonSurnameDemotesOneLevel() {
        // 3 independent lineages on Smith → would normally be .confirmed
        // but demotes to .probable because Smith is in the top-100.
        let records = [
            makeBirthRecord(id: "r1", sourceID: "freebmd", surname: "Smith"),
            makeBirthRecord(id: "r2", sourceID: "freecen", surname: "Smith"),
            makeBirthRecord(id: "r3", sourceID: "familysearch", surname: "Smith"),
        ]
        let map = makeSourceInfoMap(sources: [
            ("freebmd", .independentTranscription(of: "GRO"), .transcription, .directTranscription),
            ("freecen", .independentTranscription(of: "Census"), .transcription, .directTranscription),
            ("familysearch", .communityEdited, .primary, .primary),
        ])
        let convergence = ConvergenceEngine.score(records: records, sourceInfoMap: map)
        #expect(convergence == .probable, "common-surname 3-lineage demotes from .confirmed to .probable")
    }

    @Test func convergence_singleRecordUnaffectedByRarity() {
        // Single record returns .singleSource regardless of surname —
        // demotion floors at .singleSource.
        let records = [
            makeBirthRecord(id: "r1", sourceID: "freebmd", surname: "Smith"),
        ]
        let map = makeSourceInfoMap(sources: [
            ("freebmd", .independentTranscription(of: "GRO"), .transcription, .directTranscription),
        ])
        let convergence = ConvergenceEngine.score(records: records, sourceInfoMap: map)
        #expect(convergence == .singleSource)
    }

    @Test func convergence_emptyRecordsReturnsUncorroborated() {
        let convergence = ConvergenceEngine.score(records: [], sourceInfoMap: [:])
        #expect(convergence == .uncorroborated)
    }
}
