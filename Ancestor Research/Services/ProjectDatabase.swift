import Foundation
import GRDB
import os

/// GRDB database wrapper for a single project.
/// Each project is one SQLite file in Application Support.
nonisolated final class ProjectDatabase: Sendable {
    let dbQueue: DatabaseQueue

    init(path: String, enableWAL: Bool = true) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        // Enable WAL mode so multiple processes (the app + the
        // FieldResearcherMCP server during eval-harness runs) can
        // read while the watcher writes, instead of blocking each
        // other on SQLite's default file-level lock. WAL is a
        // persistent file-level mode — once set the file stays in
        // WAL until explicitly flipped, so callers that only need
        // a momentary metadata read (e.g. ProjectStore.listProjects
        // scanning 2000+ files) pass enableWAL: false to skip the
        // write transaction. Switching journal mode while another
        // connection holds the file would fail with SQLITE_BUSY;
        // catch that and continue — DELETE-mode still works, the
        // harness-driven concurrent-read scenario just degrades.
        if enableWAL {
            do {
                try dbQueue.write { db in
                    try db.execute(sql: "PRAGMA journal_mode = WAL")
                }
            } catch {
                // Soft-fail: leave the file in its current journal
                // mode. Logged at warning level by callers that care
                // about parity.
            }
        }
        try migrate()
    }

    /// Run all migrations to bring the schema up to date.
    private func migrate() throws {
        try Self.makeMigrator().migrate(dbQueue)
    }

    /// The full migration chain, v1…v36. Static (no instance state) so tests
    /// can drive the migrator directly — e.g. migrate a scratch DB
    /// `upTo:` a given version, seed legacy-shaped rows, then complete the
    /// chain to exercise a data migration in isolation.
    static func makeMigrator() -> DatabaseMigrator {
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

        // MARK: v6 — Manual entry support
        migrator.registerMigration("v6_manual_entry") { db in
            // Project metadata: home person anchor
            try db.alter(table: "project_meta") { t in
                t.add(column: "home_person_id", .text)
            }

            // Profiles: person attributes (JSON), soft delete flag
            try db.alter(table: "profiles") { t in
                t.add(column: "attributes", .text)          // JSON-encoded PersonAttributes
                t.add(column: "is_deleted", .integer).notNull().defaults(to: 0)
            }

            // Relationships: marriage location
            try db.alter(table: "relationships") { t in
                t.add(column: "marriage_location", .text)
            }
        }

        // MARK: v7 — Research Workbench tables
        // All workbench tables added in one migration so subsequent W sub-phases
        // (W3 Focus, W4 Sessions, W5 Hypotheses, etc.) need no further schema work.
        // FTS5 is set up for workbench_notes via triggers — search lights up
        // when W6 ships.
        migrator.registerMigration("v7_workbench") { db in
            try db.create(table: "focus_sets") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
                t.column("profile_ids", .text).notNull()       // JSON array
                t.column("created_at", .datetime).notNull()
                t.column("last_active_at", .datetime).notNull()
            }

            try db.create(table: "open_questions") { t in
                t.column("id", .text).primaryKey()
                t.column("text", .text).notNull()
                t.column("profile_ids", .text).notNull()       // JSON array
                t.column("priority", .text).notNull()
                t.column("status", .text).notNull()
                t.column("tried_sources", .text)
                t.column("promoted_from", .text)               // JSON-encoded QuestionOrigin
                t.column("created_at", .datetime).notNull()
                t.column("resolved_at", .datetime)
                t.column("resolution", .text)
            }
            try db.create(index: "idx_open_questions_status",
                          on: "open_questions", columns: ["status"])

            try db.create(table: "hypotheses") { t in
                t.column("id", .text).primaryKey()
                t.column("claim", .text).notNull()             // JSON-encoded HypothesisClaim
                t.column("confidence", .text).notNull()
                t.column("reasoning", .text).notNull()
                t.column("supporting_evidence", .text).notNull()  // JSON array
                t.column("contradicting_evidence", .text).notNull() // JSON array
                t.column("status", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("resolved_at", .datetime)
                t.column("dismissal_reason", .text)
            }
            try db.create(index: "idx_hypotheses_status",
                          on: "hypotheses", columns: ["status"])

            try db.create(table: "workbench_notes") { t in
                t.column("id", .text).primaryKey()
                t.column("content", .text).notNull()
                t.column("tag", .text).notNull()
                t.column("attached_to", .text).notNull()       // JSON-encoded NoteAttachment
                t.column("attachment_kind", .text).notNull()   // discriminator for fast filtering
                t.column("attachment_id", .text)               // profile id / relationship id / etc.
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_workbench_notes_attachment",
                          on: "workbench_notes",
                          columns: ["attachment_kind", "attachment_id"])

            // FTS5 contentless index keyed on workbench_notes.id, kept in sync
            // by triggers. Contentless avoids storing the text twice.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE workbench_notes_fts USING fts5(
                    content,
                    content='workbench_notes',
                    content_rowid='rowid'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER workbench_notes_ai AFTER INSERT ON workbench_notes BEGIN
                    INSERT INTO workbench_notes_fts(rowid, content) VALUES (new.rowid, new.content);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER workbench_notes_ad AFTER DELETE ON workbench_notes BEGIN
                    INSERT INTO workbench_notes_fts(workbench_notes_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER workbench_notes_au AFTER UPDATE ON workbench_notes BEGIN
                    INSERT INTO workbench_notes_fts(workbench_notes_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
                    INSERT INTO workbench_notes_fts(rowid, content) VALUES (new.rowid, new.content);
                END
                """)

            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("focus_set_id", .text)
                t.column("profiles_added", .integer).notNull().defaults(to: 0)
                t.column("profiles_edited", .integer).notNull().defaults(to: 0)
                t.column("disputes_resolved", .integer).notNull().defaults(to: 0)
                t.column("hypotheses_created", .integer).notNull().defaults(to: 0)
                t.column("hypotheses_promoted", .integer).notNull().defaults(to: 0)
                t.column("questions_created", .integer).notNull().defaults(to: 0)
                t.column("questions_resolved", .integer).notNull().defaults(to: 0)
                t.column("notes_created", .integer).notNull().defaults(to: 0)
                t.column("transaction_ids", .text).notNull()   // JSON array
            }
            // M13 — research_goals is created by migration v10
            // (`v10_attachments_goals`) with the correct `question_ids_json`
            // / `hypothesis_ids_json` columns the CRUD layer expects.
        }

        // MARK: v8 — Citations + Evidence Quality on field_sources
        // Per DESIGN.md §5.12. JSON-encoded Citation goes in `citation_json`;
        // EvidenceQuality (small enum) is stored as integer for cheap reads.
        // Both nullable — most existing field_sources will stay null.
        migrator.registerMigration("v8_citations") { db in
            try db.alter(table: "field_sources") { t in
                t.add(column: "citation_json", .text)
                t.add(column: "evidence_quality", .integer)
            }
        }

        // MARK: v9 — Life events + FactConfidence (M12)
        // Adds the `life_events` table and `fact_confidence` column on
        // `field_sources`. Per DESIGN.md §5.13 + §5.14.
        migrator.registerMigration("v9_life_events") { db in
            try db.alter(table: "field_sources") { t in
                t.add(column: "fact_confidence", .integer)  // 0=tentative,1=standard,2=wellEvidenced; null = unset
            }

            try db.create(table: "life_events") { t in
                t.column("id", .text).primaryKey()
                t.column("profile_id", .text).notNull()
                t.column("type", .text).notNull()
                t.column("date_original", .text)
                t.column("date_earliest", .integer)
                t.column("date_latest", .integer)
                t.column("date_qualifier", .text)
                t.column("date_approximate", .integer)      // 0/1
                t.column("end_date_original", .text)
                t.column("end_date_earliest", .integer)
                t.column("end_date_latest", .integer)
                t.column("end_date_qualifier", .text)
                t.column("end_date_approximate", .integer)  // 0/1
                t.column("location", .text)
                t.column("description", .text)
                t.column("sources_json", .text).notNull()   // JSON array of FieldSource
                t.column("confidence", .integer).notNull().defaults(to: 1)  // FactConfidence rawInt
                t.column("created_by_transaction_id", .text)
            }
            try db.create(index: "idx_life_events_profile",
                          on: "life_events", columns: ["profile_id"])
        }

        // MARK: v10 — Attachments + Research Goals (M13)
        // Per DESIGN.md §5.15 + §5.16. Attachments store metadata; the
        // actual files live in the project's media directory on disk.
        migrator.registerMigration("v10_attachments_goals") { db in
            // `ifNotExists` is defensive: some pre-v10 builds shipped an
            // earlier (now-removed) migration that already created
            // `research_goals` directly, so opening one of those projects
            // with the current schema tripped a "table already exists"
            // error on every launch — leaving the project unopenable from
            // the picker forever. Both CREATEs are no-ops when the table
            // is already present, which is the correct outcome.
            try db.create(table: "attachments", options: .ifNotExists) { t in
                t.column("id", .text).primaryKey()
                t.column("filename", .text).notNull()
                t.column("media_type", .text).notNull()         // photo / document / transcription
                t.column("caption", .text)
                t.column("date_taken", .datetime)
                t.column("location_taken", .text)
                t.column("relative_path", .text).notNull()      // Relative to project media dir
                t.column("target_kind", .text).notNull()        // profile / lifeEvent / fieldSource
                t.column("target_primary_id", .text).notNull()  // profileID / lifeEventUUID / "entityID:field"
                t.column("target_json", .text).notNull()        // Full encoded AttachmentTarget
                t.column("added_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_attachments_target",
                on: "attachments",
                columns: ["target_kind", "target_primary_id"],
                options: .ifNotExists
            )

            try db.create(table: "research_goals", options: .ifNotExists) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("description", .text)
                t.column("status", .text).notNull()             // active/paused/completed/abandoned
                t.column("progress", .integer).notNull().defaults(to: 0)
                t.column("question_ids_json", .text).notNull()  // JSON [UUID]
                t.column("hypothesis_ids_json", .text).notNull()
                t.column("focus_set_id", .text)                 // nullable FK reference
                t.column("created_at", .datetime).notNull()
                t.column("completed_at", .datetime)
            }
        }

        // MARK: v11 — Sensitive flag (M14)
        // Per DESIGN.md §7.15.2. Adds `sensitive` column to workbench_notes
        // and life_events so users can mark items for exclusion from shared
        // exports. Defaults to 0 (not sensitive) so existing rows are unaffected.
        migrator.registerMigration("v11_sensitive_flag") { db in
            try db.alter(table: "workbench_notes") { t in
                t.add(column: "sensitive", .integer).notNull().defaults(to: 0)
            }
            try db.alter(table: "life_events") { t in
                t.add(column: "sensitive", .integer).notNull().defaults(to: 0)
            }
        }

        // MARK: v12 — Audit rule overrides (M18)
        // Per DESIGN.md §13. Per-project storage of user-toggled rules,
        // user-tuned thresholds, and per-profile snooze. Scope distinguishes
        // global (rule-wide) overrides from profile-scoped (snooze-this-rule-
        // for-this-person) overrides.
        migrator.registerMigration("v12_audit_rule_overrides") { db in
            try db.create(table: "audit_rule_overrides") { t in
                t.column("id", .text).primaryKey()
                t.column("rule_id", .text).notNull()
                t.column("scope_kind", .text).notNull()    // 'global' | 'profile'
                t.column("scope_profile_id", .text)        // nil for global
                t.column("enabled", .integer).notNull().defaults(to: 1)
                t.column("snoozed_until", .datetime)
                t.column("thresholds_json", .text).notNull().defaults(to: "{}")
            }
            try db.create(index: "idx_audit_rule_overrides_lookup",
                          on: "audit_rule_overrides",
                          columns: ["rule_id", "scope_kind", "scope_profile_id"])
        }

        // Evidence records — full SourceRecord JSON per profile, so the raw detail
        // from every source response is preserved rather than thrown away after a
        // research run. Primary key is composite (profile_id + source_record_id)
        // via row-id PK + uniqueKey so INSERT OR REPLACE updates in place if the
        // same source returns an updated row (overwrite-latest semantics).
        migrator.registerMigration("v13_evidence_records") { db in
            try db.create(table: "evidence_records") { t in
                t.primaryKey("id", .text)             // "<profile_id>|<source_record_id>"
                t.column("profile_id", .text).notNull()
                t.column("source_id", .text).notNull()
                t.column("source_record_id", .text).notNull()
                t.column("record_type", .text).notNull()
                t.column("verdict", .text).notNull()
                t.column("record_json", .text).notNull()   // JSON-encoded SourceRecord
                t.column("citation_full", .text)
                t.column("citation_url", .text)
                t.column("scored_at", .datetime).notNull()
            }
            try db.create(index: "idx_evidence_records_profile",
                          on: "evidence_records",
                          columns: ["profile_id"])
            try db.create(index: "idx_evidence_records_source",
                          on: "evidence_records",
                          columns: ["source_id"])
        }

        // Structured location identifiers chosen via the LocationPicker
        // gazetteer typeahead. Travels alongside the freeform display strings
        // (birth_location, death_location), letting future features like
        // hierarchical research scope (parish → district → county → national)
        // resolve the place precisely without re-parsing the display string.
        migrator.registerMigration("v14_location_codes") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "birth_location_code", .text)
                t.add(column: "death_location_code", .text)
            }
        }

        // Mirror v14's structured-code columns on the other tables that carry
        // location strings — marriage location on relationships, event location
        // on life_events. Same gazetteer-derived ID scheme.
        migrator.registerMigration("v15_marriage_event_location_codes") { db in
            try db.alter(table: "relationships") { t in
                t.add(column: "marriage_location_code", .text)
            }
            try db.alter(table: "life_events") { t in
                t.add(column: "location_code", .text)
            }
        }

        // Task #41 — record-level user-review status on every evidence row.
        // Previously, the user's only persisted decision lived in
        // `record_rejections` (append-only list). That couldn't express
        // "saved as a lead", couldn't be undone, and was decoupled from the
        // evidence itself. Folding the status onto `evidence_records` makes
        // it mutable per-record and survives re-runs (`saveEvidence` is now
        // careful to preserve user_status across INSERT-OR-REPLACE).
        //
        // States:
        //   "unreviewed" — default; cluster review hasn't been done yet.
        //   "saved_as_lead" — user wants to keep investigating; also creates
        //                     a Lead row pointing at this evidence.
        //   "discarded" — user explicitly rejected; suppressed from future
        //                 cluster review and from proposed-relative lists.
        migrator.registerMigration("v16_evidence_user_status") { db in
            try db.alter(table: "evidence_records") { t in
                t.add(column: "user_status", .text)
                    .notNull()
                    .defaults(to: "unreviewed")
            }
            try db.create(
                index: "idx_evidence_records_user_status",
                on: "evidence_records",
                columns: ["profile_id", "user_status"]
            )
        }

        // Task #47 — optional middle-name column on profiles. Legacy rows
        // continue to carry the full given-name string in `first_name`; the
        // new column is just additive. `Profile.displayName` joins first +
        // middle + last so both shapes render identically.
        migrator.registerMigration("v17_profile_middle_name") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "middle_name", .text)
            }
        }

        // Task #49 — close the two highest-frequency name gaps the audit
        // surfaced. `nick_name` carries the familiar / known-as form (used
        // for search match, not displayName). `mothers_maiden_name` mirrors
        // how FreeBMD birth indexes record the column post-Sep-1911 —
        // critical for disambiguating same-named children of different
        // mothers and as a marriage-search seed.
        migrator.registerMigration("v18_profile_nick_and_mothers_maiden") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "nick_name", .text)
                t.add(column: "mothers_maiden_name", .text)
            }
        }

        // Task #50 — typed payload for military / probate / burial / census
        // life events. JSON-encoded `LifeEventDetails` lives in `details_json`;
        // pre-v19 rows have NULL and continue rendering from `description`.
        migrator.registerMigration("v19_life_event_typed_details") { db in
            try db.alter(table: "life_events") { t in
                t.add(column: "details_json", .text)
            }
        }

        // Archive-not-delete for projects. NULL = active; non-NULL = archived
        // at that timestamp. Hard delete remains available but only from an
        // archived state (enforced in the picker, not the schema).
        migrator.registerMigration("v20_project_archived_at") { db in
            try db.alter(table: "project_meta") { t in
                t.add(column: "archived_at", .datetime)
            }
        }

        // RESEARCH_AXES_SPEC Change 1 — per-subject RegionConfig. NULL on
        // legacy projects; resolution goes through
        // Project.resolvedHomeChapmanCode (empty string = no region anchor —
        // there is no hardcoded county fallback). Derived at creation
        // from the home-person anchor's birth location once the gazetteer
        // ships (RESEARCH_AND_CLEANSE_SPEC Change 2).
        migrator.registerMigration("v21_project_home_chapman_code") { db in
            try db.alter(table: "project_meta") { t in
                t.add(column: "home_chapman_code", .text)
            }
        }

        // CLEANSE_WIZARD_SPEC — persistent "user marked this unresolvable"
        // flag, keyed by (profile_id, field). Lets the wizard skip findings
        // the user has actively dismissed (e.g. "Madeira (born at sea)" for
        // a birth location that genuinely can't be resolved). Field is a
        // free-form string so the same table covers location, date, and
        // future field types without further migrations.
        migrator.registerMigration("v22_cleanse_unresolvable_flags") { db in
            try db.create(table: "cleanse_unresolvable_flags") { t in
                t.column("profile_id", .text).notNull()
                t.column("field", .text).notNull()
                t.column("marked_at", .datetime).notNull()
                t.primaryKey(["profile_id", "field"])
            }
        }

        // Pending relationship proposals — the firewall analogue of
        // pending_facts but for edges (parent / spouse). Lets MCP callers
        // propose a relationship without writing directly to `relationships`;
        // the app reviews the queue and accepts / rejects exactly the way
        // it does for fact proposals. INSERT OR IGNORE on id makes the
        // submit idempotent.
        migrator.registerMigration("v23_pending_relationships") { db in
            try db.create(table: "pending_relationships") { t in
                t.column("id", .text).primaryKey()
                t.column("from_profile_id", .text).notNull()
                t.column("to_profile_id", .text).notNull()
                t.column("rel_type", .text).notNull()          // 'parent' | 'spouse'
                t.column("role", .text)                        // 'father' | 'mother' | 'unspecified' (parent only)
                t.column("subtype", .text).notNull().defaults(to: "biological")
                t.column("review_status", .text).notNull().defaults(to: "pending")
                t.column("created_at", .datetime).notNull()
                t.column("source_url", .text)
                t.column("source_title", .text)
                t.column("evidence_text", .text)
                t.column("reasoning", .text)
                t.column("agent_id", .text)
            }
            try db.create(index: "idx_pending_relationships_status",
                          on: "pending_relationships",
                          columns: ["review_status"])
        }

        // Research run requests — Tier 3 of the MCP coverage plan. External
        // callers (MCP) enqueue a research target here; the app's
        // RunRequestWatcher dequeues, fires the pipeline, and writes back
        // the resulting research_run id + status. Lifecycle:
        //   queued → running → completed (with run_id) | failed (with error)
        // The caller polls `ancestor://run_status/{id}` to monitor.
        migrator.registerMigration("v24_research_run_requests") { db in
            try db.create(table: "research_run_requests") { t in
                t.column("id", .text).primaryKey()
                t.column("profile_id", .text)              // nil ⇒ lead-based request
                t.column("lead_id", .text)                 // nil ⇒ profile-based request
                t.column("mode", .text).notNull().defaults(to: "extend")
                t.column("scope", .text).notNull().defaults(to: "county")
                t.column("status", .text).notNull().defaults(to: "queued")
                t.column("run_id", .text)                  // populated when complete
                t.column("error", .text)                   // populated on failure
                t.column("created_at", .datetime).notNull()
                t.column("started_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("requested_by", .text)            // agent id / 'mcp' / etc.
            }
            try db.create(index: "idx_research_run_requests_status",
                          on: "research_run_requests",
                          columns: ["status"])
        }

        // Auto-accept flag on research_run_requests. Off-by-default; only
        // honoured by the watcher when the AUTOMATION_AUTO_ACCEPT build
        // flag is set (Debug builds only — release builds physically lack
        // the auto-accept code path). Values:
        //   'none'      — manual review as today (default)
        //   'confirmed' — auto-promote .confirmed proposed relatives during
        //                 the run, skipping the human-click step. Used by
        //                 recursive tree build-out scripts to avoid the
        //                 promote-each-proposal bottleneck.
        migrator.registerMigration("v25_run_request_auto_accept") { db in
            try db.alter(table: "research_run_requests") { t in
                t.add(column: "auto_accept", .text).notNull().defaults(to: "none")
            }
        }

        // MARK: v26 — ResearchHypothesis persistence
        // Pipeline-generated, deterministic, testable claims. Distinct from
        // the v7 `hypotheses` table (workbench, user-authored). Re-runs of
        // the pipeline upsert keyed on `id`; user-rejection persists via the
        // `user_rejected` flag. The `attempts` column tracks expansiveness
        // ladder progress for T7 / §5.11 deficit-query dispatch.
        // See AncestorApp/RESEARCH_PIPELINE_V2_SPEC.md Part II §4.3.
        migrator.registerMigration("v26_research_hypotheses") { db in
            try db.create(table: "research_hypotheses") { t in
                t.column("id", .text).primaryKey()
                t.column("subject_profile_id", .text)
                    .references("profiles", onDelete: .cascade)
                t.column("kind_discriminator", .text).notNull()
                t.column("kind_payload", .text).notNull()          // JSON
                t.column("verdict", .text).notNull()
                t.column("is_model_assisted", .integer).notNull().defaults(to: 0)
                t.column("supporting_evidence", .text).notNull()   // JSON array
                t.column("contradicting_evidence", .text).notNull()// JSON array
                t.column("reasoning", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("last_tested_at", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("history", .text).notNull()               // JSON array of VerdictTransition
                t.column("user_rejected", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_research_hypotheses_subject",
                          on: "research_hypotheses",
                          columns: ["subject_profile_id"])
            try db.create(index: "idx_research_hypotheses_verdict",
                          on: "research_hypotheses",
                          columns: ["verdict"])
        }

        // MARK: v27 — Married surname for women whose tree surname is maiden
        //
        // Genealogy convention has been to store women under their birth
        // (maiden) surname so birth/parents'/marriage searches work. But
        // death-shape records (death index, probate, FAG memorials, post-
        // marriage census) file women under their married surname. With
        // single-surname profiles, those records silently miss.
        //
        // Two cases this covers:
        //   1. Spouse is on the tree but UI workflow stored woman as
        //      maiden — derived fallback (FamilyContext.spouseSurname)
        //      handles this without needing the explicit field.
        //   2. Spouse not on tree, user only ever knew her by married
        //      surname — explicit `married_surname` is the only place to
        //      record it.
        //
        // Column is nullable; existing rows default to NULL. Source
        // dispatch uses explicit-OR-derived in that order.
        migrator.registerMigration("v27_married_surname") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "married_surname", .text)
            }
        }

        // MARK: v28 — Auto-approval metadata on pending_facts
        //
        // Per AncestorApp/AUTO_APPROVAL_VIA_MCP_SPEC.md, the MCP server
        // gains tools that can commit a pending fact when the deterministic
        // rules judge it unambiguous. Three nullable columns distinguish a
        // user keystroke from a rules-driven commit and record which gate
        // criteria approved it, so the audit trail survives.
        //
        //   approval_method:   'user' | 'rules'  (NULL while pending)
        //   approval_rule_ids: JSON of the gate criteria that approved
        //   approved_at:       distinct from reviewed_at; preserves the
        //                      existing semantic of reviewed_at as "user
        //                      review timestamp" while letting us query
        //                      auto-approvals cleanly.
        migrator.registerMigration("v28_pending_facts_approval_metadata") { db in
            try db.alter(table: "pending_facts") { t in
                t.add(column: "approval_method", .text)
                t.add(column: "approval_rule_ids", .text)
                t.add(column: "approved_at", .datetime)
            }
        }

        // V29 — per-run structured result envelope for the eval-harness
        // backend (SWIFT_MCP_EVAL_BACKEND_SPEC #Change1). The Swift app
        // doesn't read this column; the upcoming `get_research_result`
        // MCP tool (#Change4) will. Empty string is a valid "no
        // envelope persisted yet" sentinel.
        migrator.registerMigration("v29_research_run_result_json") { db in
            try db.alter(table: "research_runs") { t in
                t.add(column: "result_json", .text).notNull().defaults(to: "")
            }
        }

        // PUBLISHER_SPEC Change 1 — publisher-domain tables. Mac-local
        // publisher state: never part of the canonical genealogy, never
        // published themselves, excluded from any future canonical sync.
        // publish_policy — per-person redaction override (§5); absent row
        //   = .auto (resolve via potentiallyLiving). acknowledged_at backs
        //   the pre-publish review gate and Change 7's auto-publish rule.
        // published_ids — permanent record-UUID identity (§4.1); rows
        //   survive delete/omit/re-add; superseded_by records merges.
        // published_state — per-record checksum of the last acknowledged
        //   upload (presence diff basis). publish_meta — one-row project
        //   scalars (generation must be monotonic across zone nukes).
        // publish_media — presence = attachment opted into publishing.
        migrator.registerMigration("v30_publisher_tables") { db in
            try db.create(table: "publish_policy") { t in
                t.column("profile_id", .text).primaryKey()
                t.column("policy", .text).notNull().defaults(to: "auto")
                t.column("acknowledged_at", .datetime)
            }
            try db.create(table: "published_ids") { t in
                t.column("entity_kind", .text).notNull()
                t.column("canonical_id", .text).notNull()
                t.column("record_uuid", .text).notNull()
                t.column("superseded_by", .text)
                t.primaryKey(["entity_kind", "canonical_id"])
            }
            try db.create(table: "published_state") { t in
                t.column("record_uuid", .text).primaryKey()
                t.column("checksum", .text).notNull()
            }
            try db.create(table: "publish_meta") { t in
                t.column("id", .integer).primaryKey()
                t.column("generation", .integer).notNull().defaults(to: 0)
                t.column("last_published_at", .datetime)
            }
            try db.create(table: "publish_media") { t in
                t.column("attachment_id", .text).primaryKey()
            }
        }

        // FT-16 follow-up (CONNECTOR_AUDIT_2026-07 §2.3) — purge rows keyed
        // on the retired hash-based record IDs. FreeREG and Wirksworth
        // previously built SourceRecord ids from `String.hashValue`
        // ("freereg_<hash>_<hash>", "wirksworth_<hash>") — SipHash with a
        // per-process random seed, so the same record got a different id
        // every launch, and every row keyed on one was orphaned at the next
        // restart. This migration ships in the same build as the stable-ID
        // scheme (URL path segment / SHA256 content digest) and runs at
        // first open of each project DB, so every row whose record id
        // starts with "freereg_" or "wirksworth_" at migration time was
        // written under the old scheme and can never match again: simple
        // prefix deletion is provably correct — no pattern-parsing needed.
        // Tables covered are the cross-run record-id keys:
        //   record_rejections.record_id (v2) — rejection lookups;
        //   evidence_records.source_record_id (v13) — the PK id embeds the
        //     same id after "|", so deleting via the column clears both;
        //   scored_records.source_record_id + research_records.id (v2/v4) —
        //     vestigial since the v13 evidence_records cutover but possibly
        //     populated in older projects, and still read by the MCP
        //     get_scored_records join.
        // Deliberately NOT purged: leads (ids embed record ids as an
        // idempotency key, but rows are self-contained user-facing task
        // items — deleting could discard a lead mid-investigation) and
        // life_events (UUIDs derived from record ids are accepted tree
        // data, not lookup keys).
        migrator.registerMigration("v31_purge_hash_based_record_ids") { db in
            let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ProjectDatabase")
            let purges: [(table: String, column: String)] = [
                ("record_rejections", "record_id"),
                ("evidence_records", "source_record_id"),
                ("scored_records", "source_record_id"),
                ("research_records", "id"),
            ]
            for purge in purges {
                // ESCAPE '\' so the underscore is a literal, not the LIKE
                // single-character wildcard — "freeregister_x" must survive.
                try db.execute(sql: """
                    DELETE FROM \(purge.table)
                    WHERE \(purge.column) LIKE 'freereg\\_%' ESCAPE '\\'
                       OR \(purge.column) LIKE 'wirksworth\\_%' ESCAPE '\\'
                    """)
                logger.info("v31: purged \(db.changesCount) hash-based-id rows from \(purge.table, privacy: .public)")
            }
        }

        // MARK: v32 — user-seeded hypothesis staging (RESEARCH_PIPELINE_SPEC
        // §5.15.2, Decision E2). External surfaces never write
        // `research_hypotheses` directly — that table is engine-owned, and
        // an external writer racing pipeline upserts is the class of bug
        // the firewall exists to prevent. Intake instead mirrors the
        // sanctioned `research_run_requests` orchestration pattern (v24):
        // the MCP `submit_hypothesis` tool (and later the Workbench form)
        // INSERTs a seed row; the app-side request watcher validates and
        // materialises it into one `research_hypotheses` row with
        // `origin = 'user'`. A seed is a search directive, never data —
        // it creates no profile, no edge, no field, no citation.
        //
        // The `origin` column on research_hypotheses is the orthogonal
        // provenance field (Decision E1): 'engine' for rows the generate
        // switches produce, 'user' for seeded hunches. The engine's
        // regeneration cycle never creates, deletes, or reshapes 'user'
        // rows — only re-grades them. Pre-v32 rows are all engine-made,
        // so the DEFAULT backfills them correctly.
        migrator.registerMigration("v32_user_hypothesis_seeds") { db in
            try db.create(table: "user_hypothesis_seeds") { t in
                t.column("id", .text).primaryKey()          // seed_<uuid>
                t.column("profile_id", .text).notNull()
                    .references("profiles", onDelete: .cascade)
                t.column("kind_discriminator", .text).notNull() // 'parentCandidates' only, this epic
                t.column("payload", .text).notNull()        // JSON name hints + optional window
                t.column("status", .text).notNull().defaults(to: "queued") // queued | materialised | refused
                t.column("refusal_reason", .text)
                t.column("hypothesis_id", .text)            // set on materialisation
                t.column("requested_by", .text).notNull()   // 'mcp' | 'workbench'
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_user_hypothesis_seeds_status",
                          on: "user_hypothesis_seeds",
                          columns: ["status"])
            try db.alter(table: "research_hypotheses") { t in
                t.add(column: "origin", .text).notNull().defaults(to: "engine")
            }
        }

        // MARK: v33 — persistent negative-search cache reader key
        // (CONNECTOR_AUDIT_2026-07 §6.1 T1-04 / §5.2). The honesty
        // envelope (a6e9c6d) made `negative_searches` a genuine WRITER —
        // one pair-level row per clean-zero (source, recordType). T1-04
        // adds the READER: before re-firing a query on a re-run, consult
        // the table and skip queries a prior run proved cleanly empty
        // within a freshness window. Matching needs the exact WIRE
        // identity, so negatives are now stored at the per-query grain —
        // `search_params` holds the `QueryCache.cacheKey` string (the
        // normalized-params key, matched verbatim on read so write/read
        // normalization can never drift).
        //
        // A partial UNIQUE index on (profile_id, source_id, record_type,
        // search_params) lets a re-run UPSERT the freshness timestamp
        // instead of piling up duplicate rows — the `WHERE search_params
        // IS NOT NULL` clause deliberately excludes NULL-param legacy
        // rows and keeps the `__whole_tree__` resume-state JSON rows out
        // of the uniqueness constraint (they share a profile_id/source_id
        // by convention but carry distinct JSON, and must never be
        // coalesced with real negatives). Pre-existing duplicate rows
        // that WOULD violate the new index are collapsed first (keep the
        // most-recent `searched_at` per key) so the index build can't
        // fail on legacy data.
        migrator.registerMigration("v33_negative_search_query_key_index") { db in
            try db.execute(sql: """
                DELETE FROM negative_searches
                WHERE search_params IS NOT NULL
                  AND rowid NOT IN (
                    SELECT MAX(rowid) FROM negative_searches
                    WHERE search_params IS NOT NULL
                    GROUP BY profile_id, source_id, record_type, search_params
                  )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_negative_searches_query_key
                ON negative_searches (profile_id, source_id, record_type, search_params)
                WHERE search_params IS NOT NULL
                """)
        }

        // MARK: v34 — typed external-identifier records (MODEL_EVOLUTION_SPEC
        // §Change1 / ADR-004 E1). The untyped `external_ids` string-map column
        // (v1) holds one current ID per system with no type and no lifecycle,
        // so a merged-away FamilySearch PID (HTTP 301 merge-forwarding) can't
        // be represented. This adds a `external_identifiers` JSON column — an
        // array of typed `ExternalIdentifier` records (system/value/kind/
        // supersededBy/recordedAt) — and backfills every existing `external_ids`
        // entry as a `.primary` record, losslessly.
        //
        // New-column, not replace-in-column, for bisectability (spec decision):
        // `external_ids` freezes in place for one release as rollback insurance
        // and keeps being written from the projection; reads prefer
        // `external_identifiers` and fall back to `external_ids`. This mirrors
        // the publisher's own outbound `published_ids.superseded_by` mechanism
        // (v30), applied inbound for the first time.
        migrator.registerMigration("v34_external_identifiers") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "external_identifiers", .text).notNull().defaults(to: "[]")
            }
            // Backfill: every existing external_ids entry → one .primary record.
            // Done row-by-row in Swift (rather than a SQL JSON expression) so
            // the backfill uses the exact same `Array(legacy:)` rule as the
            // decode path, keeping the two forever in step.
            let rows = try Row.fetchAll(db, sql: "SELECT id, external_ids FROM profiles")
            for row in rows {
                let id: String = row["id"]
                let legacyJSON: String = row["external_ids"] ?? "{}"
                let legacy = (try? JSONDecoder().decode(
                    [String: String].self, from: Data(legacyJSON.utf8))) ?? [:]
                guard !legacy.isEmpty else { continue } // "[]" default already correct
                let records = [ExternalIdentifier](legacy: legacy)
                let json = (try? JSONEncoder().encode(records))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(
                    sql: "UPDATE profiles SET external_identifiers = ? WHERE id = ?",
                    arguments: [json, id])
            }
        }

        // MARK: v35 — typed repeatable name forms (MODEL_EVOLUTION_SPEC
        // §Change2 / ADR-004 E2). The flat name columns (first_name, last_name,
        // married_surname, nick_name, mothers_maiden_name) can hold exactly one
        // married surname and one nickname, so a twice-married woman, an alias
        // (WikiTree LastNameOther — silently dropped before E2), a deed-poll
        // change, or a non-Western structure can't be represented. This adds a
        // `name_forms` JSON column — an array of typed `NameForm` records
        // (type/fullText/lang/given/surname/prefix/suffix) — as an ADDITIVE
        // sidecar. The flat columns stay the canonical search keys, untouched.
        //
        // Backfill mirrors E1's row-by-row Swift rule (not a SQL JSON
        // expression) so the migration and the decode path share one source of
        // truth. Every existing name survives losslessly: the birth name
        // (last_name = maiden surname) becomes a `.birth` form and any explicit
        // married_surname becomes a `.married` form, so a legacy profile's
        // variants are captured without changing what the flat fields — or
        // `displayName` — resolve to.
        migrator.registerMigration("v35_name_forms") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "name_forms", .text).notNull().defaults(to: "[]")
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, first_name, middle_name, last_name, married_surname, nick_name
                FROM profiles
                """)
            for row in rows {
                let forms = Self.backfilledNameForms(
                    firstName: row["first_name"],
                    middleName: row["middle_name"],
                    lastName: row["last_name"],
                    marriedSurname: row["married_surname"],
                    nickName: row["nick_name"])
                guard !forms.isEmpty else { continue } // "[]" default already correct
                let json = (try? JSONEncoder().encode(forms))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(
                    sql: "UPDATE profiles SET name_forms = ? WHERE id = ?",
                    arguments: [json, row["id"] as String])
            }
        }

        // MARK: v36 — place-authority landing slot (MODEL_EVOLUTION_SPEC
        // §Change3 / ADR-004 E3). E3's substance — the typed place hierarchy
        // with temporal validity — is DERIVED at runtime from the existing seed
        // data (the gazetteer + the FreeBMD district catalogue) by
        // `PlaceAuthorityRegistry`; the *stored* `COUNTY:Place` codes in
        // `*_location_code` are unchanged and keep resolving to the same
        // county/district they always did, so **no code migration is needed and
        // this migration is losslessly additive** (AC3).
        //
        // What it adds is the optional, nullable `place_authority_id` column
        // beside each existing `*_location_code` column, on the three tables
        // that carry a location code (profiles birth/death, relationships
        // marriage, life_events). Per the spec this is the future landing slot
        // for an *external* authority id (FS Place Authority), following the
        // stash-don't-destroy discipline (L8): the column exists so those ids
        // have a home when FS arrives, and stays NULL until then. The Profile /
        // Relationship / LifeEvent Swift shapes are unchanged (still string +
        // code); nothing reads or writes these columns yet.
        migrator.registerMigration("v36_place_authority_id") { db in
            try db.alter(table: "profiles") { t in
                // Two slots — one per location code the profile carries.
                t.add(column: "birth_place_authority_id", .text)
                t.add(column: "death_place_authority_id", .text)
            }
            try db.alter(table: "relationships") { t in
                t.add(column: "marriage_place_authority_id", .text)
            }
            try db.alter(table: "life_events") { t in
                t.add(column: "place_authority_id", .text)
            }
        }

        // v37 — E4: edge-existence provenance (MODEL_EVOLUTION_SPEC §Change4).
        //
        // Additive capability marker. The `field_sources` table already stores
        // provenance keyed `(entity_id, entity_kind, field)` and `field` is
        // TEXT, so an `existence` pseudo-field on `entity_kind = 'relationship'`
        // needs **no column change** — existence rows are ordinary
        // field_sources rows. This migration therefore alters nothing and
        // backfills nothing.
        //
        // It is registered deliberately for two reasons:
        //   1. It is the schema-version fence for E4 — a project opened after
        //      this migration ran has the existence-provenance capability; one
        //      that predates it does not, and the version string records that.
        //   2. Decision log #4 — **forward-only**. This migration must NOT
        //      synthesise existence rows for the relationships that already
        //      exist: backfilling provenance never captured would fabricate
        //      evidence (violates check-before-overwrite / never-fabricate).
        //      So the body is intentionally empty of writes. Legacy edges stay
        //      bare; only edges materialised *after* E4 carry an existence row.
        //
        // Index the relationship existence lookup so `existenceSources(for:)`
        // and the idempotency pre-check don't table-scan on large trees. The
        // existing `idx_field_sources_entity` covers `(entity_id, field)` but
        // not `entity_kind`; a partial index on relationship rows keeps the
        // new read path cheap without touching the profile read path.
        migrator.registerMigration("v37_edge_existence_provenance") { db in
            try db.create(
                index: "idx_field_sources_relationship_existence",
                on: "field_sources",
                columns: ["entity_id", "field"],
                condition: Column("entity_kind") == "relationship"
            )
        }

        // ENGINE_FOUNDATION_SPEC §Change7 — per-project Discovery expansion
        // bound. Stored as a compact wire string ("generational:4" /
        // "collateral:2"); NULL = engine default. Bounds which leads may
        // promote so a run stops burning budget on peripheral kin; never a
        // scorer/verdict change.
        migrator.registerMigration("v38_project_expansion_policy") { db in
            try db.alter(table: "project_meta") { t in
                t.add(column: "expansion_policy", .text)
            }
        }

        // ENGINE_FOUNDATION_SPEC §Change5 — per-source daily-budget counters.
        // One row per source holding the request count within the current
        // reset window. Persisted here (rather than in memory) so a source's
        // spent daily budget survives a process restart — the sustained-run
        // requirement §Change6 depends on. `window_start` anchors the count
        // to the source's reset boundary; when `now` passes the next reset
        // the tracker rolls the row to a fresh window with count 0. Not
        // profile-scoped: a source's quota is global to the volunteer host,
        // not per-tree, so there is exactly one row per source_id.
        //
        // NOTE on numbering: this is v39, not the spec's implied "next after
        // v37", because a concurrent change (§Change7) claimed v38 for
        // `project_meta.expansion_policy`. GRDB applies migrations in
        // registration order and keys them by identifier, so a v39 appended
        // after v38 is correct and collision-free.
        migrator.registerMigration("v39_source_budget_state") { db in
            try db.create(table: "source_budget_state") { t in
                t.column("source_id", .text).primaryKey()
                t.column("window_start", .datetime).notNull()
                t.column("request_count", .integer).notNull().defaults(to: 0)
                t.column("updated_at", .datetime).notNull()
            }
        }

        // ENGINE_FOUNDATION_SPEC §Change6 — checkpoint/resume hardening.
        // Resume-audit columns on the run-request queue. A request killed
        // mid-run is left in `running` and orphaned forever today; on the
        // next launch the watcher RECLAIMS a stale `running` row back to
        // `queued` so the run resumes. These columns make that observable
        // (and human-readable when debugging a stuck run): `resume_count`
        // counts how many times the row was reclaimed, `resumed_at` stamps
        // the last reclaim. Additive + nullable so no data migration.
        migrator.registerMigration("v40_run_request_resume_audit") { db in
            try db.alter(table: "research_run_requests") { t in
                t.add(column: "resume_count", .integer).notNull().defaults(to: 0)
                t.add(column: "resumed_at", .datetime)
            }
        }

        // CONFLICT_LAYER_SPEC §5 — the evidence-conflict layer's single
        // migration (ships with CL-Change1; Changes 2–6 need no further
        // migration). `field_disputes` has zero production writers before
        // this layer (DS-13), so every change here is additive and
        // risk-free: existing rows are untouched and read back losslessly
        // with `kind` defaulting to the only shape the v1 machinery ever
        // modelled ('fieldValue').
        migrator.registerMigration("v41_conflict_layer") { db in
            try db.alter(table: "field_disputes") { t in
                t.add(column: "entity_kind", .text).notNull().defaults(to: "profile")
                // 'fieldValue' | 'timeline' | 'parentRole' | 'spouseIdentity'
                t.add(column: "kind", .text).notNull().defaults(to: "fieldValue")
                // DiscrepancySeverity raw value
                t.add(column: "severity", .text)
                // ⟨G6⟩ 'applyEngine' | 'runSweep' | 'consistencySweep'
                t.add(column: "detected_by", .text)
                // Non-FieldSource competitors BY REFERENCE: life_event IDs
                // (F3/T-D), relationship IDs + record refs (F4a/F4b).
                // Never WitnessKeys (§2.6 — computed, never persisted).
                t.add(column: "evidence_json", .text)
                // ⟨G2⟩ JSON [{rung, outcome, detail}] — every ladder rung
                // evaluated (fired or not), the written proof argument GPS
                // element 4 requires.
                t.add(column: "ladder_trace", .text)
                // ⟨G8⟩ JSON per-value weighing inputs; a display cache
                // recomputed on every upsert, never identity.
                t.add(column: "witness_summary", .text)
                t.add(column: "resolved_at", .datetime)
            }
            // C3 upsert identity: at most ONE open dispute per
            // (entity_id, kind, field). Partial unique index — resolved
            // rows are history and may accumulate per key (reopen = new
            // row, §2.8).
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_field_disputes_open
                ON field_disputes(entity_id, kind, field)
                WHERE resolution IS NULL
                """)

            // ⟨G5⟩ rival value-candidates share one candidate_group_id so
            // the UI can render a single choose-one card (stamped from CL5;
            // column lands now so CL5 needs no migration).
            try db.alter(table: "research_hypotheses") { t in
                t.add(column: "candidate_group_id", .text)
            }
            try db.create(
                index: "idx_research_hypotheses_group",
                on: "research_hypotheses",
                columns: ["candidate_group_id"]
            )

            // CL3 persists run discrepancies (the v1 table has severity
            // already; it only lacked a run linkage — and any INSERT).
            try db.alter(table: "research_discrepancies") { t in
                t.add(column: "run_id", .text)
            }

            // CL2's sweep bookkeeping. The spec calls these project_meta
            // "keys"; this project's project_meta is a single-row,
            // column-shaped table (see v38's expansion_policy), so the two
            // keys land as nullable columns. NULL until CL2 writes them.
            try db.alter(table: "project_meta") { t in
                // High-water mark letting the standing sweep skip an
                // unchanged project on open.
                t.add(column: "conflict_sweep_high_water", .datetime)
                // One-shot backfill flag ('done' when the CL2 backfill has
                // surfaced latent contradictions in a pre-v41 tree).
                t.add(column: "v41_conflict_backfill_done", .text)
            }
        }

        // MARK: v42 — negative-search outcome columns
        // (FAMILYSEARCH_READ_LEG_PLAN #Change3 / FS spec §6.6). Until now
        // the table could only say "searched, empty"; these columns let a
        // row distinguish HOW the search concluded so a truncated page-1
        // answer can never masquerade as verified absence.
        migrator.registerMigration("v42_negative_search_outcome") { db in
            try db.alter(table: "negative_searches") { t in
                // 'zero' | 'sparse' | 'positive' | 'truncated' (§6.6).
                // NULL = legacy row written before v42 — by writer
                // construction those were only ever clean zeros, so
                // readers treat NULL as 'zero'.
                t.add(column: "result_kind", .text)
                // 0 for zero; N for positive/sparse; the source's claimed
                // would-be total for truncated.
                t.add(column: "hit_count", .integer)
            }
        }

        // MARK: v43 — evidence external ARK identity columns
        // (FAMILYSEARCH_READ_LEG_PLAN #Change7 / FS spec §17.1). Bare
        // `ark:/61903/…` PATH SEGMENTS only, never full URLs (the FS
        // permanence guarantee excludes domain + query decorations). These
        // are the idempotency key for FS evidence ingestion and the
        // ARK-deterministic join for the citation matcher (which works
        // under the §16 pointer-only licensing posture — it matches
        // identity, not content). Nullable; populated when the FS OAuth
        // ingestion path lands (#Change5/#Change8) — data-model commits
        // early, endpoint integration later (§12.4).
        migrator.registerMigration("v43_evidence_external_ids") { db in
            try db.alter(table: "evidence_records") { t in
                t.add(column: "external_persona_id", .text)  // ark:/61903/1:1:XXXX
                t.add(column: "external_record_id", .text)   // ark:/61903/4:1:XXXX
            }
        }

        // MARK: v44 — Full scorer output on evidence rows
        // CAMPAIGN_REVIEW_SPEC Change 2. evidence_records previously kept
        // only record_json + verdict — ScoredRecord.gates and .summary were
        // discarded at persist, so DB-reconstructed records lost gate chips,
        // rejected-reasons, and the known-spouse apply bypass; and the
        // in-memory enrichment exclusion (state.enrichmentRecordIDs) was
        // unrepresentable, so any re-cluster over persisted evidence
        // fabricated orphan clusters from parents'-marriage records.
        // All nullable/defaulted — legacy rows decode as gates=[] summary="".
        migrator.registerMigration("v44_evidence_scorer_fidelity") { db in
            try db.alter(table: "evidence_records") { t in
                t.add(column: "gates_json", .text)
                t.add(column: "summary", .text)
                t.add(column: "is_enrichment", .integer).notNull().defaults(to: 0)
                t.add(column: "last_run_id", .text)
            }
        }

        // MARK: v45 — Persisted evidence-chain convergence
        // CAMPAIGN_REVIEW_SPEC Change 3. One row per (profile, asserted
        // fact value): the ConvergenceLevel + Codable SourcingStrength the
        // chain has earned, upserted at every run-persist so the level
        // upgrades as independent lineages accumulate — the durable answer
        // to "multiple sources corroborate a fact: is the bigger evidence
        // chain recorded?". WitnessKeys are never persisted (⟨G9⟩) — only
        // the scored outcome and the contributing record ids.
        migrator.registerMigration("v45_evidence_convergence") { db in
            try db.create(table: "evidence_convergence") { t in
                t.column("profile_id", .text).notNull()
                t.column("value_key", .text).notNull()
                t.column("level", .text).notNull()
                t.column("sourcing_json", .text).notNull()
                t.column("record_ids_json", .text).notNull()
                t.column("updated_at", .datetime).notNull()
                t.primaryKey(["profile_id", "value_key"])
            }
            try db.create(index: "idx_evidence_convergence_profile",
                          on: "evidence_convergence", columns: ["profile_id"])
        }

        // MARK: v46 — Campaign-review watermark
        // CAMPAIGN_REVIEW_SPEC Change 6. "Reviewed up to" high-water mark for
        // the bulk campaign-review surface — same pattern as
        // conflict_sweep_high_water (v41).
        migrator.registerMigration("v46_campaign_review_high_water") { db in
            try db.alter(table: "project_meta") { t in
                t.add(column: "campaign_review_high_water", .datetime)
            }
        }

        // v47 — structured age-at-death + event place on leads. Lead discovery
        // (LEAD_DISCOVERY_SPEC §9) derives an implied birth year from
        // age-at-death and uses place as a second discriminator so no-birth-
        // year death/burial/marriage leads stop chain-merging on name alone
        // (the Phase 0 "George Ward = 273" over-merge). Additive columns; old
        // rows read nil for both.
        migrator.registerMigration("v47_lead_age_place") { db in
            try db.alter(table: "leads") { t in
                t.add(column: "age_at_death", .integer)
                t.add(column: "place", .text)
            }
        }

        return migrator
    }

    /// Deterministic backfill of `NameForm`s from a legacy profile's flat name
    /// columns (E2 migration v35). Shared by the migration and available to
    /// tests so both exercise the exact same rule. A profile with no name parts
    /// yields `[]`. The birth name (given parts + maiden `lastName`) becomes a
    /// `.birth` form; an explicit `marriedSurname` distinct from the birth
    /// surname becomes a `.married` form. `nickName` is intentionally NOT
    /// duplicated as a form — it stays a flat search key and duplicating it
    /// would add noise the projection tests would then have to special-case;
    /// spec AC5 only requires losslessness of *representable* structure, and the
    /// nickname is fully preserved in its flat column.
    static func backfilledNameForms(
        firstName: String?,
        middleName: String?,
        lastName: String?,
        marriedSurname: String?,
        nickName: String?
    ) -> [NameForm] {
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let given = [clean(firstName), clean(middleName)].compactMap { $0 }.joined(separator: " ")
        let birthSurname = clean(lastName)
        var forms: [NameForm] = []

        // Birth form: only when there is at least one name part to record.
        if !given.isEmpty || birthSurname != nil {
            let full = [given.isEmpty ? nil : given, birthSurname]
                .compactMap { $0 }.joined(separator: " ")
            forms.append(NameForm(
                type: .birth,
                fullText: full,
                given: given.isEmpty ? nil : given,
                surname: birthSurname))
        }

        // Married form: only when an explicit married surname exists and differs
        // from the birth surname (case-insensitive) — otherwise it is redundant.
        if let married = clean(marriedSurname),
           married.lowercased() != (birthSurname?.lowercased() ?? "") {
            let full = [given.isEmpty ? nil : given, married]
                .compactMap { $0 }.joined(separator: " ")
            forms.append(NameForm(
                type: .married,
                fullText: full,
                given: given.isEmpty ? nil : given,
                surname: married))
        }
        return forms
    }

    // MARK: - Snapshot Building

    /// Load a single profile by id. Returns nil when no row exists or
    /// the row is soft-deleted. Used by callers that need one profile
    /// without the full snapshot cost — currently the placeholder
    /// write-back path (ENGINE_FOUNDATION_SPEC #Change2).
    func loadProfile(id: String) throws -> Profile? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM profiles WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            ) else { return nil }
            return try Self.profileFromRow(row, db: db)
        }
    }

    /// Build a FamilyGraphSnapshot from the database.
    /// Eagerly joins profiles + field_sources + field_disputes.
    func buildSnapshot() throws -> FamilyGraphSnapshot {
        try dbQueue.read { db in
            // Load all profiles (excluding soft-deleted)
            let profileRows = try Row.fetchAll(db, sql: "SELECT * FROM profiles WHERE is_deleted = 0")
            var profiles: [String: Profile] = [:]
            for row in profileRows {
                let id: String = row["id"]
                let profile = try Self.profileFromRow(row, db: db)
                profiles[id] = profile
            }

            // Load all relationships
            let relRows = try Row.fetchAll(db, sql: "SELECT * FROM relationships")
            let relationships = relRows.map { Self.relationshipFromRow($0) }

            // Life events, grouped by profile — carried on the snapshot so
            // RecordAfterDeathRule and ConflictSweep consume identical data
            // (CONFLICT_LAYER_SPEC CL2, shared-predicate requirement).
            let eventRows = try Row.fetchAll(db, sql: "SELECT * FROM life_events")
            var lifeEvents: [String: [LifeEvent]] = [:]
            for row in eventRows {
                guard let event = Self.lifeEventFromRow(row) else { continue }
                lifeEvents[event.profileID, default: []].append(event)
            }

            return FamilyGraphSnapshot(profiles: profiles, relationships: relationships,
                                       lifeEvents: lifeEvents)
        }
    }

    private static func profileFromRow(_ row: Row, db: Database) throws -> Profile {
        let id: String = row["id"]
        // E1 (MODEL_EVOLUTION_SPEC §Change1): prefer the typed
        // `external_identifiers` column; fall back to the legacy
        // `external_ids` string-map column (pre-v34 rows, or the frozen
        // rollback-insurance copy). A row that somehow has neither yields an
        // empty identifier list. `mergingLegacyMap` makes the fallback lossless
        // even if both columns are populated.
        let externalIdentifiers: [ExternalIdentifier] = {
            var records: [ExternalIdentifier] = []
            if let json: String = row["external_identifiers"],
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([ExternalIdentifier].self, from: data) {
                records = decoded
            }
            let legacyJSON: String = row["external_ids"] ?? "{}"
            let legacy = (try? JSONDecoder().decode([String: String].self, from: Data(legacyJSON.utf8))) ?? [:]
            return records.mergingLegacyMap(legacy)
        }()

        // E2 (MODEL_EVOLUTION_SPEC §Change2): typed name forms from the
        // `name_forms` JSON column. Absent/unparseable (a pre-v35 row that
        // somehow lacks the column, or a corrupt blob) yields `[]` — the flat
        // name columns remain the source of truth for such a profile.
        let nameForms: [NameForm] = {
            guard let json: String = row["name_forms"],
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([NameForm].self, from: data)
            else { return [] }
            return decoded
        }()

        let birthDate = dateFromRow(row, prefix: "birth_date")
        let deathDate = dateFromRow(row, prefix: "death_date")
        let genderStr: String? = row["gender"]
        let gender = genderStr.flatMap { Gender(rawValue: $0) }

        // Load sources for this profile, including citation + quality (v8) and fact_confidence (v9).
        let sourceRows = try Row.fetchAll(db, sql: """
            SELECT field, origin, raw, added_at, citation_json, evidence_quality, fact_confidence
            FROM field_sources
            WHERE entity_id = ? AND entity_kind = 'profile'
            """, arguments: [id])

        var sources: [ProfileField: [FieldSource]] = [:]
        for sRow in sourceRows {
            let fieldStr: String = sRow["field"]
            guard let field = ProfileField(rawValue: fieldStr) else { continue }
            let origin = SourceOrigin(identifier: sRow["origin"])
            let raw: String = sRow["raw"]
            let addedAt: Date = sRow["added_at"]

            // Decode optional citation JSON; nil if column null or unparseable.
            var citation: Citation?
            if let json: String = sRow["citation_json"],
               let data = json.data(using: .utf8) {
                citation = try? JSONDecoder().decode(Citation.self, from: data)
            }
            // EvidenceQuality stored as int; nil if column null or out of range.
            let quality: EvidenceQuality? = (sRow["evidence_quality"] as Int?)
                .flatMap(EvidenceQuality.init(rawValue:))
            // FactConfidence stored as int; nil if column null or out of range.
            let confidence: FactConfidence? = (sRow["fact_confidence"] as Int?)
                .flatMap(FactConfidence.init(rawInt:))

            sources[field, default: []].append(FieldSource(
                origin: origin, raw: raw, addedAt: addedAt,
                citation: citation, quality: quality, confidence: confidence
            ))
        }

        // Load disputes for this profile. CONFLICT_LAYER_SPEC §4.8.1:
        // the snapshot map carries `fieldValue` disputes only — structural
        // kinds (timeline/parentRole/spouseIdentity) use field keys that
        // are not ProfileFields and surface through the DisputeStore
        // queries instead, so the `[ProfileField: FieldDispute]` keys stay
        // valid (C3 guarantees ≤1 open row per (field, kind)). Ordered by
        // rowid so the newest row per field wins deterministically (an
        // open reopen-row shadows its resolved history for display).
        let disputeRows = try Row.fetchAll(db, sql: """
            SELECT field, reason, competing_sources, detected_at, resolution,
                   kind, severity, detected_by
            FROM field_disputes
            WHERE entity_id = ?
            ORDER BY rowid ASC
            """, arguments: [id])

        var disputes: [ProfileField: FieldDispute] = [:]
        for dRow in disputeRows {
            let fieldStr: String = dRow["field"]
            guard let field = ProfileField(rawValue: fieldStr) else { continue }
            let kind = (dRow["kind"] as String?)
                .flatMap { DisputeKind(rawValue: $0) } ?? .fieldValue
            guard kind == .fieldValue else { continue }
            let reasonStr: String = dRow["reason"]
            guard let reason = DisputeReason(rawValue: reasonStr) else { continue }
            let competingJSON: String = dRow["competing_sources"]
            let competing = (try? JSONDecoder().decode([FieldSource].self, from: Data(competingJSON.utf8))) ?? []
            let detectedAt: Date = dRow["detected_at"]
            let resolutionJSON: String? = dRow["resolution"]
            let resolution = resolutionJSON.flatMap {
                try? JSONDecoder().decode(DisputeResolution.self, from: Data($0.utf8))
            }
            let severity = (dRow["severity"] as String?)
                .flatMap { DiscrepancySeverity(rawValue: $0) }
            let detectedBy = (dRow["detected_by"] as String?)
                .flatMap { DisputeProducer(rawValue: $0) }
            disputes[field] = FieldDispute(
                field: field, reason: reason, competingSources: competing,
                detectedAt: detectedAt, resolution: resolution,
                kind: kind, severity: severity, detectedBy: detectedBy
            )
        }

        // Decode PersonAttributes from JSON column (nil for pre-v6 profiles)
        let attributes: PersonAttributes? = {
            guard let json: String = row["attributes"],
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(PersonAttributes.self, from: data)
        }()

        let isDeleted: Bool = row["is_deleted"] ?? false

        return Profile(
            id: id,
            externalIdentifiers: externalIdentifiers,
            firstName: row["first_name"],
            middleName: row["middle_name"],
            lastName: row["last_name"],
            marriedSurname: row["married_surname"],
            nickName: row["nick_name"],
            mothersMaidenName: row["mothers_maiden_name"],
            nameForms: nameForms,
            gender: gender,
            attributes: attributes,
            birthDate: birthDate,
            birthLocation: row["birth_location"],
            birthLocationCode: row["birth_location_code"],
            deathDate: deathDate,
            deathLocation: row["death_location"],
            deathLocationCode: row["death_location_code"],
            bio: row["bio"],
            isDeleted: isDeleted,
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

        let marriageLocation: String? = row["marriage_location"]
        let marriageLocationCode: String? = row["marriage_location_code"]

        return Relationship(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            from: row["from_id"],
            to: row["to_id"],
            type: RelationshipType(rawValue: typeStr) ?? .parent,
            role: roleStr.flatMap { ParentRole(rawValue: $0) },
            subtype: RelationshipSubtype(rawValue: subtypeStr) ?? .unknown,
            marriageDate: marriageDate,
            marriageLocation: marriageLocation,
            marriageLocationCode: marriageLocationCode,
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
            case .manual:
                sourceKind = "manual"
                sourceValue = ""
            }

            try db.execute(sql: """
                INSERT OR REPLACE INTO project_meta (id, name, source_kind, source_value, created_at, last_refreshed, home_person_id, archived_at, home_chapman_code, expansion_policy)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    project.id.uuidString, project.name, sourceKind, sourceValue,
                    project.createdAt, project.lastRefreshed, project.homePersonID,
                    project.archivedAt, project.homeChapmanCode,
                    project.expansionPolicy?.wireValue
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
            let source: DataSource = switch sourceKind {
            case "gedcom": .gedcom(path: sourceValue)
            case "manual": .manual
            default: .wikitree(email: sourceValue)
            }
            let homePersonID: String? = row["home_person_id"]
            // §Change7 — decode the compact expansion-policy wire string.
            // NULL / unrecognised → nil (project uses the engine default).
            let expansionPolicy: ExpansionPolicy? = (row["expansion_policy"] as String?)
                .flatMap { ExpansionPolicy(wireValue: $0) }

            return Project(
                id: UUID(uuidString: row["id"]) ?? UUID(),
                name: row["name"],
                source: source,
                homePersonID: homePersonID,
                createdAt: row["created_at"],
                lastRefreshed: row["last_refreshed"],
                archivedAt: row["archived_at"],
                homeChapmanCode: row["home_chapman_code"],
                expansionPolicy: expansionPolicy
            )
        }
    }

    /// Toggle a project's archived state. Pass nil to unarchive.
    func setArchivedAt(_ date: Date?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE project_meta SET archived_at = ?", arguments: [date])
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
        // E1: the legacy `external_ids` string-map column keeps being written
        // from the projection (rollback insurance for one release); the new
        // `external_identifiers` column carries the typed record list — the
        // source of truth from which the projection derives.
        let externalIDsJSON = (try? JSONEncoder().encode(profile.externalIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let externalIdentifiersJSON = (try? JSONEncoder().encode(profile.externalIdentifiers))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        // E2: typed name forms sidecar (source of truth for name variants; flat
        // columns stay the canonical search keys). Empty list → "[]".
        let nameFormsJSON = (try? JSONEncoder().encode(profile.nameForms))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let attributesJSON: String? = profile.attributes.flatMap {
            (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) }
        }

        try db.execute(sql: """
            INSERT INTO profiles (id, external_ids, external_identifiers,
                first_name, middle_name, last_name, married_surname, nick_name, mothers_maiden_name,
                name_forms,
                gender, attributes, is_deleted,
                birth_date_original, birth_date_earliest, birth_date_latest, birth_date_qualifier,
                birth_location, birth_location_code,
                death_date_original, death_date_earliest, death_date_latest, death_date_qualifier,
                death_location, death_location_code, bio, created_by_transaction_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                profile.id, externalIDsJSON, externalIdentifiersJSON,
                profile.firstName, profile.middleName, profile.lastName,
                profile.marriedSurname,
                profile.nickName, profile.mothersMaidenName,
                nameFormsJSON,
                profile.gender?.rawValue,
                attributesJSON, profile.isDeleted,
                profile.birthDate?.original, profile.birthDate?.earliest, profile.birthDate?.latest,
                profile.birthDate?.qualifier.rawValue,
                profile.birthLocation, profile.birthLocationCode,
                profile.deathDate?.original, profile.deathDate?.earliest, profile.deathDate?.latest,
                profile.deathDate?.qualifier.rawValue,
                profile.deathLocation, profile.deathLocationCode, profile.bio, transactionID.uuidString,
            ])
    }

    private static func insertRelationship(_ rel: Relationship, transactionID: UUID, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO relationships (id, from_id, to_id, type, role, subtype,
                marriage_date_original, marriage_date_earliest, marriage_date_latest, marriage_date_qualifier,
                marriage_location, marriage_location_code,
                divorce_date_original, divorce_date_earliest, divorce_date_latest, divorce_date_qualifier,
                created_by_transaction_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                rel.id.uuidString, rel.from, rel.to, rel.type.rawValue,
                rel.role?.rawValue, rel.subtype.rawValue,
                rel.marriageDate?.original, rel.marriageDate?.earliest, rel.marriageDate?.latest,
                rel.marriageDate?.qualifier.rawValue,
                rel.marriageLocation, rel.marriageLocationCode,
                rel.divorceDate?.original, rel.divorceDate?.earliest, rel.divorceDate?.latest,
                rel.divorceDate?.qualifier.rawValue,
                transactionID.uuidString,
            ])
    }

    // MARK: - Transaction History

    /// Load transactions ordered by most recent first. Breaks `completed_at`
    /// ties by `rowid DESC` so insertion order wins — important when several
    /// transactions land within the same millisecond (e.g. an import
    /// immediately followed by an undo).
    func loadTransactions(limit: Int = 50) throws -> [Transaction] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM transactions ORDER BY completed_at DESC, rowid DESC LIMIT ?
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

                // CONFLICT_LAYER_SPEC §6 Change 1 AC4 — reverse a dispute
                // resolution write (journalled by resolveFieldDispute with
                // entity_id = the dispute rowid). Restoring a nil old
                // resolution reopens the dispute (resolved_at cleared);
                // restoring a previous resolution leaves resolved_at as-is.
                if entityKind == "dispute" {
                    if field == "resolution", let rowid = Int64(entityID) {
                        if let oldVal = oldValue {
                            try db.execute(sql: """
                                UPDATE field_disputes SET resolution = ? WHERE rowid = ?
                                """, arguments: [oldVal, rowid])
                        } else {
                            try db.execute(sql: """
                                UPDATE field_disputes SET resolution = NULL, resolved_at = NULL
                                WHERE rowid = ?
                                """, arguments: [rowid])
                        }
                    }
                    continue
                }

                if entityKind == "profile" {
                    // Handle is_deleted as a special case (not a ProfileField)
                    if field == "is_deleted" {
                        let val = oldValue == "1" ? 1 : 0
                        try db.execute(
                            sql: "UPDATE profiles SET is_deleted = ? WHERE id = ?",
                            arguments: [val, entityID]
                        )
                        continue
                    }

                    // Handle date fields (4-column pattern)
                    if field == "birthDate" || field == "deathDate" {
                        let prefix = field == "birthDate" ? "birth_date" : "death_date"
                        if let raw = oldValue {
                            let date = GenealogicalDate(parsing: raw)
                            try db.execute(
                                sql: """
                                UPDATE profiles SET \(prefix)_original = ?, \(prefix)_earliest = ?,
                                    \(prefix)_latest = ?, \(prefix)_qualifier = ?
                                WHERE id = ?
                                """,
                                arguments: [date.original, date.earliest, date.latest, date.qualifier.rawValue, entityID]
                            )
                        } else {
                            try db.execute(
                                sql: """
                                UPDATE profiles SET \(prefix)_original = NULL, \(prefix)_earliest = NULL,
                                    \(prefix)_latest = NULL, \(prefix)_qualifier = NULL
                                WHERE id = ?
                                """,
                                arguments: [entityID]
                            )
                        }
                        continue
                    }

                    // Simple string fields
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
        case "middleName": "middle_name"
        case "lastName": "last_name"
        case "marriedSurname": "married_surname"
        case "nickName": "nick_name"
        case "mothersMaidenName": "mothers_maiden_name"
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

    /// JSON encoder shared with the rest of the database layer (incl. extensions).
    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - Manual Entry Mutations

nonisolated extension ProjectDatabase {

    /// Add a single profile to the database. All fields tagged with the given source.
    /// Returns the transaction that was created.
    @discardableResult
    func addProfile(_ profile: Profile, source: SourceOrigin) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .addProfile(profileID: profile.id),
            undoStrategy: .structural,
            startedAt: now, completedAt: now,
            changeCount: 0, profileCount: 1
        )

        try dbQueue.write { db in
            // Save transaction
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            // Insert profile
            try Self.insertProfile(profile, transactionID: transaction.id, db: db)

            // Insert field sources
            try Self.insertFieldSources(for: profile, source: source, transactionID: transaction.id, db: db)
        }

        return transaction
    }

    /// Add a family group — multiple profiles and relationships in one atomic transaction.
    ///
    /// `edgeExistenceEvidence` (E4 / MODEL_EVOLUTION_SPEC §Change4): maps a
    /// relationship's `id` to the reason that edge exists. Every entry writes
    /// an `existence` provenance row for that edge inside this same atomic
    /// transaction. Edges absent from the map get no existence row — forward-
    /// only means "cite when we have a citation", not "invent one".
    @discardableResult
    func addFamily(
        profiles: [Profile],
        relationships: [Relationship],
        source: SourceOrigin,
        edgeExistenceEvidence: [UUID: RelationshipExistenceEvidence] = [:]
    ) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .addFamily(profileIDs: profiles.map(\.id)),
            undoStrategy: .structural,
            startedAt: now, completedAt: now,
            changeCount: relationships.count, profileCount: profiles.count
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            for profile in profiles {
                try Self.insertProfile(profile, transactionID: transaction.id, db: db)
                try Self.insertFieldSources(for: profile, source: source, transactionID: transaction.id, db: db)
            }

            for rel in relationships {
                try Self.insertRelationship(rel, transactionID: transaction.id, db: db)
                if let evidence = edgeExistenceEvidence[rel.id] {
                    try Self.recordRelationshipExistenceSource(
                        relationshipID: rel.id.uuidString,
                        evidence: evidence,
                        transactionID: transaction.id,
                        db: db
                    )
                }
            }
        }

        return transaction
    }

    /// Add a relationship between two existing profiles.
    ///
    /// `existenceEvidence` (E4 / MODEL_EVOLUTION_SPEC §Change4): when the edge
    /// is being materialised from evidence, pass the driving record (or a
    /// manual/import origin) and an `existence` provenance row is written in
    /// the same transaction. Defaults to `nil` — legacy call sites keep working
    /// unchanged and simply record no existence provenance, which is correct:
    /// forward-only, only edges created *with* evidence carry it.
    @discardableResult
    func addRelationship(
        _ rel: Relationship,
        existenceEvidence: RelationshipExistenceEvidence? = nil
    ) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .addRelationship(relationshipID: rel.id),
            undoStrategy: .structural,
            startedAt: now, completedAt: now,
            changeCount: 1, profileCount: 0
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            try Self.insertRelationship(rel, transactionID: transaction.id, db: db)

            if let existenceEvidence {
                try Self.recordRelationshipExistenceSource(
                    relationshipID: rel.id.uuidString,
                    evidence: existenceEvidence,
                    transactionID: transaction.id,
                    db: db
                )
            }
        }

        return transaction
    }

    /// Idempotent variant of `addRelationship` — inserts only when
    /// no existing row has the same `(from, to, type, role)` tuple
    /// pointing in the same direction. Returns the existing row's
    /// id (or the freshly-inserted one), and a flag so the caller
    /// can decide whether to record a user-facing transaction.
    ///
    /// Used by both proposal-accept paths (sibling and parent) to
    /// prevent the same parent→child edge being inserted twice when
    /// a re-run surfaces an already-applied proposal. See
    /// `ProposalDedup` for the profile-level dedup that pairs with
    /// this for the same use case.
    @discardableResult
    func addRelationshipIfAbsent(
        _ rel: Relationship,
        existenceEvidence: RelationshipExistenceEvidence? = nil
    ) throws -> (id: UUID, inserted: Bool) {
        // role is optional; null in DB when unspecified. Match both
        // shapes — same parent edge with unspecified role on one row
        // and `.father` on another shouldn't count as distinct.
        let roleValue: String? = rel.role?.rawValue
        let existingID: UUID? = try dbQueue.read { db in
            let row: Row?
            // NB: the `relationships` table's columns are `from_id`/`to_id`
            // (see the v1 CREATE at the top of the migrator); the
            // `from_profile_id`/`to_profile_id` names belong to
            // `pending_relationships`. This dedup SELECT previously used the
            // pending-table names against `relationships`, which throws
            // "no such column" the instant the read runs — a latent bug with
            // no prior coverage. Corrected here because E4's AC3 (idempotent
            // existence rows through this method) requires the dedup to work.
            if let roleValue {
                row = try Row.fetchOne(db, sql: """
                    SELECT id FROM relationships
                    WHERE from_id = ?
                      AND to_id = ?
                      AND type = ?
                      AND (role = ? OR role IS NULL)
                    LIMIT 1
                    """, arguments: [rel.from, rel.to, rel.type.rawValue, roleValue])
            } else {
                row = try Row.fetchOne(db, sql: """
                    SELECT id FROM relationships
                    WHERE from_id = ?
                      AND to_id = ?
                      AND type = ?
                    LIMIT 1
                    """, arguments: [rel.from, rel.to, rel.type.rawValue])
            }
            guard let row else { return nil }
            let raw = row["id"] as String
            return UUID(uuidString: raw)
        }
        if let existingID {
            // Edge already present (a re-run surfaced an already-applied
            // proposal). E4 AC3 — idempotent: attaching the same driving
            // record's existence source to the existing edge is a no-op
            // (the recorder dedups on (edge, origin, raw)). A genuinely new
            // corroborating record still lands as a second existence row.
            // This is NOT a backfill of a bare legacy edge — it fires only
            // when today's accept was handed evidence.
            if let existenceEvidence {
                _ = try dbQueue.write { db in
                    try Self.recordRelationshipExistenceSource(
                        relationshipID: existingID.uuidString,
                        evidence: existenceEvidence,
                        transactionID: nil,
                        db: db
                    )
                }
            }
            return (existingID, false)
        }
        try addRelationship(rel, existenceEvidence: existenceEvidence)
        return (rel.id, true)
    }

    /// Remove a relationship. Records the old values for undo replay.
    @discardableResult
    func removeRelationship(id: UUID) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .removeRelationship(relationshipID: id),
            undoStrategy: .replay,
            startedAt: now, completedAt: now,
            changeCount: 1, profileCount: 0
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            try db.execute(sql: "DELETE FROM relationships WHERE id = ?", arguments: [id.uuidString])
        }

        return transaction
    }

    /// Fill in the marriage_date and/or marriage_location columns of an
    /// existing spouse relationship — but only where the current value is
    /// NULL. Mirrors the "Check Before Overwrite" rule applied to profile
    /// fields: never replace a value the user already supplied. Returns the
    /// transaction so callers can chain audit / undo.
    @discardableResult
    func fillRelationshipMarriage(
        relationshipID: UUID,
        candidateDate: GenealogicalDate?,
        candidateLocation: String?
    ) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .manualEdit,
            undoStrategy: .replay,
            startedAt: now, completedAt: now,
            changeCount: 0, profileCount: 0
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            // Read current values to honour the overwrite policy. The
            // "Check Before Overwrite" rule (feedback_check_before_overwrite.md)
            // is directional: precise data must not be replaced with
            // imprecise data. Earlier code implemented this as an absolute
            // nil-only rule, which silently blocked precise BMD quarters
            // from overwriting wide GEDCOM ranges. Now: overwrite when the
            // candidate's year-span is strictly narrower than the existing
            // value's. Mirrors ApplyEngine.shouldOverwriteDateField.
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT marriage_date_original, marriage_date_earliest,
                           marriage_date_latest, marriage_location
                    FROM relationships WHERE id = ?
                    """,
                arguments: [relationshipID.uuidString]
            ) else { return }

            let existingDate: String? = row["marriage_date_original"]
            let existingEarliest: Int? = row["marriage_date_earliest"]
            let existingLatest: Int? = row["marriage_date_latest"]
            let existingLocation: String? = row["marriage_location"]

            let candidateNarrower: Bool = {
                guard let date = candidateDate else { return false }
                if existingDate == nil { return true }
                let candidateSpan: Int = {
                    guard let e = date.earliest, let l = date.latest else { return .max }
                    return l - e
                }()
                let existingSpan: Int = {
                    guard let e = existingEarliest, let l = existingLatest else { return .max }
                    return l - e
                }()
                return candidateSpan < existingSpan
            }()

            if candidateNarrower, let date = candidateDate {
                try db.execute(sql: """
                    UPDATE relationships SET
                        marriage_date_original = ?,
                        marriage_date_earliest = ?,
                        marriage_date_latest = ?,
                        marriage_date_qualifier = ?
                    WHERE id = ?
                    """, arguments: [
                        date.original, date.earliest, date.latest,
                        date.qualifier.rawValue, relationshipID.uuidString,
                    ])
            }
            if (existingLocation ?? "").isEmpty,
               let loc = candidateLocation?.trimmingCharacters(in: .whitespaces),
               !loc.isEmpty {
                try db.execute(
                    sql: "UPDATE relationships SET marriage_location = ? WHERE id = ?",
                    arguments: [loc, relationshipID.uuidString]
                )
            }
        }

        return transaction
    }

    /// Update a simple string field on a profile. Creates a FieldChange for undo.
    func updateProfileField(
        profileID: String,
        field: ProfileField,
        oldValue: String?,
        newValue: String?,
        source: SourceOrigin,
        transactionID: UUID,
        db: Database
    ) throws {
        guard let column = Self.profileFieldToColumn(field.rawValue) else { return }

        if let newVal = newValue {
            try db.execute(
                sql: "UPDATE profiles SET \(column) = ? WHERE id = ?",
                arguments: [newVal, profileID]
            )
        } else {
            try db.execute(
                sql: "UPDATE profiles SET \(column) = NULL WHERE id = ?",
                arguments: [profileID]
            )
        }

        // Record field change
        try db.execute(sql: """
            INSERT INTO field_changes (id, transaction_id, entity_id, entity_kind, field, old_value, new_value, source, reason)
            VALUES (?, ?, ?, 'profile', ?, ?, ?, ?, NULL)
            """, arguments: [
                UUID().uuidString, transactionID.uuidString, profileID,
                field.rawValue, oldValue, newValue ?? "", source.identifier,
            ])

        // Add field source
        try db.execute(sql: """
            INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at, created_by_transaction_id)
            VALUES (?, 'profile', ?, ?, ?, ?, ?)
            """, arguments: [
                profileID, field.rawValue, source.identifier,
                newValue ?? "", Date(), transactionID.uuidString,
            ])
    }

    /// Update a date field on a profile. Handles the 4-column pattern (original/earliest/latest/qualifier).
    func updateProfileDateField(
        profileID: String,
        field: ProfileField,
        oldDate: GenealogicalDate?,
        newDate: GenealogicalDate?,
        source: SourceOrigin,
        transactionID: UUID,
        db: Database
    ) throws {
        let prefix: String
        switch field {
        case .birthDate: prefix = "birth_date"
        case .deathDate: prefix = "death_date"
        default: return // Only date fields use this method
        }

        if let date = newDate {
            try db.execute(
                sql: """
                UPDATE profiles SET \(prefix)_original = ?, \(prefix)_earliest = ?,
                    \(prefix)_latest = ?, \(prefix)_qualifier = ?
                WHERE id = ?
                """,
                arguments: [date.original, date.earliest, date.latest, date.qualifier.rawValue, profileID]
            )
        } else {
            try db.execute(
                sql: """
                UPDATE profiles SET \(prefix)_original = NULL, \(prefix)_earliest = NULL,
                    \(prefix)_latest = NULL, \(prefix)_qualifier = NULL
                WHERE id = ?
                """,
                arguments: [profileID]
            )
        }

        // Record field change (store original string for undo)
        try db.execute(sql: """
            INSERT INTO field_changes (id, transaction_id, entity_id, entity_kind, field, old_value, new_value, source, reason)
            VALUES (?, ?, ?, 'profile', ?, ?, ?, ?, NULL)
            """, arguments: [
                UUID().uuidString, transactionID.uuidString, profileID,
                field.rawValue, oldDate?.original, newDate?.original ?? "", source.identifier,
            ])

        // Add field source
        if let date = newDate {
            try db.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at, created_by_transaction_id)
                VALUES (?, 'profile', ?, ?, ?, ?, ?)
                """, arguments: [
                    profileID, field.rawValue, source.identifier,
                    date.original, Date(), transactionID.uuidString,
                ])
        }
    }

    /// Create a manual edit transaction that applies multiple field changes at once.
    @discardableResult
    func editProfile(
        profileID: String,
        changes: [(field: ProfileField, oldValue: String?, newValue: String?)],
        dateChanges: [(field: ProfileField, oldDate: GenealogicalDate?, newDate: GenealogicalDate?)],
        source: SourceOrigin
    ) throws -> Transaction {
        let now = Date()
        let totalChanges = changes.count + dateChanges.count
        let transaction = Transaction(
            id: UUID(),
            kind: .manualEdit,
            undoStrategy: .replay,
            startedAt: now, completedAt: now,
            changeCount: totalChanges, profileCount: 1
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            for change in changes {
                try self.updateProfileField(
                    profileID: profileID,
                    field: change.field,
                    oldValue: change.oldValue,
                    newValue: change.newValue,
                    source: source,
                    transactionID: transaction.id,
                    db: db
                )
            }

            for dateChange in dateChanges {
                try self.updateProfileDateField(
                    profileID: profileID,
                    field: dateChange.field,
                    oldDate: dateChange.oldDate,
                    newDate: dateChange.newDate,
                    source: source,
                    transactionID: transaction.id,
                    db: db
                )
            }
        }

        return transaction
    }

    /// Record an alternative fact for a profile field. The existing column
    /// value is **not** changed — instead, a new entry is appended to
    /// `field_sources` so the field shows multiple competing values. Used by
    /// EditPersonView when the user opts to "Record alternative" rather than
    /// "Correct" an imported value.
    ///
    /// Undo strategy: `.structural`, so undoing the transaction simply removes
    /// the inserted field_sources row. No column update means no replay needed.
    @discardableResult
    func recordAlternativeFact(
        profileID: String,
        field: ProfileField,
        rawValue: String,
        source: SourceOrigin
    ) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .manualEdit,
            undoStrategy: .structural,
            startedAt: now, completedAt: now,
            changeCount: 1, profileCount: 1
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            try db.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at, created_by_transaction_id)
                VALUES (?, 'profile', ?, ?, ?, ?, ?)
                """, arguments: [
                    profileID, field.rawValue, source.identifier,
                    rawValue, Date(), transaction.id.uuidString,
                ])
        }

        return transaction
    }

    /// Soft-delete profiles — sets is_deleted = 1. Reversible via restore.
    @discardableResult
    func softDeleteProfiles(ids: [String]) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .softDelete(profileIDs: ids),
            undoStrategy: .replay,
            startedAt: now, completedAt: now,
            changeCount: ids.count, profileCount: ids.count
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            for id in ids {
                try db.execute(
                    sql: "UPDATE profiles SET is_deleted = 1 WHERE id = ?",
                    arguments: [id]
                )
                // Record field change for undo
                try db.execute(sql: """
                    INSERT INTO field_changes (id, transaction_id, entity_id, entity_kind, field, old_value, new_value, source, reason)
                    VALUES (?, ?, ?, 'profile', 'is_deleted', '0', '1', 'manual', 'soft delete')
                    """, arguments: [UUID().uuidString, transaction.id.uuidString, id])
            }
        }

        return transaction
    }

    /// Restore soft-deleted profiles — sets is_deleted = 0.
    @discardableResult
    func restoreProfiles(ids: [String]) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .manualEdit,
            undoStrategy: .replay,
            startedAt: now, completedAt: now,
            changeCount: ids.count, profileCount: ids.count
        )

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            for id in ids {
                try db.execute(
                    sql: "UPDATE profiles SET is_deleted = 0 WHERE id = ?",
                    arguments: [id]
                )
                try db.execute(sql: """
                    INSERT INTO field_changes (id, transaction_id, entity_id, entity_kind, field, old_value, new_value, source, reason)
                    VALUES (?, ?, ?, 'profile', 'is_deleted', '1', '0', 'manual', 'restore')
                    """, arguments: [UUID().uuidString, transaction.id.uuidString, id])
            }
        }

        return transaction
    }

    /// Load all soft-deleted profiles (for Settings > Deleted People).
    func loadDeletedProfiles() throws -> [Profile] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM profiles WHERE is_deleted = 1")
            return try rows.map { try Self.profileFromRow($0, db: db) }
        }
    }

    /// Update the home person ID on the project metadata.
    func setHomePerson(id: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project_meta SET home_person_id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Private Helpers for Manual Entry

    /// Insert field sources for all non-nil fields on a profile.
    private static func insertFieldSources(
        for profile: Profile,
        source: SourceOrigin,
        transactionID: UUID,
        db: Database
    ) throws {
        let now = Date()
        let fields: [(ProfileField, String?)] = [
            (.firstName, profile.firstName),
            (.middleName, profile.middleName),
            (.lastName, profile.lastName),
            (.nickName, profile.nickName),
            (.mothersMaidenName, profile.mothersMaidenName),
            (.gender, profile.gender?.rawValue),
            (.birthDate, profile.birthDate?.original),
            (.birthLocation, profile.birthLocation),
            (.deathDate, profile.deathDate?.original),
            (.deathLocation, profile.deathLocation),
            (.bio, profile.bio),
        ]

        for (field, value) in fields {
            guard let raw = value else { continue }
            try db.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at, created_by_transaction_id)
                VALUES (?, 'profile', ?, ?, ?, ?, ?)
                """, arguments: [
                    profile.id, field.rawValue, source.identifier,
                    raw, now, transactionID.uuidString,
                ])
        }
    }

    /// Update the citation/quality on the most-recent field_sources row
    /// matching (profileID, field, origin). Per DESIGN.md §5.12, citations
    /// are layered onto existing sources rather than replacing them; the
    /// raw value stays untouched. nil arguments clear that column.
    /// No-op when no matching row exists.
    func updateFieldSourceCitation(
        profileID: String,
        field: ProfileField,
        origin: SourceOrigin,
        citation: Citation?,
        quality: EvidenceQuality?
    ) throws {
        let citationJSON: String? = citation.flatMap { c -> String? in
            guard !c.isEmpty else { return nil }
            return Self.encodeJSON(c)
        }
        try dbQueue.write { db in
            // Update the rowid-most-recent matching source so manual edits
            // attach to the freshest entry rather than back-dated imports.
            try db.execute(sql: """
                UPDATE field_sources
                SET citation_json = ?, evidence_quality = ?
                WHERE rowid = (
                    SELECT rowid FROM field_sources
                    WHERE entity_id = ? AND entity_kind = 'profile'
                          AND field = ? AND origin = ?
                    ORDER BY rowid DESC LIMIT 1
                )
                """, arguments: [
                    citationJSON, quality?.rawValue,
                    profileID, field.rawValue, origin.identifier,
                ])
        }
    }

    // MARK: - Edge-existence provenance (MODEL_EVOLUTION_SPEC §Change4 / E4)

    /// The reason we believe an edge exists, in the two shapes E4's write
    /// points produce. Callers hand one of these to the edge-creation methods
    /// (`addRelationship`/`addRelationshipIfAbsent`/`addFamily`) so the
    /// existence row lands inside the *same* write transaction as the edge —
    /// carrying `created_by_transaction_id` like every other provenance row.
    ///
    /// Forward-only (decision log #4): this is only ever attached when an edge
    /// is materialised. There is no variant that rewrites a pre-existing edge.
    nonisolated enum RelationshipExistenceEvidence: Sendable {
        /// The edge exists because of this scored record (accept / promote /
        /// enrichment paths). Origin, URL, trust-tier-bearing citation and the
        /// human-readable "because of this record" note are all derived from
        /// the record — no tier is asserted.
        case record(ScoredRecord)
        /// The edge was created by user action or a third-party import that
        /// carries no citable record (manual add, GEDCOM/WikiTree import). The
        /// origin states the tier honestly (`.userAuthoritative` /
        /// `.initialImport`) and `raw` is a short origin note.
        case origin(SourceOrigin, note: String)
    }

    /// Record an existence source for `relationshipID` from a piece of
    /// `RelationshipExistenceEvidence`, inside the given transaction. Shared by
    /// the edge-creation write paths.
    @discardableResult
    static func recordRelationshipExistenceSource(
        relationshipID: String,
        evidence: RelationshipExistenceEvidence,
        transactionID: UUID?,
        db: Database
    ) throws -> Bool {
        switch evidence {
        case .record(let scored):
            return try recordRelationshipExistenceSource(
                relationshipID: relationshipID,
                from: scored,
                transactionID: transactionID,
                db: db
            )
        case .origin(let origin, let note):
            return try recordRelationshipExistenceSource(
                relationshipID: relationshipID,
                origin: origin,
                raw: note,
                citation: nil,
                quality: nil,
                transactionID: transactionID,
                db: db
            )
        }
    }


    /// The `field` value under which an edge's existence provenance is stored
    /// in `field_sources`. A relationship (`entity_kind = 'relationship'`) row
    /// with this field answers "why do we believe this edge exists?" — it
    /// cites the driving record, exactly as a profile field-source cites the
    /// record that attests a birth date. Mirrors `RelationshipField.existence`
    /// from AncestorKit; kept as a string constant here so the SQL write path
    /// never has to import the enum's rawValue at every call site.
    static let relationshipExistenceField = RelationshipField.existence.rawValue

    /// Record why a relationship edge exists, citing the driving record.
    ///
    /// E4, forward-only (decision log #4): callers invoke this **only when
    /// materialising a fresh edge from evidence**. It is never called to
    /// backfill an edge that already existed before E4 — doing so would
    /// fabricate provenance that was never captured.
    ///
    /// Idempotent (AC3): re-running an accept, or `addRelationshipIfAbsent`
    /// on an edge that already carries the same existence citation, inserts
    /// no duplicate. Identity of an existence row is `(relationshipID, field
    /// = "existence", origin, raw)` — the same driving record recorded twice
    /// is one row; a *different* corroborating record legitimately adds a
    /// second existence row (edges, like fields, can be multiply attested).
    ///
    /// Trust tier stays URL-derived (firewall): the caller passes a `Citation`
    /// whose `url` was resolved through `SourceTierRegistry`; this method never
    /// asserts a tier. `origin` is the source identifier (e.g. "freebmd"), or
    /// a `.userAuthoritative` / `.initialImport` origin for manual/import
    /// edges whose `raw` is a short human-readable origin note.
    ///
    /// - Returns: `true` if a new existence row was inserted, `false` if an
    ///   identical row already existed (idempotent no-op).
    @discardableResult
    static func recordRelationshipExistenceSource(
        relationshipID: String,
        origin: SourceOrigin,
        raw: String,
        citation: Citation?,
        quality: EvidenceQuality?,
        transactionID: UUID?,
        db: Database
    ) throws -> Bool {
        // Idempotency pre-check: same edge + same origin + same raw ⇒ already
        // recorded. Deliberately keyed on (entity_id, entity_kind, field,
        // origin, raw) not rowid, so a re-run producing the identical citation
        // is a no-op while a genuinely new corroborating source still lands.
        let existing = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM field_sources
            WHERE entity_id = ? AND entity_kind = 'relationship'
                  AND field = ? AND origin = ? AND raw = ?
            """, arguments: [
                relationshipID, relationshipExistenceField, origin.identifier, raw,
            ]) ?? 0
        if existing > 0 { return false }

        let citationJSON: String? = citation.flatMap { c -> String? in
            guard !c.isEmpty else { return nil }
            return encodeJSON(c)
        }
        try db.execute(sql: """
            INSERT INTO field_sources
                (entity_id, entity_kind, field, origin, raw, added_at,
                 created_by_transaction_id, citation_json, evidence_quality)
            VALUES (?, 'relationship', ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                relationshipID, relationshipExistenceField, origin.identifier,
                raw, Date(), transactionID?.uuidString,
                citationJSON, quality?.rawValue,
            ])
        return true
    }

    /// Build the existence-provenance origin/raw/citation from the driving
    /// `ScoredRecord` and record it for a freshly-materialised edge.
    ///
    /// - `origin` is `SourceOrigin(identifier: record.sourceID)` — the trust
    ///   tier is thereby URL-derived downstream, never asserted here.
    /// - `citation.url` is `record.detailURL`; `citation.title` is the rendered
    ///   citation's short form. This is the same URL a field-source cites, so
    ///   `SourceTierRegistry` resolves the tier identically.
    /// - `raw` is the rendered short citation — a human-readable "because of
    ///   this record" string shown in a future "why this edge exists" inspector.
    @discardableResult
    static func recordRelationshipExistenceSource(
        relationshipID: String,
        from scoredRecord: ScoredRecord,
        transactionID: UUID?,
        db: Database
    ) throws -> Bool {
        let rendered = CitationRenderer.cite(scoredRecord.record)
        let citation = Citation(
            title: rendered.short,
            url: rendered.url,
            dateAccessed: rendered.accessedAt
        )
        return try recordRelationshipExistenceSource(
            relationshipID: relationshipID,
            origin: SourceOrigin(identifier: scoredRecord.record.sourceID),
            raw: rendered.short,
            citation: citation,
            quality: nil,
            transactionID: transactionID,
            db: db
        )
    }

    /// Read an edge's existence provenance — the record(s) that attest it.
    ///
    /// Returns `[]` for any edge created before E4 (forward-only, decision
    /// log #4): no backfill ever ran, so legacy edges legitimately have no
    /// existence source and behave exactly as before. A non-empty result is
    /// the "why this edge exists" evidence, reconstructed as full
    /// `FieldSource`s (origin + raw + citation + quality) just like profile
    /// field-sources.
    func existenceSources(forRelationshipID relationshipID: String) throws -> [FieldSource] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT origin, raw, added_at, citation_json, evidence_quality, fact_confidence
                FROM field_sources
                WHERE entity_id = ? AND entity_kind = 'relationship' AND field = ?
                ORDER BY rowid ASC
                """, arguments: [relationshipID, Self.relationshipExistenceField])
            return rows.map { row in
                let origin = SourceOrigin(identifier: row["origin"])
                let raw: String = row["raw"]
                let addedAt: Date = row["added_at"]
                var citation: Citation?
                if let json: String = row["citation_json"],
                   let data = json.data(using: .utf8) {
                    citation = try? JSONDecoder().decode(Citation.self, from: data)
                }
                let quality: EvidenceQuality? = (row["evidence_quality"] as Int?)
                    .flatMap(EvidenceQuality.init(rawValue:))
                let confidence: FactConfidence? = (row["fact_confidence"] as Int?)
                    .flatMap(FactConfidence.init(rawInt:))
                return FieldSource(
                    origin: origin, raw: raw, addedAt: addedAt,
                    citation: citation, quality: quality, confidence: confidence
                )
            }
        }
    }
}

