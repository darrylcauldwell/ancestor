import Foundation
import GRDB

// PUBLISHER_SPEC Change 2 — accessors for the v30 publisher tables.
// Publisher state is Mac-local and never part of the canonical genealogy;
// these are the only readers/writers (the Evidence Firewall is untouched —
// nothing here is reachable from outside the app).
nonisolated extension ProjectDatabase {

    // MARK: - publish_policy (§5)

    /// Stored per-person overrides. Absent row = `.auto`.
    func loadPublishPolicies() throws -> [String: PublishPolicy] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT profile_id, policy FROM publish_policy")
            var policies: [String: PublishPolicy] = [:]
            for row in rows {
                let raw: String = row["policy"]
                if let policy = PublishPolicy(rawValue: raw) {
                    policies[row["profile_id"]] = policy
                }
            }
            return policies
        }
    }

    func setPublishPolicy(profileID: String, policy: PublishPolicy) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO publish_policy (profile_id, policy) VALUES (?, ?)
                    ON CONFLICT(profile_id) DO UPDATE SET policy = excluded.policy
                    """,
                arguments: [profileID, policy.rawValue]
            )
        }
    }

    // MARK: - published_ids (§4.1 — permanent identity)

    /// Full identity map keyed `"kind|canonicalID"` → record UUID.
    /// Superseded rows are included — their canonical id no longer projects,
    /// so the stale mapping is inert, and keeping it preserves history.
    func loadPublishedIdentityMap() throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT entity_kind, canonical_id, record_uuid FROM published_ids")
            var map: [String: String] = [:]
            for row in rows {
                let key = PublishedIdentity.key(kind: row["entity_kind"], canonicalID: row["canonical_id"])
                map[key] = row["record_uuid"]
            }
            return map
        }
    }

    /// Persist newly minted identities. Idempotent: the (kind, canonical)
    /// primary key means a re-run with the same mint set is a no-op.
    func savePublishedIDs(_ minted: [PublishedIdentity.MintedID]) throws {
        guard !minted.isEmpty else { return }
        try dbQueue.write { db in
            for id in minted {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO published_ids (entity_kind, canonical_id, record_uuid)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [id.kind, id.canonicalID, id.uuid]
                )
            }
        }
    }

    // MARK: - publish_media (§4.2 — per-attachment opt-in)

    func loadPublishMediaOptIns() throws -> Set<UUID> {
        try dbQueue.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT attachment_id FROM publish_media")
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    func setPublishMediaOptIn(attachmentID: UUID, optedIn: Bool) throws {
        try dbQueue.write { db in
            if optedIn {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO publish_media (attachment_id) VALUES (?)",
                    arguments: [attachmentID.uuidString])
            } else {
                try db.execute(
                    sql: "DELETE FROM publish_media WHERE attachment_id = ?",
                    arguments: [attachmentID.uuidString])
            }
        }
    }

    // MARK: - publish_meta (read-only here)

    /// Current publish generation. Bundle export reads it for the manifest
    /// but NEVER bumps it — only a CloudKit publish (Change 4) increments,
    /// because viewers treat the bump as "refresh complete".
    func loadPublishGeneration() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT generation FROM publish_meta WHERE id = 1") ?? 0
        }
    }

    /// Commit a successful publish (PublishEngine only; called after all
    /// records are server-acked so the generation is strictly monotonic
    /// and survives nuke-and-republish per spec Change 4).
    func setPublishGeneration(_ generation: Int, publishedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO publish_meta (id, generation, last_published_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET generation = excluded.generation,
                    last_published_at = excluded.last_published_at
                """, arguments: [generation, publishedAt])
        }
    }
}
