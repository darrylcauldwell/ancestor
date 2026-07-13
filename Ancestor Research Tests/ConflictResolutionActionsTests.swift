import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// CL UI pass — the deterministic logic behind the conflict-resolution
/// controls: choose-parent (removes rival edge + resolves dispute +
/// contradicts rival candidates, undo-compatible via transactions),
/// timeline resolutions, and the ⟨G12⟩ proposal derivation.
@MainActor
struct ConflictResolutionActionsTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: """
                INSERT INTO project_meta (id, name, source_kind, source_value, created_at)
                VALUES ('t', 'T', 'manual', '', ?)
                """, arguments: [Date()])
        }
        return db
    }

    private func profile(_ id: String, first: String, last: String,
                         death: String? = nil) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, lastName: last,
            gender: .female, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: death.map { GenealogicalDate(parsing: $0) }, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// Two-mothers fixture: child + two biological mother edges, swept so
    /// the F4a dispute and the CL6 candidate group both exist.
    private func twoMothersFixture() throws -> (ProjectDatabase, FamilyGraphSnapshot) {
        let db = try makeDB()
        _ = try db.addProfile(profile("child", first: "George", last: "Brooks"), source: .gedcom)
        _ = try db.addProfile(profile("m1", first: "Mary", last: "Bown"), source: .gedcom)
        _ = try db.addProfile(profile("m2", first: "Sarah", last: "Land"), source: .gedcom)
        for m in ["m1", "m2"] {
            _ = try db.addRelationship(Relationship(
                id: UUID(), from: m, to: "child", type: .parent,
                role: .mother, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        }
        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        return (db, snapshot)
    }

    // MARK: - choose-parent end to end

    @Test func chooseParentRemovesRivalResolvesDisputeContradictsCandidates() throws {
        let (db, snapshot) = try twoMothersFixture()
        #expect(try db.openDisputes(profileID: "child").contains { $0.kind == .parentRole })

        try ConflictResolutionActions.chooseParent(
            subjectID: "child", role: .mother, keepParentID: "m1",
            snapshot: snapshot, db: db)

        // Rival edge removed…
        let after = try db.buildSnapshot()
        let mothers = after.relationships.filter {
            $0.type == .parent && $0.to == "child" && $0.role == .mother
        }
        #expect(mothers.count == 1)
        #expect(mothers.first?.from == "m1")
        // …dispute resolved…
        #expect(!(try db.openDisputes(profileID: "child").contains { $0.kind == .parentRole }))
        // …rival candidate contradicted, kept one untouched.
        let group = try db.hypotheses(inCandidateGroup: "parentIdentity:child:mother")
        let rival = group.first { $0.id.contains("SARAH LAND") }
        let kept = group.first { $0.id.contains("MARY BOWN") }
        #expect(rival?.verdict == .contradicted)
        #expect(kept?.verdict != .contradicted)
    }

    @Test func keepBothResolvesWithoutTouchingEdges() throws {
        let (db, _) = try twoMothersFixture()
        try ConflictResolutionActions.keepBothParents(subjectID: "child", role: .mother, db: db)
        let after = try db.buildSnapshot()
        #expect(after.relationships.filter { $0.type == .parent && $0.to == "child" }.count == 2)
        #expect(!(try db.openDisputes(profileID: "child").contains { $0.kind == .parentRole }))
    }

    // MARK: - timeline resolutions

    @Test func clearDeathDateResolvesTimelineDispute() throws {
        let db = try makeDB()
        let p = profile("p1", first: "John", last: "Smith", death: "1905")
        _ = try db.addProfile(p, source: .gedcom)
        _ = try db.addLifeEvent(LifeEvent(
            id: UUID(), profileID: "p1", type: .census,
            date: GenealogicalDate(parsing: "1911")))
        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        #expect(try db.openDisputes(profileID: "p1").contains { $0.field == "death-vs-alive" })

        try ConflictResolutionActions.clearDeathDate(
            profile: snapshot.profiles["p1"]!, db: db)

        #expect(try db.buildSnapshot().profiles["p1"]?.deathDate == nil)
        #expect(!(try db.openDisputes(profileID: "p1").contains { $0.field == "death-vs-alive" }))
    }

    @Test func discardLifeEventResolvesTimelineDispute() throws {
        let db = try makeDB()
        let p = profile("p1", first: "John", last: "Smith", death: "1905")
        _ = try db.addProfile(p, source: .gedcom)
        let event = try db.addLifeEvent(LifeEvent(
            id: UUID(), profileID: "p1", type: .census,
            date: GenealogicalDate(parsing: "1911")))
        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)

        try ConflictResolutionActions.discardLifeEvent(
            event, disputeFieldKey: "death-vs-alive", db: db)

        #expect((try db.loadLifeEvents(profileID: "p1")).isEmpty)
        #expect(!(try db.openDisputes(profileID: "p1").contains { $0.field == "death-vs-alive" }))
        // The death date is untouched — the human said the EVENT was wrong.
        #expect(try db.buildSnapshot().profiles["p1"]?.deathDate?.earliest == 1905)
    }

    // MARK: - G12 proposal derivation

    @Test func proposalAppearsOnlyWhenOneSupportedAndAllRivalsContradicted() throws {
        let db = try makeDB()
        let p = profile("p1", first: "George", last: "Brooks", death: "1905")
        _ = try db.addProfile(p, source: .gedcom)
        // Second precise attestation lands as a field_sources row (the
        // in-memory sources map does not survive the addProfile round
        // trip — provenance is derived from flat fields).
        try db.dbQueue.write { sql in
            try sql.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at)
                VALUES ('p1', 'profile', 'deathDate', 'freebmd', 'Dec 1913', ?)
                """, arguments: [Date()])
        }
        let snapshot = try db.buildSnapshot()
        let state = ResearchState(subject: ResearchSubject.fromProfile(p, snapshot: snapshot))
        var group = HypothesisEngine.generateDeathYearCandidate(state: state, snapshot: snapshot)
        try db.upsertHypotheses(group)

        // Both inconclusive → no proposal.
        #expect(ConflictResolutionActions.proposedResolution(
            for: .deathDate, profileID: "p1", db: db) == nil)

        // One supported + rival contradicted → proposal names the winner.
        func rebuilt(_ h: ResearchHypothesis, verdict: ResearchHypothesis.Verdict) -> ResearchHypothesis {
            var c = ResearchHypothesis(
                id: h.id, subjectProfileID: h.subjectProfileID, kind: h.kind,
                origin: h.origin, verdict: verdict, isModelAssisted: false,
                supportingEvidence: [], contradictingEvidence: [],
                reasoning: "alive at 1911", createdAt: h.createdAt,
                lastTestedAt: Date(), attempts: h.attempts, history: h.history)
            c.candidateGroupID = h.candidateGroupID
            return c
        }
        let idx1913 = group.firstIndex { $0.id.contains("1913") }!
        let idx1905 = group.firstIndex { $0.id.contains("1905") }!
        group[idx1913] = rebuilt(group[idx1913], verdict: .supported)
        group[idx1905] = rebuilt(group[idx1905], verdict: .contradicted)
        try db.upsertHypotheses(group)

        let proposal = ConflictResolutionActions.proposedResolution(
            for: .deathDate, profileID: "p1", db: db)
        #expect(proposal != nil)
        #expect(proposal?.label.contains("1913") == true)
        #expect(proposal?.hypothesisID.contains("1913") == true)
    }
}