// MARK: - GenealogicalDate internal init for database reconstruction

// MARK: - Research Persistence

nonisolated extension ProjectDatabase {

    /// Save a research run record. `resultJSON` carries the per-run
    /// envelope consumed by the SWIFT_MCP_EVAL_BACKEND `get_research_result`
    /// tool (#Change4); the in-app paths leave it empty.
    func saveResearchRun(
        id: UUID, profileID: String, mode: ResearchMode,
        startedAt: Date, completedAt: Date,
        factCount: Int, leadCount: Int, clusterCount: Int, gpsScore: Int?,
        resultJSON: String = ""
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO research_runs
                (id, profile_id, mode, started_at, completed_at, fact_count, lead_count, cluster_count, gps_score, result_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id.uuidString, profileID, mode.rawValue,
                    startedAt, completedAt,
                    factCount, leadCount, clusterCount, gpsScore,
                    resultJSON
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

    /// Update the structured location codes on a profile. Bypasses the per-field
    /// source attribution path because the codes are derived metadata from the
    /// gazetteer picker, not facts from an external source. Codes can be `nil`
    /// (user typed freeform that didn't match any gazetteer entry).
    func updateProfileLocationCodes(
        profileID: String,
        birthCode: String?,
        deathCode: String?
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE profiles
                SET birth_location_code = ?, death_location_code = ?
                WHERE id = ?
                """, arguments: [birthCode, deathCode, profileID])
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

    /// Load rejected record IDs for a profile. Returns the union of two
    /// sources: the legacy `record_rejections` table (write-only path for
    /// derived proposals like ghost-parent inferences that have no
    /// evidence_records row) and `evidence_records.user_status = 'discarded'`
    /// (the new canonical path for source-derived records). Older projects
    /// keep working without re-migration; new code only writes the
    /// `evidence_records` side via `updateEvidenceUserStatus(...)`.
    func loadRejections(profileID: String) throws -> Set<String> {
        try dbQueue.read { db in
            let legacy = try Row.fetchAll(db, sql: """
                SELECT record_id FROM record_rejections WHERE profile_id = ?
                """, arguments: [profileID]).map { $0["record_id"] as String }
            let modern = try String.fetchAll(db, sql: """
                SELECT source_record_id FROM evidence_records
                WHERE profile_id = ? AND user_status = 'discarded'
                """, arguments: [profileID])
            return Set(legacy).union(modern)
        }
    }

    /// Remove a rejection so a restored record is genuinely live again —
    /// `saveRejection` and `user_status = 'discarded'` are written together
    /// on discard, so a restore must clear both or `loadRejections` keeps
    /// suppressing the record in future runs.
    func deleteRejection(profileID: String, recordID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM record_rejections
                WHERE profile_id = ? AND record_id = ?
                """, arguments: [profileID, recordID])
        }
    }

    /// Record ids the user has already ADJUDICATED — applied/kept
    /// (`saved_as_lead`) or discarded — plus legacy `record_rejections`.
    /// The campaign review surface drops these from its needs-review
    /// counts; NULL / `unreviewed` rows stay live. Distinct from
    /// `loadRejections`, which the pipeline uses to suppress re-proposal
    /// and therefore must NOT include kept records.
    func adjudicatedEvidenceRecordIDs(profileID: String) throws -> Set<String> {
        try dbQueue.read { db in
            let legacy = try Row.fetchAll(db, sql: """
                SELECT record_id FROM record_rejections WHERE profile_id = ?
                """, arguments: [profileID]).map { $0["record_id"] as String }
            let modern = try String.fetchAll(db, sql: """
                SELECT source_record_id FROM evidence_records
                WHERE profile_id = ? AND user_status IN ('discarded', 'saved_as_lead')
                """, arguments: [profileID])
            return Set(legacy).union(modern)
        }
    }

    /// Attach a citation to the NEWEST uncited field_sources row for
    /// (profile, field, origin) — the row an ApplyEngine write branch just
    /// produced (fill-write, alternative fact, or CL5 displacement all
    /// insert one). Sourcing-gate fix 2026-07-15: research applies carried
    /// origin only, so `FieldSource.citation` stayed nil forever — the
    /// Sourcing tab's visibility gate could never fire from research and
    /// per-field citations were missing despite living in evidence_records.
    func attachFieldSourceCitation(
        profileID: String, field: ProfileField, origin: SourceOrigin, citation: Citation
    ) throws {
        let json = String(data: try JSONEncoder().encode(citation), encoding: .utf8)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE field_sources SET citation_json = ?
                WHERE rowid = (
                    SELECT rowid FROM field_sources
                    WHERE entity_id = ? AND entity_kind = 'profile'
                      AND field = ? AND origin = ? AND citation_json IS NULL
                    ORDER BY rowid DESC LIMIT 1
                )
                """, arguments: [json, profileID, field.rawValue, origin.identifier])
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
    ///
    /// When `params` is non-nil it is the per-query wire identity
    /// (`QueryCache.cacheKey`) and the write UPSERTs on
    /// (profile_id, source_id, record_type, search_params) — a re-run of
    /// the same clean-negative query refreshes `searched_at` in place
    /// (advancing the T1-04 freshness window) rather than accumulating a
    /// duplicate row. The `__whole_tree__` resume-state writer and any
    /// NULL-param legacy callers fall through to a plain INSERT (the
    /// unique index is partial on `search_params IS NOT NULL`).
    /// `resultKind`/`hitCount` (v42, spec §6.6): how the search concluded —
    /// 'zero' | 'sparse' | 'positive' | 'truncated' plus the claimed hit
    /// count. The genuine-negative writer stamps 'zero'/0; NULL means a
    /// legacy pre-v42 row (readers treat as 'zero') or a non-search reuse
    /// of the table (whole-tree resume state).
    func saveNegativeSearch(
        profileID: String, sourceID: String, recordType: String, params: String?,
        resultKind: String? = nil, hitCount: Int? = nil
    ) throws {
        try dbQueue.write { db in
            if params != nil {
                try db.execute(sql: """
                    INSERT INTO negative_searches (profile_id, source_id, record_type, searched_at, search_params, result_kind, hit_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (profile_id, source_id, record_type, search_params)
                    WHERE search_params IS NOT NULL
                    DO UPDATE SET searched_at = excluded.searched_at,
                                  result_kind = excluded.result_kind,
                                  hit_count = excluded.hit_count
                    """, arguments: [profileID, sourceID, recordType, Date(), params, resultKind, hitCount])
            } else {
                try db.execute(sql: """
                    INSERT INTO negative_searches (profile_id, source_id, record_type, searched_at, search_params, result_kind, hit_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [profileID, sourceID, recordType, Date(), params, resultKind, hitCount])
            }
        }
    }

    // MARK: - Source budget state (ENGINE_FOUNDATION #Change5)

    /// Load every persisted per-source request window. Used by
    /// `SourceBudgetTracker` at startup to rehydrate counters so a spent
    /// daily budget survives a process restart (§Change6 depends on this).
    /// Returns raw window rows; the tracker applies the roll-forward /
    /// pause math against a live clock.
    func loadSourceBudgetWindows() throws -> [SourceBudgetWindow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_id, window_start, request_count
                FROM source_budget_state
                """)
            return rows.map {
                SourceBudgetWindow(
                    sourceID: $0["source_id"] as String,
                    windowStart: $0["window_start"] as Date,
                    requestCount: $0["request_count"] as Int
                )
            }
        }
    }

    /// Persist one source's current window. UPSERT on `source_id` — there is
    /// exactly one row per source (a quota is global to the volunteer host,
    /// not per-tree). Called on every counted request; cheap single-row write.
    func saveSourceBudgetWindow(_ window: SourceBudgetWindow) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source_budget_state (source_id, window_start, request_count, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (source_id)
                DO UPDATE SET window_start = excluded.window_start,
                              request_count = excluded.request_count,
                              updated_at = excluded.updated_at
                """, arguments: [window.sourceID, window.windowStart, window.requestCount, Date()])
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

    /// Load per-query clean negatives for a profile (connector-audit
    /// T1-04 reader). Returns the wire-identity `queryKey`
    /// (`QueryCache.cacheKey`, stored in `search_params`) and the last
    /// time it was proved cleanly empty, so the cross-run suppressor can
    /// match a next-run query verbatim and apply its freshness window.
    /// NULL-param rows (legacy pair-level aggregates, `__whole_tree__`
    /// resume state) are excluded — only rows carrying a real query key
    /// can suppress a future dispatch.
    ///
    /// v42 guard: only clean-zero rows may suppress. `result_kind` NULL
    /// means a legacy pre-v42 row, which the writer only ever produced
    /// for clean zeros — treated as 'zero'. Any future writer that
    /// persists truncated/positive kinds is automatically excluded here,
    /// so a partial answer can never suppress a re-search (T1-04
    /// correctness guard (a), moved into the reader).
    func loadNegativeSearchKeys(
        profileID: String
    ) throws -> [(sourceID: String, recordType: String, queryKey: String, date: Date)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_id, record_type, search_params, searched_at
                FROM negative_searches
                WHERE profile_id = ? AND search_params IS NOT NULL
                  AND (result_kind IS NULL OR result_kind = 'zero')
                ORDER BY searched_at DESC
                """, arguments: [profileID])
            return rows.map {
                (sourceID: $0["source_id"] as String,
                 recordType: $0["record_type"] as String,
                 queryKey: $0["search_params"] as String,
                 date: $0["searched_at"] as Date)
            }
        }
    }

    // MARK: - Evidence Records

    /// Save a scored record as evidence for a profile. JSON-encodes the full
    /// SourceRecord so every typed and raw field is preserved. Idempotent —
    /// re-saving the same (profileID, sourceRecordID) overwrites in place.
    ///
    /// `user_status` is **preserved** on conflict (Task #41). If the user has
    /// already marked this record as `saved_as_lead` or `discarded` in a prior
    /// run, re-saving the scorer's view must not silently reset that decision.
    /// `INSERT … ON CONFLICT DO UPDATE` excludes `user_status` from the SET
    /// clause; on first insert the column's default value (`'unreviewed'`)
    /// applies.
    func saveEvidence(profileID: String, scored: ScoredRecord, citationFull: String?, citationURL: String?,
                      isEnrichment: Bool = false, runID: String? = nil) throws {
        let compositeID = EvidenceRecord.compositeID(profileID: profileID, sourceRecordID: scored.record.id)
        let recordJSON = Self.encodeJSON(scored.record)
        // CAMPAIGN_REVIEW_SPEC Change 2 — the FULL scorer output persists:
        // gates + summary make the row a complete ScoredRecord; the
        // enrichment flag preserves the run's cluster-input exclusion; the
        // run id links the row to the run that last scored it.
        let gatesJSON = Self.encodeJSON(scored.gates)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records
                (id, profile_id, source_id, source_record_id, record_type, verdict, record_json, citation_full, citation_url, scored_at,
                 gates_json, summary, is_enrichment, last_run_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    source_record_id = excluded.source_record_id,
                    record_type = excluded.record_type,
                    verdict = excluded.verdict,
                    record_json = excluded.record_json,
                    citation_full = excluded.citation_full,
                    citation_url = excluded.citation_url,
                    scored_at = excluded.scored_at,
                    gates_json = excluded.gates_json,
                    summary = excluded.summary,
                    is_enrichment = excluded.is_enrichment,
                    last_run_id = excluded.last_run_id
                """, arguments: [
                    compositeID,
                    profileID,
                    scored.record.sourceID,
                    scored.record.id,
                    scored.record.recordType.rawValue,
                    scored.verdict.rawValue,
                    recordJSON,
                    citationFull,
                    citationURL,
                    Date(),
                    gatesJSON,
                    scored.summary,
                    isEnrichment ? 1 : 0,
                    runID,
                ])
        }
    }

    /// Load all evidence records for a profile, newest first.
    func loadEvidenceForProfile(_ profileID: String) throws -> [EvidenceRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, profile_id, source_id, source_record_id, record_type, verdict, record_json, citation_full, citation_url, scored_at, user_status,
                       gates_json, summary, is_enrichment, last_run_id
                FROM evidence_records
                WHERE profile_id = ?
                ORDER BY scored_at DESC
                """, arguments: [profileID])
            return rows.compactMap { row in
                guard let recordType = RecordType(rawValue: row["record_type"] as String),
                      let verdict = RecordVerdict(rawValue: row["verdict"] as String),
                      let json = row["record_json"] as String?,
                      let data = json.data(using: .utf8),
                      let record = try? JSONDecoder().decode(SourceRecord.self, from: data)
                else { return nil }
                // Defensive fallback: pre-v16 rows or unrecognised values
                // collapse to `.unreviewed` so an upgrade can't strand data
                // behind a parsing failure.
                let userStatus = (row["user_status"] as String?)
                    .flatMap(UserReviewStatus.init(rawValue:)) ?? .unreviewed
                // Pre-v44 rows have no persisted gates/summary — decode
                // leniently to the pre-Change-2 reconstruction shape
                // (empty gates, empty summary) rather than dropping data.
                let gates: [GateResult] = (row["gates_json"] as String?)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([GateResult].self, from: $0) } ?? []
                return EvidenceRecord(
                    id: row["id"] as String,
                    profileID: row["profile_id"] as String,
                    sourceID: row["source_id"] as String,
                    sourceRecordID: row["source_record_id"] as String,
                    recordType: recordType,
                    verdict: verdict,
                    record: record,
                    citationFull: row["citation_full"] as String?,
                    citationURL: row["citation_url"] as String?,
                    scoredAt: row["scored_at"] as Date,
                    userStatus: userStatus,
                    gates: gates,
                    summary: (row["summary"] as String?) ?? "",
                    isEnrichment: ((row["is_enrichment"] as Int?) ?? 0) != 0,
                    lastRunID: row["last_run_id"] as String?
                )
            }
        }
    }

    /// Count of evidence rows for a profile — cheap lookup for badge counts in UI.
    func evidenceCountForProfile(_ profileID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM evidence_records WHERE profile_id = ?", arguments: [profileID]) ?? 0
        }
    }

    // MARK: - Evidence convergence (CAMPAIGN_REVIEW_SPEC Change 3)

    /// Upsert the persisted convergence rows for a profile — one per
    /// asserted fact value. Called at run-persist; the stored level is the
    /// chain's CURRENT strength (it rises as independent lineages accumulate
    /// across runs and may legitimately fall on registry re-audits).
    func upsertEvidenceConvergence(
        profileID: String,
        groups: [ConvergenceEngine.ValueGroup]
    ) throws {
        guard !groups.isEmpty else { return }
        try dbQueue.write { db in
            for group in groups {
                try db.execute(sql: """
                    INSERT INTO evidence_convergence
                    (profile_id, value_key, level, sourcing_json, record_ids_json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(profile_id, value_key) DO UPDATE SET
                        level = excluded.level,
                        sourcing_json = excluded.sourcing_json,
                        record_ids_json = excluded.record_ids_json,
                        updated_at = excluded.updated_at
                    """, arguments: [
                        profileID,
                        group.key,
                        group.level.rawValue,
                        Self.encodeJSON(group.sourcing),
                        Self.encodeJSON(group.records.map(\.id)),
                        Date(),
                    ])
            }
        }
    }

    /// One persisted convergence entry — the durable "how strong is this
    /// fact's evidence chain" record the review surfaces read.
    nonisolated struct EvidenceConvergenceRow: Sendable {
        let profileID: String
        let valueKey: String              // "death:1986", "birth:1877", …
        let level: ConvergenceLevel
        let sourcing: SourcingStrength
        let recordIDs: [String]
        let updatedAt: Date
    }

    /// Load a profile's persisted convergence rows, strongest first.
    func loadEvidenceConvergence(profileID: String) throws -> [EvidenceConvergenceRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT profile_id, value_key, level, sourcing_json, record_ids_json, updated_at
                FROM evidence_convergence WHERE profile_id = ?
                """, arguments: [profileID])
            return rows.compactMap { row -> EvidenceConvergenceRow? in
                guard let level = ConvergenceLevel(rawValue: row["level"] as String),
                      let sourcingData = (row["sourcing_json"] as String).data(using: .utf8),
                      let sourcing = try? JSONDecoder().decode(SourcingStrength.self, from: sourcingData)
                else { return nil }
                let ids = (row["record_ids_json"] as String).data(using: .utf8)
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                return EvidenceConvergenceRow(
                    profileID: row["profile_id"] as String,
                    valueKey: row["value_key"] as String,
                    level: level,
                    sourcing: sourcing,
                    recordIDs: ids,
                    updatedAt: row["updated_at"] as Date
                )
            }
            .sorted { $0.level > $1.level }
        }
    }

    /// Set the user-review status for a single evidence row. Idempotent —
    /// repeating the same call leaves the row unchanged.
    func updateEvidenceUserStatus(evidenceID: String, status: UserReviewStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE evidence_records SET user_status = ? WHERE id = ?",
                arguments: [status.rawValue, evidenceID]
            )
        }
    }

    /// Set the user-review status on every evidence row in a profile that
    /// matches one of `sourceRecordIDs`. Used when the UI applies a decision
    /// at cluster level (a cluster contains multiple records; one click
    /// flips them all).
    func updateEvidenceUserStatus(
        profileID: String,
        sourceRecordIDs: [String],
        status: UserReviewStatus
    ) throws {
        guard !sourceRecordIDs.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = Array(repeating: "?", count: sourceRecordIDs.count).joined(separator: ",")
            try db.execute(
                sql: """
                    UPDATE evidence_records
                    SET user_status = ?
                    WHERE profile_id = ? AND source_record_id IN (\(placeholders))
                    """,
                arguments: StatementArguments([status.rawValue, profileID] + sourceRecordIDs)
            )
        }
    }

    /// Set of source-record IDs the user has discarded for this profile.
    /// Pulled live from `evidence_records.user_status = 'discarded'`. Replaces
    /// the old `record_rejections` path — that table still exists for legacy
    /// rows but is no longer the write target.
    func loadDiscardedSourceRecordIDs(profileID: String) throws -> Set<String> {
        try dbQueue.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT source_record_id FROM evidence_records
                WHERE profile_id = ? AND user_status = 'discarded'
                """, arguments: [profileID])
            return Set(ids)
        }
    }
}


// MARK: - Pending Facts

nonisolated extension ProjectDatabase {

    /// Cheap count of pending facts awaiting human review for a profile.
    /// Used by the profile detail header to surface a badge so the user
    /// can see at a glance that a profile has firewall-queued proposals
    /// without having to navigate to Triage. Returns 0 on any DB error.
    func pendingFactCount(profileID: String) -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM pending_facts
                    WHERE profile_id = ? AND review_status = 'pending'
                    """,
                arguments: [profileID]
            ) ?? 0
        }) ?? 0
    }

    /// Pending-review counts for EVERY profile in one query — the Triage
    /// profile selector needs all of them to badge rows and sort
    /// needs-review profiles to the top (an overnight campaign can queue
    /// findings across dozens of profiles; per-row COUNT queries would be
    /// 200+ reads per render). Profiles with zero pending facts are absent
    /// from the dictionary. Returns empty on any DB error.
    func pendingFactCountsByProfile() -> [String: Int] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT profile_id, COUNT(*) AS n FROM pending_facts
                WHERE review_status = 'pending'
                GROUP BY profile_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["profile_id"] as String, $0["n"] as Int)
            })
        }) ?? [:]
    }

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

    /// Insert a pending fact submitted by an external agent (MCP, the
    /// prose-corpus extractor). Uses `INSERT OR IGNORE` so re-runs that
    /// produce the same deterministic `id` (idempotency key) don't
    /// duplicate rows. The MCP server has its own inline SQL for the
    /// same table; this method is the typed Swift equivalent that
    /// in-process agents like `ProseCorpusExtractor` go through.
    func savePendingFact(_ fact: PendingFact) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO pending_facts
                (id, profile_id, fact_kind, value_json, sources_json, review_status, created_at,
                 source_url, source_title, evidence_text, reasoning, agent_id, verification_status)
                VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    fact.id, fact.profileID, fact.field, fact.value,
                    "{}",  // sources_json placeholder — Evidence Firewall reconstructs from source_url/title columns
                    fact.submittedAt,
                    fact.sourceURL, fact.sourceTitle,
                    String(fact.evidenceText.prefix(200)),
                    fact.reasoning, fact.agentID,
                    fact.verificationStatus.rawValue,
                ])
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

    /// Insert a new lead. If a lead with the same `id` already exists the
    /// existing row is preserved — including any user-set status, resolution,
    /// and timestamps. Re-running research therefore can't reset an
    /// `investigating` or `dismissed` lead back to `.new`. Use `upsertLead`
    /// for deliberate status transitions.
    func saveLead(_ lead: Lead) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO leads
                (id, profile_id, name, surname, given_name, birth_year, death_year,
                 age_at_death, place,
                 relationship, source, status, evidence, created_at, investigated_at, resolved_at, resolution)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    lead.id, lead.profileID, lead.name, lead.surname, lead.givenName,
                    lead.birthYear, lead.deathYear, lead.ageAtDeath, lead.place,
                    lead.relationship,
                    lead.source.rawValue, lead.status.rawValue, lead.evidence,
                    lead.createdAt, lead.investigatedAt, lead.resolvedAt, lead.resolution?.rawValue
                ])
        }
    }

    /// Force-write a lead, overwriting any existing row at the same `id`.
    /// Used by status transitions (`updateStatus`, `promote`) where the
    /// caller has authority to mutate the persisted state.
    func upsertLead(_ lead: Lead) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO leads
                (id, profile_id, name, surname, given_name, birth_year, death_year,
                 age_at_death, place,
                 relationship, source, status, evidence, created_at, investigated_at, resolved_at, resolution)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    lead.id, lead.profileID, lead.name, lead.surname, lead.givenName,
                    lead.birthYear, lead.deathYear, lead.ageAtDeath, lead.place,
                    lead.relationship,
                    lead.source.rawValue, lead.status.rawValue, lead.evidence,
                    lead.createdAt, lead.investigatedAt, lead.resolvedAt, lead.resolution?.rawValue
                ])
        }
    }

    /// Decode a persisted lead status, mapping the legacy MCP value
    /// 'resolved' (written by promote_lead before CAMPAIGN_REVIEW_SPEC
    /// Change 1) to `.promoted` instead of dropping the row — those leads
    /// were silently invisible to every in-app surface.
    nonisolated static func leadStatus(fromRaw raw: String) -> LeadStatus? {
        if let status = LeadStatus(rawValue: raw) { return status }
        if raw == "resolved" { return .promoted }
        return nil
    }

    func loadLeads() throws -> [Lead] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM leads ORDER BY created_at DESC")
            return rows.compactMap { row -> Lead? in
                guard let source = LeadSource(rawValue: row["source"] as String),
                      let status = Self.leadStatus(fromRaw: row["status"] as String) else { return nil }
                return Lead(
                    id: row["id"],
                    profileID: row["profile_id"],
                    name: row["name"],
                    surname: row["surname"],
                    givenName: row["given_name"],
                    birthYear: row["birth_year"],
                    deathYear: row["death_year"],
                    ageAtDeath: row["age_at_death"],
                    place: row["place"],
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
                      let status = Self.leadStatus(fromRaw: row["status"] as String) else { return nil }
                return Lead(
                    id: row["id"], profileID: row["profile_id"],
                    name: row["name"], surname: row["surname"], givenName: row["given_name"],
                    birthYear: row["birth_year"], deathYear: row["death_year"],
                    ageAtDeath: row["age_at_death"], place: row["place"],
                    relationship: row["relationship"], source: source, status: status,
                    evidence: row["evidence"], createdAt: row["created_at"],
                    investigatedAt: row["investigated_at"], resolvedAt: row["resolved_at"],
                    resolution: (row["resolution"] as String?).flatMap { LeadResolution(rawValue: $0) }
                )
            }
        }
    }
}

