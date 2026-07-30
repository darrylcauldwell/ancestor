import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// MC1/MC3 consumer-surface fixes (MCP_CONSUMER_SURFACE_SPEC): tokenised
/// multi-token search (incl. married-surname matching), soft-deleted rows
/// excluded from the list resources, split name fields, the implemented
/// find_ancestor / research_lifecycle prompts, and user_status + gates
/// exposure on scored records.
struct ConsumerSurfaceTests {

    private func makeDB() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE leads (id TEXT PRIMARY KEY, profile_id TEXT, name TEXT, surname TEXT,
                    given_name TEXT, birth_year INTEGER, death_year INTEGER, relationship TEXT,
                    source TEXT, status TEXT, evidence TEXT, created_at DATETIME,
                    investigated_at DATETIME, resolved_at DATETIME, resolution TEXT)
                """)
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: """
                CREATE TABLE profiles (
                    id TEXT PRIMARY KEY, first_name TEXT, middle_name TEXT, last_name TEXT,
                    married_surname TEXT, gender TEXT,
                    birth_date_original TEXT, birth_date_earliest INTEGER, birth_date_latest INTEGER,
                    death_date_original TEXT, death_date_earliest INTEGER, death_date_latest INTEGER,
                    birth_location TEXT, death_location TEXT, bio TEXT,
                    is_deleted INTEGER DEFAULT 0)
                """)
            try db.execute(sql: "CREATE TABLE relationships (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES (?,'T','manual','',?)", arguments: [UUID().uuidString, Date()])

            try db.execute(sql: """
                INSERT INTO profiles (id, first_name, middle_name, last_name, married_surname, gender,
                                      birth_date_original, death_date_original, death_location, is_deleted)
                VALUES ('@WHK@', 'William', 'Henry', 'Keyworth', NULL, 'male', 'Jun 1875', 'Sep 1943', 'Bakewell', 0),
                       ('@ES@', 'Elizabeth', NULL, 'Shaw', 'Keyworth', 'female', 'Mar 1869', '1916', NULL, 0),
                       ('@DEL@', 'Deleted', NULL, 'Keyworth', NULL, 'male', '1880', NULL, NULL, 1)
                """)
        }
        return path
    }

    // MARK: MC1 — search

    @Test func multiTokenSearchMatchesAcrossNameParts() async throws {
        let handler = try MCPHandler(dbPath: try makeDB())
        // The original defect: whole-query LIKE against single columns —
        // any multi-token query returned [].
        let full = try await handler.searchProfiles(query: "William Henry Keyworth")
        #expect(full.contains("@WHK@"))
        let surname = try await handler.searchProfiles(query: "Keyworth")
        #expect(surname.contains("@WHK@"))
        let mismatch = try await handler.searchProfiles(query: "William Shaw")
        #expect(!mismatch.contains("@WHK@") && !mismatch.contains("@ES@"))
    }

    @Test func womenAreFindableByMarriedSurname() async throws {
        // UK convention: many women are only known by married surname.
        let handler = try MCPHandler(dbPath: try makeDB())
        let result = try await handler.searchProfiles(query: "Elizabeth Keyworth")
        #expect(result.contains("@ES@"))
    }

    // MARK: MC1 — soft-deleted exclusion

    @Test func softDeletedProfilesAreExcludedEverywhere() async throws {
        let handler = try MCPHandler(dbPath: try makeDB())
        #expect(!(try await handler.searchProfiles(query: "Keyworth")).contains("@DEL@"))
        #expect(!(try await handler.allProfiles()).contains("@DEL@"))
        #expect(!(try await handler.treeGaps()).contains("@DEL@"))
    }

    // MARK: MC2 — list payload

    @Test func allProfilesSplitsNamesAndCarriesDeathLocation() async throws {
        let handler = try MCPHandler(dbPath: try makeDB())
        let json = try await handler.allProfiles()
        #expect(json.contains("\"first_name\":\"William\""))
        #expect(json.contains("\"last_name\":\"Keyworth\""))
        #expect(json.contains("\"death_location\":\"Bakewell\""))
        // Compact serialisation — the set-query workhorse must not be
        // pretty-printed (it ~doubles token cost).
        #expect(!json.contains("\n  "))
    }

    // MARK: MC1 — prompts

    @Test func advertisedPromptsAreAllImplemented() async throws {
        let handler = try MCPHandler(dbPath: try makeDB())
        for name in ["find_ancestor", "research_lifecycle"] {
            let json = await handler.getPromptResponseText(["name": name, "arguments": ["profile_id": "@WHK@", "role": "father"]])
            #expect(json.contains("\"text\""), "prompt \(name) must not be silently empty")
        }
        let father = await handler.getPromptResponseText(["name": "find_ancestor", "arguments": ["profile_id": "@WHK@", "role": "father"]])
        #expect(father.contains("father"))
        #expect(father.contains("kick_off_research"))
        let unknown = await handler.getPromptResponseText(["name": "no_such_prompt", "arguments": [:]])
        #expect(!unknown.contains("\"text\""))
    }
}
