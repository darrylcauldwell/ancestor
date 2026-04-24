import Foundation
import GRDB

/// GRDB database wrapper for a single project.
/// Each project is one SQLite file in Application Support.
nonisolated final class ProjectDatabase: Sendable {
    let dbQueue: DatabaseQueue

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    /// Run all migrations to bring the schema up to date.
    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "project_meta") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("source_kind", .text).notNull()
                t.column("source_value", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("last_refreshed", .datetime)
            }

            try db.create(table: "transactions") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("undo_strategy", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("completed_at", .datetime).notNull()
                t.column("change_count", .integer).notNull().defaults(to: 0)
                t.column("profile_count", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "profiles") { t in
                t.primaryKey("id", .text)
                t.column("external_ids", .text).notNull().defaults(to: "{}")
                t.column("first_name", .text)
                t.column("last_name", .text)
                t.column("gender", .text)
                t.column("birth_date_original", .text)
                t.column("birth_date_earliest", .integer)
                t.column("birth_date_latest", .integer)
                t.column("birth_date_qualifier", .text)
                t.column("birth_location", .text)
                t.column("death_date_original", .text)
                t.column("death_date_earliest", .integer)
                t.column("death_date_latest", .integer)
                t.column("death_date_qualifier", .text)
                t.column("death_location", .text)
                t.column("bio", .text)
                t.column("created_by_transaction_id", .text)
                    .references("transactions", onDelete: .setNull)
            }

            try db.create(table: "relationships") { t in
                t.primaryKey("id", .text)
                t.column("from_id", .text).notNull()
                    .references("profiles", onDelete: .cascade)
                t.column("to_id", .text).notNull()
                    .references("profiles", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("role", .text)
                t.column("subtype", .text).notNull().defaults(to: "unknown")
                t.column("marriage_date_original", .text)
                t.column("marriage_date_earliest", .integer)
                t.column("marriage_date_latest", .integer)
                t.column("marriage_date_qualifier", .text)
                t.column("divorce_date_original", .text)
                t.column("divorce_date_earliest", .integer)
                t.column("divorce_date_latest", .integer)
                t.column("divorce_date_qualifier", .text)
                t.column("created_by_transaction_id", .text)
                    .references("transactions", onDelete: .setNull)
            }

            try db.create(table: "field_sources") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("entity_id", .text).notNull()
                t.column("entity_kind", .text).notNull()
                t.column("field", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("raw", .text).notNull()
                t.column("added_at", .datetime).notNull()
                t.column("created_by_transaction_id", .text)
                    .references("transactions", onDelete: .setNull)
            }

            try db.create(table: "field_changes") { t in
                t.primaryKey("id", .text)
                t.column("transaction_id", .text).notNull()
                    .references("transactions", onDelete: .cascade)
                t.column("entity_id", .text).notNull()
                t.column("entity_kind", .text).notNull()
                t.column("field", .text).notNull()
                t.column("old_value", .text)
                t.column("new_value", .text).notNull()
                t.column("source", .text).notNull()
                t.column("reason", .text)
            }

            try db.create(table: "field_disputes") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("entity_id", .text).notNull()
                t.column("field", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("competing_sources", .text).notNull()
                t.column("detected_at", .datetime).notNull()
                t.column("resolution", .text)
                t.column("created_by_transaction_id", .text)
                    .references("transactions", onDelete: .setNull)
            }

            // Indices for common queries
            try db.create(index: "idx_relationships_from", on: "relationships", columns: ["from_id"])
            try db.create(index: "idx_relationships_to", on: "relationships", columns: ["to_id"])
            try db.create(index: "idx_field_sources_entity", on: "field_sources", columns: ["entity_id", "field"])
            try db.create(index: "idx_field_changes_transaction", on: "field_changes", columns: ["transaction_id"])
            try db.create(index: "idx_field_changes_entity", on: "field_changes", columns: ["entity_id"])
            try db.create(index: "idx_field_disputes_entity", on: "field_disputes", columns: ["entity_id", "field"])
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Snapshot Building

    /// Build a FamilyGraphSnapshot from the database.
    /// Eagerly joins profiles + field_sources + field_disputes.
    func buildSnapshot() throws -> FamilyGraphSnapshot {
        try dbQueue.read { db in
            // Load all profiles
            let profileRows = try Row.fetchAll(db, sql: "SELECT * FROM profiles")
            var profiles: [String: Profile] = [:]
            for row in profileRows {
                let id: String = row["id"]
                let profile = try Self.profileFromRow(row, db: db)
                profiles[id] = profile
            }

            // Load all relationships
            let relRows = try Row.fetchAll(db, sql: "SELECT * FROM relationships")
            let relationships = relRows.map { Self.relationshipFromRow($0) }

            return FamilyGraphSnapshot(profiles: profiles, relationships: relationships)
        }
    }

    private static func profileFromRow(_ row: Row, db: Database) throws -> Profile {
        let id: String = row["id"]
        let externalIDsJSON: String = row["external_ids"]
        let externalIDs = (try? JSONDecoder().decode([String: String].self, from: Data(externalIDsJSON.utf8))) ?? [:]

        let birthDate = dateFromRow(row, prefix: "birth_date")
        let deathDate = dateFromRow(row, prefix: "death_date")
        let genderStr: String? = row["gender"]
        let gender = genderStr.flatMap { Gender(rawValue: $0) }

        // Load sources for this profile
        let sourceRows = try Row.fetchAll(db, sql: """
            SELECT field, origin, raw, added_at FROM field_sources
            WHERE entity_id = ? AND entity_kind = 'profile'
            """, arguments: [id])

        var sources: [ProfileField: [FieldSource]] = [:]
        for sRow in sourceRows {
            let fieldStr: String = sRow["field"]
            guard let field = ProfileField(rawValue: fieldStr) else { continue }
            let origin = SourceOrigin(identifier: sRow["origin"])
            let raw: String = sRow["raw"]
            let addedAt: Date = sRow["added_at"]
            sources[field, default: []].append(FieldSource(origin: origin, raw: raw, addedAt: addedAt))
        }

        // Load disputes for this profile
        let disputeRows = try Row.fetchAll(db, sql: """
            SELECT field, reason, competing_sources, detected_at, resolution FROM field_disputes
            WHERE entity_id = ?
            """, arguments: [id])

        var disputes: [ProfileField: FieldDispute] = [:]
        for dRow in disputeRows {
            let fieldStr: String = dRow["field"]
            guard let field = ProfileField(rawValue: fieldStr) else { continue }
            let reasonStr: String = dRow["reason"]
            guard let reason = DisputeReason(rawValue: reasonStr) else { continue }
            let competingJSON: String = dRow["competing_sources"]
            let competing = (try? JSONDecoder().decode([FieldSource].self, from: Data(competingJSON.utf8))) ?? []
            let detectedAt: Date = dRow["detected_at"]
            let resolutionJSON: String? = dRow["resolution"]
            let resolution = resolutionJSON.flatMap {
                try? JSONDecoder().decode(DisputeResolution.self, from: Data($0.utf8))
            }
            disputes[field] = FieldDispute(
                field: field, reason: reason, competingSources: competing,
                detectedAt: detectedAt, resolution: resolution
            )
        }

        return Profile(
            id: id,
            externalIDs: externalIDs,
            firstName: row["first_name"],
            lastName: row["last_name"],
            gender: gender,
            birthDate: birthDate,
            birthLocation: row["birth_location"],
            deathDate: deathDate,
            deathLocation: row["death_location"],
            bio: row["bio"],
            sources: sources,
            disputes: disputes
        )
    }

    private static func dateFromRow(_ row: Row, prefix: String) -> GenealogicalDate? {
        guard let original: String = row["\(prefix)_original"] else { return nil }
        let earliest: Int? = row["\(prefix)_earliest"]
        let latest: Int? = row["\(prefix)_latest"]
        let qualifierStr: String? = row["\(prefix)_qualifier"]
        let qualifier = qualifierStr.flatMap { DateQualifier(rawValue: $0) } ?? .yearOnly
        let isApproximate = qualifier != .exact && qualifier != .yearOnly
        return GenealogicalDate(
            original: original, earliest: earliest, latest: latest,
            isApproximate: isApproximate, qualifier: qualifier
        )
    }

    private static func relationshipFromRow(_ row: Row) -> Relationship {
        let marriageDate = dateFromRow(row, prefix: "marriage_date")
        let divorceDate = dateFromRow(row, prefix: "divorce_date")
        let typeStr: String = row["type"]
        let roleStr: String? = row["role"]
        let subtypeStr: String = row["subtype"]

        return Relationship(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            from: row["from_id"],
            to: row["to_id"],
            type: RelationshipType(rawValue: typeStr) ?? .parent,
            role: roleStr.flatMap { ParentRole(rawValue: $0) },
            subtype: RelationshipSubtype(rawValue: subtypeStr) ?? .unknown,
            marriageDate: marriageDate,
            divorceDate: divorceDate
        )
    }

    // MARK: - Project Metadata

    func saveProjectMeta(_ project: Project) throws {
        try dbQueue.write { db in
            let sourceKind: String
            let sourceValue: String
            switch project.source {
            case .gedcom(let path):
                sourceKind = "gedcom"
                sourceValue = path
            case .wikitree(let email):
                sourceKind = "wikitree"
                sourceValue = email
            }

            try db.execute(sql: """
                INSERT OR REPLACE INTO project_meta (id, name, source_kind, source_value, created_at, last_refreshed)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    project.id.uuidString, project.name, sourceKind, sourceValue,
                    project.createdAt, project.lastRefreshed
                ])
        }
    }

    func loadProjectMeta() throws -> Project? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM project_meta LIMIT 1") else {
                return nil
            }
            let sourceKind: String = row["source_kind"]
            let sourceValue: String = row["source_value"]
            let source: DataSource = sourceKind == "gedcom"
                ? .gedcom(path: sourceValue)
                : .wikitree(email: sourceValue)

            return Project(
                id: UUID(uuidString: row["id"]) ?? UUID(),
                name: row["name"],
                source: source,
                createdAt: row["created_at"],
                lastRefreshed: row["last_refreshed"]
            )
        }
    }

    // MARK: - Import (write snapshot to database)

    /// Import a parsed GEDCOM snapshot into the database.
    /// Creates a single Transaction (.importGEDCOM) and writes all profiles,
    /// relationships, and field_sources in one SQLite transaction.
    func importSnapshot(
        _ snapshot: FamilyGraphSnapshot,
        source path: String
    ) throws -> Transaction {
        let transaction = Transaction(
            id: UUID(),
            kind: .importGEDCOM(path: path),
            undoStrategy: .structural,
            startedAt: Date(),
            completedAt: Date(),
            changeCount: 0,
            profileCount: snapshot.profiles.count
        )

        try dbQueue.write { db in
            // Write transaction record
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt,
                    transaction.completedAt,
                    transaction.changeCount,
                    transaction.profileCount,
                ])

            // Write profiles
            for (_, profile) in snapshot.profiles {
                try Self.insertProfile(profile, transactionID: transaction.id, db: db)
            }

            // Write relationships
            for rel in snapshot.relationships {
                try Self.insertRelationship(rel, transactionID: transaction.id, db: db)
            }

            // Write field_sources
            for (_, profile) in snapshot.profiles {
                for (field, sources) in profile.sources {
                    for source in sources {
                        try db.execute(sql: """
                            INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at, created_by_transaction_id)
                            VALUES (?, 'profile', ?, ?, ?, ?, ?)
                            """, arguments: [
                                profile.id, field.rawValue, source.origin.identifier,
                                source.raw, source.addedAt, transaction.id.uuidString,
                            ])
                    }
                }
            }
        }

        return transaction
    }

    private static func insertProfile(_ profile: Profile, transactionID: UUID, db: Database) throws {
        let externalIDsJSON = (try? JSONEncoder().encode(profile.externalIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        try db.execute(sql: """
            INSERT INTO profiles (id, external_ids, first_name, last_name, gender,
                birth_date_original, birth_date_earliest, birth_date_latest, birth_date_qualifier,
                birth_location,
                death_date_original, death_date_earliest, death_date_latest, death_date_qualifier,
                death_location, bio, created_by_transaction_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                profile.id, externalIDsJSON, profile.firstName, profile.lastName,
                profile.gender?.rawValue,
                profile.birthDate?.original, profile.birthDate?.earliest, profile.birthDate?.latest,
                profile.birthDate?.qualifier.rawValue,
                profile.birthLocation,
                profile.deathDate?.original, profile.deathDate?.earliest, profile.deathDate?.latest,
                profile.deathDate?.qualifier.rawValue,
                profile.deathLocation, profile.bio, transactionID.uuidString,
            ])
    }

    private static func insertRelationship(_ rel: Relationship, transactionID: UUID, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO relationships (id, from_id, to_id, type, role, subtype,
                marriage_date_original, marriage_date_earliest, marriage_date_latest, marriage_date_qualifier,
                divorce_date_original, divorce_date_earliest, divorce_date_latest, divorce_date_qualifier,
                created_by_transaction_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                rel.id.uuidString, rel.from, rel.to, rel.type.rawValue,
                rel.role?.rawValue, rel.subtype.rawValue,
                rel.marriageDate?.original, rel.marriageDate?.earliest, rel.marriageDate?.latest,
                rel.marriageDate?.qualifier.rawValue,
                rel.divorceDate?.original, rel.divorceDate?.earliest, rel.divorceDate?.latest,
                rel.divorceDate?.qualifier.rawValue,
                transactionID.uuidString,
            ])
    }

    // MARK: - Transaction History

    /// Load transactions ordered by most recent first.
    func loadTransactions(limit: Int = 50) throws -> [Transaction] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM transactions ORDER BY completed_at DESC LIMIT ?
                """, arguments: [limit])
            return rows.compactMap { row in
                guard let kindJSON: String = row["kind"],
                      let kind = try? JSONDecoder().decode(TransactionKind.self, from: Data(kindJSON.utf8)),
                      let strategyStr: String = row["undo_strategy"],
                      let strategy = UndoStrategy(rawValue: strategyStr) else {
                    return nil
                }
                return Transaction(
                    id: UUID(uuidString: row["id"]) ?? UUID(),
                    kind: kind,
                    undoStrategy: strategy,
                    startedAt: row["started_at"],
                    completedAt: row["completed_at"],
                    changeCount: row["change_count"],
                    profileCount: row["profile_count"]
                )
            }
        }
    }

    // MARK: - JSON Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - GenealogicalDate internal init for database reconstruction

nonisolated extension GenealogicalDate {
    /// Internal init for reconstructing from database columns.
    init(original: String, earliest: Int?, latest: Int?,
         isApproximate: Bool, qualifier: DateQualifier) {
        self.original = original
        self.earliest = earliest
        self.latest = latest
        self.isApproximate = isApproximate
        self.qualifier = qualifier
    }
}
