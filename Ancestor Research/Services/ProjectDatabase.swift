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

        migrator.registerMigration("v2_research_tables") { db in
            // Records found during research
            try db.create(table: "research_records") { t in
                t.primaryKey("id", .text)
                t.column("profile_id", .text).notNull()
                t.column("source_id", .text).notNull()
                t.column("record_type", .text).notNull()
                t.column("verdict", .text).notNull()       // fact, lead, impossible
                t.column("summary", .text).notNull()
                t.column("raw_json", .text).notNull()       // full SourceRecord as JSON
                t.column("citation_full", .text)
                t.column("citation_short", .text)
                t.column("citation_url", .text)
                t.column("researched_at", .datetime).notNull()
            }

            // Record rejections — records the user rejected (remembered across restarts)
            try db.create(table: "record_rejections") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("profile_id", .text).notNull()
                t.column("record_id", .text).notNull()
                t.column("rejected_at", .datetime).notNull()
                t.uniqueKey(["profile_id", "record_id"])
            }

            // Name equivalences learned from user review
            try db.create(table: "name_equivalences") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("name_a", .text).notNull()
                t.column("name_b", .text).notNull()
                t.column("learned_at", .datetime).notNull()
                t.uniqueKey(["name_a", "name_b"])
            }

            // Negative searches — sources that returned no results
            try db.create(table: "negative_searches") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("profile_id", .text).notNull()
                t.column("source_id", .text).notNull()
                t.column("record_type", .text).notNull()
                t.column("searched_at", .datetime).notNull()
                t.column("search_params", .text)    // JSON of query params
            }

            // Research runs — history of pipeline executions
            try db.create(table: "research_runs") { t in
                t.primaryKey("id", .text)
                t.column("profile_id", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("completed_at", .datetime)
                t.column("fact_count", .integer).notNull().defaults(to: 0)
                t.column("lead_count", .integer).notNull().defaults(to: 0)
                t.column("cluster_count", .integer).notNull().defaults(to: 0)
                t.column("gps_score", .integer)
            }

            // Indices
            try db.create(index: "idx_research_records_profile", on: "research_records", columns: ["profile_id"])
            try db.create(index: "idx_record_rejections_profile", on: "record_rejections", columns: ["profile_id"])
            try db.create(index: "idx_negative_searches_profile", on: "negative_searches", columns: ["profile_id"])
            try db.create(index: "idx_research_runs_profile", on: "research_runs", columns: ["profile_id"])
        }

        migrator.registerMigration("v3_leads") { db in
            try db.create(table: "leads") { t in
                t.primaryKey("id", .text)
                t.column("profile_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("surname", .text)
                t.column("given_name", .text)
                t.column("birth_year", .integer)
                t.column("death_year", .integer)
                t.column("relationship", .text)
                t.column("source", .text).notNull()
                t.column("status", .text).notNull()
                t.column("evidence", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("investigated_at", .datetime)
                t.column("resolved_at", .datetime)
                t.column("resolution", .text)
            }
            try db.create(index: "idx_leads_profile", on: "leads", columns: ["profile_id"])
            try db.create(index: "idx_leads_status", on: "leads", columns: ["status"])
        }

        migrator.registerMigration("v4_scored_records_discrepancies_pending") { db in
            // Scored records — full 4-gate results persisted per research run
            try db.create(table: "scored_records") { t in
                t.primaryKey("id", .text)
                t.column("profile_id", .text).notNull()
                t.column("source_record_id", .text).notNull()
                t.column("verdict", .text).notNull()
                t.column("gate_name", .text)
                t.column("gate_date", .text)
                t.column("gate_geography", .text)
                t.column("gate_family", .text)
                t.column("summary", .text).notNull()
                t.column("scored_at", .datetime).notNull()
            }

            // Research discrepancies — conflicts between sources and tree
            try db.create(table: "research_discrepancies") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("profile_id", .text).notNull()
                t.column("field", .text).notNull()
                t.column("existing_value", .text).notNull()
                t.column("source_value", .text).notNull()
                t.column("source_id", .text).notNull()
                t.column("severity", .text).notNull()
                t.column("reasoning", .text).notNull()
                t.column("resolution_status", .text).notNull().defaults(to: "unresolved")
                t.column("detected_at", .datetime).notNull()
            }

            // Pending facts — facts awaiting user review before tree commit
            try db.create(table: "pending_facts") { t in
                t.primaryKey("id", .text)
                t.column("profile_id", .text).notNull()
                t.column("fact_kind", .text).notNull()    // birth_year, death_year, etc.
                t.column("value_json", .text).notNull()    // The proposed value
                t.column("sources_json", .text).notNull()  // Supporting source citations
                t.column("review_status", .text).notNull().defaults(to: "pending")
                t.column("created_at", .datetime).notNull()
                t.column("reviewed_at", .datetime)
            }

            try db.create(index: "idx_scored_records_profile", on: "scored_records", columns: ["profile_id"])
            try db.create(index: "idx_discrepancies_profile", on: "research_discrepancies", columns: ["profile_id"])
            try db.create(index: "idx_pending_facts_profile", on: "pending_facts", columns: ["profile_id"])
        }

        migrator.registerMigration("v5_field_researcher") { db in
            // Narrative findings — unstructured biographical evidence
            try db.create(table: "narrative_findings") { t in
                t.primaryKey("id", .text)
                t.column("profile_id", .text).notNull()
                t.column("category", .text).notNull()
                t.column("description", .text).notNull()
                t.column("date_or_period", .text)
                t.column("source_url", .text).notNull()
                t.column("source_title", .text).notNull()
                t.column("evidence_text", .text).notNull()
                t.column("reasoning", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("verification_status", .text).notNull().defaults(to: "pending")
                t.column("submitted_at", .datetime).notNull()
            }

            // Page cache — cached source pages for provenance (Rule 2)
            try db.create(table: "page_cache") { t in
                t.primaryKey("url_hash", .text)   // SHA256 of URL
                t.column("url", .text).notNull()
                t.column("content_hash", .text).notNull()
                t.column("fetched_at", .datetime).notNull()
                t.column("content_length", .integer).notNull()
                // Actual page data stored as files in Application Support, keyed by url_hash
            }

            // Field researcher sessions — cost tracking (§10)
            try db.create(table: "field_researcher_sessions") { t in
                t.primaryKey("id", .text)
                t.column("profile_id", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("completed_at", .datetime)
                t.column("tokens_input", .integer).notNull().defaults(to: 0)
                t.column("tokens_output", .integer).notNull().defaults(to: 0)
                t.column("estimated_cost", .double).notNull().defaults(to: 0)
                t.column("findings_submitted", .integer).notNull().defaults(to: 0)
                t.column("findings_accepted", .integer).notNull().defaults(to: 0)
            }

            // Add verification columns to pending_facts
            try db.alter(table: "pending_facts") { t in
                t.add(column: "source_url", .text)
                t.add(column: "source_title", .text)
                t.add(column: "evidence_text", .text)
                t.add(column: "reasoning", .text)
                t.add(column: "agent_id", .text)
                t.add(column: "verification_status", .text).defaults(to: "pending")
                t.add(column: "source_trust_tier", .text)
                t.add(column: "source_directness", .text)
            }

            try db.create(index: "idx_narrative_findings_profile", on: "narrative_findings", columns: ["profile_id"])
            try db.create(index: "idx_fr_sessions_profile", on: "field_researcher_sessions", columns: ["profile_id"])
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

    // MARK: - Undo

    /// Structural undo: delete all entities created by a transaction (import undo).
    func undoStructural(transactionID: UUID) throws {
        try dbQueue.write { db in
            let txID = transactionID.uuidString
            try db.execute(sql: "DELETE FROM field_sources WHERE created_by_transaction_id = ?", arguments: [txID])
            try db.execute(sql: "DELETE FROM field_disputes WHERE created_by_transaction_id = ?", arguments: [txID])
            try db.execute(sql: "DELETE FROM relationships WHERE created_by_transaction_id = ?", arguments: [txID])
            try db.execute(sql: "DELETE FROM profiles WHERE created_by_transaction_id = ?", arguments: [txID])
        }
    }

    /// Replay undo: reverse each FieldChange for a transaction.
    func undoReplay(transactionID: UUID) throws {
        try dbQueue.write { db in
            let txID = transactionID.uuidString
            let changes = try Row.fetchAll(db, sql: """
                SELECT * FROM field_changes WHERE transaction_id = ? ORDER BY rowid DESC
                """, arguments: [txID])

            for row in changes {
                let entityID: String = row["entity_id"]
                let entityKind: String = row["entity_kind"]
                let field: String = row["field"]
                let oldValue: String? = row["old_value"]

                if entityKind == "profile" {
                    // Map field name back to column
                    let column = Self.profileFieldToColumn(field)
                    if let column {
                        if let oldVal = oldValue {
                            try db.execute(
                                sql: "UPDATE profiles SET \(column) = ? WHERE id = ?",
                                arguments: [oldVal, entityID]
                            )
                        } else {
                            try db.execute(
                                sql: "UPDATE profiles SET \(column) = NULL WHERE id = ?",
                                arguments: [entityID]
                            )
                        }
                    }
                }
                // Relationship field undo would go here
            }

            // Remove the field_changes for this transaction
            try db.execute(sql: "DELETE FROM field_changes WHERE transaction_id = ?", arguments: [txID])
            // Remove field_sources added by this transaction
            try db.execute(sql: "DELETE FROM field_sources WHERE created_by_transaction_id = ?", arguments: [txID])
            // Restore disputes removed by this transaction
            try db.execute(sql: "DELETE FROM field_disputes WHERE created_by_transaction_id = ?", arguments: [txID])
        }
    }

    /// Save a transaction record.
    func saveTransaction(_ tx: Transaction) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    tx.id.uuidString,
                    Self.encodeJSON(tx.kind),
                    tx.undoStrategy.rawValue,
                    tx.startedAt, tx.completedAt,
                    tx.changeCount, tx.profileCount,
                ])
        }
    }

    private static func profileFieldToColumn(_ field: String) -> String? {
        switch field {
        case "firstName": "first_name"
        case "lastName": "last_name"
        case "gender": "gender"
        case "birthLocation": "birth_location"
        case "deathLocation": "death_location"
        case "bio": "bio"
        // Date fields need special handling (original + earliest + latest + qualifier)
        // For now, simple string fields only
        default: nil
        }
    }

    // MARK: - JSON Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - GenealogicalDate internal init for database reconstruction

