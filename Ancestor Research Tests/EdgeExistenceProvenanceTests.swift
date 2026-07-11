import Testing
import Foundation
import GRDB
@testable import AncestorKit
@testable import Ancestor_Research

/// Pins E4 — edge-existence provenance (MODEL_EVOLUTION_SPEC §Change4).
///
/// "This parent/spouse edge exists because of this record" gets a home: an
/// `existence` pseudo-field on the `field_sources` mechanism, keyed
/// `entity_kind = 'relationship'`. These tests prove the load-bearing rules:
///
///   • **Forward-only** (decision log #4, the correctness rule): the v37
///     migration adds the *capability* but backfills nothing — an edge that
///     existed before E4 has no existence source after migration; only an edge
///     materialised *from a record* carries one. Backfilling would fabricate
///     evidence never captured.
///   • **Firewall / trust tier from URL**: the existence source cites the
///     driving record's real URL; the trust tier is derived from that URL
///     through `SourceTierRegistry`, never asserted by the writer.
///   • **Additive + lossless migration**: v37 appends to the chain, touches no
///     existing rows, and the profile field-source read path is unchanged.
///   • **Idempotent** (AC3): re-recording the same driving record adds no
///     duplicate; a genuinely different corroborating record legitimately adds
///     a second existence row.
nonisolated struct EdgeExistenceProvenanceTests {

    // MARK: - Fixtures

    /// A fresh, fully-migrated project DB backed by a scratch file so the
    /// `ProjectDatabase(path:)` round-trip helpers work.
    private func makeDatabase() throws -> (db: ProjectDatabase, path: String) {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        return (db, path)
    }

    /// A minimal ghost profile so a relationship's FK targets exist.
    private func makeProfile(id: String, surname: String) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: nil, lastName: surname, gender: nil,
            attributes: PersonAttributes(nameStatus: .placeholder, lifeStatus: .normal, privacy: .normal),
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    /// A FreeBMD birth `ScoredRecord` with a real detail URL, so the citation
    /// and trust-tier lookup have a genuine URL to derive from.
    ///
    /// `district`/`year` feed the *rendered short citation*, which is the
    /// existence row's `raw` and part of its idempotency key — vary them to
    /// get a genuinely distinct corroborating record.
    private func birthScoredRecord(
        id: String = "birth-1",
        surname: String = "BROOKS",
        givenName: String = "GEORGE",
        district: String = "Belper",
        year: Int = 1880,
        detailURL: String? = "https://www.freebmd.org.uk/cgi/information.pl?r=12345&d=bmd_1"
    ) -> ScoredRecord {
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(
                id: id, sourceID: "freebmd",
                name: nil, surname: surname, givenName: givenName,
                detailURL: detailURL, rawFields: [:]
            ),
            birthYear: year, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: district, volume: "7b", page: "100",
            mothersMaidenName: nil
        ))
        return ScoredRecord(id: id, record: record, verdict: .fact, gates: [], summary: "birth of George Brooks")
    }

    private func parentEdge(from parentID: String, to childID: String, role: ParentRole = .father) -> Relationship {
        Relationship(
            id: UUID(), from: parentID, to: childID,
            type: .parent, role: role, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    // MARK: - Migration: additive + in-chain + lossless (AC — backwards compat)

    @Test func v37MigratesCleanlyAndAppendsToChain() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v37_edge_existence_provenance"))
        // v36 must remain part of the chain — v37 appends, never replaces.
        #expect(applied.contains("v36_place_authority_id"))
    }

    @Test func v37AddsRelationshipExistenceIndexOnly() throws {
        // The migration is additive-capability: it must create the partial
        // index and alter no table (existence rows are ordinary field_sources
        // rows on entity_kind='relationship').
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let indexes = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
                .map { $0["name"] as String }
        }
        #expect(indexes.contains("idx_field_sources_relationship_existence"))
        // field_sources schema is unchanged — the columns E4 uses (entity_kind,
        // field, citation_json, evidence_quality) all predate v37.
        let cols = try dbQueue.read { db in
            try db.columns(in: "field_sources").map(\.name)
        }
        #expect(cols.contains("entity_kind"))
        #expect(cols.contains("field"))
        #expect(cols.contains("citation_json"))
    }

    @Test func v37MigrationDoesNotBackfillExistenceRows() throws {
        // Forward-only proof at the migration boundary: seed a DB migrated up
        // to the prior tail (v36), insert a legacy relationship the old way,
        // then run v37. The migration must NOT synthesise an existence row for
        // that pre-existing edge — backfilling provenance never captured would
        // fabricate evidence (decision log #4).
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v36_place_authority_id")

        let legacyRelID = UUID().uuidString
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO profiles (id, external_ids, is_deleted) VALUES ('leg-parent', '{}', 0)")
            try db.execute(sql: "INSERT INTO profiles (id, external_ids, is_deleted) VALUES ('leg-child', '{}', 0)")
            try db.execute(sql: """
                INSERT INTO relationships (id, from_id, to_id, type, role, subtype)
                VALUES (?, 'leg-parent', 'leg-child', 'parent', 'father', 'biological')
                """, arguments: [legacyRelID])
        }

        // Run the rest of the chain — this is where v37 fires.
        try migrator.migrate(dbQueue)

        let existenceCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM field_sources
                WHERE entity_id = ? AND entity_kind = 'relationship' AND field = 'existence'
                """, arguments: [legacyRelID]) ?? -1
        }
        #expect(existenceCount == 0, "v37 must not backfill existence rows for pre-existing edges")
    }

    // MARK: - Write + read back (AC1, AC2)

    @Test func recordAndReadBackExistenceSourceForNewEdge() throws {
        let (db, _) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["p-parent": makeProfile(id: "p-parent", surname: "Brooks"),
                           "p-child": makeProfile(id: "p-child", surname: "Brooks")],
                relationships: []
            ), source: "test")

        let edge = parentEdge(from: "p-parent", to: "p-child")
        let driving = birthScoredRecord()
        _ = try db.addRelationship(edge, existenceEvidence: .record(driving))

        let sources = try db.existenceSources(forRelationshipID: edge.id.uuidString)
        #expect(sources.count == 1)
        let src = try #require(sources.first)
        // Origin is the record's source id — not an asserted tier.
        #expect(src.origin.identifier == "freebmd")
        // Citation carries the record's real URL.
        #expect(src.citation?.url == "https://www.freebmd.org.uk/cgi/information.pl?r=12345&d=bmd_1")
        // Human-readable "because of this record" note survives the round-trip.
        #expect(src.raw.contains("Brooks") || src.raw.contains("BROOKS"))
    }

    // MARK: - Forward-only proof at the write boundary (AC4, decision log #4)

    @Test func legacyEdgeHasNoExistenceSourceButNewFromRecordEdgeDoes() throws {
        let (db, _) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["p1": makeProfile(id: "p1", surname: "A"),
                           "p2": makeProfile(id: "p2", surname: "A"),
                           "p3": makeProfile(id: "p3", surname: "A")],
                relationships: []
            ), source: "test")

        // A "legacy" edge created with NO evidence (as manual/import paths do).
        let bareEdge = parentEdge(from: "p1", to: "p2")
        _ = try db.addRelationship(bareEdge)   // no existenceEvidence

        // A new edge materialised FROM a record.
        let evidencedEdge = parentEdge(from: "p1", to: "p3")
        _ = try db.addRelationship(evidencedEdge, existenceEvidence: .record(birthScoredRecord()))

        let bareSources = try db.existenceSources(forRelationshipID: bareEdge.id.uuidString)
        let evidencedSources = try db.existenceSources(forRelationshipID: evidencedEdge.id.uuidString)

        #expect(bareSources.isEmpty, "an edge created without evidence must have no existence source")
        #expect(evidencedSources.count == 1, "an edge created from a record must carry its existence source")
    }

    // MARK: - Trust tier is URL-derived, never asserted (firewall)

    @Test func trustTierDerivesFromCitedURLNotFromWriter() throws {
        let (db, _) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["p-parent": makeProfile(id: "p-parent", surname: "B"),
                           "p-child": makeProfile(id: "p-child", surname: "B")],
                relationships: []
            ), source: "test")

        let edge = parentEdge(from: "p-parent", to: "p-child")
        let driving = birthScoredRecord(detailURL: "https://www.freebmd.org.uk/cgi/information.pl?r=999")
        _ = try db.addRelationship(edge, existenceEvidence: .record(driving))

        let src = try #require(try db.existenceSources(forRelationshipID: edge.id.uuidString).first)
        let citedURL = try #require(src.citation?.url)

        // The tier is resolved from the cited URL through the registry — the
        // existence writer stored no tier of its own. This is the firewall
        // guarantee: URL decides trust, not the caller.
        let tierEntry = SourceTierRegistry.lookup(url: citedURL)
        let unknownEntry = SourceTierRegistry.lookup(url: "https://example.invalid/nothing")
        #expect(tierEntry.trustTier != unknownEntry.trustTier,
                "a freebmd.org.uk URL must resolve to a known tier distinct from unknown")
    }

    // MARK: - Idempotency (AC3)

    @Test func reRecordingSameDrivingRecordAddsNoDuplicate() throws {
        let (db, _) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["p-parent": makeProfile(id: "p-parent", surname: "C"),
                           "p-child": makeProfile(id: "p-child", surname: "C")],
                relationships: []
            ), source: "test")

        let edge = parentEdge(from: "p-parent", to: "p-child")
        let driving = birthScoredRecord()

        // First create with evidence.
        _ = try db.addRelationshipIfAbsent(edge, existenceEvidence: .record(driving))
        // Re-run surfaces the already-applied proposal (same edge, same record).
        _ = try db.addRelationshipIfAbsent(edge, existenceEvidence: .record(driving))
        _ = try db.addRelationshipIfAbsent(edge, existenceEvidence: .record(driving))

        let sources = try db.existenceSources(forRelationshipID: edge.id.uuidString)
        #expect(sources.count == 1, "re-recording the same driving record must not duplicate the existence row")
    }

    @Test func differentCorroboratingRecordAddsSecondExistenceRow() throws {
        let (db, _) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["p-parent": makeProfile(id: "p-parent", surname: "D"),
                           "p-child": makeProfile(id: "p-child", surname: "D")],
                relationships: []
            ), source: "test")

        let edge = parentEdge(from: "p-parent", to: "p-child")
        // Two records that render to *distinct* citations (different district)
        // — genuinely different attestations, not the same record twice.
        let firstRecord = birthScoredRecord(
            id: "birth-A", district: "Belper",
            detailURL: "https://www.freebmd.org.uk/cgi/information.pl?r=1")
        let secondRecord = birthScoredRecord(
            id: "birth-B", district: "Bakewell",
            detailURL: "https://www.freebmd.org.uk/cgi/information.pl?r=2")

        _ = try db.addRelationshipIfAbsent(edge, existenceEvidence: .record(firstRecord))
        // Same edge already exists; a *different* corroborating record attaches
        // a second existence row (edges, like fields, can be multiply attested).
        _ = try db.addRelationshipIfAbsent(edge, existenceEvidence: .record(secondRecord))

        let sources = try db.existenceSources(forRelationshipID: edge.id.uuidString)
        #expect(sources.count == 2, "a distinct corroborating record must add a second existence row")
    }

    // MARK: - addFamily wires per-edge existence (accept/promote shape)

    @Test func addFamilyRecordsExistenceOnlyForMappedEdges() throws {
        let (db, _) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["subject": makeProfile(id: "subject", surname: "E")],
                relationships: []
            ), source: "test")

        let ghost = makeProfile(id: "ghost-parent", surname: "E")
        let citedEdge = parentEdge(from: "ghost-parent", to: "subject", role: .father)
        // A second edge in the same family with NO evidence mapping.
        let ghost2 = makeProfile(id: "ghost-parent-2", surname: "E")
        let bareEdge = parentEdge(from: "ghost-parent-2", to: "subject", role: .mother)

        _ = try db.addFamily(
            profiles: [ghost, ghost2],
            relationships: [citedEdge, bareEdge],
            source: .freebmd,
            edgeExistenceEvidence: [citedEdge.id: .record(birthScoredRecord())]
        )

        #expect(try db.existenceSources(forRelationshipID: citedEdge.id.uuidString).count == 1)
        #expect(try db.existenceSources(forRelationshipID: bareEdge.id.uuidString).isEmpty)
    }

    // MARK: - Origin variant for manual/import edges (honest, no fabricated citation)

    @Test func originVariantRecordsNoteWithoutCitationURL() throws {
        let (db, _) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["p-parent": makeProfile(id: "p-parent", surname: "F"),
                           "p-child": makeProfile(id: "p-child", surname: "F")],
                relationships: []
            ), source: "test")

        let edge = parentEdge(from: "p-parent", to: "p-child")
        _ = try db.addRelationship(
            edge,
            existenceEvidence: .origin(.manual, note: "Added by hand from a family bible")
        )

        let src = try #require(try db.existenceSources(forRelationshipID: edge.id.uuidString).first)
        #expect(src.origin.identifier == "manual")
        #expect(src.origin.tier == .userAuthoritative)
        // No citation URL fabricated for a manual origin.
        #expect(src.citation == nil)
        #expect(src.raw == "Added by hand from a family bible")
    }

    // MARK: - Persistence round-trip through a reopened DB (lossless)

    @Test func existenceSourceSurvivesDatabaseReopen() throws {
        let (db, path) = try makeDatabase()
        _ = try db.importSnapshot(
            FamilyGraphSnapshot(
                profiles: ["p-parent": makeProfile(id: "p-parent", surname: "G"),
                           "p-child": makeProfile(id: "p-child", surname: "G")],
                relationships: []
            ), source: "test")

        let edge = parentEdge(from: "p-parent", to: "p-child")
        _ = try db.addRelationship(edge, existenceEvidence: .record(birthScoredRecord()))

        // Reopen the same file — a fresh ProjectDatabase over the same path.
        let reopened = try ProjectDatabase(path: path)
        let sources = try reopened.existenceSources(forRelationshipID: edge.id.uuidString)
        #expect(sources.count == 1)
        #expect(sources.first?.citation?.url != nil)
    }
}
