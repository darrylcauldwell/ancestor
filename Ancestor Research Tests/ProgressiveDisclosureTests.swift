import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the progressive-disclosure helpers on `AppState` (DESIGN.md §7.16).
///
/// We inject state directly rather than going through `openProject` — these
/// are unit tests of pure computed properties that don't need a real DB.
@MainActor
struct ProgressiveDisclosureTests {

    // MARK: - Helpers

    /// Build a stub `Profile` with only the fields we care about for these
    /// tests — sources can be customised to exercise the citation gate.
    private func makeProfile(
        id: String,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: "Person",
            lastName: id,
            gender: .unknown,
            attributes: nil,
            birthDate: nil,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: sources,
            disputes: [:]
        )
    }

    private func makeProject(source: DataSource = .manual) -> Project {
        Project(
            id: UUID(),
            name: "Test",
            source: source,
            homePersonID: nil,
            createdAt: Date(),
            lastRefreshed: nil
        )
    }

    private func makeSnapshot(profileCount: Int) -> FamilyGraphSnapshot {
        let profiles = (0..<profileCount).map { makeProfile(id: "p\($0)") }
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    private func makeAppState(
        source: DataSource = .manual,
        profileCount: Int = 0,
        snapshot: FamilyGraphSnapshot? = nil
    ) -> AppState {
        let state = AppState()
        state.currentProject = makeProject(source: source)
        state.snapshot = snapshot ?? makeSnapshot(profileCount: profileCount)
        return state
    }

    // MARK: - Tasks tab visibility

    @Test func tasksTabHiddenForSmallManualProjects() {
        let state = makeAppState(source: .manual, profileCount: 3)
        #expect(state.tasksTabVisible == false)
    }

    @Test func tasksTabVisibleForLargeManualProjects() {
        let state = makeAppState(source: .manual, profileCount: 5)
        #expect(state.tasksTabVisible == true)
    }

    @Test func tasksTabVisibleForGEDCOMProjects() {
        // Even with zero profiles, a GEDCOM-source project shows Tasks
        // because import-driven projects can have audit/gap content immediately.
        let state = makeAppState(source: .gedcom(path: "/tmp/test.ged"), profileCount: 0)
        #expect(state.tasksTabVisible == true)
    }

    // MARK: - Sourcing tab visibility

    @Test func sourcingTabHiddenWhenNoCitations() {
        // A populated tree without any citations should still hide Sourcing.
        let state = makeAppState(source: .manual, profileCount: 5)
        #expect(state.sourcingTabVisible == false)
    }

    @Test func sourcingTabVisibleWhenAnyCitationExists() {
        // Build one profile carrying a FieldSource with a non-nil citation.
        let citation = Citation(
            repository: nil, collection: "FreeBMD", title: nil,
            page: nil, url: nil, dateAccessed: nil, notes: nil
        )
        let cited = FieldSource(
            origin: .manualMemory,
            raw: "John",
            addedAt: Date(),
            citation: citation
        )
        let profile = makeProfile(id: "p0", sources: [.firstName: [cited]])
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let state = makeAppState(source: .manual, snapshot: snapshot)
        #expect(state.sourcingTabVisible == true)
    }

    // MARK: - Small manual project flag

    @Test func isSmallManualProjectFlipsAtThreshold() {
        let small = makeAppState(source: .manual, profileCount: 4)
        #expect(small.isSmallManualProject == true)

        let large = makeAppState(source: .manual, profileCount: 5)
        #expect(large.isSmallManualProject == false)
    }
}
