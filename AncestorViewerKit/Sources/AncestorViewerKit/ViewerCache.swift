import Foundation
import GRDB

// The disposable local replica. Lives in Caches by convention (tvOS
// storage is purgeable — "cache vanished, refetch from scratch" is a
// normal startup path, not an error) and carries nothing that cannot be
// refetched. Deliberately NO foreign keys: a zone fetch delivers records
// in arbitrary order, including mid-publish partial states (§4.3), so
// rows must be storable before their parents arrive.

public nonisolated struct ViewerCache {
    let db: DatabaseQueue
    public let url: URL

    public static func open(at url: URL) throws -> ViewerCache {
        let db = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("viewer-cache-v1") { db in
            try db.execute(sql: """
                CREATE TABLE manifests (
                    id TEXT PRIMARY KEY NOT NULL,
                    schemaVersion INTEGER NOT NULL DEFAULT 1,
                    generation INTEGER NOT NULL DEFAULT 0,
                    rootPerson TEXT,
                    personCount INTEGER NOT NULL DEFAULT 0,
                    relationshipCount INTEGER NOT NULL DEFAULT 0,
                    publishedAtISO TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE persons (
                    id TEXT PRIMARY KEY NOT NULL,
                    manifestID TEXT NOT NULL,
                    schemaVersion INTEGER NOT NULL DEFAULT 1,
                    displayName TEXT NOT NULL DEFAULT '',
                    givenName TEXT, familyName TEXT, genderRaw TEXT,
                    birthOriginal TEXT, birthEarliest INTEGER, birthLatest INTEGER,
                    birthQualifierRaw TEXT, birthIsApproximate INTEGER,
                    birthPlace TEXT,
                    deathOriginal TEXT, deathEarliest INTEGER, deathLatest INTEGER,
                    deathQualifierRaw TEXT, deathIsApproximate INTEGER,
                    deathPlace TEXT,
                    bioText TEXT NOT NULL DEFAULT '',
                    citationsJSON TEXT NOT NULL DEFAULT '',
                    badgesJSON TEXT NOT NULL DEFAULT '',
                    isRedacted INTEGER NOT NULL DEFAULT 0,
                    isProvisional INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX persons_manifest ON persons(manifestID);
                CREATE TABLE relationships (
                    id TEXT PRIMARY KEY NOT NULL,
                    fromPersonID TEXT NOT NULL,
                    toPersonID TEXT NOT NULL DEFAULT '',
                    schemaVersion INTEGER NOT NULL DEFAULT 1,
                    typeRaw TEXT NOT NULL DEFAULT '',
                    roleRaw TEXT,
                    subtypeRaw TEXT NOT NULL DEFAULT 'unknown',
                    marriageOriginal TEXT, marriageEarliest INTEGER, marriageLatest INTEGER,
                    marriageQualifierRaw TEXT, marriageIsApproximate INTEGER,
                    marriageLocation TEXT,
                    divorceOriginal TEXT, divorceEarliest INTEGER, divorceLatest INTEGER,
                    divorceQualifierRaw TEXT, divorceIsApproximate INTEGER
                );
                CREATE INDEX relationships_from ON relationships(fromPersonID);
                CREATE TABLE lifeEvents (
                    id TEXT PRIMARY KEY NOT NULL,
                    personID TEXT NOT NULL,
                    schemaVersion INTEGER NOT NULL DEFAULT 1,
                    kindRaw TEXT NOT NULL DEFAULT '',
                    dateOriginal TEXT, dateEarliest INTEGER, dateLatest INTEGER,
                    dateQualifierRaw TEXT, dateIsApproximate INTEGER,
                    location TEXT,
                    detailsJSON TEXT,
                    sourceURL TEXT
                );
                CREATE INDEX lifeEvents_person ON lifeEvents(personID);
                CREATE TABLE media (
                    id TEXT PRIMARY KEY NOT NULL,
                    personID TEXT NOT NULL,
                    schemaVersion INTEGER NOT NULL DEFAULT 1,
                    kind TEXT NOT NULL DEFAULT '',
                    caption TEXT,
                    relativePath TEXT NOT NULL DEFAULT '',
                    localAssetPath TEXT
                );
                CREATE INDEX media_person ON media(personID);
                CREATE TABLE syncState (
                    scopeKey TEXT PRIMARY KEY NOT NULL,
                    changeToken BLOB
                );
                """)
        }
        try migrator.migrate(db)
        return ViewerCache(db: db, url: url)
    }

    // MARK: - Apply

    /// Upsert fetched records and apply tombstones. Record order is
    /// arbitrary (no FKs by design).
    public func apply(records: [MappedRecord], deletedRecordNames: [String]) throws {
        try db.write { db in
            for record in records {
                switch record {
                case .manifest(let row):
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO manifests
                        (id, schemaVersion, generation, rootPerson, personCount, relationshipCount, publishedAtISO)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.id, row.schemaVersion, row.generation, row.rootPerson,
                                         row.personCount, row.relationshipCount, row.publishedAtISO])
                case .person(let row):
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO persons
                        (id, manifestID, schemaVersion, displayName, givenName, familyName, genderRaw,
                         birthOriginal, birthEarliest, birthLatest, birthQualifierRaw, birthIsApproximate, birthPlace,
                         deathOriginal, deathEarliest, deathLatest, deathQualifierRaw, deathIsApproximate, deathPlace,
                         bioText, citationsJSON, badgesJSON, isRedacted, isProvisional)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.id, row.manifestID, row.schemaVersion, row.displayName,
                                         row.givenName, row.familyName, row.genderRaw,
                                         row.birthOriginal, row.birthEarliest, row.birthLatest,
                                         row.birthQualifierRaw, row.birthIsApproximate, row.birthPlace,
                                         row.deathOriginal, row.deathEarliest, row.deathLatest,
                                         row.deathQualifierRaw, row.deathIsApproximate, row.deathPlace,
                                         row.bioText, row.citationsJSON, row.badgesJSON,
                                         row.isRedacted, row.isProvisional])
                case .relationship(let row):
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO relationships
                        (id, fromPersonID, toPersonID, schemaVersion, typeRaw, roleRaw, subtypeRaw,
                         marriageOriginal, marriageEarliest, marriageLatest, marriageQualifierRaw, marriageIsApproximate,
                         marriageLocation,
                         divorceOriginal, divorceEarliest, divorceLatest, divorceQualifierRaw, divorceIsApproximate)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.id, row.fromPersonID, row.toPersonID, row.schemaVersion,
                                         row.typeRaw, row.roleRaw, row.subtypeRaw,
                                         row.marriageOriginal, row.marriageEarliest, row.marriageLatest,
                                         row.marriageQualifierRaw, row.marriageIsApproximate, row.marriageLocation,
                                         row.divorceOriginal, row.divorceEarliest, row.divorceLatest,
                                         row.divorceQualifierRaw, row.divorceIsApproximate])
                case .lifeEvent(let row):
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO lifeEvents
                        (id, personID, schemaVersion, kindRaw,
                         dateOriginal, dateEarliest, dateLatest, dateQualifierRaw, dateIsApproximate,
                         location, detailsJSON, sourceURL)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.id, row.personID, row.schemaVersion, row.kindRaw,
                                         row.dateOriginal, row.dateEarliest, row.dateLatest,
                                         row.dateQualifierRaw, row.dateIsApproximate,
                                         row.location, row.detailsJSON, row.sourceURL])
                case .media(let row):
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO media
                        (id, personID, schemaVersion, kind, caption, relativePath, localAssetPath)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.id, row.personID, row.schemaVersion, row.kind,
                                         row.caption, row.relativePath, row.localAssetPath])
                }
            }

            // Tombstones arrive as `<uuid>:<tableName>` record names
            // (unpublish = row tombstoning). Unknown tables are ignored.
            for name in deletedRecordNames {
                guard let id = RecordMapper.rowID(fromRecordName: name),
                      let table = RecordMapper.tableName(fromRecordName: name),
                      let cacheTable = Self.cacheTable(forRecordType: table)
                else { continue }
                try db.execute(sql: "DELETE FROM \(cacheTable) WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Drop every cached row (token-expiry / purge recovery). The change
    /// token is cleared too — the next fetch starts from scratch.
    public func wipe() throws {
        try db.write { db in
            for table in ["manifests", "persons", "relationships", "lifeEvents", "media", "syncState"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    // MARK: - Change token

    public func changeToken(scopeKey: String = "default") throws -> Data? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT changeToken FROM syncState WHERE scopeKey = ?",
                              arguments: [scopeKey])
        }
    }

    public func setChangeToken(_ data: Data?, scopeKey: String = "default") throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (scopeKey, changeToken) VALUES (?, ?)",
                           arguments: [scopeKey, data])
        }
    }

    // MARK: - Reads

    public func manifests() throws -> [ManifestRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM manifests ORDER BY publishedAtISO DESC")
                .map(Self.manifestRow)
        }
    }

    /// All rows of one manifest lineage — the SnapshotBuilder input.
    /// Scoping is mandatory: the zone (and therefore the cache) holds
    /// every published project.
    public func lineage(manifestID: String) throws -> (manifest: ManifestRow, persons: [PersonRow], relationships: [RelationshipRow], events: [EventRow], media: [MediaRow]) {
        try db.read { db in
            guard let manifestRaw = try Row.fetchOne(
                db, sql: "SELECT * FROM manifests WHERE id = ?", arguments: [manifestID])
            else { throw ViewerError.manifestNotFound(manifestID) }

            let persons = try Row.fetchAll(
                db, sql: "SELECT * FROM persons WHERE manifestID = ?", arguments: [manifestID])
                .map(Self.personRow)
            let relationships = try Row.fetchAll(db, sql: """
                SELECT * FROM relationships
                WHERE fromPersonID IN (SELECT id FROM persons WHERE manifestID = ?)
                """, arguments: [manifestID]).map(Self.relationshipRow)
            let events = try Row.fetchAll(db, sql: """
                SELECT * FROM lifeEvents
                WHERE personID IN (SELECT id FROM persons WHERE manifestID = ?)
                """, arguments: [manifestID]).map(Self.eventRow)
            let media = try Row.fetchAll(db, sql: """
                SELECT * FROM media
                WHERE personID IN (SELECT id FROM persons WHERE manifestID = ?)
                """, arguments: [manifestID]).map(Self.mediaRow)

            return (Self.manifestRow(manifestRaw), persons, relationships, events, media)
        }
    }

    // MARK: - Row decoding

    private static func manifestRow(_ row: Row) -> ManifestRow {
        ManifestRow(id: row["id"], schemaVersion: row["schemaVersion"],
                    generation: row["generation"], rootPerson: row["rootPerson"],
                    personCount: row["personCount"], relationshipCount: row["relationshipCount"],
                    publishedAtISO: row["publishedAtISO"])
    }

    private static func personRow(_ row: Row) -> PersonRow {
        PersonRow(id: row["id"], manifestID: row["manifestID"], schemaVersion: row["schemaVersion"],
                  displayName: row["displayName"], givenName: row["givenName"],
                  familyName: row["familyName"], genderRaw: row["genderRaw"],
                  birthOriginal: row["birthOriginal"], birthEarliest: row["birthEarliest"],
                  birthLatest: row["birthLatest"], birthQualifierRaw: row["birthQualifierRaw"],
                  birthIsApproximate: row["birthIsApproximate"], birthPlace: row["birthPlace"],
                  deathOriginal: row["deathOriginal"], deathEarliest: row["deathEarliest"],
                  deathLatest: row["deathLatest"], deathQualifierRaw: row["deathQualifierRaw"],
                  deathIsApproximate: row["deathIsApproximate"], deathPlace: row["deathPlace"],
                  bioText: row["bioText"], citationsJSON: row["citationsJSON"],
                  badgesJSON: row["badgesJSON"], isRedacted: row["isRedacted"],
                  isProvisional: row["isProvisional"])
    }

    private static func relationshipRow(_ row: Row) -> RelationshipRow {
        RelationshipRow(id: row["id"], fromPersonID: row["fromPersonID"],
                        toPersonID: row["toPersonID"], schemaVersion: row["schemaVersion"],
                        typeRaw: row["typeRaw"], roleRaw: row["roleRaw"],
                        subtypeRaw: row["subtypeRaw"],
                        marriageOriginal: row["marriageOriginal"], marriageEarliest: row["marriageEarliest"],
                        marriageLatest: row["marriageLatest"], marriageQualifierRaw: row["marriageQualifierRaw"],
                        marriageIsApproximate: row["marriageIsApproximate"], marriageLocation: row["marriageLocation"],
                        divorceOriginal: row["divorceOriginal"], divorceEarliest: row["divorceEarliest"],
                        divorceLatest: row["divorceLatest"], divorceQualifierRaw: row["divorceQualifierRaw"],
                        divorceIsApproximate: row["divorceIsApproximate"])
    }

    private static func eventRow(_ row: Row) -> EventRow {
        EventRow(id: row["id"], personID: row["personID"], schemaVersion: row["schemaVersion"],
                 kindRaw: row["kindRaw"], dateOriginal: row["dateOriginal"],
                 dateEarliest: row["dateEarliest"], dateLatest: row["dateLatest"],
                 dateQualifierRaw: row["dateQualifierRaw"], dateIsApproximate: row["dateIsApproximate"],
                 location: row["location"], detailsJSON: row["detailsJSON"],
                 sourceURL: row["sourceURL"])
    }

    private static func mediaRow(_ row: Row) -> MediaRow {
        MediaRow(id: row["id"], personID: row["personID"], schemaVersion: row["schemaVersion"],
                 kind: row["kind"], caption: row["caption"], relativePath: row["relativePath"],
                 localAssetPath: row["localAssetPath"])
    }

    private static func cacheTable(forRecordType type: String) -> String? {
        switch type {
        case RecordMapper.manifestType: return "manifests"
        case RecordMapper.personType: return "persons"
        case RecordMapper.relationshipType: return "relationships"
        case RecordMapper.lifeEventType: return "lifeEvents"
        case RecordMapper.mediaType: return "media"
        default: return nil
        }
    }
}

public nonisolated enum ViewerError: Error, Equatable {
    /// The published zone doesn't exist in the target database —
    /// nothing has been published (or the share isn't accepted yet).
    case treeNotFound
    case manifestNotFound(String)
}
