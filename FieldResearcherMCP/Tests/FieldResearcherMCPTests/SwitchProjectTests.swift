import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// `switch_project` — runtime rebinding to a SIBLING project database:
/// switch works and subsequent reads hit the new project; targets are
/// validated before the swap (a bad target never unbinds the server);
/// path traversal is refused by construction.
struct SwitchProjectTests {

    private func makeProject(in dir: URL, name: String) throws -> String {
        let path = dir.appendingPathComponent("\(UUID().uuidString).sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, profile_id TEXT, name TEXT, relationship TEXT, status TEXT, evidence TEXT, birth_year INTEGER, death_year INTEGER, created_at DATETIME, investigated_at DATETIME, source TEXT, given_name TEXT, surname TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES (?, ?, 'manual', '', ?)",
                           arguments: [UUID().uuidString, name, Date()])
        }
        return path
    }

    @Test func switchRebindsToSiblingAndReadsHitNewProject() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pathA = try makeProject(in: dir, name: "Project A")
        let pathB = try makeProject(in: dir, name: "Project B")

        let handler = try MCPHandler(dbPath: pathA)
        let result = try await handler.switchProjectStatus(
            project: URL(fileURLWithPath: pathB).lastPathComponent)
        #expect(result.status == "switched")
        #expect(result.toName == "Project B")
        #expect(await handler.dbPath == pathB)

        // UUID form (no .sqlite suffix) works too — switch back.
        let uuidA = URL(fileURLWithPath: pathA).deletingPathExtension().lastPathComponent
        let back = try await handler.switchProjectStatus(project: uuidA)
        #expect(back.status == "switched")
        #expect(await handler.dbPath == pathA)
    }

    @Test func badTargetNeverUnbinds() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pathA = try makeProject(in: dir, name: "Project A")
        let handler = try MCPHandler(dbPath: pathA)

        // Missing sibling → structured refusal, binding untouched.
        let missing = try await handler.switchProjectStatus(project: "no-such-project")
        #expect(missing.status == "refused")
        #expect(await handler.dbPath == pathA)

        // Schema-invalid sibling (no leads table) → throws, binding untouched.
        let badPath = dir.appendingPathComponent("bad.sqlite").path
        _ = try DatabaseQueue(path: badPath)
        await #expect(throws: (any Error).self) {
            _ = try await handler.switchProjectStatus(project: "bad.sqlite")
        }
        #expect(await handler.dbPath == pathA)
    }

    @Test func pathTraversalRefusedByConstruction() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pathA = try makeProject(in: dir, name: "Project A")
        let handler = try MCPHandler(dbPath: pathA)

        for hostile in ["../outside", "/etc/anything", "a/../../b", "..\\\\windowsy"] {
            await #expect(throws: (any Error).self) {
                _ = try await handler.switchProjectStatus(project: hostile)
            }
        }
        #expect(await handler.dbPath == pathA)
    }
}
