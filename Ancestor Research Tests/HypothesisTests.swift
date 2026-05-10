import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for M8 W5 (Hypotheses) — model JSON round-trip across all four
/// claim types, DB CRUD, status transitions (dismiss preserves reason),
/// active-only filter for the tree uncertainty layer.
struct HypothesisTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeHypothesis(
        claim: HypothesisClaim,
        confidence: HypothesisConfidence = .speculation,
        status: HypothesisStatus = .active
    ) -> Hypothesis {
        Hypothesis(
            id: UUID(), claim: claim, confidence: confidence,
            reasoning: "test reasoning",
            supportingEvidence: ["A", "B"],
            contradictingEvidence: [],
            status: status,
            createdAt: Date(), resolvedAt: nil, dismissalReason: nil
        )
    }

    // MARK: - Claim JSON round-trip

    @Test func claimJSON_relationship_roundTrips() throws {
        let claim = HypothesisClaim.relationship(
            fromID: "p1", toID: "p2", type: .parent, role: .father
        )
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(HypothesisClaim.self, from: data)
        #expect(decoded == claim)
    }

    @Test func claimJSON_fieldValue_roundTrips() throws {
        let claim = HypothesisClaim.fieldValue(profileID: "p", field: .birthDate, value: "1880")
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(HypothesisClaim.self, from: data)
        #expect(decoded == claim)
    }

    @Test func claimJSON_identityMatch_roundTrips() throws {
        let claim = HypothesisClaim.identityMatch(profileID1: "a", profileID2: "b")
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(HypothesisClaim.self, from: data)
        #expect(decoded == claim)
    }

    @Test func claimJSON_existence_roundTrips() throws {
        let claim = HypothesisClaim.existence(
            description: "James, sibling who died young",
            relatedProfileIDs: ["father", "mother"]
        )
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(HypothesisClaim.self, from: data)
        #expect(decoded == claim)
    }

    @Test func claimKind_disambiguatesAllFour() {
        let kinds: [HypothesisClaim.Kind] = [
            HypothesisClaim.relationship(fromID: "a", toID: "b", type: .parent, role: nil).kind,
            HypothesisClaim.fieldValue(profileID: "a", field: .firstName, value: "x").kind,
            HypothesisClaim.identityMatch(profileID1: "a", profileID2: "b").kind,
            HypothesisClaim.existence(description: "x", relatedProfileIDs: []).kind,
        ]
        #expect(kinds == [.relationship, .fieldValue, .identityMatch, .existence])
    }

    // MARK: - DB CRUD

    @Test func addHypothesis_persistsAndLoads() throws {
        let db = try makeTempDB()
        let h = makeHypothesis(claim: .fieldValue(profileID: "p", field: .firstName, value: "Alice"))
        try db.addHypothesis(h)
        let loaded = try db.loadHypothesis(id: h.id)
        #expect(loaded?.id == h.id)
        if case .fieldValue(let pid, let field, let value) = loaded?.claim {
            #expect(pid == "p")
            #expect(field == .firstName)
            #expect(value == "Alice")
        } else {
            Issue.record("Expected fieldValue claim")
        }
    }

    @Test func updateHypothesis_changesStatus() throws {
        let db = try makeTempDB()
        let h = makeHypothesis(claim: .existence(description: "test", relatedProfileIDs: []))
        try db.addHypothesis(h)
        var updated = h
        updated.status = .promoted
        updated.resolvedAt = Date()
        try db.updateHypothesis(updated)
        #expect(try db.loadHypothesis(id: h.id)?.status == .promoted)
    }

    @Test func updateHypothesis_preservesDismissalReason() throws {
        let db = try makeTempDB()
        let h = makeHypothesis(claim: .existence(description: "test", relatedProfileIDs: []))
        try db.addHypothesis(h)
        var updated = h
        updated.status = .dismissed
        updated.dismissalReason = "Census confirms otherwise"
        updated.resolvedAt = Date()
        try db.updateHypothesis(updated)
        let loaded = try db.loadHypothesis(id: h.id)
        #expect(loaded?.dismissalReason == "Census confirms otherwise")
        #expect(loaded?.status == .dismissed)
    }

    @Test func deleteHypothesis_removes() throws {
        let db = try makeTempDB()
        let h = makeHypothesis(claim: .identityMatch(profileID1: "a", profileID2: "b"))
        try db.addHypothesis(h)
        try db.deleteHypothesis(id: h.id)
        #expect(try db.loadHypothesis(id: h.id) == nil)
    }

    @Test func loadActiveHypotheses_filtersResolved() throws {
        let db = try makeTempDB()
        let active = makeHypothesis(
            claim: .relationship(fromID: "a", toID: "b", type: .parent, role: nil),
            status: .active
        )
        let dismissed = makeHypothesis(
            claim: .relationship(fromID: "c", toID: "d", type: .parent, role: nil),
            status: .dismissed
        )
        let promoted = makeHypothesis(
            claim: .relationship(fromID: "e", toID: "f", type: .parent, role: nil),
            status: .promoted
        )
        try db.addHypothesis(active)
        try db.addHypothesis(dismissed)
        try db.addHypothesis(promoted)

        let actives = try db.loadActiveHypotheses()
        #expect(actives.count == 1)
        #expect(actives.first?.id == active.id)
    }

    @Test func evidenceArrays_roundTripIncludingEmpty() throws {
        let db = try makeTempDB()
        var h = makeHypothesis(claim: .existence(description: "x", relatedProfileIDs: []))
        h.supportingEvidence = []
        h.contradictingEvidence = ["one", "two"]
        try db.addHypothesis(h)
        let loaded = try db.loadHypothesis(id: h.id)
        #expect(loaded?.supportingEvidence.isEmpty == true)
        #expect(loaded?.contradictingEvidence == ["one", "two"])
    }

    // MARK: - Confidence + Status enum properties

    @Test func confidence_groupOrderHighestFirst() {
        #expect(HypothesisConfidence.strong.groupOrder < HypothesisConfidence.working.groupOrder)
        #expect(HypothesisConfidence.working.groupOrder < HypothesisConfidence.speculation.groupOrder)
    }

    @Test func status_isResolved_correctness() {
        #expect(!HypothesisStatus.active.isResolved)
        #expect(HypothesisStatus.promoted.isResolved)
        #expect(HypothesisStatus.dismissed.isResolved)
        #expect(HypothesisStatus.superseded.isResolved)
    }

    @Test func claimSummary_relationshipDescribesType() {
        let h = makeHypothesis(claim: .relationship(
            fromID: "a", toID: "b", type: .parent, role: .mother
        ))
        let summary = h.claimSummary
        #expect(summary.contains("Parent"))
        #expect(summary.contains("mother"))
    }

    @Test func claimSummary_existenceUsesDescription() {
        let h = makeHypothesis(claim: .existence(
            description: "James, died young", relatedProfileIDs: []
        ))
        #expect(h.claimSummary == "James, died young")
    }
}
