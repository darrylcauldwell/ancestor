import Foundation
import CryptoKit
import GRDB
import SQLiteData

// PUBLISHER_SPEC Change 4 — the SQLiteData-backed published store.
//
// A small, DISPOSABLE SQLite file per project (`<projectID>.publish.sqlite`
// beside the canonical store) holding the §4 published schema. The store
// IS the diff basis (Change 3 amendment): publishing means upserting/
// deleting store rows from the projection — SQLiteData mirrors the deltas
// to CloudKit. Rules binding here:
//   * UPDATE in place, never DELETE+INSERT the same primary key
//     (sqlite-data #418 — data loss on delete-then-reinsert).
//   * Single-FK chain: Manifest ← Person ← LifeEvent/Media;
//     Relationship.fromPersonID is a real FK, toPersonID plain TEXT.
//   * Every table carries a `checksum` so unchanged rows are never
//     touched (no-op publishes push nothing).

// MARK: - Store tables (schema v1 — CloudKit record types derive from these)

@Table("publishedManifests")
nonisolated struct StoreManifest: Identifiable {
    let id: String
    var schemaVersion = 1
    var generation = 0
    var rootPerson: String?
    var personCount = 0
    var relationshipCount = 0
    var publishedAtISO = ""
    var checksum = ""
}

@Table("publishedPersons")
nonisolated struct StorePerson: Identifiable {
    let id: String
    var manifestID: String
    var schemaVersion = 1
    var displayName = ""
    var givenName: String?
    var familyName: String?
    var genderRaw: String?
    var birthOriginal: String?
    var birthEarliest: Int?
    var birthLatest: Int?
    var birthQualifierRaw: String?
    var birthIsApproximate: Bool?
    var birthPlace: String?
    var deathOriginal: String?
    var deathEarliest: Int?
    var deathLatest: Int?
    var deathQualifierRaw: String?
    var deathIsApproximate: Bool?
    var deathPlace: String?
    var bioText = ""
    var citationsJSON = ""
    var badgesJSON = ""
    var isRedacted = false
    var isProvisional = false
    var checksum = ""
}

@Table("publishedRelationships")
nonisolated struct StoreRelationship: Identifiable {
    let id: String
    var fromPersonID: String
    var toPersonID = ""       // plain column, no REFERENCES — §Change3 concession
    var schemaVersion = 1
    var typeRaw = ""
    var roleRaw: String?
    var subtypeRaw = ""
    var marriageOriginal: String?
    var marriageEarliest: Int?
    var marriageLatest: Int?
    var marriageQualifierRaw: String?
    var marriageIsApproximate: Bool?
    var marriageLocation: String?
    var divorceOriginal: String?
    var divorceEarliest: Int?
    var divorceLatest: Int?
    var divorceQualifierRaw: String?
    var divorceIsApproximate: Bool?
    var checksum = ""
}

@Table("publishedLifeEvents")
nonisolated struct StoreLifeEvent: Identifiable {
    let id: String
    var personID: String
    var schemaVersion = 1
    var kindRaw = ""
    var dateOriginal: String?
    var dateEarliest: Int?
    var dateLatest: Int?
    var dateQualifierRaw: String?
    var dateIsApproximate: Bool?
    var location: String?
    var detailsJSON: String?
    var sourceURL: String?
    var checksum = ""
}

@Table("publishedMedia")
nonisolated struct StoreMedia: Identifiable {
    let id: String
    var personID: String
    var schemaVersion = 1
    var kind = ""
    var caption: String?
    var relativePath = ""
    var asset: Data?          // BLOB → CKAsset (sqlite-data convention)
    var checksum = ""
}

// MARK: - Store

