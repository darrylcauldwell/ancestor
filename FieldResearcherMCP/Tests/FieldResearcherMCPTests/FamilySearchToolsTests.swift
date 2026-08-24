import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// FamilySearch MCP tools (WL7): status/link/hint reads over the v52/v53
/// tables, request staging with dedupe, and the friendly schema_out_of_date
/// payload for pre-migration databases. The request tools only INSERT staged
/// rows — execution belongs to the app.
struct FamilySearchToolsTests {

    /// Minimal DB with the schema-age tables MCPHandler.init requires, plus
    /// the FS write-leg tables (v52/v53 shapes).
    private func makeDB(withFSTables: Bool = true) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, profile_id TEXT, name TEXT, surname TEXT, given_name TEXT, birth_year INTEGER, death_year INTEGER, relationship TEXT, source TEXT, status TEXT, evidence TEXT, created_at DATETIME, investigated_at DATETIME, resolved_at DATETIME, resolution TEXT, age_at_death INTEGER, place TEXT)")
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, is_deleted INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE relationships (id TEXT PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE evidence_records (id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, source_id TEXT NOT NULL, source_record_id TEXT NOT NULL, record_type TEXT NOT NULL, verdict TEXT NOT NULL, record_json TEXT NOT NULL, citation_full TEXT, citation_url TEXT, scored_at DATETIME NOT NULL)")
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES (?,'T','manual','',?)", arguments: [UUID().uuidString, Date()])
            if withFSTables {
                try db.execute(sql: "CREATE TABLE familysearch_tree_uploads (id TEXT PRIMARY KEY, environment TEXT NOT NULL, fs_group_id TEXT, fs_tree_id TEXT, tree_name TEXT NOT NULL, tree_description TEXT, starting_profile_id TEXT, private INTEGER, phase TEXT NOT NULL, started_at DATETIME NOT NULL, finalized_at DATETIME, persons_uploaded INTEGER NOT NULL DEFAULT 0, relationships_uploaded INTEGER NOT NULL DEFAULT 0, sources_uploaded INTEGER NOT NULL DEFAULT 0)")
                try db.execute(sql: "CREATE TABLE familysearch_person_links (profile_id TEXT NOT NULL, fs_tree_id TEXT NOT NULL, fs_pid TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'created', superseded_by TEXT, uploaded_at DATETIME NOT NULL, PRIMARY KEY (profile_id, fs_tree_id))")
                try db.execute(sql: "CREATE TABLE fs_action_requests (id TEXT PRIMARY KEY, kind TEXT NOT NULL, profile_id TEXT, tree_name TEXT, tree_description TEXT, status TEXT NOT NULL DEFAULT 'queued', note TEXT, requested_by TEXT NOT NULL, created_at DATETIME NOT NULL, started_at DATETIME, completed_at DATETIME)")
            }
        }
        return path
    }

    private func write(_ dbPath: String, _ sql: String, _ arguments: [DatabaseValueConvertible?] = []) throws {
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(arguments.map { $0 ?? nil }))
        }
    }

    // MARK: Requests

    // (The hints request/read tests were removed with the tools themselves —
    // get_fs_hints/request_fs_hints went away when FamilySearch became a
    // tree-only integration, 2026-08-07. This file kept referencing the
    // deleted handler methods, which broke `swift test` for the whole
    // package; nobody noticed because only `swift build` was routinely run.)

    @Test func requestFSUploadQueuesStatesHiddenCapAndDedupes() async throws {
        let dbPath = try makeDB()
        let handler = try MCPHandler(dbPath: dbPath)
        let first = try await handler.requestFSUploadResponseText(["tree_name": "Cauldwell Tree"])
        #expect(first.contains("request_id: fsreq_"))
        #expect(first.contains("HIDDEN"))     // the finalize cap is stated to the caller
        #expect(first.contains("wizard"))
        let second = try await handler.requestFSUploadResponseText([:])
        #expect(second.contains("already"))
        let q = try DatabaseQueue(path: dbPath)
        let count = try await q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fs_action_requests WHERE kind = 'upload'") ?? 0 }
        #expect(count == 1)
    }

    @Test func requestStatusReturnsRowNotFoundAndLatest() async throws {
        let dbPath = try makeDB()
        try write(dbPath, """
            INSERT INTO fs_action_requests (id, kind, profile_id, status, note, requested_by, created_at, completed_at)
            VALUES ('fsreq_done', 'hints', '@I1@', 'completed', '3 hint(s) reviewed — 2 lead(s) in Triage.', 'mcp', ?, ?)
            """, [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)])
        let handler = try MCPHandler(dbPath: dbPath)

        let one = try await handler.getFSRequestStatusResponseText(["request_id": "fsreq_done"])
        #expect(one.contains("\"completed\""))
        #expect(one.contains("Triage"))

        let missing = try await handler.getFSRequestStatusResponseText(["request_id": "fsreq_ghost"])
        #expect(missing.contains("request_not_found"))

        let latest = try await handler.getFSRequestStatusResponseText([:])
        #expect(latest.contains("fsreq_done"))
    }

    // MARK: Reads

    @Test func uploadStatusReadsRunsNewestFirst() async throws {
        let dbPath = try makeDB()
        try write(dbPath, """
            INSERT INTO familysearch_tree_uploads
              (id, environment, fs_tree_id, tree_name, phase, private, started_at, finalized_at,
               persons_uploaded, relationships_uploaded, sources_uploaded)
            VALUES ('run1', 'beta', 'T1', 'Old Tree', 'failed', NULL, ?, NULL, 3, 0, 0),
                   ('run2', 'beta', 'T2', 'Cauldwell Tree', 'finalized', 1, ?, ?, 42, 30, 7)
            """, [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 500), Date(timeIntervalSince1970: 600)])
        let handler = try MCPHandler(dbPath: dbPath)
        let json = try await handler.getFSUploadStatusResponseText([:])
        #expect(json.contains("\"fs_tree_id\""))
        #expect(json.contains("T2"))
        #expect(json.contains("\"finalized\""))
        #expect(json.contains("\"persons_uploaded\" : 42"))
        // Newest first: run2 appears before run1.
        let run2Index = try #require(json.range(of: "run2")?.lowerBound)
        let run1Index = try #require(json.range(of: "run1")?.lowerBound)
        #expect(run2Index < run1Index)
    }

    @Test func personLinksFilterByProfile() async throws {
        let dbPath = try makeDB()
        try write(dbPath, """
            INSERT INTO familysearch_person_links (profile_id, fs_tree_id, fs_pid, status, uploaded_at)
            VALUES ('@I1@', 'T1', 'AAAA-111', 'created', ?), ('@I2@', 'T1', 'BBBB-222', 'created', ?)
            """, [Date(), Date()])
        let handler = try MCPHandler(dbPath: dbPath)
        let all = try await handler.getFSPersonLinksResponseText([:])
        #expect(all.contains("AAAA-111") && all.contains("BBBB-222"))
        let one = try await handler.getFSPersonLinksResponseText(["profile_id": "@I1@"])
        #expect(one.contains("AAAA-111") && !one.contains("BBBB-222"))
    }

    // MARK: Pre-migration database

    @Test func preMigrationDatabaseGetsFriendlySchemaError() async throws {
        let handler = try MCPHandler(dbPath: try makeDB(withFSTables: false))
        let status = try await handler.getFSUploadStatusResponseText([:])
        #expect(status.contains("schema_out_of_date"))
        let request = try await handler.requestFSUploadResponseText([:])
        #expect(request.contains("schema_out_of_date"))
    }
}
