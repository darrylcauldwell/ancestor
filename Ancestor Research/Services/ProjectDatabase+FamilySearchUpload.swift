import Foundation
import GRDB
import AncestorKit

/// One FamilySearch User Tree upload run (v52). A run is created when the
/// wizard confirms, advances through `phase` as the orchestrator progresses,
/// and is the resume anchor: the latest non-finalized run for an environment
/// carries the group/tree IDs an interrupted upload continues into.
nonisolated struct FSTreeUploadRecord: Sendable, Equatable {
    var id: String
    var environment: String
    var fsGroupID: String?
    var fsTreeID: String?
    var treeName: String
    var treeDescription: String?
    var startingProfileID: String?
    /// nil until finalize — the wizard's privacy choice is applied last.
    var isPrivate: Bool?
    /// 'created' | 'uploading' | 'finalized' | 'failed'
    var phase: String
    var startedAt: Date
    var finalizedAt: Date?
    var personsUploaded: Int
    var relationshipsUploaded: Int
    var sourcesUploaded: Int
}

/// Persistence for the FamilySearch User Tree write leg (WL3,
/// FAMILYSEARCH_TREES_WRITE_SPEC §5). Every write is an idempotent upsert so
/// the orchestrator can re-record on resume without special-casing.
nonisolated extension ProjectDatabase {

    // MARK: Upload runs

    func saveFamilySearchUploadRun(_ record: FSTreeUploadRecord) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO familysearch_tree_uploads
                  (id, environment, fs_group_id, fs_tree_id, tree_name, tree_description,
                   starting_profile_id, private, phase, started_at, finalized_at,
                   persons_uploaded, relationships_uploaded, sources_uploaded)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  fs_group_id = excluded.fs_group_id,
                  fs_tree_id = excluded.fs_tree_id,
                  tree_name = excluded.tree_name,
                  tree_description = excluded.tree_description,
                  starting_profile_id = excluded.starting_profile_id,
                  private = excluded.private,
                  phase = excluded.phase,
                  finalized_at = excluded.finalized_at,
                  persons_uploaded = excluded.persons_uploaded,
                  relationships_uploaded = excluded.relationships_uploaded,
                  sources_uploaded = excluded.sources_uploaded
                """, arguments: [
                    record.id, record.environment, record.fsGroupID, record.fsTreeID,
                    record.treeName, record.treeDescription, record.startingProfileID,
                    record.isPrivate, record.phase, record.startedAt, record.finalizedAt,
                    record.personsUploaded, record.relationshipsUploaded, record.sourcesUploaded,
                ])
        }
    }

    /// The most recent run for an environment — the resume anchor. `phase`
    /// tells the caller whether it is continuable ('created'/'uploading') or
    /// terminal ('finalized'/'failed').
    func latestFamilySearchUploadRun(environment: String) throws -> FSTreeUploadRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM familysearch_tree_uploads
                WHERE environment = ? ORDER BY started_at DESC LIMIT 1
                """, arguments: [environment]) else { return nil }
            return Self.uploadRunFromRow(row)
        }
    }

    private static func uploadRunFromRow(_ row: Row) -> FSTreeUploadRecord {
        FSTreeUploadRecord(
            id: row["id"], environment: row["environment"],
            fsGroupID: row["fs_group_id"], fsTreeID: row["fs_tree_id"],
            treeName: row["tree_name"], treeDescription: row["tree_description"],
            startingProfileID: row["starting_profile_id"],
            isPrivate: row["private"],
            phase: row["phase"], startedAt: row["started_at"], finalizedAt: row["finalized_at"],
            personsUploaded: row["persons_uploaded"],
            relationshipsUploaded: row["relationships_uploaded"],
            sourcesUploaded: row["sources_uploaded"])
    }

    // MARK: Person links (pid map + E1 dual-write)

    /// Record a minted pid for a local profile. Also dual-writes the E1
    /// `external_identifiers` column (system "familysearch", bare pid) via
    /// `mergingLegacyMap`, which demotes any superseded prior primary to
    /// `.persistent` instead of losing it — one write transaction for both.
    func recordFamilySearchPersonLink(
        profileID: String, fsTreeID: String, fsPID: String, at date: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO familysearch_person_links
                  (profile_id, fs_tree_id, fs_pid, status, superseded_by, uploaded_at)
                VALUES (?, ?, ?, 'created', NULL, ?)
                ON CONFLICT(profile_id, fs_tree_id) DO UPDATE SET
                  fs_pid = excluded.fs_pid,
                  status = 'created',
                  superseded_by = NULL,
                  uploaded_at = excluded.uploaded_at
                """, arguments: [profileID, fsTreeID, fsPID, date])

            // E1 dual-write, mirroring the profileFromRow decode + insertProfile
            // encode exactly (typed list is the source of truth; the legacy map
            // stays projected for rollback insurance).
            guard let row = try Row.fetchOne(
                db, sql: "SELECT external_identifiers, external_ids FROM profiles WHERE id = ?",
                arguments: [profileID]) else { return }
            var records: [ExternalIdentifier] = []
            if let json: String = row["external_identifiers"],
               let decoded = try? JSONDecoder().decode([ExternalIdentifier].self, from: Data(json.utf8)) {
                records = decoded
            }
            let legacyJSON: String = row["external_ids"] ?? "{}"
            let legacy = (try? JSONDecoder().decode([String: String].self, from: Data(legacyJSON.utf8))) ?? [:]
            records = records.mergingLegacyMap(legacy).mergingLegacyMap(["familysearch": fsPID])

            let identifiersJSON = (try? JSONEncoder().encode(records))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let legacyOut = (try? JSONEncoder().encode(records.primaryValuesBySystem))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try db.execute(
                sql: "UPDATE profiles SET external_identifiers = ?, external_ids = ? WHERE id = ?",
                arguments: [identifiersJSON, legacyOut, profileID])
        }
    }

    /// profileID → pid for a tree. The resume set: anything absent here still
    /// needs its person created.
    func familySearchPersonLinks(fsTreeID: String) throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT profile_id, fs_pid FROM familysearch_person_links
                WHERE fs_tree_id = ? AND status = 'created'
                """, arguments: [fsTreeID])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["profile_id"], $0["fs_pid"]) })
        }
    }

    // MARK: Entity links (relationships, source descriptions/references)

    func recordFamilySearchEntityLink(
        localKey: String, fsTreeID: String, kind: String, fsID: String, at date: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO familysearch_entity_links (local_key, fs_tree_id, kind, fs_id, uploaded_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(local_key, fs_tree_id, kind) DO UPDATE SET
                  fs_id = excluded.fs_id,
                  uploaded_at = excluded.uploaded_at
                """, arguments: [localKey, fsTreeID, kind, fsID, date])
        }
    }

    /// localKey → FS id for one entity kind in one tree.
    func familySearchEntityLinks(fsTreeID: String, kind: String) throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT local_key, fs_id FROM familysearch_entity_links
                WHERE fs_tree_id = ? AND kind = ?
                """, arguments: [fsTreeID, kind])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["local_key"], $0["fs_id"]) })
        }
    }
}
