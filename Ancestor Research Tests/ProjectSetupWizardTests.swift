import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// PROJECT_ONBOARDING_SPEC Part A (Slice 1) — the project setup wizard's
/// lifecycle and Step 1 (home region). The wizard VIEW isn't unit-tested (per
/// project convention), but the load-bearing logic is: the once-per-project
/// marker, the offer-gating that avoids sheet collisions, and that Step 1's
/// home-region write reaches the anchor the research dispatcher reads.
@MainActor
struct ProjectSetupWizardTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeState() throws -> (AppState, ProjectDatabase, Project) {
        let db = try makeDB()
        let project = Project(id: UUID(), name: "T", source: .manual, createdAt: Date())
        try db.saveProjectMeta(project)   // creates the single project_meta row
        let state = AppState()
        state.currentDatabase = db
        state.currentProject = project
        return (state, db, project)
    }

    // MARK: - The once-per-project marker

    @Test func setupMarkerRoundTrips() throws {
        let db = try makeDB()
        try db.saveProjectMeta(Project(id: UUID(), name: "T", source: .manual, createdAt: Date()))
        #expect(try db.isSetupComplete() == false, "a fresh project has not completed setup")
        try db.markSetupComplete(at: Date())
        #expect(try db.isSetupComplete() == true)
    }

    /// The marker must survive a full-row saveProjectMeta (which does NOT write
    /// the setup_completed_at column) — the discipline that keeps a later
    /// home-region save from resetting it.
    @Test func setupMarkerSurvivesSaveProjectMeta() throws {
        let db = try makeDB()
        var project = Project(id: UUID(), name: "T", source: .manual, createdAt: Date())
        try db.saveProjectMeta(project)
        try db.markSetupComplete(at: Date())

        project.homeChapmanCode = "DBY"
        try db.saveProjectMeta(project)   // full-row rewrite

        #expect(try db.isSetupComplete() == true, "marker preserved across a full save")
        #expect(try db.loadProjectMeta()?.homeChapmanCode == "DBY")
    }

    // MARK: - offerSetupIfNeeded gating

    @Test func offerFiresWhenIncomplete() throws {
        let (state, _, _) = try makeState()
        state.offerSetupIfNeeded()
        #expect(state.showSetupWizard == true)
    }

    @Test func offerNoOpWhenComplete() throws {
        let (state, db, _) = try makeState()
        try db.markSetupComplete(at: Date())
        state.offerSetupIfNeeded()
        #expect(state.showSetupWizard == false, "a completed project is never re-offered")
    }

    @Test func offerNoOpWhileFamilyWizardUp() throws {
        let (state, _, _) = try makeState()
        state.showOnboardingWizard = true
        state.offerSetupIfNeeded()
        #expect(state.showSetupWizard == false, "must not collide with the family wizard")
    }

    @Test func offerNoOpWhileCleanseReviewUp() throws {
        let (state, _, _) = try makeState()
        state.importCleanseReview = ImportCleanseReview(candidates: [], phantomSpouseCandidates: [])
        state.offerSetupIfNeeded()
        #expect(state.showSetupWizard == false, "must not collide with the import cleanse review")
    }

    // MARK: - finish / re-run

    @Test func finishMarksCompleteAndCloses() throws {
        let (state, db, _) = try makeState()
        state.showSetupWizard = true
        state.finishSetup()
        #expect(state.showSetupWizard == false)
        #expect(try db.isSetupComplete() == true)
        // And a subsequent auto-offer stays closed.
        state.offerSetupIfNeeded()
        #expect(state.showSetupWizard == false)
    }

    @Test func rerunOpensRegardlessOfMarker() throws {
        let (state, db, _) = try makeState()
        try db.markSetupComplete(at: Date())
        state.rerunSetup()
        #expect(state.showSetupWizard == true, "explicit re-run ignores the completed marker")
    }

    // MARK: - Step 1: home region

    /// A.4 acceptance: setting the home region reaches resolvedHomeChapmanCode
    /// — the exact anchor every dispatch call-site reads
    /// ((try db.loadProjectMeta())?.resolvedHomeChapmanCode).
    @Test func homeRegionPersistsAndResolves() throws {
        let (state, db, _) = try makeState()
        state.setHomeChapmanCode("DBY")

        #expect(state.currentProject?.homeChapmanCode == "DBY")
        #expect(state.currentProject?.resolvedHomeChapmanCode == "DBY")
        // Reloaded from disk — the value the dispatcher reads at run time.
        #expect(try db.loadProjectMeta()?.resolvedHomeChapmanCode == "DBY")
    }

    @Test func homeRegionEmptyClearsAnchor() throws {
        let (state, db, _) = try makeState()
        state.setHomeChapmanCode("YKS")
        #expect(state.currentProject?.homeChapmanCode == "YKS")

        state.setHomeChapmanCode("")
        #expect(state.currentProject?.homeChapmanCode == nil, "empty picks the derive-per-profile default")
        #expect(try db.loadProjectMeta()?.resolvedHomeChapmanCode == "", "no anchor")
    }

    // MARK: - Step 3: home person (and the field-preservation fix)

    /// The wizard sets home region (Step 1) THEN home person (Step 3).
    /// setHomePerson must NOT wipe the region — it previously rebuilt Project
    /// via a partial memberwise init that dropped homeChapmanCode. This is the
    /// same latent bug the "Set as Home Person" context actions hit.
    @Test func setHomePersonPreservesHomeRegion() throws {
        let (state, db, _) = try makeState()
        state.setHomeChapmanCode("DBY")
        state.setHomePerson(id: "@P1@")

        #expect(state.currentProject?.homePersonID == "@P1@")
        #expect(state.currentProject?.homeChapmanCode == "DBY", "region survives setting the home person")
        // And on disk — the value the dispatcher reads.
        let reloaded = try db.loadProjectMeta()
        #expect(reloaded?.homePersonID == "@P1@")
        #expect(reloaded?.resolvedHomeChapmanCode == "DBY")
    }

    /// The reverse order is also safe — set person first, then region.
    @Test func setHomeRegionPreservesHomePerson() throws {
        let (state, db, _) = try makeState()
        state.setHomePerson(id: "@P1@")
        state.setHomeChapmanCode("YKS")

        #expect(try db.loadProjectMeta()?.homePersonID == "@P1@", "person survives setting the region")
        #expect(try db.loadProjectMeta()?.resolvedHomeChapmanCode == "YKS")
    }
}