// MARK: - Field disputes (M16.14 + CONFLICT_LAYER_SPEC §4.3 C3 — DisputeStore)

/// Full-fidelity projection of one `field_disputes` row (post-v41). The
/// snapshot's `[ProfileField: FieldDispute]` map carries only `fieldValue`
/// kinds; this row type is the store-level contract that carries every
/// kind, the ladder trace, and the witness summary — `allDisputes` over it
/// is the T9 dossier read contract (§4.8.6).
nonisolated struct DisputeRow: Identifiable, Sendable {
    let id: Int64
    let entityID: String
    let entityKind: String
    let kind: DisputeKind
    let field: String
    let reason: DisputeReason
    let severity: DiscrepancySeverity?
    let detectedBy: DisputeProducer?
    let competingSources: [FieldSource]
    let evidenceJSON: String?
    let ladderTrace: String?
    let witnessSummary: String?
    let detectedAt: Date
    let resolution: DisputeResolution?
    let resolvedAt: Date?

    var isOpen: Bool { resolution == nil }

    /// Short label naming HOW a resolved dispute was settled — cited in
    /// GPS criterion 4's met-with-evidence reason string (CL3 ⟨G2⟩).
    var resolutionRuleLabel: String? {
        switch resolution {
        case .rule(let id, _): return id
        case .accepted:        return "user choice"
        case .manual:          return "manual note"
        case .deferred, .none: return nil
        }
    }
}

