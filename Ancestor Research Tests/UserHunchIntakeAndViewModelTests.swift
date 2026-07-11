import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// RESEARCH_PIPELINE_SPEC §5.15 Slice 4 — the Workbench intake seam
/// (`HypothesisSeedService.submitSeed`), the straight-to-`.contradicted`
/// intake materialisation (§5.15.2 last paragraph, deferred by Slice 2),
/// and the §5.15.8 refuted/exhausted UX surfaced by
/// `UserHypothesisViewModel`.
///
/// The project tests services/models, not views — so the testable unit
/// for the UI is the view-model + the shared service seam it drives.
@MainActor
struct UserHunchIntakeAndViewModelTests {

    // MARK: - Fixtures

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func insertSubject(
        id: String = "subj",
        birthDate: String? = "1887",
        into db: ProjectDatabase
    ) throws {
        let profile = Profile(
            id: id, externalIDs: [:],
            firstName: "George", lastName: "Wheeldon", gender: .male,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            isDeleted: false, sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
    }

    /// Persist a confirmed father (sourced firstName via `addProfile`,
    /// which writes a field_sources row for every non-nil field) and the
    /// parent edge, so `buildSnapshot` reconstructs `sources[.firstName]`
    /// non-empty — the condition `confirmedParentGivenNameConflict`
    /// requires.
    private func insertConfirmedFather(
        named: String,
        childID: String = "subj",
        into db: ProjectDatabase
    ) throws {
        let father = Profile(
            id: "father1", externalIDs: [:],
            firstName: named, lastName: "Wheeldon", gender: .male,
            isDeleted: false, sources: [:], disputes: [:]
        )
        _ = try db.addProfile(father, source: .gedcom)
        let edge = Relationship(
            id: UUID(), from: "father1", to: childID,
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        _ = try db.addRelationship(edge)
    }

    private func seedRows(profileID: String, db: ProjectDatabase) throws -> [Row] {
        try db.dbQueue.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT * FROM user_hypothesis_seeds WHERE profile_id = ?
                """, arguments: [profileID])
        }
    }

    private func hypothesisCount(db: ProjectDatabase) throws -> Int {
        try db.dbQueue.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM research_hypotheses") ?? -1
        }
    }

    // MARK: - submitSeed happy path (§5.15.7 phase b)

    @Test func submitSeedQueuesRowWithWorkbenchProvenance() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)

        let result = try HypothesisSeedService.submitSeed(
            profileID: "subj",
            hints: .init(fatherGiven: "Bob", motherGiven: "Sue"),
            requestedBy: "workbench",
            db: db
        )

        guard case .queued(let seedID) = result else {
            Issue.record("expected queued, got \(result)")
            return
        }
        #expect(seedID.hasPrefix("seed_"))
        let rows = try seedRows(profileID: "subj", db: db)
        #expect(rows.count == 1)
        #expect(rows.first?["status"] == "queued")
        #expect(rows.first?["requested_by"] == "workbench")
        #expect(rows.first?["kind_discriminator"] == "parentCandidates")
        // Intake writes ONLY the seed — no hypothesis row yet (that's the
        // watcher's job).
        #expect(try hypothesisCount(db: db) == 0)
    }

    @Test func submitSeedThenMaterialiseProducesUserHypothesis() throws {
        // The seam feeds the same watcher path the MCP tool does.
        let db = try makeTempDB()
        try insertSubject(into: db)
        _ = try HypothesisSeedService.submitSeed(
            profileID: "subj",
            hints: .init(fatherGiven: "Bob", motherGiven: "Sue"),
            requestedBy: "workbench",
            db: db
        )

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)
        guard case .materialised(let hid) = outcomes.first?.outcome else {
            Issue.record("expected materialised")
            return
        }
        let h = try #require(try db.loadHypothesis(id: hid))
        #expect(h.origin == .user)
        #expect(h.verdict == .inconclusive)
        #expect(h.reasoning.contains("workbench"))
    }

    // MARK: - submitSeed refusals (validation not duplicated, §5.15.2)

    @Test func submitSeedRefusesEmptyHintsWithoutWriting() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)

        let result = try HypothesisSeedService.submitSeed(
            profileID: "subj",
            hints: .init(fatherGiven: "   ", motherGiven: ""),
            requestedBy: "workbench",
            db: db
        )

        #expect(result == .refused(.noNameHints))
        #expect(try seedRows(profileID: "subj", db: db).isEmpty)
    }

    @Test func submitSeedRefusesUnknownProfile() throws {
        let db = try makeTempDB()
        let result = try HypothesisSeedService.submitSeed(
            profileID: "ghost",
            hints: .init(fatherGiven: "Bob"),
            requestedBy: "workbench",
            db: db
        )
        #expect(result == .refused(.profileNotFound))
    }

    @Test func submitSeedRefusesNoBirthEstimateNoWindow() throws {
        let db = try makeTempDB()
        try insertSubject(birthDate: nil, into: db)
        let result = try HypothesisSeedService.submitSeed(
            profileID: "subj",
            hints: .init(fatherGiven: "Bob"),
            requestedBy: "workbench",
            db: db
        )
        #expect(result == .refused(.noSubjectBirthEstimate))
    }

    @Test func submitSeedRefusesBackwardsWindow() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)
        let result = try HypothesisSeedService.submitSeed(
            profileID: "subj",
            hints: .init(
                fatherGiven: "Bob",
                marriageWindowStart: 1900, marriageWindowEnd: 1850
            ),
            requestedBy: "workbench",
            db: db
        )
        #expect(result == .refused(.invalidWindow))
    }

    @Test func submitSeedRefusesPreviouslyRejectedHunch() throws {
        // §5.15.2 rule 4 / §5.15.6 rejection memory applies at intake.
        let db = try makeTempDB()
        try insertSubject(into: db)
        let hints = HypothesisSeedService.SeedHints(fatherGiven: "Bob", motherGiven: "Sue")
        _ = try HypothesisSeedService.submitSeed(
            profileID: "subj", hints: hints, requestedBy: "workbench", db: db
        )
        let out = HypothesisSeedService.materialiseQueuedSeeds(db: db)
        guard case .materialised(let hid) = out.first?.outcome else {
            Issue.record("setup failed"); return
        }
        try db.rejectHypothesis(id: hid)

        let result = try HypothesisSeedService.submitSeed(
            profileID: "subj", hints: hints, requestedBy: "workbench", db: db
        )
        #expect(result == .refused(.previouslyRejected))
    }

    // MARK: - Straight-to-.contradicted at intake (§5.15.2 last paragraph)

    @Test func intakeMaterialisesContradictedWhenConfirmedParentConflicts() throws {
        // Tree already holds a confirmed father "Thomas"; a hunch that the
        // father was "Bob" conflicts beyond nickname equivalence → the seed
        // is ACCEPTED but materialised straight to .contradicted.
        let db = try makeTempDB()
        try insertSubject(into: db)
        try insertConfirmedFather(named: "Thomas", into: db)

        _ = try HypothesisSeedService.submitSeed(
            profileID: "subj",
            hints: .init(fatherGiven: "Bob"),
            requestedBy: "workbench",
            db: db
        )
        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        guard case .materialised(let hid) = outcomes.first?.outcome else {
            Issue.record("a contradicted hunch is accepted, not refused")
            return
        }
        let h = try #require(try db.loadHypothesis(id: hid))
        #expect(h.verdict == .contradicted)
        #expect(h.origin == .user)
        #expect(h.contradictingEvidence == ["edge:parent:father1"])
        #expect(h.reasoning.contains("Thomas"))
        #expect(h.reasoning.contains("Bob"))
    }

    @Test func intakeStaysInconclusiveWhenParentAgreesViaNickname() throws {
        // Confirmed father "Robert"; hunch "Bob" agrees via nickname
        // equivalence → NOT contradicted at intake.
        let db = try makeTempDB()
        try insertSubject(into: db)
        try insertConfirmedFather(named: "Robert", into: db)

        _ = try HypothesisSeedService.submitSeed(
            profileID: "subj",
            hints: .init(fatherGiven: "Bob"),
            requestedBy: "workbench",
            db: db
        )
        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)
        guard case .materialised(let hid) = outcomes.first?.outcome else {
            Issue.record("expected materialised"); return
        }
        let h = try #require(try db.loadHypothesis(id: hid))
        #expect(h.verdict == .inconclusive, "Bob ≈ Robert must not contradict")
    }

    @Test func intakeContradictionWritesNothingToTree() throws {
        // Even a contradicted hunch is a search directive, never data.
        let db = try makeTempDB()
        try insertSubject(into: db)
        try insertConfirmedFather(named: "Thomas", into: db)

        func counts() throws -> [Int] {
            try db.dbQueue.read { c in
                try [
                    Int.fetchOne(c, sql: "SELECT COUNT(*) FROM profiles") ?? -1,
                    Int.fetchOne(c, sql: "SELECT COUNT(*) FROM relationships") ?? -1,
                    Int.fetchOne(c, sql: "SELECT COUNT(*) FROM life_events") ?? -1,
                    Int.fetchOne(c, sql: "SELECT COUNT(*) FROM pending_facts") ?? -1,
                    Int.fetchOne(c, sql: "SELECT COUNT(*) FROM leads") ?? -1,
                ]
            }
        }
        let before = try counts()
        _ = try HypothesisSeedService.submitSeed(
            profileID: "subj", hints: .init(fatherGiven: "Bob"),
            requestedBy: "workbench", db: db
        )
        HypothesisSeedService.materialiseQueuedSeeds(db: db)
        #expect(try counts() == before)
    }

    // MARK: - UserHypothesisViewModel: submit delegation

    @Test func viewModelSubmitDelegatesToSeamAndReportsQueued() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)
        let model = UserHypothesisViewModel(database: db)

        let result = model.submit(
            profileID: "subj",
            hints: .init(fatherGiven: "Bob", motherGiven: "Sue")
        )
        guard case .queued = result else {
            Issue.record("expected queued from VM, got \(String(describing: result))")
            return
        }
        #expect(try seedRows(profileID: "subj", db: db).count == 1)
        #expect(model.lastSubmitResult == result)
    }

    @Test func viewModelSubmitSurfacesRefusal() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)
        let model = UserHypothesisViewModel(database: db)

        let result = model.submit(profileID: "subj", hints: .init())
        #expect(result == .refused(.noNameHints))
    }

    @Test func viewModelSubmitWithoutDatabaseIsInert() {
        let model = UserHypothesisViewModel(database: nil)
        let result = model.submit(profileID: "subj", hints: .init(fatherGiven: "Bob"))
        #expect(result == nil)
        #expect(model.errorMessage != nil)
    }

    // MARK: - UserHypothesisViewModel: load + verdict surface (§5.15.8)

    @Test func viewModelLoadReturnsUserHunchesOnly() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)
        // Seed + materialise one user hunch.
        _ = try HypothesisSeedService.submitSeed(
            profileID: "subj", hints: .init(fatherGiven: "Bob", motherGiven: "Sue"),
            requestedBy: "workbench", db: db
        )
        HypothesisSeedService.materialiseQueuedSeeds(db: db)
        // Insert an engine-origin hypothesis for the same subject — must
        // NOT appear on the user-hunch surface.
        let engineHyp = ResearchHypothesis(
            id: "engine-1", subjectProfileID: "subj",
            kind: .siblingExists(district: "Belper", mmn: "Smith", yearWindow: 1880...1890),
            origin: .engine, verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "engine", createdAt: Date(), lastTestedAt: Date(),
            attempts: 0, history: []
        )
        try db.upsertHypothesis(engineHyp)

        let model = UserHypothesisViewModel(database: db)
        model.load(profileID: "subj")

        #expect(model.hunches.count == 1)
        #expect(model.hunches.first?.hypothesis.origin == .user)
    }

    @Test func viewModelSortsRefutedToTop() {
        // §5.15.8: contradicted hunches sort to the top.
        let refuted = makeHunch(id: "r", verdict: .contradicted, attempts: 1)
        let supported = makeHunch(id: "s", verdict: .supported, attempts: 2)
        let inconclusive = makeHunch(id: "i", verdict: .inconclusive, attempts: 1)

        let sorted = UserHypothesisViewModel.sortedForSurface(
            [inconclusive, supported, refuted]
        )
        #expect(sorted.map(\.id) == ["r", "s", "i"])
    }

    @Test func statusLabelDistinguishesExhaustedFromInconclusive() {
        // Ladder ceiling for .parentCandidates is 3 → attempts == 3 means
        // the next level exceeds the ceiling → exhausted.
        let stillGoing = makeHunch(id: "a", verdict: .inconclusive, attempts: 1)
        let exhausted = makeHunch(id: "b", verdict: .inconclusive, attempts: 3)

        #expect(stillGoing.statusLabel == "Inconclusive")
        #expect(stillGoing.isExhausted == false)
        #expect(exhausted.statusLabel == "Exhausted")
        #expect(exhausted.isExhausted == true)
    }

    @Test func statusLabelUsesRefutedForContradicted() {
        let refuted = makeHunch(id: "r", verdict: .contradicted, attempts: 1)
        #expect(refuted.statusLabel == "Refuted")
    }

    @Test func viewModelBucketsHunchesByState() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)
        let model = UserHypothesisViewModel(database: db)
        model.hunches = UserHypothesisViewModel.sortedForSurface([
            makeHunch(id: "r", verdict: .contradicted, attempts: 1),
            makeHunch(id: "s", verdict: .supported, attempts: 2),
            makeHunch(id: "x", verdict: .inconclusive, attempts: 3),   // exhausted
            makeHunch(id: "i", verdict: .inconclusive, attempts: 1),   // active
        ])
        #expect(model.refutedHunches.map(\.id) == ["r"])
        #expect(Set(model.activeHunches.map(\.id)) == ["s", "i"])
        #expect(model.exhaustedHunches.map(\.id) == ["x"])
    }

    // MARK: - UserHypothesisViewModel: dismiss (§5.15.8)

    @Test func viewModelDismissFlipsRejectedAndRemovesFromList() throws {
        let db = try makeTempDB()
        try insertSubject(into: db)
        _ = try HypothesisSeedService.submitSeed(
            profileID: "subj", hints: .init(fatherGiven: "Bob", motherGiven: "Sue"),
            requestedBy: "workbench", db: db
        )
        HypothesisSeedService.materialiseQueuedSeeds(db: db)
        let model = UserHypothesisViewModel(database: db)
        model.load(profileID: "subj")
        let hid = try #require(model.hunches.first?.id)

        model.dismiss(hunchID: hid)

        #expect(model.hunches.isEmpty)
        // The row stays in the table, flagged rejected (history retained).
        let rejected = try db.dbQueue.read { c in
            try Int.fetchOne(c, sql: """
                SELECT user_rejected FROM research_hypotheses WHERE id = ?
                """, arguments: [hid])
        }
        #expect(rejected == 1)
        // And a reload no longer surfaces it (loadHypotheses filters rejected).
        model.load(profileID: "subj")
        #expect(model.hunches.isEmpty)
    }

    // MARK: - Helpers

    private func makeHunch(
        id: String,
        verdict: ResearchHypothesis.Verdict,
        attempts: Int
    ) -> UserHypothesisViewModel.Hunch {
        UserHypothesisViewModel.Hunch(hypothesis: ResearchHypothesis(
            id: id, subjectProfileID: "subj",
            kind: .parentCandidates(
                fatherGiven: "Bob", fatherSurname: nil,
                motherGiven: "Sue", motherMaidenSurname: nil,
                marriageWindow: 1857...1888
            ),
            origin: .user, verdict: verdict, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "test", createdAt: Date(),
            lastTestedAt: Date(), attempts: attempts, history: []
        ))
    }
}
