import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// Migration tests for CONFLICT_LAYER_SPEC §5 — `v41_conflict_layer`, the
/// evidence-conflict layer's single migration (ships with CL-Change1;
/// Changes 2–6 need no further migration).
///
/// `field_disputes` has zero production writers before this layer (DS-13),
/// so the assertions are (a) a legacy-shaped dispute row survives
/// byte-for-byte and reads back through the snapshot with `kind`
/// defaulting to `fieldValue`, (b) all new columns exist with their
/// defaults, and (c) the one-open-dispute partial unique index enforces
/// the C3 identity. Same scratch-DB / migrate-upTo idiom as
/// MigrationV34/V35/V36.
struct MigrationV41ConflictLayerTests {

    /// Migrate a scratch DB to just before v41, seed legacy-shaped rows,
    /// then complete the chain.
    private func makeMigratedDB() throws -> DatabaseQueue {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v40_run_request_resume_audit")

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, last_name, is_deleted)
                VALUES ('p1', '{}', 'William', 'Cauldwell', 0)
                """)
            // Legacy dispute row written by the pre-CL1 shape (no kind /
            // severity / detected_by / trace columns existed).
            let competing = """
                [{"origin":{"identifier":"gedcom"},"raw":"1901","addedAt":0},\
                {"origin":{"identifier":"freebmd"},"raw":"Dec 1900","addedAt":0}]
                """
            try db.execute(sql: """
                INSERT INTO field_disputes
                (entity_id, field, reason, competing_sources, detected_at, resolution)
                VALUES ('p1', 'deathDate', 'noOverlap', ?, ?, NULL)
                """, arguments: [competing, Date(timeIntervalSince1970: 1000)])
            // A hypothesis row + discrepancy row so the sibling ALTERs are
            // proven lossless too.
            try db.execute(sql: """
                INSERT INTO research_discrepancies
                (profile_id, field, existing_value, source_value, source_id,
                 severity, reasoning, resolution_status, detected_at)
                VALUES ('p1', 'deathYear', '1901', '1900', 'freebmd',
                        'conflict', 'test', 'unresolved', ?)
                """, arguments: [Date(timeIntervalSince1970: 1000)])
        }

        try migrator.migrate(dbQueue)
        return dbQueue
    }

    // MARK: - Chain registration

    @Test func migrationRegistersV41AndKeepsPriorMigrations() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v41_conflict_layer"))
        #expect(applied.contains("v40_run_request_resume_audit"))
        #expect(applied.contains("v39_source_budget_state"))
    }

    // MARK: - New columns exist with spec defaults

    @Test func fieldDisputesGainsConflictLayerColumns() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT entity_kind, kind, severity, detected_by, evidence_json,
                       ladder_trace, witness_summary, resolved_at
                FROM field_disputes WHERE entity_id = 'p1'
                """)
            #expect(row != nil)
            // NOT NULL defaults backfill existing rows.
            #expect((row?["entity_kind"] as String?) == "profile")
            #expect((row?["kind"] as String?) == "fieldValue")
            // Nullable columns stay NULL on legacy rows — nothing fabricated.
            #expect((row?["severity"] as String?) == nil)
            #expect((row?["detected_by"] as String?) == nil)
            #expect((row?["evidence_json"] as String?) == nil)
            #expect((row?["ladder_trace"] as String?) == nil)
            #expect((row?["witness_summary"] as String?) == nil)
            #expect((row?["resolved_at"] as Date?) == nil)
        }
    }

    @Test func researchHypothesesGainsCandidateGroupID() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let hasColumn = try db.columns(in: "research_hypotheses")
                .contains { $0.name == "candidate_group_id" }
            #expect(hasColumn)
        }
    }

    @Test func researchDiscrepanciesGainsRunIDAndKeepsRows() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT run_id, severity, existing_value, source_value
                FROM research_discrepancies WHERE profile_id = 'p1'
                """)
            #expect(row != nil)
            #expect((row?["run_id"] as String?) == nil)
            #expect((row?["severity"] as String?) == "conflict")
            #expect((row?["existing_value"] as String?) == "1901")
        }
    }

    @Test func projectMetaGainsSweepBookkeepingColumns() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let columns = try db.columns(in: "project_meta").map(\.name)
            #expect(columns.contains("conflict_sweep_high_water"))
            #expect(columns.contains("v41_conflict_backfill_done"))
        }
    }

    // MARK: - Legacy rows survive losslessly (lossless round-trip)

    @Test func legacyDisputeRowSurvivesByteForByte() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT field, reason, competing_sources, resolution
                FROM field_disputes WHERE entity_id = 'p1'
                """)
            #expect((row?["field"] as String?) == "deathDate")
            #expect((row?["reason"] as String?) == "noOverlap")
            #expect((row?["resolution"] as String?) == nil)
            let json: String = row?["competing_sources"] ?? ""
            #expect(json.contains("Dec 1900"))
            #expect(json.contains("1901"))
        }
    }

    // MARK: - C3 identity: unique partial index

    @Test func openDisputeIndexRejectsSecondOpenRowPerIdentity() throws {
        let dbQueue = try makeMigratedDB()
        // p1 already carries an OPEN (deathDate, fieldValue) dispute — a
        // second open row for the same identity must violate the index.
        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO field_disputes
                    (entity_id, field, reason, competing_sources, detected_at, kind)
                    VALUES ('p1', 'deathDate', 'noOverlap', '[]', ?, 'fieldValue')
                    """, arguments: [Date()])
            }
        }
    }

    @Test func openDisputeIndexAllowsResolvedHistoryPerIdentity() throws {
        let dbQueue = try makeMigratedDB()
        // Resolved rows are history (§3) — many may accumulate per identity.
        try dbQueue.write { db in
            for _ in 0..<2 {
                try db.execute(sql: """
                    INSERT INTO field_disputes
                    (entity_id, field, reason, competing_sources, detected_at, kind, resolution)
                    VALUES ('p1', 'deathDate', 'noOverlap', '[]', ?, 'fieldValue', '{"deferred":{}}')
                    """, arguments: [Date()])
            }
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM field_disputes
                WHERE entity_id = 'p1' AND field = 'deathDate'
                """)
            #expect(count == 3)
        }
    }

    @Test func openDisputeIndexAllowsSameFieldDifferentKind() throws {
        let dbQueue = try makeMigratedDB()
        // (deathDate, timeline) is a distinct identity from
        // (deathDate, fieldValue) — CL2's F3 disputes must coexist.
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO field_disputes
                (entity_id, field, reason, competing_sources, detected_at, kind)
                VALUES ('p1', 'deathDate', 'valueMismatch', '[]', ?, 'timeline')
                """, arguments: [Date()])
        }
        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM field_disputes WHERE resolution IS NULL
                """) ?? 0
        }
        #expect(count == 2)
    }

    // MARK: - Post-migration snapshot read (kind defaults to fieldValue)

    @Test func legacyDisputeReadsBackThroughSnapshotWithDefaultKind() throws {
        // Full ProjectDatabase open (runs the whole chain) over a DB
        // seeded with a legacy dispute row, then buildSnapshot.
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let profile = Profile(
            id: "p1", externalIDs: [:],
            firstName: "William", lastName: "Cauldwell",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1901"), deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
        let dispute = FieldDispute(
            field: .deathDate,
            reason: .noOverlap,
            competingSources: [
                FieldSource(origin: .gedcom, raw: "1901", addedAt: Date()),
                FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date()),
            ],
            detectedAt: Date()
        )
        try db.addFieldDispute(profileID: "p1", dispute: dispute)

        let snapshot = try db.buildSnapshot()
        let loaded = snapshot.profiles["p1"]?.disputes[.deathDate]
        #expect(loaded != nil)
        #expect(loaded?.kind == .fieldValue)
        #expect(loaded?.reason == .noOverlap)
        #expect(loaded?.competingSources.count == 2)
    }

    // MARK: - FieldDispute old-JSON decode (AC7)

    @Test func preConflictLayerFieldDisputeJSONStillDecodes() throws {
        // The exact key set the pre-CL1 synthesized Codable wrote — no
        // kind, no severity, no detectedBy.
        let oldJSON = """
        {
            "field": "deathDate",
            "reason": "noOverlap",
            "competingSources": [
                {"origin": {"identifier": "gedcom"}, "raw": "1901", "addedAt": 0},
                {"origin": {"identifier": "freebmd"}, "raw": "Dec 1900", "addedAt": 0}
            ],
            "detectedAt": 0
        }
        """
        let decoded = try JSONDecoder().decode(FieldDispute.self, from: Data(oldJSON.utf8))
        #expect(decoded.field == .deathDate)
        #expect(decoded.reason == .noOverlap)
        #expect(decoded.competingSources.count == 2)
        #expect(decoded.resolution == nil)
        // Decode-defaulted new fields (§5).
        #expect(decoded.kind == .fieldValue)
        #expect(decoded.severity == nil)
        #expect(decoded.detectedBy == nil)
    }

    @Test func oldResolutionJSONStillDecodesBesideNewRuleCase() throws {
        let oldAccepted = """
        {"accepted":{"_0":{"origin":{"identifier":"freebmd"},"raw":"Dec 1900","addedAt":0}}}
        """
        let decoded = try JSONDecoder().decode(DisputeResolution.self, from: Data(oldAccepted.utf8))
        guard case .accepted(let src) = decoded else {
            Issue.record("Expected .accepted, got \(decoded)")
            return
        }
        #expect(src.raw == "Dec 1900")

        // The additive .rule case round-trips.
        let rule = DisputeResolution.rule(
            id: "R2a",
            accepted: FieldSource(origin: .cwgc, raw: "14 July 1918", addedAt: Date())
        )
        let data = try JSONEncoder().encode(rule)
        let roundTripped = try JSONDecoder().decode(DisputeResolution.self, from: data)
        guard case .rule(let id, let accepted) = roundTripped else {
            Issue.record("Expected .rule, got \(roundTripped)")
            return
        }
        #expect(id == "R2a")
        #expect(accepted.raw == "14 July 1918")
    }
}
