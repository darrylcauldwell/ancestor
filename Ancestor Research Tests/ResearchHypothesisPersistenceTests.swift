import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the V2 spec §4.1 ResearchHypothesis type + the v26 migration's
/// research_hypotheses table. Covers:
///   • Round-trip persistence for every HypothesisKind case (JSON payload
///     survives serialise → store → load → decode).
///   • Upsert semantics: re-inserting by ID updates the mutable fields
///     and preserves `created_at` + `user_rejected` flag.
///   • Reject / unreject behaviour.
///   • Empty result when no hypotheses exist for a profile.
///
/// T11 ships the table + CRUD; T12 fills in generators/graders. These
/// tests run against the empty engine and verify the persistence layer
/// itself is correct.
@MainActor
struct ResearchHypothesisPersistenceTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// Insert a minimal profile row so hypotheses can reference it via the
    /// `subject_profile_id` foreign key. Tests that exercise per-profile
    /// loading must call this first.
    private func insertProfile(id: String, into db: ProjectDatabase) throws {
        let profile = Profile(
            id: id, externalIDs: [:],
            firstName: "Test", lastName: id, gender: .male,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
    }

    /// Tests default to `subjectProfileID: nil` so the FK to `profiles`
    /// doesn't fire — the persistence tests are about hypothesis-table
    /// semantics, not the profile relationship. A separate test exercises
    /// the FK explicitly.
    private func makeHypothesis(
        id: String = "test-id-1",
        subjectProfileID: String? = nil,
        kind: HypothesisKind = .siblingExists(district: "BELPER", mmn: "HOLMES", yearWindow: 1956...1996),
        verdict: ResearchHypothesis.Verdict = .supported,
        isModelAssisted: Bool = false,
        attempts: Int = 1
    ) -> ResearchHypothesis {
        ResearchHypothesis(
            id: id,
            subjectProfileID: subjectProfileID,
            kind: kind,
            verdict: verdict,
            isModelAssisted: isModelAssisted,
            supportingEvidence: ["record-1", "record-2"],
            contradictingEvidence: [],
            reasoning: "test reasoning",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            lastTestedAt: Date(timeIntervalSince1970: 1_000_500),
            attempts: attempts,
            history: [
                ResearchHypothesis.Transition(
                    verdict: .inconclusive,
                    isModelAssisted: false,
                    at: Date(timeIntervalSince1970: 999_000),
                    reason: "initial generation"
                ),
                ResearchHypothesis.Transition(
                    verdict: verdict,
                    isModelAssisted: isModelAssisted,
                    at: Date(timeIntervalSince1970: 1_000_500),
                    reason: "graded"
                ),
            ]
        )
    }

    // MARK: - Identity-key invariants

    @Test func identityKey_isDeterministic_forSameKind() {
        let kind1 = HypothesisKind.siblingExists(district: "Belper", mmn: "Holmes", yearWindow: 1956...1996)
        let kind2 = HypothesisKind.siblingExists(district: "Belper", mmn: "Holmes", yearWindow: 1956...1996)
        #expect(kind1.identityKey(subjectProfileID: "subj") == kind2.identityKey(subjectProfileID: "subj"))
    }

    @Test func identityKey_normalisesCaseForLocationAndName() {
        // Same district + MMN with different case should produce the same id —
        // re-runs of the pipeline shouldn't drift if a transcriber capitalises
        // differently between two FreeBMD index entries.
        let kind1 = HypothesisKind.siblingExists(district: "belper", mmn: "holmes", yearWindow: 1956...1996)
        let kind2 = HypothesisKind.siblingExists(district: "BELPER", mmn: "Holmes", yearWindow: 1956...1996)
        #expect(kind1.identityKey(subjectProfileID: "subj") == kind2.identityKey(subjectProfileID: "subj"))
    }

    @Test func identityKey_differsByPayload() {
        let kind1 = HypothesisKind.siblingExists(district: "Belper", mmn: "Holmes", yearWindow: 1956...1996)
        let kind2 = HypothesisKind.siblingExists(district: "Belper", mmn: "Sambrook", yearWindow: 1956...1996)
        #expect(kind1.identityKey(subjectProfileID: "subj") != kind2.identityKey(subjectProfileID: "subj"))
    }

    // MARK: - isDeterministicallySupported helper

    @Test func isDeterministicallySupported_trueWhenSupportedAndNoModel() {
        let h = makeHypothesis(verdict: .supported, isModelAssisted: false)
        #expect(h.isDeterministicallySupported == true)
    }

    @Test func isDeterministicallySupported_falseWhenModelAssisted() {
        let h = makeHypothesis(verdict: .supported, isModelAssisted: true)
        #expect(h.isDeterministicallySupported == false)
    }

    @Test func isDeterministicallySupported_falseWhenContradicted() {
        let h = makeHypothesis(verdict: .contradicted, isModelAssisted: false)
        #expect(h.isDeterministicallySupported == false)
    }

    @Test func isDeterministicallySupported_falseWhenInconclusive() {
        let h = makeHypothesis(verdict: .inconclusive, isModelAssisted: false)
        #expect(h.isDeterministicallySupported == false)
    }

    // MARK: - JSON round-trip for every kind

    @Test func jsonRoundTrip_subjectIdentity() throws {
        let kind = HypothesisKind.subjectIdentity(birthYearWindow: 1880...1882, districtHint: "Wirksworth")
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    @Test func jsonRoundTrip_parentMarriage() throws {
        let kind = HypothesisKind.parentMarriage(motherSurname: "Holmes", fatherSurname: "Cauldwell", windowYears: 1940...1970)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    @Test func jsonRoundTrip_siblingExists() throws {
        let kind = HypothesisKind.siblingExists(district: "Belper", mmn: "Holmes", yearWindow: 1956...1996)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    @Test func jsonRoundTrip_clusterIsSubject() throws {
        let uuid = UUID()
        let kind = HypothesisKind.clusterIsSubject(clusterID: uuid)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    @Test func jsonRoundTrip_burialAtParish() throws {
        let kind = HypothesisKind.burialAtParish(parish: "St Mary, Wirksworth", yearWindow: 1900...1950)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    @Test func jsonRoundTrip_secondMarriage() throws {
        let kind = HypothesisKind.secondMarriage(afterYear: 1920)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    // MARK: - Database upsert + load

    @Test func upsert_thenLoad_returnsHypothesis() throws {
        let db = try makeTempDB()
        let h = makeHypothesis()
        try db.upsertHypothesis(h)
        let loaded = try db.loadHypothesis(id: h.id)
        #expect(loaded != nil)
        #expect(loaded?.id == h.id)
        #expect(loaded?.subjectProfileID == h.subjectProfileID)
        #expect(loaded?.kind == h.kind)
        #expect(loaded?.verdict == h.verdict)
        #expect(loaded?.isModelAssisted == h.isModelAssisted)
        #expect(loaded?.supportingEvidence == h.supportingEvidence)
        #expect(loaded?.contradictingEvidence == h.contradictingEvidence)
        #expect(loaded?.reasoning == h.reasoning)
        #expect(loaded?.attempts == h.attempts)
        #expect(loaded?.history == h.history)
    }

    @Test func loadHypotheses_byProfile_returnsAll() throws {
        let db = try makeTempDB()
        try insertProfile(id: "subject-a", into: db)
        try insertProfile(id: "subject-b", into: db)
        let h1 = makeHypothesis(id: "h1", subjectProfileID: "subject-a")
        let h2 = makeHypothesis(id: "h2", subjectProfileID: "subject-a")
        let other = makeHypothesis(id: "h3", subjectProfileID: "subject-b")
        try db.upsertHypotheses([h1, h2, other])

        let aResults = try db.loadHypotheses(forProfile: "subject-a")
        #expect(aResults.count == 2)
        #expect(Set(aResults.map(\.id)) == Set(["h1", "h2"]))

        let bResults = try db.loadHypotheses(forProfile: "subject-b")
        #expect(bResults.count == 1)
        #expect(bResults.first?.id == "h3")
    }

    @Test func foreignKey_acceptsValidProfileReference() throws {
        // Exercises the v26 FK: with a real profile, the insert succeeds.
        // Cascade-delete behaviour is SQLite-standard and tested elsewhere
        // when higher-level delete flows touch this path.
        let db = try makeTempDB()
        try insertProfile(id: "subject-fk", into: db)
        let h = makeHypothesis(id: "fk-hyp", subjectProfileID: "subject-fk")
        try db.upsertHypothesis(h)
        let loaded = try db.loadHypothesis(id: "fk-hyp")
        #expect(loaded?.subjectProfileID == "subject-fk")
    }

    @Test func loadHypotheses_emptyForUnknownProfile() throws {
        let db = try makeTempDB()
        let results = try db.loadHypotheses(forProfile: "no-such-profile")
        #expect(results.isEmpty)
    }

    @Test func upsert_updatesMutableFields_preservesId() throws {
        let db = try makeTempDB()
        let original = makeHypothesis(verdict: .inconclusive, attempts: 0)
        try db.upsertHypothesis(original)

        // Re-insert with same id, different verdict + attempts.
        let updated = ResearchHypothesis(
            id: original.id,
            subjectProfileID: original.subjectProfileID,
            kind: original.kind,
            verdict: .supported,         // changed
            isModelAssisted: false,
            supportingEvidence: ["new-record"],
            contradictingEvidence: [],
            reasoning: "updated after second pass",
            createdAt: Date(timeIntervalSince1970: 2_000_000),   // tries to overwrite, should be ignored
            lastTestedAt: Date(timeIntervalSince1970: 2_000_500),
            attempts: 1,                  // changed
            history: original.history + [
                ResearchHypothesis.Transition(
                    verdict: .supported, isModelAssisted: false,
                    at: Date(timeIntervalSince1970: 2_000_500),
                    reason: "found a candidate"
                )
            ]
        )
        try db.upsertHypothesis(updated)

        let loaded = try db.loadHypothesis(id: original.id)
        #expect(loaded?.verdict == .supported)
        #expect(loaded?.attempts == 1)
        #expect(loaded?.history.count == 3)
        // created_at preserved from the original — DO UPDATE excludes it.
        #expect(loaded?.createdAt == original.createdAt)
    }

    // MARK: - Reject / unreject

    @Test func rejectHypothesis_excludesFromDefaultLoad() throws {
        let db = try makeTempDB()
        let h = makeHypothesis()
        try db.upsertHypothesis(h)
        try db.rejectHypothesis(id: h.id)

        let visible = try db.loadHypotheses(forProfile: h.subjectProfileID)
        #expect(visible.isEmpty)
    }

    @Test func rejectHypothesis_keepsRowVisibleWithFlag() throws {
        let db = try makeTempDB()
        let h = makeHypothesis()
        try db.upsertHypothesis(h)
        try db.rejectHypothesis(id: h.id)

        // includingRejected: true should still return it
        let all = try db.loadHypotheses(forProfile: h.subjectProfileID, includingRejected: true)
        #expect(all.count == 1)
        #expect(all.first?.id == h.id)
    }

    @Test func upsert_preservesRejectedFlag() throws {
        let db = try makeTempDB()
        let h = makeHypothesis()
        try db.upsertHypothesis(h)
        try db.rejectHypothesis(id: h.id)

        // Re-run dispatches an upsert — the rejection must survive.
        try db.upsertHypothesis(h)
        let visible = try db.loadHypotheses(forProfile: h.subjectProfileID)
        #expect(visible.isEmpty, "rejection must persist across re-run upserts")
    }

    @Test func unrejectHypothesis_restoresVisibility() throws {
        let db = try makeTempDB()
        let h = makeHypothesis()
        try db.upsertHypothesis(h)
        try db.rejectHypothesis(id: h.id)
        try db.unrejectHypothesis(id: h.id)

        let visible = try db.loadHypotheses(forProfile: h.subjectProfileID)
        #expect(visible.count == 1)
    }

    // MARK: - HypothesisEngine scaffold (T11 returns empty / inconclusive)

    @Test func hypothesisEngine_runAll_passesThroughPersisted_inT11Scaffold() throws {
        // T11 engine is a scaffold — runAll returns whatever was passed in
        // without generating new hypotheses. T12 wires generators in.
        let h = makeHypothesis()
        let result = HypothesisEngine.runAll(
            state: makeEmptyState(),
            snapshot: makeEmptySnapshot(),
            persisted: [h]
        )
        #expect(result.count == 1)
        #expect(result.first?.id == h.id)
    }

    @Test func hypothesisEngine_generateSiblingExists_returnsEmptyInT11Scaffold() {
        let result = HypothesisEngine.generateSiblingExists(
            state: makeEmptyState(),
            snapshot: makeEmptySnapshot()
        )
        #expect(result.isEmpty)
    }

    @Test func hypothesisEngine_deficitQuery_returnsNilInT11Scaffold() {
        let h = makeHypothesis()
        let result = HypothesisEngine.deficitQuery(
            for: h, atLevel: 1, state: makeEmptyState()
        )
        #expect(result == nil)
    }

    // MARK: - Helpers

    private func makeEmptyState() -> ResearchState {
        let subject = ResearchSubject(
            profileID: nil,
            surname: "Test",
            givenName: nil,
            middleName: nil,
            birthYearFrom: nil,
            birthYearTo: nil,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: nil,
            region: nil,
            mode: ResearchMode.verify,
            familyContext: nil,
            homeChapmanCode: "DBY"
        )
        return ResearchState(subject: subject)
    }

    private func makeEmptySnapshot() -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [:], relationships: [])
    }
}
