import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// EV33 follow-up (review C2) — the MCP server filed every `workbench_notes`
/// row under its raw idempotency id, `"fr_" + 16 lowercase hex digits`, and
/// `noteFromRow` guards `UUID(uuidString:)`, so every note the field
/// researcher ever wrote (refusal reasons AND `add_workbench_note`) was
/// silently invisible in the Workbench while MCP's raw-SQL
/// `get_workbench_notes` still showed it.
///
/// The repair is two-ended and these tests pin the app end: legacy `fr_…`
/// rows are mapped on read to the SAME deterministic UUID new MCP writes use
/// (doubled hex digits, 8-4-4-4-12 — documented byte-for-byte on both sides),
/// and edit/delete reach the on-disk legacy row through that UUID. No schema
/// change, no migration — pure functions only.
@MainActor
struct WorkbenchNoteLegacyIDFallbackTests {

    private let profileID = "@P1@"
    /// A realistic legacy id: "fr_" + exactly 16 lowercase hex digits, the
    /// shape `MCPHandler.idempotencyKey` has always produced.
    private let legacyID = "fr_00a1b2c3d4e5f607"
    /// Its mapped UUID — the 16 digits doubled to 32, uppercased, hyphenated.
    private let mappedUUIDString = "00A1B2C3-D4E5-F607-00A1-B2C3D4E5F607"

    private func makeDB() throws -> ProjectDatabase {
        let db = try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO project_meta (id, name, source_kind, source_value, created_at)
                    VALUES ('t','T','manual','',?)
                    """,
                arguments: [Date()])
        }
        return db
    }

    /// A row exactly as the pre-fix MCP writer left it: legacy id, valid tag,
    /// valid attachment JSON — the id is the ONLY thing that ever failed.
    private func insertLegacyNote(_ db: ProjectDatabase, content: String) throws {
        let now = Date()
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT OR IGNORE INTO workbench_notes
                (id, content, tag, attached_to, attachment_kind, attachment_id,
                 created_at, updated_at)
                VALUES (?, ?, 'meta', ?, 'profile', ?, ?, ?)
                """, arguments: [
                    legacyID, content,
                    #"{"profile":{"id":"\#(profileID)"}}"#,
                    profileID, now, now,
                ])
        }
    }

    // MARK: - The mapping itself

    @Test func theLegacyMappingIsDeterministicAndMatchesTheMCPDerivation() {
        let mapped = ProjectDatabase.noteUUID(fromLegacyFieldResearcherID: legacyID)
        #expect(mapped == UUID(uuidString: mappedUUIDString))
        // Same input, same UUID, every time — dedup on both ends depends on it.
        #expect(mapped == ProjectDatabase.noteUUID(fromLegacyFieldResearcherID: legacyID))
    }

    @Test func onlyTheRealLegacyShapeIsMapped() {
        // Not the fr_ prefix at all.
        #expect(ProjectDatabase.noteUUID(fromLegacyFieldResearcherID: "lead_fr_1_2") == nil)
        // Too short / too long.
        #expect(ProjectDatabase.noteUUID(fromLegacyFieldResearcherID: "fr_abc") == nil)
        #expect(ProjectDatabase.noteUUID(fromLegacyFieldResearcherID: "fr_00a1b2c3d4e5f60700") == nil)
        // Non-hex.
        #expect(ProjectDatabase.noteUUID(fromLegacyFieldResearcherID: "fr_00a1b2c3d4e5g607") == nil)
        // A genuine UUID string must never be re-mapped.
        #expect(ProjectDatabase.noteUUID(
            fromLegacyFieldResearcherID: "6BB7E5D0-1E52-4F0A-9C3D-2A46E8A1B901") == nil)
    }

    @Test func theMappingIsInvertibleOnlyForDoubledDigitUUIDs() throws {
        let mapped = try #require(UUID(uuidString: mappedUUIDString))
        #expect(ProjectDatabase.legacyFieldResearcherNoteID(from: mapped) == legacyID)
        // A UUID without the doubled signature is left alone — an app-native
        // note must never have its writes redirected at a phantom fr_ row.
        let native = try #require(UUID(uuidString: "6BB7E5D0-1E52-4F0A-9C3D-2A46E8A1B901"))
        #expect(ProjectDatabase.legacyFieldResearcherNoteID(from: native) == nil)
    }

    // MARK: - Reading legacy rows

    /// THE regression: pre-fix, this row existed in SQLite and `loadNotes`
    /// silently dropped it — the refusal reason was invisible to the one
    /// person it exists for.
    @Test func aLegacyFieldResearcherNoteRendersInTheApp() throws {
        let db = try makeDB()
        try insertLegacyNote(db, content: "Discarded scored record x via MCP: namesake.")

        let notes = try db.loadNotes(attachedToKind: "profile", id: profileID)
        #expect(notes.count == 1, "the legacy fr_ id must not drop the note on read")
        #expect(notes.first?.content == "Discarded scored record x via MCP: namesake.")
        #expect(notes.first?.tag == .meta)
        #expect(notes.first?.id == UUID(uuidString: mappedUUIDString),
                "the surfaced id must be the SAME deterministic UUID new MCP writes use")
    }

    @Test func aLegacyNoteAppearsInTheAllNotesList() throws {
        let db = try makeDB()
        try insertLegacyNote(db, content: "reason the user must see")

        #expect(try db.loadNotes().count == 1)
    }

    // MARK: - Editing and deleting legacy rows through the mapped UUID

    @Test func deletingALegacyNoteRemovesTheOnDiskRow() throws {
        let db = try makeDB()
        try insertLegacyNote(db, content: "to be deleted")
        let note = try #require(try db.loadNotes(attachedToKind: "profile", id: profileID).first)

        try db.deleteNote(id: note.id)

        let raw = try db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM workbench_notes") ?? -1
        }
        #expect(raw == 0, "delete must reach the fr_ row, not miss on the mapped UUID")
    }

    @Test func updatingALegacyNoteEditsTheOnDiskRow() throws {
        let db = try makeDB()
        try insertLegacyNote(db, content: "original wording")
        var note = try #require(try db.loadNotes(attachedToKind: "profile", id: profileID).first)

        note.content = "corrected wording"
        try db.updateNote(note)

        let reloaded = try db.loadNotes(attachedToKind: "profile", id: profileID)
        #expect(reloaded.count == 1, "the update must edit in place, never fork a second row")
        #expect(reloaded.first?.content == "corrected wording",
                "update must reach the fr_ row, not silently no-op on the mapped UUID")
    }
}
