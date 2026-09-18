import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// Review C9 — spouse edges are undirected everywhere they are READ
/// (`ApplyEngine`, `RecordRemoval`, `FamilyGraphSnapshot.spousesOf`), and
/// MCP's submit tool explicitly allows "either party" as from_profile_id,
/// but `addRelationshipIfAbsent`'s dedup matched (from, to) in one exact
/// direction. A hand-added A→B marriage plus an approved B→A proposal
/// therefore inserted a SECOND spouse edge between the same pair — and
/// `fillRelationshipMarriage` then enriched the empty duplicate instead of
/// the real edge, double-rendering the marriage in every spouse consumer.
@MainActor
struct SpouseEdgeBidirectionalDedupTests {

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

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    /// Same raw-SQL proposal shape as `PendingRelationshipApprovalTests` —
    /// the app deliberately has no submit API of its own.
    private func insertProposal(
        _ db: ProjectDatabase, id: String,
        from: String, to: String, relType: String,
        marriageDate: String? = nil, marriageLocation: String? = nil
    ) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO pending_relationships
                (id, from_profile_id, to_profile_id, rel_type, role, subtype,
                 review_status, created_at, source_url, source_title,
                 evidence_text, reasoning, agent_id, marriage_date, marriage_location)
                VALUES (?, ?, ?, ?, NULL, 'biological', 'pending', ?, 'https://example.test/rec',
                        'Test source', 'evidence', 'reasoning', 'field-researcher', ?, ?)
                """, arguments: [id, from, to, relType, Date(), marriageDate, marriageLocation])
        }
    }

    @Test func spouseDedupMatchesTheReversedDirection() throws {
        let db = try makeDB()
        let original = spouseEdge("A1", "B1")
        _ = try db.addFamily(
            profiles: [profile("A1", "John", "Wheeldon"), profile("B1", "Ruth", "Brelsford")],
            relationships: [original], source: SourceOrigin(identifier: "test"))

        let (id, inserted) = try db.addRelationshipIfAbsent(spouseEdge("B1", "A1"))

        #expect(!inserted, "the reversed spouse edge is the SAME marriage, not a new one")
        #expect(id == original.id)
        let spouseEdges = try db.buildSnapshot().relationships.filter { $0.type == .spouse }
        #expect(spouseEdges.count == 1)
    }

    @Test func parentDedupStaysDirectionExact() throws {
        // A→B parent and B→A parent are DIFFERENT claims (who is whose
        // parent) — the spouse fix must not loosen parent dedup.
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("P1", "John", "Wheeldon"), profile("C1", "Samuel", "Wheeldon")],
            relationships: [parentEdge("P1", "C1")], source: SourceOrigin(identifier: "test"))

        let (_, inserted) = try db.addRelationshipIfAbsent(parentEdge("C1", "P1"))

        #expect(inserted, "a reversed parent edge is a distinct claim and must insert")
    }

    @Test func approvingAReversedSpouseProposalEnrichesTheRealEdge() throws {
        // The stranded-Wheeldon scenario minus a coin-flip on direction: the
        // user hand-added A→B; MCP proposed the same marriage as B→A.
        // Approve must enrich the existing edge, never mint a duplicate.
        let db = try makeDB()
        let handAdded = spouseEdge("J1", "E1")
        _ = try db.addFamily(
            profiles: [profile("J1", "James", "Beresford"), profile("E1", "Elizabeth Ann", "Crawshaw")],
            relationships: [handAdded], source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "r1", from: "E1", to: "J1", relType: "spouse",
                           marriageDate: "Jun 1880", marriageLocation: "Ecclesall Bierlow")

        #expect(try db.approvePendingRelationship(id: "r1"))

        let spouseEdges = try db.buildSnapshot().relationships.filter { $0.type == .spouse }
        #expect(spouseEdges.count == 1, "no duplicate spouse edge from the reversed proposal")
        #expect(spouseEdges.first?.id == handAdded.id, "the hand-added edge survives as THE edge")
        #expect(spouseEdges.first?.marriageDate?.original == "Jun 1880",
                "the marriage details land on the real edge, not a phantom duplicate")
        #expect(spouseEdges.first?.marriageLocation == "Ecclesall Bierlow")
    }

    @Test func reversedDuplicateNoLongerDoubleRendersTheSpouse() throws {
        // FamilyGraphSnapshot.spousesOf has no person-level dedupe, so the
        // old behaviour showed the same wife twice. With the bidirectional
        // dedup the second insert never happens.
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("A1", "Thomas", "Land"), profile("B1", "Hannah", "Hewkin")],
            relationships: [spouseEdge("A1", "B1")], source: SourceOrigin(identifier: "test"))
        _ = try db.addRelationshipIfAbsent(spouseEdge("B1", "A1"))

        let snapshot = try db.buildSnapshot()
        #expect(snapshot.spousesOf("A1").count == 1)
        #expect(snapshot.spousesOf("B1").count == 1)
    }
}
