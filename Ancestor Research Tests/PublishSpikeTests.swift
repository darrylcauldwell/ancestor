import Testing
import Foundation
import CloudKit
import GRDB
import SQLiteData
import Dependencies
@testable import Ancestor_Research

// PUBLISHER_SPEC Change 3 — runtime spike (decision-gate proof).
//
// NOT part of the normal gate: enabled only when RUN_PUBLISH_SPIKE=1
// (pass via `xcodebuild test ... TEST_RUNNER_RUN_PUBLISH_SPIKE=1`).
// Talks to the REAL CloudKit development environment of
// iCloud.dev.dreamfold.Ancestor-Research using a throwaway store in
// the temp directory — never the canonical project database.
//
// Proves the three spike criteria from the spec amendment:
//   (a) SyncEngine init validation passes on the five-table published
//       shape (Manifest root, single-FK chain, Relationship.toPersonID
//       as plain TEXT);
//   (b) local rows reach the development environment (server-acked
//       CKRecords appear in sqlitedata_icloud_metadata);
//   (c) share(record: manifest) yields a CKShare.

// MARK: - Spike tables (published-store shape per Change 3 amendment)

@Table("spikeManifests")
private struct SpikeManifest: Identifiable {
    let id: String
    var generation = 0
    var rootPerson = ""
}

@Table("spikePersons")
private struct SpikePerson: Identifiable {
    let id: String
    var manifestID: String
    var displayName = ""
}

@Table("spikeRelationships")
private struct SpikeRelationship: Identifiable {
    let id: String
    var fromPersonID: String
    var toPersonID = ""   // plain column, no REFERENCES — the §Change3 concession
    var typeRaw = ""
}

@Table("spikeLifeEvents")
private struct SpikeLifeEvent: Identifiable {
    let id: String
    var personID: String
    var kindRaw = ""
}

@Table("spikeMedia")
private struct SpikeMedia: Identifiable {
    let id: String
    var personID: String
    var caption = ""
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_PUBLISH_SPIKE"] == "1"))
struct PublishSpikeTests {

    private static let containerID = "iCloud.dev.dreamfold.Ancestor-Research"

    @Test func runtimeProof() async throws {
        // Pre-flight: the Mac must be signed into iCloud.
        let status = try await CKContainer(identifier: Self.containerID).accountStatus()
        try #require(status == .available,
                     "iCloud account not available (status \(status.rawValue)) — sign into iCloud in System Settings")

        // Throwaway store.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.attachMetadatabase()
        }
        let db = try DatabaseQueue(
            path: dir.appendingPathComponent("spike.sqlite").path,
            configuration: configuration)

        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE "spikeManifests" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "generation" INTEGER NOT NULL DEFAULT 0,
                    "rootPerson" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "spikePersons" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "manifestID" TEXT NOT NULL REFERENCES "spikeManifests"("id") ON DELETE CASCADE,
                    "displayName" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "spikeRelationships" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "fromPersonID" TEXT NOT NULL REFERENCES "spikePersons"("id") ON DELETE CASCADE,
                    "toPersonID" TEXT NOT NULL DEFAULT '',
                    "typeRaw" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "spikeLifeEvents" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "personID" TEXT NOT NULL REFERENCES "spikePersons"("id") ON DELETE CASCADE,
                    "kindRaw" TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE "spikeMedia" (
                    "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                    "personID" TEXT NOT NULL REFERENCES "spikePersons"("id") ON DELETE CASCADE,
                    "caption" TEXT NOT NULL DEFAULT ''
                );
                """)
        }

        // (a) Engine init — this is where SQLiteData validates PK/FK/
        // sharing rules against our shape. A throw here refutes the
        // Change 3 decision.
        var engine: SyncEngine!
        try prepareDependencies {
            $0.defaultDatabase = db
            let built = try SyncEngine(
                for: db,
                tables: SpikeManifest.self, SpikePerson.self, SpikeRelationship.self,
                        SpikeLifeEvent.self, SpikeMedia.self,
                containerIdentifier: Self.containerID,
                startImmediately: true)
            $0.defaultSyncEngine = built
            engine = built
        }
        print("SPIKE (a) PASS — SyncEngine accepted the five-table published shape")

        // Seed a tiny tree with explicit IDs (lowercase — CKRecord
        // recordName discipline).
        let manifestID = UUID().uuidString.lowercased()
        let georgeID = UUID().uuidString.lowercased()
        let idaID = UUID().uuidString.lowercased()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO spikeManifests (id, generation, rootPerson) VALUES (?, 1, ?)",
                           arguments: [manifestID, georgeID])
            try db.execute(sql: "INSERT INTO spikePersons (id, manifestID, displayName) VALUES (?, ?, 'George Brooks')",
                           arguments: [georgeID, manifestID])
            try db.execute(sql: "INSERT INTO spikePersons (id, manifestID, displayName) VALUES (?, ?, 'Ida Land')",
                           arguments: [idaID, manifestID])
            try db.execute(sql: "INSERT INTO spikeRelationships (id, fromPersonID, toPersonID, typeRaw) VALUES (?, ?, ?, 'spouse')",
                           arguments: [UUID().uuidString.lowercased(), georgeID, idaID])
            try db.execute(sql: "INSERT INTO spikeLifeEvents (id, personID, kindRaw) VALUES (?, ?, 'census')",
                           arguments: [UUID().uuidString.lowercased(), georgeID])
        }

        // (b) Push explicitly — CKSyncEngine's scheduler can defer sends
        // in a short-lived process; sendChanges() is the "backup now"
        // pump — then confirm server acks (lastKnownServerRecord set).
        try await engine.sendChanges()
        var acked = 0
        for attempt in 1...45 {
            try await Task.sleep(for: .seconds(2))
            acked = try await db.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sqlitedata_icloud_metadata
                    WHERE lastKnownServerRecord IS NOT NULL
                    """) ?? 0
            }
            if acked >= 5 { break }
            if attempt % 5 == 0 { print("SPIKE (b) waiting — \(acked)/5 records acked after \(attempt * 2)s") }
        }
        #expect(acked >= 5, "expected all 5 records server-acked, got \(acked)")
        if acked >= 5 { print("SPIKE (b) PASS — \(acked) records acked by the development environment") }

        // (c) Hierarchy share rooted at the manifest.
        let manifest = try await db.read { db in
            try SpikeManifest.find(manifestID).fetchOne(db)
        }
        let unwrapped = try #require(manifest)
        let shared = try await engine.share(record: unwrapped) { share in
            share[CKShare.SystemFieldKey.title] = "Spike Tree" as CKRecordValue
        }
        print("SPIKE (c) PASS — CKShare created: \(shared.share.recordID.recordName), url: \(shared.share.url?.absoluteString ?? "pending")")
        #expect(shared.share.recordID.recordName.hasPrefix("share-"),
                "SQLiteData share naming: share-<uuid>:<tableName>")
    }
}
