import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// CAMPAIGN_REVIEW_SPEC Changes 2+3 — the evidence chain is PERSISTED, not
/// recomputed-only. Change 2: evidence_records carries the full scorer
/// output (gates_json, summary, is_enrichment, last_run_id) so a DB
/// reconstruction yields complete ScoredRecords. Change 3:
/// evidence_convergence stores the per-fact-value ConvergenceLevel +
/// SourcingStrength, upserted at every run-persist — the level rises as
/// independent lineages accumulate (Darryl: "further research finds same
/// fact in a different source — is the bigger evidence chain recorded?").
struct EvidenceChainPersistenceTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func deathRecord(id: String, sourceID: String, year: Int = 1986,
                             district: String? = "Belper") -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(
                id: id, sourceID: sourceID,
                name: "George Keyworth", surname: "Keyworth", givenName: "George",
                detailURL: nil, rawFields: [:]
            ),
            deathYear: year, deathDate: String(year), deathPlace: "Derbyshire",
            age: nil, quarter: "Q1", district: district, volume: "7b", page: "12",
            spouseSurname: nil
        ))
    }

    private func scored(_ record: SourceRecord, verdict: RecordVerdict = .fact) -> ScoredRecord {
        ScoredRecord(
            id: record.id, record: record, verdict: verdict,
            gates: [
                GateResult(gate: .name, outcome: .pass, reason: "surname=1.00, given=1.00"),
                GateResult(gate: .date, outcome: .pass, reason: "age at death plausible"),
                GateResult(gate: .geography, outcome: .softFail, reason: "county-level only"),
            ],
            summary: "George Keyworth, \(record.id)"
        )
    }

    // MARK: - Change 2: full scorer output round-trips

    @Test func gatesSummaryEnrichmentAndRunIDRoundTrip() throws {
        let db = try makeTempDB()
        let rec = scored(deathRecord(id: "fb_d_1", sourceID: "freebmd"))
        try db.saveEvidence(profileID: "@P@", scored: rec,
                            citationFull: "cite", citationURL: "https://x",
                            isEnrichment: true, runID: "RUN-1")
        let loaded = try db.loadEvidenceForProfile("@P@")
        #expect(loaded.count == 1)
        let row = try #require(loaded.first)
        #expect(row.gates.count == 3)
        #expect(row.gates.first?.gate == .name)
        #expect(row.gates.first?.outcome == .pass)
        #expect(row.gates.last?.outcome == .softFail)
        #expect(row.summary == "George Keyworth, fb_d_1")
        #expect(row.isEnrichment == true)
        #expect(row.lastRunID == "RUN-1")
        // The reconstruction shape is a COMPLETE ScoredRecord.
        let rebuilt = row.asScoredRecord
        #expect(rebuilt.verdict == .fact)
        #expect(rebuilt.gates.count == 3)
        #expect(rebuilt.summary == rec.summary)
    }

    @Test func legacyRowsWithoutGatesDecodeLeniently() throws {
        let db = try makeTempDB()
        let rec = scored(deathRecord(id: "fb_d_2", sourceID: "freebmd"))
        try db.saveEvidence(profileID: "@P@", scored: rec, citationFull: nil, citationURL: nil)
        // Simulate a pre-v44 row: null the new columns directly.
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                UPDATE evidence_records SET gates_json = NULL, summary = NULL
                WHERE profile_id = '@P@'
                """)
        }
        let row = try #require(try db.loadEvidenceForProfile("@P@").first)
        #expect(row.gates.isEmpty, "legacy rows load as gate-less, not dropped")
        #expect(row.summary == "")
        #expect(row.isEnrichment == false)
    }

    @Test func reSaveOverwritesScorerColumnsButPreservesUserStatus() throws {
        let db = try makeTempDB()
        let rec = scored(deathRecord(id: "fb_d_3", sourceID: "freebmd"))
        try db.saveEvidence(profileID: "@P@", scored: rec, citationFull: nil, citationURL: nil,
                            isEnrichment: false, runID: "RUN-A")
        try db.updateEvidenceUserStatus(
            profileID: "@P@", sourceRecordIDs: ["fb_d_3"], status: .discarded)
        // Second run re-scores the same record.
        try db.saveEvidence(profileID: "@P@", scored: rec, citationFull: nil, citationURL: nil,
                            isEnrichment: true, runID: "RUN-B")
        let row = try #require(try db.loadEvidenceForProfile("@P@").first)
        #expect(row.lastRunID == "RUN-B", "scorer columns follow the latest run")
        #expect(row.isEnrichment == true)
        #expect(row.userStatus == .discarded, "user decision survives re-runs")
    }

    // MARK: - Change 3: convergence persists and upgrades

    private func sourceInfo() -> [String: SourceInfo] {
        [
            "freebmd": SourceInfo(sourceID: "freebmd",
                                  lineage: .independentTranscription(of: "GRO indexes"),
                                  trustTier: .transcription, directness: .directTranscription),
            "wirksworth": SourceInfo(sourceID: "wirksworth",
                                     lineage: .independentTranscription(of: "Wirksworth parish registers"),
                                     trustTier: .transcription, directness: .directTranscription),
            "cwgc": SourceInfo(sourceID: "cwgc", lineage: .primaryRecord,
                               trustTier: .primary, directness: .primary),
        ]
    }

    @Test func convergencePersistsAndUpgradesAsLineagesAccumulate() throws {
        let db = try makeTempDB()
        let map = sourceInfo()

        // Run 1: one source, one lineage → singleSource.
        let first = [deathRecord(id: "fb_d_10", sourceID: "freebmd")]
        try db.upsertEvidenceConvergence(
            profileID: "@P@",
            groups: ConvergenceEngine.scoreValueGroups(records: first, sourceInfoMap: map)
        )
        var rows = try db.loadEvidenceConvergence(profileID: "@P@")
        #expect(rows.count == 1)
        #expect(rows.first?.valueKey == "death:1986")
        #expect(rows.first?.level == .singleSource)
        #expect(rows.first?.sourcing.independentLineageCount == 1)

        // Run 2: same fact value corroborated by two MORE independent
        // lineages — the persisted chain upgrades in place.
        let corroborated = first + [
            deathRecord(id: "wk_d_10", sourceID: "wirksworth", district: nil),
            deathRecord(id: "cw_d_10", sourceID: "cwgc", district: nil),
        ]
        try db.upsertEvidenceConvergence(
            profileID: "@P@",
            groups: ConvergenceEngine.scoreValueGroups(records: corroborated, sourceInfoMap: map)
        )
        rows = try db.loadEvidenceConvergence(profileID: "@P@")
        #expect(rows.count == 1, "same value key upserts in place")
        let row = try #require(rows.first)
        #expect(row.level > .singleSource,
                "three independent lineages must outrank one; got \(row.level)")
        #expect(row.sourcing.independentLineageCount == 3)
        #expect(row.recordIDs.count == 3)
    }

    @Test func contradictingValuesGetSeparateChains() throws {
        // DS-24: a 1986 death and a 1992 death are DIFFERENT asserted values
        // — they must not pool into one inflated chain.
        let db = try makeTempDB()
        let map = sourceInfo()
        let records = [
            deathRecord(id: "fb_d_20", sourceID: "freebmd", year: 1986),
            deathRecord(id: "wk_d_21", sourceID: "wirksworth", year: 1992, district: nil),
        ]
        try db.upsertEvidenceConvergence(
            profileID: "@P@",
            groups: ConvergenceEngine.scoreValueGroups(records: records, sourceInfoMap: map)
        )
        let rows = try db.loadEvidenceConvergence(profileID: "@P@")
        #expect(Set(rows.map(\.valueKey)) == ["death:1986", "death:1992"])
        #expect(rows.allSatisfy { $0.level == .singleSource })
    }
}