nonisolated extension ProjectDatabase {

    /// Insert a `FieldDispute` row directly. Predates the conflict layer
    /// (M16.14) — kept for the snapshot round-trip tests and manual
    /// seeding. Production detection goes through `upsertDispute`, which
    /// enforces the one-open-row identity.
    @discardableResult
    func addFieldDispute(profileID: String, dispute: FieldDispute) throws -> Int64 {
        let competingJSON = Self.encodeJSON(dispute.competingSources)
        let resolutionJSON = dispute.resolution.map { Self.encodeJSON($0) }
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO field_disputes
                (entity_id, field, reason, competing_sources, detected_at, resolution,
                 kind, severity, detected_by, resolved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    profileID, dispute.field.rawValue, dispute.reason.rawValue,
                    competingJSON, dispute.detectedAt, resolutionJSON,
                    dispute.kind.rawValue, dispute.severity?.rawValue,
                    dispute.detectedBy?.rawValue,
                    dispute.resolution == nil ? nil : Date(),
                ])
            return db.lastInsertedRowID
        }
    }

    // MARK: - C3 upsert (idempotent; detection runs repeatedly)

    /// Persist a detected conflict, enforcing the C3 identity: at most ONE
    /// open dispute per `(entity_id, kind, field)` (unique partial index,
    /// §5). Behaviour:
    ///
    /// - **No matching open row** → insert a new open dispute stamped with
    ///   `detected_by` ⟨G6⟩, the ladder trace ⟨G2⟩, and the (interim,
    ///   lineage-based) witness summary ⟨G8⟩.
    /// - **Matching open row** → a newly-detected competing value *joins*
    ///   the row's `competing_sources` set (severity floor-ratchets,
    ///   trace + witness summary recomputed); an identical re-detection is
    ///   a no-op.
    /// - **Matching resolved row, no open row** → witness-gated reopen
    ///   scaffolding (§2.8 ⟨G3⟩): a new row opens ONLY when the incoming
    ///   conflict asserts a value not already represented among the
    ///   resolved row's competitors. Until WitnessIdentity ships (CL4)
    ///   value-novelty stands in for witness-novelty — the conservative
    ///   direction (§4.1: when independence cannot be proven it is not
    ///   counted), so an already-weighed value never re-litigates.
    ///
    /// `transactionID` (optional) binds the row to the apply transaction
    /// that surfaced it, so structural/replay undo cascades the dispute
    /// away with the write that caused it (`created_by_transaction_id`).
    @discardableResult
    func upsertDispute(
        profileID: String,
        conflict: DetectedConflict,
        adjudication: DisputeResolver.Adjudication,
        transactionID: UUID? = nil
    ) throws -> Int64 {
        let witnessSummary = Self.interimWitnessSummary(for: conflict.competingSources)
        let traceJSON = adjudication.traceJSON
        let resolutionJSON = adjudication.resolution.map { Self.encodeJSON($0) }

        return try dbQueue.write { db in
            // 1. Join an existing open dispute for the same identity.
            if let openRow = try Row.fetchOne(db, sql: """
                SELECT rowid, competing_sources, severity FROM field_disputes
                WHERE entity_id = ? AND kind = ? AND field = ? AND resolution IS NULL
                """, arguments: [profileID, conflict.kind.rawValue, conflict.field]) {
                let rowid: Int64 = openRow["rowid"]
                let existingJSON: String = openRow["competing_sources"]
                var existing = (try? JSONDecoder().decode(
                    [FieldSource].self, from: Data(existingJSON.utf8))) ?? []
                let known = Set(existing.map { "\($0.origin.identifier)|\($0.raw)" })
                let newcomers = conflict.competingSources.filter {
                    !known.contains("\($0.origin.identifier)|\($0.raw)")
                }
                let storedSeverity = (openRow["severity"] as String?)
                    .flatMap { DiscrepancySeverity(rawValue: $0) } ?? .none
                let mergedSeverity = max(storedSeverity, conflict.severity)
                guard !newcomers.isEmpty || mergedSeverity != storedSeverity else {
                    return rowid // identical re-detection — no-op
                }
                existing.append(contentsOf: newcomers)
                try db.execute(sql: """
                    UPDATE field_disputes
                    SET competing_sources = ?, severity = ?, ladder_trace = ?,
                        witness_summary = ?
                    WHERE rowid = ?
                    """, arguments: [
                        Self.encodeJSON(existing), mergedSeverity.rawValue,
                        traceJSON, Self.interimWitnessSummary(for: existing),
                        rowid,
                    ])
                return rowid
            }

            // 2. Reopen gate against the most recent resolved row ⟨G3⟩.
            if let resolvedRow = try Row.fetchOne(db, sql: """
                SELECT rowid, competing_sources FROM field_disputes
                WHERE entity_id = ? AND kind = ? AND field = ? AND resolution IS NOT NULL
                ORDER BY rowid DESC LIMIT 1
                """, arguments: [profileID, conflict.kind.rawValue, conflict.field]) {
                let resolvedJSON: String = resolvedRow["competing_sources"]
                let weighed = (try? JSONDecoder().decode(
                    [FieldSource].self, from: Data(resolvedJSON.utf8))) ?? []
                let weighedValues = Set(weighed.map(\.raw))
                let novel = conflict.competingSources.contains {
                    !weighedValues.contains($0.raw)
                }
                if !novel {
                    // Every asserted value was already weighed when the
                    // human (or a future rule) resolved this dispute —
                    // never re-litigate (§2.8).
                    return resolvedRow["rowid"] as Int64
                }
                // Fall through: a genuinely new value reopens as a NEW row
                // (the resolved row is history — preserved for undo and
                // the dossier, §3).
            }

            // 3. Insert a fresh dispute row.
            try db.execute(sql: """
                INSERT INTO field_disputes
                (entity_id, entity_kind, kind, field, reason, competing_sources,
                 detected_at, resolution, resolved_at, severity, detected_by,
                 evidence_json, ladder_trace, witness_summary,
                 created_by_transaction_id)
                VALUES (?, 'profile', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    profileID, conflict.kind.rawValue, conflict.field,
                    conflict.reason.rawValue,
                    Self.encodeJSON(conflict.competingSources),
                    Date(),
                    resolutionJSON,
                    resolutionJSON == nil ? nil : Date(),
                    conflict.severity.rawValue,
                    conflict.detectedBy.rawValue,
                    conflict.evidenceJSON,
                    traceJSON,
                    witnessSummary,
                    transactionID?.uuidString,
                ])
            return db.lastInsertedRowID
        }
    }

    /// ⟨G8⟩ interim witness summary — per-value weighing inputs the
    /// resolution UI renders. Until WitnessIdentity ships (CL4) the
    /// "witnesses" listed are provenance origins (lineage-level), stated
    /// here so nobody mistakes the interim for the design. A display
    /// cache recomputed on every upsert, never identity (§2.6).
    static func interimWitnessSummary(for sources: [FieldSource]) -> String {
        struct ValueSummary: Codable {
            let value: String
            let witnesses: [String]
            let bestTier: Int
        }
        var byValue: [String: [FieldSource]] = [:]
        for source in sources { byValue[source.raw, default: []].append(source) }
        let summaries = byValue.keys.sorted().map { value -> ValueSummary in
            let group = byValue[value] ?? []
            let origins = Array(Set(group.map(\.origin.identifier))).sorted()
            let bestTier = origins
                .map { ConflictDetector.trustTier(forOriginIdentifier: $0).rawValue }
                .max() ?? SourceTrustTier.community.rawValue
            return ValueSummary(value: value, witnesses: origins, bestTier: bestTier)
        }
        return (try? JSONEncoder().encode(summaries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    // MARK: - C3 surfacing queries

    /// Open disputes for one profile, newest first.
    func openDisputes(profileID: String) throws -> [DisputeRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, * FROM field_disputes
                WHERE entity_id = ? AND resolution IS NULL
                ORDER BY rowid DESC
                """, arguments: [profileID])
            return rows.compactMap(Self.disputeRow(from:))
        }
    }

    /// Count of open disputes across the whole project (Audit tab badge).
    func openDisputeCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM field_disputes WHERE resolution IS NULL
                """) ?? 0
        }
    }

    /// Every open dispute in the project, newest first.
    func allOpenDisputes() throws -> [DisputeRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, * FROM field_disputes
                WHERE resolution IS NULL
                ORDER BY rowid DESC
                """)
            return rows.compactMap(Self.disputeRow(from:))
        }
    }

    /// Open + resolved disputes for one profile — the T9 dossier read
    /// contract (§4.8.6): each row carries its deterministic reasoning
    /// inputs (`ladderTrace`, `witnessSummary`) verbatim.
    func allDisputes(profileID: String) throws -> [DisputeRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, * FROM field_disputes
                WHERE entity_id = ?
                ORDER BY rowid DESC
                """, arguments: [profileID])
            return rows.compactMap(Self.disputeRow(from:))
        }
    }

    /// CL3 T-B — persist a run's discrepancies (the v1 table never had an
    /// INSERT; DS-13). Stamped with the owning run so the eval envelope
    /// and dossier can trace a discrepancy to the run that found it.
    func insertRunDiscrepancies(
        profileID: String,
        runID: String,
        discrepancies: [ResearchDiscrepancy]
    ) throws {
        guard !discrepancies.isEmpty else { return }
        try dbQueue.write { db in
            for d in discrepancies {
                try db.execute(sql: """
                    INSERT INTO research_discrepancies
                      (profile_id, field, existing_value, source_value,
                       source_id, severity, reasoning, detected_at, run_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        profileID, d.field, d.existingValue, d.sourceValue,
                        d.sourceID, d.severity.rawValue, d.reasoning,
                        Date(), runID,
                    ])
            }
        }
    }

    /// Full-fidelity discrepancies for a profile's MOST RECENT run —
    /// reconstruction input for ResearchResult.discrepancies
    /// (CAMPAIGN_REVIEW_SPEC Change 5; the tuple loader below is
    /// insufficient — the CL3 badge needs sourceID + severity + values).
    func latestRunDiscrepancies(profileID: String) throws -> [ResearchDiscrepancy] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT field, existing_value, source_value, source_id, severity, reasoning
                FROM research_discrepancies
                WHERE profile_id = ? AND run_id = (
                    SELECT run_id FROM research_discrepancies
                    WHERE profile_id = ? ORDER BY detected_at DESC LIMIT 1
                )
                """, arguments: [profileID, profileID])
            return rows.compactMap { row -> ResearchDiscrepancy? in
                guard let severity = DiscrepancySeverity(rawValue: row["severity"] as String)
                else { return nil }
                return ResearchDiscrepancy(
                    field: row["field"] as String,
                    existingValue: (row["existing_value"] as String?) ?? "",
                    sourceValue: (row["source_value"] as String?) ?? "",
                    sourceID: (row["source_id"] as String?) ?? "",
                    severity: severity,
                    reasoning: (row["reasoning"] as String?) ?? ""
                )
            }
        }
    }

    /// One campaign-ledger row from research_run_requests — the only
    /// durable record of WHAT a campaign attempted (incl. failures/skips).
    nonisolated struct RunRequestRow: Sendable {
        let id: String
        let profileID: String?
        let leadID: String?
        let status: String            // queued | running | completed | failed
        let runID: String?
        let error: String?
        let createdAt: Date
        let completedAt: Date?
    }

    /// Campaign window enumeration: every request created since `since`,
    /// newest first (CAMPAIGN_REVIEW_SPEC Change 5).
    func loadRunRequests(since: Date) throws -> [RunRequestRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, profile_id, lead_id, status, run_id, error, created_at, completed_at
                FROM research_run_requests
                WHERE created_at >= ?
                ORDER BY created_at DESC
                """, arguments: [since])
            return rows.map { row in
                RunRequestRow(
                    id: row["id"] as String,
                    profileID: row["profile_id"] as String?,
                    leadID: row["lead_id"] as String?,
                    status: row["status"] as String,
                    runID: row["run_id"] as String?,
                    error: row["error"] as String?,
                    createdAt: row["created_at"] as Date,
                    completedAt: row["completed_at"] as Date?
                )
            }
        }
    }

    /// Campaign-review watermark — "findings reviewed up to". Mirrors
    /// conflictSweepHighWater (CAMPAIGN_REVIEW_SPEC Change 6).
    func campaignReviewHighWater() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT campaign_review_high_water FROM project_meta LIMIT 1")
        }
    }

    func setCampaignReviewHighWater(_ date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE project_meta SET campaign_review_high_water = ?",
                           arguments: [date])
        }
    }

    /// Discrepancies persisted for one run (CL3 acceptance surface).
    func runDiscrepancies(runID: String) throws -> [(field: String, severity: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT field, severity FROM research_discrepancies WHERE run_id = ?
                """, arguments: [runID])
            return rows.map { ($0["field"], $0["severity"]) }
        }
    }

    private static func disputeRow(from row: Row) -> DisputeRow? {
        guard let reason = DisputeReason(rawValue: row["reason"] as String? ?? "") else { return nil }
        let competingJSON: String = row["competing_sources"] ?? "[]"
        let competing = (try? JSONDecoder().decode(
            [FieldSource].self, from: Data(competingJSON.utf8))) ?? []
        let resolution = (row["resolution"] as String?).flatMap {
            try? JSONDecoder().decode(DisputeResolution.self, from: Data($0.utf8))
        }
        return DisputeRow(
            id: row["rowid"],
            entityID: row["entity_id"],
            entityKind: row["entity_kind"] as String? ?? "profile",
            kind: (row["kind"] as String?).flatMap { DisputeKind(rawValue: $0) } ?? .fieldValue,
            field: row["field"],
            reason: reason,
            severity: (row["severity"] as String?).flatMap { DiscrepancySeverity(rawValue: $0) },
            detectedBy: (row["detected_by"] as String?).flatMap { DisputeProducer(rawValue: $0) },
            competingSources: competing,
            evidenceJSON: row["evidence_json"],
            ladderTrace: row["ladder_trace"],
            witnessSummary: row["witness_summary"],
            detectedAt: row["detected_at"],
            resolution: resolution,
            resolvedAt: row["resolved_at"]
        )
    }

    // MARK: - Resolution (existing write path, extended for CL1 AC4)

    /// Persist a resolution onto the most-recent matching `field_disputes`
    /// row for `(profileID, field)`. Wraps the write in a transaction so
    /// undo can replay the change. Returns the new transaction record so
    /// callers can record session events.
    ///
    /// CONFLICT_LAYER_SPEC §6 Change 1 AC4 — pick-a-value resolution is
    /// end-to-end: an `.accepted(source)` (or rule-`.rule`) resolution also
    /// updates the **canonical profile field** to the accepted value inside
    /// the same transaction, journalled through `field_changes` so ONE undo
    /// restores both the field and the open dispute. The resolution write
    /// itself is journalled as an `entity_kind = 'dispute'` field change
    /// that `undoReplay` reverses.
    ///
    /// `resolution == nil` clears any previous decision (used by "Defer"
    /// in the UI when the user opens the dialog, changes their mind, and
    /// wants to leave the dispute unresolved). The conventional path for
    /// "leave it for later" is `.deferred`, which keeps the dispute in
    /// the resolved state but flags it as not-yet-acted-upon.
    /// CL-UI pass — resolve a STRUCTURAL dispute (timeline / parentRole /
    /// spouseIdentity), whose field keys deliberately do not parse as
    /// `ProfileField`. Targets the open row for (profile, kind, fieldKey).
    func resolveStructuralDispute(
        profileID: String,
        kind: DisputeKind,
        fieldKey: String,
        resolution: DisputeResolution
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE field_disputes
                SET resolution = ?, resolved_at = ?
                WHERE entity_id = ? AND kind = ? AND field = ? AND resolution IS NULL
                """, arguments: [
                    Self.encodeJSON(resolution), Date(),
                    profileID, kind.rawValue, fieldKey,
                ])
        }
    }

    func resolveFieldDispute(
        profileID: String,
        field: ProfileField,
        resolution: DisputeResolution?
    ) throws -> Transaction {
        let now = Date()
        let transaction = Transaction(
            id: UUID(),
            kind: .resolveDispute(field: field, profileID: profileID),
            undoStrategy: .replay,
            startedAt: now, completedAt: now,
            changeCount: 1, profileCount: 1
        )

        // The value the human picked, when they picked one.
        let acceptedSource: FieldSource? = switch resolution {
        case .accepted(let src): src
        case .rule(_, let src): src
        case .manual, .deferred, nil: nil
        }

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions
                (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString,
                    Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            guard let target = try Row.fetchOne(db, sql: """
                SELECT rowid, resolution FROM field_disputes
                WHERE entity_id = ? AND field = ?
                ORDER BY rowid DESC LIMIT 1
                """, arguments: [profileID, field.rawValue]) else { return }
            let rowid: Int64 = target["rowid"]
            let oldResolutionJSON: String? = target["resolution"]

            let resolutionJSON: String? = resolution.map { Self.encodeJSON($0) }
            try db.execute(sql: """
                UPDATE field_disputes
                SET resolution = ?, resolved_at = ?
                WHERE rowid = ?
                """, arguments: [
                    resolutionJSON,
                    resolution == nil ? nil : Date(),
                    rowid,
                ])

            // Journal the resolution write so undoReplay can reverse it
            // (entity_kind 'dispute' arm). new_value is NOT NULL — the
            // clear-resolution case journals an empty string.
            try db.execute(sql: """
                INSERT INTO field_changes (id, transaction_id, entity_id, entity_kind, field, old_value, new_value, source, reason)
                VALUES (?, ?, ?, 'dispute', 'resolution', ?, ?, 'user', NULL)
                """, arguments: [
                    UUID().uuidString, transaction.id.uuidString,
                    String(rowid),
                    oldResolutionJSON, resolutionJSON ?? "",
                ])

            // AC4 — pick-a-value updates the canonical field in the same
            // transaction (human decided; this is not an engine overwrite,
            // so the apply-path policies are not consulted).
            if let accepted = acceptedSource {
                try self.applyAcceptedDisputeValue(
                    accepted, field: field, profileID: profileID,
                    transactionID: transaction.id, db: db
                )
            }
        }

        return transaction
    }

    /// Write a dispute's accepted value onto the canonical profile column,
    /// journalled under the resolve transaction. Skips the write when the
    /// canonical value already equals the accepted one.
    private func applyAcceptedDisputeValue(
        _ accepted: FieldSource,
        field: ProfileField,
        profileID: String,
        transactionID: UUID,
        db: Database
    ) throws {
        switch field {
        case .birthDate, .deathDate:
            let prefix = field == .birthDate ? "birth_date" : "death_date"
            let row = try Row.fetchOne(db, sql: """
                SELECT \(prefix)_original AS original, \(prefix)_earliest AS earliest,
                       \(prefix)_latest AS latest, \(prefix)_qualifier AS qualifier
                FROM profiles WHERE id = ?
                """, arguments: [profileID])
            let currentOriginal: String? = row?["original"]
            guard currentOriginal != accepted.raw else { return }
            let oldDate: GenealogicalDate? = currentOriginal.map { GenealogicalDate(parsing: $0) }
            let newDate = GenealogicalDate(parsing: accepted.raw)
            try updateProfileDateField(
                profileID: profileID, field: field,
                oldDate: oldDate, newDate: newDate,
                source: accepted.origin, transactionID: transactionID, db: db
            )
        default:
            guard let column = Self.profileFieldToColumn(field.rawValue) else { return }
            let current = try String.fetchOne(db, sql: """
                SELECT \(column) FROM profiles WHERE id = ?
                """, arguments: [profileID])
            guard current != accepted.raw else { return }
            try updateProfileField(
                profileID: profileID, field: field,
                oldValue: current, newValue: accepted.raw,
                source: accepted.origin, transactionID: transactionID, db: db
            )
        }
    }
}