// MARK: - Research Persistence

nonisolated extension ProjectDatabase {

    /// Save a research run record.
    func saveResearchRun(
        id: UUID, profileID: String, mode: ResearchMode,
        startedAt: Date, completedAt: Date,
        factCount: Int, leadCount: Int, clusterCount: Int, gpsScore: Int?
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO research_runs
                (id, profile_id, mode, started_at, completed_at, fact_count, lead_count, cluster_count, gps_score)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id.uuidString, profileID, mode.rawValue,
                    startedAt, completedAt,
                    factCount, leadCount, clusterCount, gpsScore
                ])
        }
    }

    /// Load research history for a profile.
    func loadResearchRuns(profileID: String) throws -> [(id: UUID, mode: String, date: Date, facts: Int, leads: Int, clusters: Int, gps: Int?)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM research_runs WHERE profile_id = ? ORDER BY completed_at DESC
                """, arguments: [profileID])
            return rows.map { row in
                (
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    mode: row["mode"] as String,
                    date: row["completed_at"] as Date,
                    facts: row["fact_count"] as Int,
                    leads: row["lead_count"] as Int,
                    clusters: row["cluster_count"] as Int,
                    gps: row["gps_score"] as Int?
                )
            }
        }
    }

    /// Save a rejected record ID for a profile.
    func saveRejection(profileID: String, recordID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO record_rejections (profile_id, record_id, rejected_at)
                VALUES (?, ?, ?)
                """, arguments: [profileID, recordID, Date()])
        }
    }

    /// Load rejected record IDs for a profile.
    func loadRejections(profileID: String) throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT record_id FROM record_rejections WHERE profile_id = ?
                """, arguments: [profileID])
            return Set(rows.map { $0["record_id"] as String })
        }
    }

    /// Save a name equivalence learned during review.
    func saveNameEquivalence(nameA: String, nameB: String) throws {
        let a = nameA.uppercased()
        let b = nameB.uppercased()
        let (first, second) = a < b ? (a, b) : (b, a)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO name_equivalences (name_a, name_b, learned_at)
                VALUES (?, ?, ?)
                """, arguments: [first, second, Date()])
        }
    }

    /// Load all learned name equivalences.
    func loadNameEquivalences() throws -> [(String, String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name_a, name_b FROM name_equivalences")
            return rows.map { ($0["name_a"] as String, $0["name_b"] as String) }
        }
    }

    /// Record a negative search (source returned no results).
    func saveNegativeSearch(profileID: String, sourceID: String, recordType: String, params: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO negative_searches (profile_id, source_id, record_type, searched_at, search_params)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [profileID, sourceID, recordType, Date(), params])
        }
    }

    /// Load negative searches for a profile.
    func loadNegativeSearches(profileID: String) throws -> [(sourceID: String, recordType: String, date: Date)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_id, record_type, searched_at FROM negative_searches
                WHERE profile_id = ? ORDER BY searched_at DESC
                """, arguments: [profileID])
            return rows.map {
                (sourceID: $0["source_id"] as String,
                 recordType: $0["record_type"] as String,
                 date: $0["searched_at"] as Date)
            }
        }
    }
}

// MARK: - Pending Facts

nonisolated extension ProjectDatabase {

    func loadPendingFacts(profileID: String) throws -> [[String: Any]] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_facts WHERE profile_id = ? AND review_status = 'pending'
                ORDER BY created_at DESC
                """, arguments: [profileID])
            return rows.map { row in
                var dict: [String: Any] = [:]
                for column in row.columnNames {
                    dict[column] = row[column] as Any
                }
                return dict
            }
        }
    }

    func loadCitedURLs(profileID: String) throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT source_url FROM pending_facts
                WHERE profile_id = ? AND source_url IS NOT NULL
                """, arguments: [profileID])
            return Set(rows.compactMap { $0["source_url"] as String? })
        }
    }

    func updatePendingFactStatus(id: String, status: String, verificationStatus: String? = nil) throws {
        try dbQueue.write { db in
            if let vs = verificationStatus {
                try db.execute(
                    sql: "UPDATE pending_facts SET review_status = ?, verification_status = ? WHERE id = ?",
                    arguments: [status, vs, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE pending_facts SET review_status = ? WHERE id = ?",
                    arguments: [status, id]
                )
            }
        }
    }

    func saveNarrativeFinding(_ finding: NarrativeFinding) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO narrative_findings
                (id, profile_id, category, description, date_or_period,
                 source_url, source_title, evidence_text, reasoning,
                 agent_id, verification_status, submitted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    finding.id, finding.profileID, finding.category,
                    finding.description, finding.dateOrPeriod,
                    finding.sourceURL, finding.sourceTitle,
                    String(finding.evidenceText.prefix(200)),
                    finding.reasoning, finding.agentID,
                    finding.verificationStatus.rawValue, finding.submittedAt,
                ])
        }
    }
}

// MARK: - Lead Persistence

nonisolated extension ProjectDatabase {

    func saveLead(_ lead: Lead) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO leads
                (id, profile_id, name, surname, given_name, birth_year, death_year,
                 relationship, source, status, evidence, created_at, investigated_at, resolved_at, resolution)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    lead.id, lead.profileID, lead.name, lead.surname, lead.givenName,
                    lead.birthYear, lead.deathYear, lead.relationship,
                    lead.source.rawValue, lead.status.rawValue, lead.evidence,
                    lead.createdAt, lead.investigatedAt, lead.resolvedAt, lead.resolution?.rawValue
                ])
        }
    }

    func loadLeads() throws -> [Lead] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM leads ORDER BY created_at DESC")
            return rows.compactMap { row -> Lead? in
                guard let source = LeadSource(rawValue: row["source"] as String),
                      let status = LeadStatus(rawValue: row["status"] as String) else { return nil }
                return Lead(
                    id: row["id"],
                    profileID: row["profile_id"],
                    name: row["name"],
                    surname: row["surname"],
                    givenName: row["given_name"],
                    birthYear: row["birth_year"],
                    deathYear: row["death_year"],
                    relationship: row["relationship"],
                    source: source,
                    status: status,
                    evidence: row["evidence"],
                    createdAt: row["created_at"],
                    investigatedAt: row["investigated_at"],
                    resolvedAt: row["resolved_at"],
                    resolution: (row["resolution"] as String?).flatMap { LeadResolution(rawValue: $0) }
                )
            }
        }
    }

    func loadLeads(profileID: String) throws -> [Lead] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM leads WHERE profile_id = ? ORDER BY created_at DESC", arguments: [profileID])
            return rows.compactMap { row -> Lead? in
                guard let source = LeadSource(rawValue: row["source"] as String),
                      let status = LeadStatus(rawValue: row["status"] as String) else { return nil }
                return Lead(
                    id: row["id"], profileID: row["profile_id"],
                    name: row["name"], surname: row["surname"], givenName: row["given_name"],
                    birthYear: row["birth_year"], deathYear: row["death_year"],
                    relationship: row["relationship"], source: source, status: status,
                    evidence: row["evidence"], createdAt: row["created_at"],
                    investigatedAt: row["investigated_at"], resolvedAt: row["resolved_at"],
                    resolution: (row["resolution"] as String?).flatMap { LeadResolution(rawValue: $0) }
                )
            }
        }
    }
}

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
