import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// #36 — the first-ever consumer of `pending_relationships`. The queue was
/// orphaned from v23: MCP wrote proposals "for human review" and no app
/// surface read them. These tests pin the new approve/reject verbs:
/// approve ENSURES the edge (idempotent against a hand-added one), a spouse
/// proposal's marriage date/location fill through the check-before-overwrite
/// rule, and a rejected proposal never resurfaces.
@MainActor
struct PendingRelationshipApprovalTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func profile(_ id: String, _ given: String, _ surname: String) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, middleName: nil, lastName: surname,
            gender: nil, attributes: nil,
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// Write a pending proposal the way the MCP server does — straight SQL,
    /// since the app deliberately has no submit API of its own.
    private func insertProposal(
        _ db: ProjectDatabase, id: String,
        from: String, to: String, relType: String, role: String? = nil,
        marriageDate: String? = nil, marriageLocation: String? = nil
    ) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO pending_relationships
                (id, from_profile_id, to_profile_id, rel_type, role, subtype,
                 review_status, created_at, source_url, source_title,
                 evidence_text, reasoning, agent_id, marriage_date, marriage_location)
                VALUES (?, ?, ?, ?, ?, 'biological', 'pending', ?, 'https://example.test/rec',
                        'Test source', 'evidence', 'reasoning', 'field-researcher', ?, ?)
                """, arguments: [id, from, to, relType, role, Date(), marriageDate, marriageLocation])
        }
    }

    private func relationships(_ db: ProjectDatabase) throws -> [Relationship] {
        try db.buildSnapshot().relationships
    }

    @Test func approvingAParentProposalCreatesTheEdge() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("P1", "Margaret", "Oates"), profile("P2", "Sarah", "Oates")],
            relationships: [], source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "r1", from: "P1", to: "P2", relType: "parent", role: "mother")

        #expect(try db.pendingRelationships(touching: "P2").count == 1)
        #expect(try db.approvePendingRelationship(id: "r1"))

        let edges = try relationships(db)
        #expect(edges.contains {
            $0.from == "P1" && $0.to == "P2" && $0.type == .parent && $0.role == .mother
        })
        #expect(try db.pendingRelationships(touching: "P2").isEmpty,
                "approved rows leave the pending queue")
    }

    @Test func approvingASpouseProposalCarriesTheMarriage() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("T1", "Thomas", "Crawshaw"), profile("S1", "Sarah", "Oates")],
            relationships: [], source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "r2", from: "T1", to: "S1", relType: "spouse",
                           marriageDate: "Jun 1880", marriageLocation: "Ecclesall Bierlow, Sheffield")

        #expect(try db.approvePendingRelationship(id: "r2"))

        let edge = try relationships(db).first { $0.type == .spouse && $0.from == "T1" && $0.to == "S1" }
        #expect(edge != nil)
        #expect(edge?.marriageDate?.original == "Jun 1880")
        #expect(edge?.marriageLocation == "Ecclesall Bierlow, Sheffield")
    }

    @Test func approvalEnrichesAHandAddedEdgeInsteadOfDuplicating() throws {
        // The stranded-Wheeldon case: the user added the edge by hand while
        // the proposal sat unreviewable. Approving later must not duplicate
        // the edge — and SHOULD fill the marriage details the hand-added
        // edge lacks.
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("J1", "James", "Beresford"), profile("E1", "Elizabeth Ann", "Crawshaw")],
            relationships: [Relationship(
                id: UUID(), from: "J1", to: "E1",
                type: .spouse, role: nil, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "r3", from: "J1", to: "E1", relType: "spouse",
                           marriageDate: "Jun 1880", marriageLocation: "Ecclesall Bierlow")

        #expect(try db.approvePendingRelationship(id: "r3"))

        let spouseEdges = try relationships(db).filter { $0.type == .spouse }
        #expect(spouseEdges.count == 1, "no duplicate spouse edge")
        #expect(spouseEdges.first?.marriageDate?.original == "Jun 1880")
        #expect(spouseEdges.first?.marriageLocation == "Ecclesall Bierlow")
    }

    @Test func approvalNeverDegradesAnExistingPreciseMarriageDate() throws {
        // Check-before-overwrite: the edge already carries an exact day; a
        // quarter-precision proposal must not replace it.
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("A1", "John", "Wheldon"), profile("B1", "Ruth", "Brelsford")],
            relationships: [Relationship(
                id: UUID(), from: "A1", to: "B1",
                type: .spouse, role: nil, subtype: .biological,
                marriageDate: GenealogicalDate(parsing: "27 Feb 1843"),
                marriageLocation: "Wirksworth", divorceDate: nil)],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "r4", from: "A1", to: "B1", relType: "spouse",
                           marriageDate: "1843", marriageLocation: "Derby")

        #expect(try db.approvePendingRelationship(id: "r4"))

        let edge = try relationships(db).first { $0.type == .spouse }
        #expect(edge?.marriageDate?.original == "27 Feb 1843",
                "wider candidate must not replace the exact date")
        #expect(edge?.marriageLocation == "Wirksworth",
                "existing location survives")
    }

    @Test func rejectedProposalsLeaveTheQueueAndCreateNothing() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("X1", "A", "B"), profile("X2", "C", "D")],
            relationships: [], source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "r5", from: "X1", to: "X2", relType: "parent", role: "father")

        try db.rejectPendingRelationship(id: "r5")

        #expect(try db.pendingRelationships(touching: "X1").isEmpty)
        #expect(try relationships(db).isEmpty)
        #expect(try db.approvePendingRelationship(id: "r5") == false,
                "a rejected row cannot be approved afterwards")
    }
}
