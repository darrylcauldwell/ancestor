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
        // legacy projects; call sites fall back to "DBY" (behaviour-preserving
        // for the existing Derbyshire-anchored data). Derived at creation
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

        try migrator.migrate(dbQueue)
    }

    // MARK: - Snapshot Building

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

        // Decode PersonAttributes from JSON column (nil for pre-v6 profiles)
        let attributes: PersonAttributes? = {
            guard let json: String = row["attributes"],
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(PersonAttributes.self, from: data)
        }()

        let isDeleted: Bool = row["is_deleted"] ?? false

        return Profile(
            id: id,
            externalIDs: externalIDs,
            firstName: row["first_name"],
            middleName: row["middle_name"],
            lastName: row["last_name"],
            nickName: row["nick_name"],
            mothersMaidenName: row["mothers_maiden_name"],
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
                INSERT OR REPLACE INTO project_meta (id, name, source_kind, source_value, created_at, last_refreshed, home_person_id, archived_at, home_chapman_code)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    project.id.uuidString, project.name, sourceKind, sourceValue,
                    project.createdAt, project.lastRefreshed, project.homePersonID,
                    project.archivedAt, project.homeChapmanCode
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

            return Project(
                id: UUID(uuidString: row["id"]) ?? UUID(),
                name: row["name"],
                source: source,
                homePersonID: homePersonID,
                createdAt: row["created_at"],
                lastRefreshed: row["last_refreshed"],
                archivedAt: row["archived_at"],
                homeChapmanCode: row["home_chapman_code"]
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
        let externalIDsJSON = (try? JSONEncoder().encode(profile.externalIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let attributesJSON: String? = profile.attributes.flatMap {
            (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) }
        }

        try db.execute(sql: """
            INSERT INTO profiles (id, external_ids,
                first_name, middle_name, last_name, nick_name, mothers_maiden_name,
                gender, attributes, is_deleted,
                birth_date_original, birth_date_earliest, birth_date_latest, birth_date_qualifier,
                birth_location, birth_location_code,
                death_date_original, death_date_earliest, death_date_latest, death_date_qualifier,
                death_location, death_location_code, bio, created_by_transaction_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                profile.id, externalIDsJSON,
                profile.firstName, profile.middleName, profile.lastName,
                profile.nickName, profile.mothersMaidenName,
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
    @discardableResult
    func addFamily(
        profiles: [Profile],
        relationships: [Relationship],
        source: SourceOrigin
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
            }
        }

        return transaction
    }

    /// Add a relationship between two existing profiles.
    @discardableResult
    func addRelationship(_ rel: Relationship) throws -> Transaction {
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
        }

        return transaction
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

            // Read current values to honour the nil-only rule.
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT marriage_date_original, marriage_location FROM relationships WHERE id = ?",
                arguments: [relationshipID.uuidString]
            ) else { return }

            let existingDate: String? = row["marriage_date_original"]
            let existingLocation: String? = row["marriage_location"]

            if existingDate == nil, let date = candidateDate {
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
    func saveEvidence(profileID: String, scored: ScoredRecord, citationFull: String?, citationURL: String?) throws {
        let compositeID = EvidenceRecord.compositeID(profileID: profileID, sourceRecordID: scored.record.id)
        let recordJSON = Self.encodeJSON(scored.record)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records
                (id, profile_id, source_id, source_record_id, record_type, verdict, record_json, citation_full, citation_url, scored_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    source_record_id = excluded.source_record_id,
                    record_type = excluded.record_type,
                    verdict = excluded.verdict,
                    record_json = excluded.record_json,
                    citation_full = excluded.citation_full,
                    citation_url = excluded.citation_url,
                    scored_at = excluded.scored_at
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
                ])
        }
    }

    /// Load all evidence records for a profile, newest first.
    func loadEvidenceForProfile(_ profileID: String) throws -> [EvidenceRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, profile_id, source_id, source_record_id, record_type, verdict, record_json, citation_full, citation_url, scored_at, user_status
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
                    userStatus: userStatus
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

// MARK: - Field disputes (M16.14)

nonisolated extension ProjectDatabase {

    /// Insert a `FieldDispute` row. Used by tests and (in future) by the
    /// dispute-detection pass that runs alongside imports. Production import
    /// paths don't seed disputes today — buildSnapshot will simply find an
    /// empty `disputes` map for every profile.
    @discardableResult
    func addFieldDispute(profileID: String, dispute: FieldDispute) throws -> Int64 {
        let competingJSON = Self.encodeJSON(dispute.competingSources)
        let resolutionJSON = dispute.resolution.map { Self.encodeJSON($0) }
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO field_disputes
                (entity_id, field, reason, competing_sources, detected_at, resolution)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    profileID, dispute.field.rawValue, dispute.reason.rawValue,
                    competingJSON, dispute.detectedAt, resolutionJSON,
                ])
            return db.lastInsertedRowID
        }
    }

    /// Persist a resolution onto the most-recent matching `field_disputes`
    /// row for `(profileID, field)`. Wraps the write in a transaction so
    /// undo can replay the change. Returns the new transaction record so
    /// callers can record session events.
    ///
    /// `resolution == nil` clears any previous decision (used by "Defer"
    /// in the UI when the user opens the dialog, changes their mind, and
    /// wants to leave the dispute unresolved). The conventional path for
    /// "leave it for later" is `.deferred`, which keeps the dispute in
    /// the resolved state but flags it as not-yet-acted-upon.
    @discardableResult
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

            let resolutionJSON: String? = resolution.map { Self.encodeJSON($0) }
            try db.execute(sql: """
                UPDATE field_disputes
                SET resolution = ?
                WHERE rowid = (
                    SELECT rowid FROM field_disputes
                    WHERE entity_id = ? AND field = ?
                    ORDER BY rowid DESC LIMIT 1
                )
                """, arguments: [
                    resolutionJSON,
                    profileID, field.rawValue,
                ])
        }

        return transaction
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
}
