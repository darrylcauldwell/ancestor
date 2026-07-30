import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
@testable import AncestorKit

/// v56 applied-at stamp: mark/clear round-trip, and NULL semantics for
/// pre-stamp rows (NULL = unknown, never "definitely unapplied").
struct EvidenceAppliedStampTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func seedEvidence(_ db: ProjectDatabase, id: String) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO evidence_records
                  (id, profile_id, source_id, source_record_id, record_type, verdict, record_json, scored_at)
                VALUES (?, '@P@', 'freebmd', ?, 'death', 'fact', '{}', ?)
                """, arguments: [id, String(id.split(separator: "|").last ?? ""), Date()])
        }
    }

    @Test func markAndClearRoundTrip() throws {
        let db = try makeTempDB()
        try seedEvidence(db, id: "@P@|rec1")
        try db.markEvidenceApplied(evidenceID: "@P@|rec1", at: Date(timeIntervalSince1970: 500))

        let applied = try db.dbQueue.read { conn in
            try Date.fetchOne(conn, sql: "SELECT applied_at FROM evidence_records WHERE id = '@P@|rec1'")
        }
        #expect(applied != nil)

        try db.clearEvidenceApplied(evidenceID: "@P@|rec1")
        let cleared = try db.dbQueue.read { conn in
            try Date.fetchOne(conn, sql: "SELECT applied_at FROM evidence_records WHERE id = '@P@|rec1'")
        }
        #expect(cleared == nil)
    }

    @Test func preStampRowsStayNull() throws {
        let db = try makeTempDB()
        try seedEvidence(db, id: "@P@|old")
        let value = try db.dbQueue.read { conn in
            try Date.fetchOne(conn, sql: "SELECT applied_at FROM evidence_records WHERE id = '@P@|old'")
        }
        #expect(value == nil)   // NULL = unknown, the explainer's contract
    }
}
