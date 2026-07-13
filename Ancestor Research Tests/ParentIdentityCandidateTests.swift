import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// CONFLICT_LAYER_SPEC CL6 — engine-origin `.parentIdentityCandidate`:
/// F4a disputes seed choose-one groups including the incumbent edge ⟨G11⟩,
/// user-seeded `.parentCandidates` stay untouched (AC1), and supported
/// requires linkage back to the subject (AC2, no self-confirmation).
@MainActor
struct ParentIdentityCandidateTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: """
                INSERT INTO project_meta (id, name, source_kind, source_value, created_at)
                VALUES ('test', 'Test', 'manual', '', ?)
                """, arguments: [Date()])
        }
        return db
    }

    private func profile(_ id: String, first: String, last: String) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, lastName: last,
            gender: .female, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
    }

    // MARK: - AC1: F4a dispute seeds a group with BOTH mothers; user seeds untouched

    @Test func sweepSeedsIdentityGroupContainingBothMothers() throws {
        let db = try makeDB()
        _ = try db.addProfile(profile("child", first: "George", last: "Brooks"), source: .gedcom)
        _ = try db.addProfile(profile("m1", first: "Mary", last: "Bown"), source: .gedcom)
        _ = try db.addProfile(profile("m2", first: "Sarah", last: "Land"), source: .gedcom)
        for mother in ["m1", "m2"] {
            _ = try db.addRelationship(Relationship(
                id: UUID(), from: mother, to: "child", type: .parent,
                role: .mother, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        }
        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)

        // Both mothers in one choose-one group, incumbent included ⟨G11⟩.
        let group = try db.hypotheses(inCandidateGroup: "parentIdentity:child:mother")
        #expect(group.count == 2)
        let names = Set(group.map(\.reasoning).joined().split(separator: "'").map(String.init))
        #expect(names.contains { $0.contains("Bown") } || group.contains { $0.id.contains("BOWN") })
        #expect(group.allSatisfy { $0.origin == .engine })

        // User-seeded .parentCandidates rows are untouched (distinct kind).
        #expect(group.allSatisfy { $0.kind.discriminator == "parentIdentityCandidate" })

        // Re-running the sweep regenerates freely without duplication.
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        #expect(try db.hypotheses(inCandidateGroup: "parentIdentity:child:mother").count == 2)
    }

    // MARK: - AC2: supported requires linkage back to the subject

    @Test func mmnLinkageSupportsAndBareRowStaysInconclusive() throws {
        let child = profile("child", first: "George", last: "Brooks")
        let snapshot = FamilyGraphSnapshot(profiles: ["child": child], relationships: [])
        var state = ResearchState(subject: ResearchSubject.fromProfile(child, snapshot: snapshot))

        let candidates = HypothesisEngine.seedParentIdentityCandidates(
            profileID: "child", role: "mother",
            candidateNames: [("Mary Bown", "tree edge"), ("Sarah Land", "accepted rival")])

        // Bare candidate — no linkage evidence: inconclusive (never
        // supported by its own existence).
        let bare = HypothesisEngine.gradeParentIdentityCandidate(
            candidates[0], state: state, snapshot: snapshot)
        #expect(bare.verdict == .inconclusive)
        #expect(bare.reasoning.contains("self-confirmation") || bare.reasoning.contains("linkage"))

        // Subject's own birth record carries MMN BOWN → linkage → supported.
        let common = RecordCommon(
            id: "b1", sourceID: "freebmd", name: "George Brooks",
            surname: "Brooks", givenName: "George", detailURL: nil, rawFields: [:])
        let birth = ScoredRecord(
            id: "b1",
            record: .birth(BirthRecord(common: common, birthYear: 1883, mothersMaidenName: "Bown")),
            verdict: .fact, gates: [], summary: "birth 1883 MMN Bown")
        state.scoredRecords = [birth]
        let linked = HypothesisEngine.gradeParentIdentityCandidate(
            candidates[0], state: state, snapshot: snapshot)
        #expect(linked.verdict == .supported)
        #expect(linked.reasoning.contains("BOWN"))

        // The rival (Land) gains nothing from Bown's linkage.
        let rival = HypothesisEngine.gradeParentIdentityCandidate(
            candidates[1], state: state, snapshot: snapshot)
        #expect(rival.verdict == .inconclusive)
    }
}
