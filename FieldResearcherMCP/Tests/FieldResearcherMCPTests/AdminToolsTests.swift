import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// list_projects + delete_project — sibling-scoped admin tools with the
/// same traversal-proof, current-project-protected guards as switch_project.
struct AdminToolsTests {

    private func makeProject(in dir: URL, name: String, profiles: Int = 0) throws -> String {
        let path = dir.appendingPathComponent("\(UUID().uuidString).sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, status TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, is_deleted INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE relationships (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES (?,?,'manual','',?)", arguments: [UUID().uuidString, name, Date()])
            for i in 0..<profiles { try db.execute(sql: "INSERT INTO profiles (id) VALUES (?)", arguments: ["p\(i)"]) }
        }
        return path
    }

    /// Sendable projections for cross-actor test calls.
    @Test func listReportsNameAndCountsAndCurrentFlag() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pathA = try makeProject(in: dir, name: "Real Tree", profiles: 5)
        _ = try makeProject(in: dir, name: "Empty Leak", profiles: 0)
        let handler = try MCPHandler(dbPath: pathA)

        let json = try await handler.listProjectsJSON()
        #expect(json.contains("Real Tree"))
        #expect(json.contains("Empty Leak"))
        #expect(json.contains("is_current"))
        #expect(json.contains("\"profiles\" : 5") || json.contains("\"profiles\": 5"))
    }

    @Test func deleteRemovesSiblingButRefusesCurrentAndUnconfirmed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pathA = try makeProject(in: dir, name: "Keep", profiles: 3)
        let pathB = try makeProject(in: dir, name: "Delete Me", profiles: 0)
        let handler = try MCPHandler(dbPath: pathA)
        let fileB = URL(fileURLWithPath: pathB).lastPathComponent

        // Unconfirmed → refused, file survives.
        let unconfirmed = try await handler.deleteProjectStatus(project: fileB, confirm: nil)
        #expect(unconfirmed == "not_confirmed")
        #expect(FileManager.default.fileExists(atPath: pathB))

        // Current project → refused even when confirmed.
        let current = try await handler.deleteProjectStatus(project: URL(fileURLWithPath: pathA).lastPathComponent, confirm: "true")
        #expect(current == "is_current_project")
        #expect(FileManager.default.fileExists(atPath: pathA))

        // Confirmed sibling → deleted.
        let deleted = try await handler.deleteProjectStatus(project: fileB, confirm: "true")
        #expect(deleted == "deleted")
        #expect(!FileManager.default.fileExists(atPath: pathB))
    }

    @Test func deleteRefusesPathTraversal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pathA = try makeProject(in: dir, name: "Keep", profiles: 1)
        let handler = try MCPHandler(dbPath: pathA)
        for hostile in ["../evil", "/etc/passwd", "a/../b"] {
            await #expect(throws: (any Error).self) {
                _ = try await handler.deleteProjectStatus(project: hostile, confirm: "true")
            }
        }
    }
}