// MARK: - Cleanse Unresolvable Flags
//
// CLEANSE_WIZARD_SPEC §3 — persistent per-(profile, field) flag that hides a
// finding from the wizard once the user has decided it cannot be resolved.
// Cleared explicitly from Settings; otherwise survives app restarts.
nonisolated extension ProjectDatabase {

    /// True if the user has previously marked this (profile, field) as
    /// unresolvable. Cheap lookup used while generating findings.
    func isCleanseUnresolvable(profileID: String, field: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT 1 FROM cleanse_unresolvable_flags
                WHERE profile_id = ? AND field = ?
                LIMIT 1
                """, arguments: [profileID, field]) ?? false
        }
    }

    /// All unresolvable-flag keys, for Settings → "Reset unresolvable flags".
    func loadCleanseUnresolvableFlags() throws -> [(profileID: String, field: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT profile_id, field FROM cleanse_unresolvable_flags
                ORDER BY marked_at DESC
                """)
            return rows.map { ($0["profile_id"] as String, $0["field"] as String) }
        }
    }

    /// Set the unresolvable flag for one (profile, field). Idempotent — calling
    /// twice leaves the row unchanged (marked_at is overwritten).
    func markCleanseUnresolvable(profileID: String, field: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO cleanse_unresolvable_flags
                (profile_id, field, marked_at)
                VALUES (?, ?, ?)
                """, arguments: [profileID, field, Date()])
        }
    }

    /// Remove the unresolvable flag for one (profile, field). Lets the user
    /// re-surface a finding they previously dismissed.
    func clearCleanseUnresolvable(profileID: String, field: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM cleanse_unresolvable_flags
                WHERE profile_id = ? AND field = ?
                """, arguments: [profileID, field])
        }
    }

    /// Clear every unresolvable flag. Used from Settings.
    func clearAllCleanseUnresolvableFlags() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cleanse_unresolvable_flags")
        }
    }

    // MARK: - One-shot reconciliation against persisted field_sources

    /// Result of a reconciliation pass. One entry per (profile, field) the
    /// pass actually updated. Records both old and new dates so the report
    /// is human-reviewable and the per-profile editProfile Transaction
    /// remains undoable from the existing replay path.
    nonisolated struct DateReconciliationReport: Sendable, Equatable {
        nonisolated struct Update: Sendable, Equatable {
            let profileID: String
            let field: ProfileField
            let from: String?
            let to: String
        }
        var updates: [Update] = []
        var profilesScanned: Int = 0
    }

    /// Reconcile profile `birthDate` / `deathDate` against the persisted
    /// `field_sources` audit log: where the log contains an unambiguous
    /// narrower precise candidate (per the same rule as the start-of-run
    /// seeding from `ResearchSubject.narrowBirthWindowFromSources`) AND
    /// the apply-time overwrite policy
    /// (`ApplyEngine.shouldOverwriteDateField`) would have written
    /// it, update the canonical column.
    ///
    /// Why this is needed: profiles already on disk that were "applied"
    /// before the apply-path date overwrite fix (`aeda564`) still carry
    /// wide GEDCOM date ranges even though precise quarters sit in
    /// `field_sources`. This one-shot pass back-fills them without
    /// requiring a re-research.
    ///
    /// Each updated profile gets its own `editProfile` Transaction (per
    /// the existing manualEdit / replay-undo machinery), so the user can
    /// undo per profile if a row looks wrong.
    ///
    /// Scope: profile dates only — `marriageDate` lives on the
    /// `relationships` table without a sources audit log (#17 follow-up
    /// adds relationship-level provenance before this can be extended
    /// safely). String fields are also out of scope here; covered by a
    /// separate pass once string reconciliation policy is decided.
    ///
    /// Idempotent: re-running with no new `field_sources` is a no-op
    /// because `shouldOverwriteDateField` only triggers on a strictly
    /// narrower candidate.
    @discardableResult
    func reconcileProfileDateFields(origin: SourceOrigin = .engineEnrichment) throws -> DateReconciliationReport {
        let snapshot = try buildSnapshot()
        var report = DateReconciliationReport(profilesScanned: snapshot.profiles.count)

        for profile in snapshot.profiles.values {
            for field in [ProfileField.birthDate, ProfileField.deathDate] {
                let existing = (field == .birthDate) ? profile.birthDate : profile.deathDate
                let sources = profile.sources[field] ?? []
                guard let candidate = Self.narrowestUnambiguousDate(
                    from: sources, currentSpan: Self.yearSpan(of: existing)
                ) else { continue }
                guard ApplyEngine.shouldOverwriteDateField(
                    existing: existing, candidate: candidate
                ) else { continue }

                try editProfile(
                    profileID: profile.id,
                    changes: [],
                    dateChanges: [(field, existing, candidate)],
                    source: origin
                )
                report.updates.append(.init(
                    profileID: profile.id, field: field,
                    from: existing?.original, to: candidate.original
                ))
            }
        }
        return report
    }

    /// Pick the unambiguous narrowest date from a `field_sources` list:
    /// strictly narrower than `currentSpan`, exactly one distinct
    /// (earliest, latest) window among the narrowest candidates after
    /// deduping. Returns nil otherwise.
    ///
    /// Mirrors `ResearchSubject.narrowBirthWindowFromSources`' refuse-on-
    /// ties rule deliberately — silent picking of one tied candidate over
    /// another is exactly the fragility that motivated the multi-
    /// hypothesis slice; reconciliation must not introduce it.
    nonisolated static func narrowestUnambiguousDate(
        from sources: [FieldSource], currentSpan: Int
    ) -> GenealogicalDate? {
        struct Candidate {
            let date: GenealogicalDate
            let earliest: Int
            let latest: Int
            let span: Int
        }
        let candidates: [Candidate] = sources.compactMap { src in
            let date = GenealogicalDate(parsing: src.raw)
            guard let e = date.earliest, let l = date.latest else { return nil }
            return Candidate(date: date, earliest: e, latest: l, span: l - e)
        }
        let narrower = candidates.filter { $0.span < currentSpan }
        guard let minSpan = narrower.map(\.span).min() else { return nil }
        let tied = narrower.filter { $0.span == minSpan }
        struct Pair: Hashable { let e: Int; let l: Int }
        let distinct = Set(tied.map { Pair(e: $0.earliest, l: $0.latest) })
        guard distinct.count == 1 else { return nil }
        return tied.first?.date
    }

    /// Year-span of a `GenealogicalDate`. Either nil bound → treat as
    /// "infinite" so any finite source wins.
    nonisolated static func yearSpan(of date: GenealogicalDate?) -> Int {
        guard let date, let f = date.earliest, let l = date.latest else { return .max }
        return l - f
    }
}
