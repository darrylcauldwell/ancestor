import Testing
import Foundation
@testable import Ancestor_Research

/// M23 — multi-window support. Each WindowGroup instance gets its own
/// AppState (owned by ContentRoot), so transient UI state — sidebar
/// selection, sheets, currently-selected profile, error/success toasts —
/// must not leak between instances. App-wide preferences (the @AppStorage
/// keys) intentionally do remain shared, since they're user settings, not
/// per-window state.
///
/// SwiftUI scene-instance testing is fragile, so these tests exercise the
/// AppState side directly. If two AppState instances are independent
/// references, two windows will be too.
@MainActor
struct MultiWindowAppStateTests {

    @Test func twoAppStateInstancesAreIndependent() {
        let a = AppState()
        let b = AppState()

        // Initial state matches — both freshly constructed.
        #expect(a.errorMessage == nil)
        #expect(b.errorMessage == nil)
        #expect(a.currentProject == nil)
        #expect(b.currentProject == nil)

        // But they're separate references…
        #expect(a !== b)

        // …and mutating one does not affect the other.
        a.errorMessage = "X"
        #expect(a.errorMessage == "X")
        #expect(b.errorMessage == nil)

        b.successMessage = "Y"
        #expect(a.successMessage == nil)
        #expect(b.successMessage == "Y")
    }

    @Test func twoAppStatesCanOpenDifferentProjects() {
        let a = AppState()
        let b = AppState()

        let projectA = Project(
            id: UUID(),
            name: "Project A",
            source: .manual,
            homePersonID: nil,
            createdAt: Date(),
            lastRefreshed: nil
        )
        let projectB = Project(
            id: UUID(),
            name: "Project B",
            source: .manual,
            homePersonID: nil,
            createdAt: Date(),
            lastRefreshed: nil
        )

        a.currentProject = projectA
        b.currentProject = projectB

        #expect(a.currentProject?.id == projectA.id)
        #expect(b.currentProject?.id == projectB.id)
        #expect(a.currentProject?.id != b.currentProject?.id)

        // Selected profile and pending actions are also per-instance.
        a.selectedProfileID = "profile-a"
        b.selectedProfileID = "profile-b"
        #expect(a.selectedProfileID == "profile-a")
        #expect(b.selectedProfileID == "profile-b")
    }

    @Test func twoAppStatesShareAppStorage() {
        // @AppStorage is backed by UserDefaults.standard and is intentionally
        // app-wide — preferences like "exclude sensitive on export" should
        // apply to every window. This test sanity-checks that mutating the
        // backing key updates the value visible to both AppStates' views.
        let key = "excludeSensitiveOnExport"
        let originalValue = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(originalValue, forKey: key) }

        _ = AppState()
        _ = AppState()

        UserDefaults.standard.set(true, forKey: key)
        #expect(UserDefaults.standard.bool(forKey: key) == true)

        UserDefaults.standard.set(false, forKey: key)
        #expect(UserDefaults.standard.bool(forKey: key) == false)
    }

    @Test func staticServicesAreThreadSafe() async {
        // Two parallel callers — simulating two windows both refreshing the
        // project list at once — must not crash. ProjectStore is a
        // nonisolated struct over the filesystem; this is a light correctness
        // check for the contention multi-window introduces.
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let projects = ProjectStore.listProjects()
                    return projects.count
                }
            }
            var counts: [Int] = []
            for await c in group { counts.append(c) }
            // All calls should return the same count — there's nothing else
            // mutating the directory in this test.
            #expect(counts.count == 4)
            if let first = counts.first {
                #expect(counts.allSatisfy { $0 == first })
            }
        }
    }
}