nonisolated struct PublishedStore {
    let db: DatabaseQueue
    let url: URL

    struct ApplyStats: Sendable, Equatable {
        var inserted = 0
        var updated = 0
        var deleted = 0
        var unchanged = 0
        var missingMediaPaths: [String] = []
    }

    static func url(for projectID: UUID) -> URL {
        ProjectStore.projectsDirectory
            .appendingPathComponent("\(projectID.uuidString).publish.sqlite")
    }

    static func open(projectID: UUID) throws -> PublishedStore {
        try open(at: url(for: projectID))
    }

    static func open(at url: URL) throws -> PublishedStore {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.attachMetadatabase()
        }
        let db = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("publish-v1") { db in
            try db.execute(sql: """
                CREATE TABLE "publishedManifests" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "schemaVersion" INTEGER NOT NULL DEFAULT 1,
                    "generation" INTEGER NOT NULL DEFAULT 0,
                    "rootPerson" TEXT,
                    "personCount" INTEGER NOT NULL DEFAULT 0,
                    "relationshipCount" INTEGER NOT NULL DEFAULT 0,
                    "publishedAtISO" TEXT NOT NULL DEFAULT '',
                    "checksum" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "publishedPersons" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "manifestID" TEXT NOT NULL REFERENCES "publishedManifests"("id") ON DELETE CASCADE,
                    "schemaVersion" INTEGER NOT NULL DEFAULT 1,
                    "displayName" TEXT NOT NULL DEFAULT '',
                    "givenName" TEXT, "familyName" TEXT, "genderRaw" TEXT,
                    "birthOriginal" TEXT, "birthEarliest" INTEGER, "birthLatest" INTEGER,
                    "birthQualifierRaw" TEXT, "birthIsApproximate" INTEGER,
                    "birthPlace" TEXT,
                    "deathOriginal" TEXT, "deathEarliest" INTEGER, "deathLatest" INTEGER,
                    "deathQualifierRaw" TEXT, "deathIsApproximate" INTEGER,
                    "deathPlace" TEXT,
                    "bioText" TEXT NOT NULL DEFAULT '',
                    "citationsJSON" TEXT NOT NULL DEFAULT '',
                    "badgesJSON" TEXT NOT NULL DEFAULT '',
                    "isRedacted" INTEGER NOT NULL DEFAULT 0,
                    "isProvisional" INTEGER NOT NULL DEFAULT 0,
                    "checksum" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "publishedRelationships" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "fromPersonID" TEXT NOT NULL REFERENCES "publishedPersons"("id") ON DELETE CASCADE,
                    "toPersonID" TEXT NOT NULL DEFAULT '',
                    "schemaVersion" INTEGER NOT NULL DEFAULT 1,
                    "typeRaw" TEXT NOT NULL DEFAULT '',
                    "roleRaw" TEXT,
                    "subtypeRaw" TEXT NOT NULL DEFAULT '',
                    "marriageOriginal" TEXT, "marriageEarliest" INTEGER, "marriageLatest" INTEGER,
                    "marriageQualifierRaw" TEXT, "marriageIsApproximate" INTEGER,
                    "marriageLocation" TEXT,
                    "divorceOriginal" TEXT, "divorceEarliest" INTEGER, "divorceLatest" INTEGER,
                    "divorceQualifierRaw" TEXT, "divorceIsApproximate" INTEGER,
                    "checksum" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "publishedLifeEvents" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "personID" TEXT NOT NULL REFERENCES "publishedPersons"("id") ON DELETE CASCADE,
                    "schemaVersion" INTEGER NOT NULL DEFAULT 1,
                    "kindRaw" TEXT NOT NULL DEFAULT '',
                    "dateOriginal" TEXT, "dateEarliest" INTEGER, "dateLatest" INTEGER,
                    "dateQualifierRaw" TEXT, "dateIsApproximate" INTEGER,
                    "location" TEXT,
                    "detailsJSON" TEXT,
                    "sourceURL" TEXT,
                    "checksum" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "publishedMedia" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "personID" TEXT NOT NULL REFERENCES "publishedPersons"("id") ON DELETE CASCADE,
                    "schemaVersion" INTEGER NOT NULL DEFAULT 1,
                    "kind" TEXT NOT NULL DEFAULT '',
                    "caption" TEXT,
                    "relativePath" TEXT NOT NULL DEFAULT '',
                    "asset" BLOB,
                    "checksum" TEXT NOT NULL DEFAULT ''
                );
                """)
        }
        try migrator.migrate(db)
        return PublishedStore(db: db, url: url)
    }

    // MARK: - Apply (projection → store, checksum-diffed, update-in-place)

    /// Reconcile the store to exactly match the projection. Presence
    /// semantics: rows absent from the projection are deleted (their
    /// CKRecords tombstone via sync); changed rows UPDATE in place;
    /// unchanged rows are untouched so no CK traffic is generated.
    func apply(
        tree: PublishedTree,
        manifestID: String,
        mediaSourceDirectory: URL
    ) throws -> ApplyStats {
        var stats = ApplyStats()

        // Pre-compute media asset hashes outside the write transaction.
        var mediaAssets: [String: (sha: String, data: Data?)] = [:]
        for item in tree.media {
            let fileURL = mediaSourceDirectory.appendingPathComponent(item.relativePath)
            if let data = try? Data(contentsOf: fileURL) {
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                mediaAssets[item.id] = (sha, data)
            } else {
                mediaAssets[item.id] = ("missing", nil)
                stats.missingMediaPaths.append(item.relativePath)
            }
        }

        try db.write { db in
            // Manifest (singleton row).
            let manifestChecksum = PublishChecksum.checksum(tree.manifest)
            let existingManifest = try Row.fetchOne(
                db, sql: "SELECT checksum FROM publishedManifests WHERE id = ?", arguments: [manifestID])
            if let existingManifest {
                if existingManifest["checksum"] != manifestChecksum {
                    try db.execute(sql: """
                        UPDATE publishedManifests SET generation = ?, rootPerson = ?, personCount = ?,
                            relationshipCount = ?, publishedAtISO = ?, checksum = ? WHERE id = ?
                        """, arguments: [
                            tree.manifest.generation, tree.manifest.rootPerson,
                            tree.manifest.personCount, tree.manifest.relationshipCount,
                            tree.manifest.publishedAtISO, manifestChecksum, manifestID])
                    stats.updated += 1
                } else { stats.unchanged += 1 }
            } else {
                try db.execute(sql: """
                    INSERT INTO publishedManifests (id, schemaVersion, generation, rootPerson,
                        personCount, relationshipCount, publishedAtISO, checksum)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        manifestID, tree.manifest.schemaVersion, tree.manifest.generation,
                        tree.manifest.rootPerson, tree.manifest.personCount,
                        tree.manifest.relationshipCount, tree.manifest.publishedAtISO, manifestChecksum])
                stats.inserted += 1
            }

            // Persons — parents before children (FK discipline).
            var keepPersons: [String] = []
            for person in tree.persons {
                keepPersons.append(person.id)
                let checksum = PublishChecksum.checksum(person)
                let existing = try Row.fetchOne(
                    db, sql: "SELECT checksum FROM publishedPersons WHERE id = ?", arguments: [person.id])
                if let existing {
                    if existing["checksum"] != checksum {
                        try db.execute(sql: """
                            UPDATE publishedPersons SET manifestID = ?, displayName = ?, givenName = ?,
                                familyName = ?, genderRaw = ?,
                                birthOriginal = ?, birthEarliest = ?, birthLatest = ?, birthQualifierRaw = ?, birthIsApproximate = ?,
                                birthPlace = ?,
                                deathOriginal = ?, deathEarliest = ?, deathLatest = ?, deathQualifierRaw = ?, deathIsApproximate = ?,
                                deathPlace = ?, bioText = ?, citationsJSON = ?, badgesJSON = ?,
                                isRedacted = ?, isProvisional = ?, checksum = ?
                            WHERE id = ?
                            """, arguments: StatementArguments(personArguments(person, manifestID: manifestID, checksum: checksum) + [person.id]))
                        stats.updated += 1
                    } else { stats.unchanged += 1 }
                } else {
                    try db.execute(sql: """
                        INSERT INTO publishedPersons (manifestID, displayName, givenName, familyName, genderRaw,
                            birthOriginal, birthEarliest, birthLatest, birthQualifierRaw, birthIsApproximate, birthPlace,
                            deathOriginal, deathEarliest, deathLatest, deathQualifierRaw, deathIsApproximate, deathPlace,
                            bioText, citationsJSON, badgesJSON, isRedacted, isProvisional, checksum, id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: StatementArguments(personArguments(person, manifestID: manifestID, checksum: checksum) + [person.id]))
                    stats.inserted += 1
                }
            }

            // Relationships / events / media — same upsert pattern.
            var keepRelationships: [String] = []
            for rel in tree.relationships {
                keepRelationships.append(rel.id)
                let checksum = PublishChecksum.checksum(rel)
                try upsert(db, table: "publishedRelationships", id: rel.id, checksum: checksum, stats: &stats,
                    update: ("""
                        UPDATE publishedRelationships SET fromPersonID = ?, toPersonID = ?, typeRaw = ?, roleRaw = ?,
                            subtypeRaw = ?,
                            marriageOriginal = ?, marriageEarliest = ?, marriageLatest = ?, marriageQualifierRaw = ?, marriageIsApproximate = ?,
                            marriageLocation = ?,
                            divorceOriginal = ?, divorceEarliest = ?, divorceLatest = ?, divorceQualifierRaw = ?, divorceIsApproximate = ?,
                            checksum = ? WHERE id = ?
                        """, relationshipArguments(rel, checksum: checksum) + [rel.id]),
                    insert: ("""
                        INSERT INTO publishedRelationships (fromPersonID, toPersonID, typeRaw, roleRaw, subtypeRaw,
                            marriageOriginal, marriageEarliest, marriageLatest, marriageQualifierRaw, marriageIsApproximate, marriageLocation,
                            divorceOriginal, divorceEarliest, divorceLatest, divorceQualifierRaw, divorceIsApproximate,
                            checksum, id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, relationshipArguments(rel, checksum: checksum) + [rel.id]))
            }

            var keepEvents: [String] = []
            for event in tree.events {
                keepEvents.append(event.id)
                let checksum = PublishChecksum.checksum(event)
                try upsert(db, table: "publishedLifeEvents", id: event.id, checksum: checksum, stats: &stats,
                    update: ("""
                        UPDATE publishedLifeEvents SET personID = ?, kindRaw = ?,
                            dateOriginal = ?, dateEarliest = ?, dateLatest = ?, dateQualifierRaw = ?, dateIsApproximate = ?,
                            location = ?, detailsJSON = ?, sourceURL = ?, checksum = ? WHERE id = ?
                        """, eventArguments(event, checksum: checksum) + [event.id]),
                    insert: ("""
                        INSERT INTO publishedLifeEvents (personID, kindRaw,
                            dateOriginal, dateEarliest, dateLatest, dateQualifierRaw, dateIsApproximate,
                            location, detailsJSON, sourceURL, checksum, id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, eventArguments(event, checksum: checksum) + [event.id]))
            }

            var keepMedia: [String] = []
            for item in tree.media {
                keepMedia.append(item.id)
                let assetInfo = mediaAssets[item.id] ?? ("missing", nil)
                // Asset content participates in the checksum so a re-scanned
                // photo re-uploads and an unchanged one never does.
                let checksum = PublishChecksum.checksum(item) + ":" + assetInfo.sha
                let existing = try Row.fetchOne(
                    db, sql: "SELECT checksum FROM publishedMedia WHERE id = ?", arguments: [item.id])
                if let existing {
                    if existing["checksum"] != checksum {
                        try db.execute(sql: """
                            UPDATE publishedMedia SET personID = ?, kind = ?, caption = ?, relativePath = ?,
                                asset = ?, checksum = ? WHERE id = ?
                            """, arguments: [item.person, item.kind, item.caption, item.relativePath,
                                             assetInfo.data, checksum, item.id])
                        stats.updated += 1
                    } else { stats.unchanged += 1 }
                } else {
                    try db.execute(sql: """
                        INSERT INTO publishedMedia (personID, kind, caption, relativePath, asset, checksum, id)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [item.person, item.kind, item.caption, item.relativePath,
                                         assetInfo.data, checksum, item.id])
                    stats.inserted += 1
                }
            }

            // Presence deletes — children before parents so every tombstone
            // is explicit (CASCADE would also fire, but explicit deletes give
            // deterministic stats and sync ordering).
            stats.deleted += try deleteAbsent(db, table: "publishedMedia", keep: keepMedia)
            stats.deleted += try deleteAbsent(db, table: "publishedLifeEvents", keep: keepEvents)
            stats.deleted += try deleteAbsent(db, table: "publishedRelationships", keep: keepRelationships)
            stats.deleted += try deleteAbsent(db, table: "publishedPersons", keep: keepPersons)
        }
        return stats
    }

    /// Total row count across the five tables (ack-polling denominator).
    func totalRows() throws -> Int {
        try db.read { db in
            var total = 0
            for table in ["publishedManifests", "publishedPersons", "publishedRelationships",
                          "publishedLifeEvents", "publishedMedia"] {
                total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return total
        }
    }

    /// Rows CloudKit has acknowledged (lastKnownServerRecord present).
    func ackedRows() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlitedata_icloud_metadata
                WHERE lastKnownServerRecord IS NOT NULL
                """) ?? 0
        }
    }

    // MARK: - Private helpers

    private func upsert(
        _ db: Database, table: String, id: String, checksum: String,
        stats: inout ApplyStats,
        update: (sql: String, arguments: [(any DatabaseValueConvertible)?]),
        insert: (sql: String, arguments: [(any DatabaseValueConvertible)?])
    ) throws {
        let existing = try Row.fetchOne(
            db, sql: "SELECT checksum FROM \(table) WHERE id = ?", arguments: [id])
        if let existing {
            if existing["checksum"] != checksum {
                try db.execute(sql: update.sql, arguments: StatementArguments(update.arguments))
                stats.updated += 1
            } else { stats.unchanged += 1 }
        } else {
            try db.execute(sql: insert.sql, arguments: StatementArguments(insert.arguments))
            stats.inserted += 1
        }
    }

    private func deleteAbsent(_ db: Database, table: String, keep: [String]) throws -> Int {
        let placeholders = keep.isEmpty ? "''" : keep.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM \(table) WHERE id NOT IN (\(placeholders))",
            arguments: StatementArguments(keep))
        return db.changesCount
    }

    private func personArguments(
        _ p: PublishedPerson, manifestID: String, checksum: String
    ) -> [(any DatabaseValueConvertible)?] {
        [manifestID, p.displayName, p.givenName, p.familyName, p.genderRaw,
         p.birth?.original, p.birth?.earliest, p.birth?.latest, p.birth?.qualifierRaw, p.birth?.isApproximate,
         p.birthPlace,
         p.death?.original, p.death?.earliest, p.death?.latest, p.death?.qualifierRaw, p.death?.isApproximate,
         p.deathPlace, p.bioText, p.citationsJSON, p.badgesJSON,
         p.isRedacted, p.isProvisional, checksum]
    }

    private func relationshipArguments(
        _ r: PublishedRelationship, checksum: String
    ) -> [(any DatabaseValueConvertible)?] {
        [r.fromPerson, r.toPerson, r.typeRaw, r.roleRaw, r.subtypeRaw,
         r.marriage?.original, r.marriage?.earliest, r.marriage?.latest, r.marriage?.qualifierRaw, r.marriage?.isApproximate,
         r.marriageLocation,
         r.divorce?.original, r.divorce?.earliest, r.divorce?.latest, r.divorce?.qualifierRaw, r.divorce?.isApproximate,
         checksum]
    }

    private func eventArguments(
        _ e: PublishedLifeEvent, checksum: String
    ) -> [(any DatabaseValueConvertible)?] {
        [e.person, e.kindRaw,
         e.date?.original, e.date?.earliest, e.date?.latest, e.date?.qualifierRaw, e.date?.isApproximate,
         e.location, e.detailsJSON, e.sourceURL, checksum]
    }
}
