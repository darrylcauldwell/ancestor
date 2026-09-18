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

    // MARK: - EV27: role is an attribute of a parent edge, not its identity

    private func parentEdges(_ db: ProjectDatabase, _ from: String, _ to: String) throws -> [Relationship] {
        try relationships(db).filter { $0.type == .parent && $0.from == from && $0.to == to }
    }

    @Test func approvingARoleChangeOnAnExistingEdgeDoesNotDuplicateIt() throws {
        // The live symptom: proposing a role change on an edge that already
        // existed inserted a TWIN parent row, because the dedup matched
        // `(role = ? OR role IS NULL)` and 'father' ≠ 'mother'.
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("H1", "Hannah", "Hewkin"), profile("F1", "Frances", "Gladwin")],
            relationships: [Relationship(
                id: UUID(), from: "H1", to: "F1", type: .parent,
                role: .father, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "rr1", from: "H1", to: "F1", relType: "parent", role: "mother")

        #expect(try db.approvePendingRelationship(id: "rr1"))

        let edges = try parentEdges(db, "H1", "F1")
        #expect(edges.count == 1, "a role change must not insert a twin parent edge")
        #expect(edges.first?.role == .father,
                "an approval never silently overwrites a stated role")
        #expect(try db.openDisputes(profileID: "F1").contains(where: { $0.kind == .parentRole }),
                "the contradiction is recorded, not dropped")
    }

    @Test func approvingARoleLessProposalFillsAnUnspecifiedRoleInPlace() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("H2", "Hannah", "Hewkin"), profile("F2", "Frances", "Gladwin")],
            relationships: [Relationship(
                id: UUID(), from: "H2", to: "F2", type: .parent,
                role: .unspecified, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "rr2", from: "H2", to: "F2", relType: "parent", role: "mother")

        #expect(try db.approvePendingRelationship(id: "rr2"))

        let edges = try parentEdges(db, "H2", "F2")
        #expect(edges.count == 1)
        #expect(edges.first?.role == .mother,
                "fill-only: an EMPTY role is the one thing an approval may write")
        #expect(try db.openDisputes(profileID: "F2").isEmpty,
                "filling an empty slot is not a contradiction")
    }

    @Test func approvingARoleLessProposalOnARoledEdgeIsANoOp() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("H3", "Hannah", "Hewkin"), profile("F3", "Frances", "Gladwin")],
            relationships: [Relationship(
                id: UUID(), from: "H3", to: "F3", type: .parent,
                role: .father, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "rr3", from: "H3", to: "F3", relType: "parent")

        #expect(try db.approvePendingRelationship(id: "rr3"))

        let edges = try parentEdges(db, "H3", "F3")
        #expect(edges.count == 1, "re-proposing an existing relationship is a no-op, never a twin")
        #expect(edges.first?.role == .father)
    }

    @Test func approvingASecondDifferentMotherOpensAnF4aDispute() throws {
        // Two DIFFERENT people in one biological role is a real split, not a
        // duplicate: both edges stand (when in doubt, split) and the
        // two-mothers state is recorded rather than left invisible.
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("M1", "Sarah", "Oates"), profile("M2", "Hannah", "Hewkin"),
                       profile("C1", "Frances", "Gladwin")],
            relationships: [Relationship(
                id: UUID(), from: "M1", to: "C1", type: .parent,
                role: .mother, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "rr4", from: "M2", to: "C1", relType: "parent", role: "mother")

        #expect(try db.approvePendingRelationship(id: "rr4"))

        let edges = try relationships(db).filter { $0.type == .parent && $0.to == "C1" }
        #expect(edges.count == 2, "two different parents are two edges — never collapsed")
        #expect(try db.openDisputes(profileID: "C1").contains(where: { $0.kind == .parentRole }),
                "F4a parity with ApplyEngine — the two-mothers state is never invisible")
    }

    // MARK: - Review F06: FILLING a role is as much a two-mothers claim as inserting one

    /// The `.unspecified` biological parent edge is not exotic — it is what
    /// `ProjectDatabase+PromoteLead` writes for every promoted sibling/parent
    /// ghost and what `AppState.addCensusFamily` writes for a roster row of
    /// unknown sex. An external proposal landing on one used to fill the role
    /// and record NOTHING.
    @Test func fillingAnUnspecifiedRoleIntoAnOccupiedOneOpensAnF4aDispute() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("M1", "Sarah", "Oates"), profile("M2", "Hannah", "Hewkin"),
                       profile("C1", "Frances", "Gladwin")],
            relationships: [
                Relationship(
                    id: UUID(), from: "M1", to: "C1", type: .parent,
                    role: .mother, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil),
                // The promoted-ghost / census-roster shape: edge already there,
                // role never stated.
                Relationship(
                    id: UUID(), from: "M2", to: "C1", type: .parent,
                    role: .unspecified, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil),
            ],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "rr5", from: "M2", to: "C1", relType: "parent", role: "mother")

        #expect(try db.approvePendingRelationship(id: "rr5"))

        let edges = try relationships(db).filter { $0.type == .parent && $0.to == "C1" }
        #expect(edges.count == 2, "both edges stand — when in doubt, split")
        #expect(edges.first(where: { $0.from == "M2" })?.role == .mother,
                "the empty role is still filled; the contradiction is recorded, not suppressed")
        #expect(try db.openDisputes(profileID: "C1").contains(where: { $0.kind == .parentRole }),
                "an external proposal must never be able to complete a two-mothers state silently")
    }

    /// The recorded outcome must not turn on whether the proposed parent
    /// happened to have a prior edge — that precondition is irrelevant to
    /// whether the child ends up with two biological mothers.
    @Test func f4aDisputeDoesNotDependOnWhetherTheProposedParentHadAPriorEdge() throws {
        func disputesAfterApproval(withPriorEdge: Bool) throws -> Int {
            let db = try makeDB()
            var rels = [Relationship(
                id: UUID(), from: "M1", to: "C1", type: .parent,
                role: .mother, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)]
            if withPriorEdge {
                rels.append(Relationship(
                    id: UUID(), from: "M2", to: "C1", type: .parent,
                    role: .unspecified, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil))
            }
            _ = try db.addFamily(
                profiles: [profile("M1", "Sarah", "Oates"), profile("M2", "Hannah", "Hewkin"),
                           profile("C1", "Frances", "Gladwin")],
                relationships: rels, source: SourceOrigin(identifier: "test"))
            try insertProposal(db, id: "rr6", from: "M2", to: "C1", relType: "parent", role: "mother")
            #expect(try db.approvePendingRelationship(id: "rr6"))
            return try db.openDisputes(profileID: "C1").filter { $0.kind == .parentRole }.count
        }

        let withEdge = try disputesAfterApproval(withPriorEdge: true)
        let withoutEdge = try disputesAfterApproval(withPriorEdge: false)
        #expect(withEdge == withoutEdge,
                "identical proposal, identical resulting tree — the dispute cannot hinge on the prior edge")
        #expect(withEdge == 1)
    }

    /// Re-approving a proposal whose role the edge ALREADY states writes
    /// nothing, but the state it affirms may still be two-mothers.
    /// `upsertDispute` is idempotent on (entity, kind, field), so asking is free.
    @Test func reApprovingAnAlreadyRoledEdgeStillRecordsTheOccupiedRole() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("M1", "Sarah", "Oates"), profile("M2", "Hannah", "Hewkin"),
                       profile("C1", "Frances", "Gladwin")],
            relationships: [
                Relationship(
                    id: UUID(), from: "M1", to: "C1", type: .parent,
                    role: .mother, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil),
                Relationship(
                    id: UUID(), from: "M2", to: "C1", type: .parent,
                    role: .mother, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil),
            ],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "rr7", from: "M2", to: "C1", relType: "parent", role: "mother")

        #expect(try db.approvePendingRelationship(id: "rr7"))

        #expect(try db.openDisputes(profileID: "C1").filter { $0.kind == .parentRole }.count == 1,
                "the affirmed two-mothers state is recorded exactly once")
    }

    /// Fence: the fill arm must not manufacture a conflict where there is
    /// none. One parent, empty role — nothing to contradict.
    @Test func fillingAnUnspecifiedRoleWithNoRivalOpensNoDispute() throws {
        let db = try makeDB()
        _ = try db.addFamily(
            profiles: [profile("D1", "Joseph", "Wheeldon"), profile("K1", "Kezia", "Wheeldon")],
            relationships: [Relationship(
                id: UUID(), from: "D1", to: "K1", type: .parent,
                role: .unspecified, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)],
            source: SourceOrigin(identifier: "test"))
        try insertProposal(db, id: "rr8", from: "D1", to: "K1", relType: "parent", role: "father")

        #expect(try db.approvePendingRelationship(id: "rr8"))

        #expect(try relationships(db).first { $0.type == .parent }?.role == .father)
        #expect(try db.openDisputes(profileID: "K1").isEmpty,
                "filling an unoccupied slot is not a contradiction")
    }
}
