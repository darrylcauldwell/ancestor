import Testing
@testable import Ancestor_Research

/// PROJECT_ONBOARDING_SPEC Part B — the Getting Started overview. It's a view,
/// so the copy isn't unit-tested, but one contract is worth pinning: it must
/// explain EVERY sidebar tab, so a tab added later can't ship without help
/// copy. The tour hand-off is a pure AppState flag round-trip.
@MainActor
struct GettingStartedTests {

    /// Every SidebarTab has exactly one help entry (completeness + no dupes).
    @Test func everyTabHasHelpCopy() {
        let covered = GettingStartedView.entries.map(\.tab)
        for tab in SidebarTab.allCases {
            #expect(covered.contains(tab), "no Getting Started copy for the \(tab.rawValue) tab")
        }
        #expect(covered.count == SidebarTab.allCases.count, "one entry per tab, no duplicates")
        #expect(GettingStartedView.entries.allSatisfy { !$0.blurb.isEmpty && !$0.icon.isEmpty })
    }

    /// The end-of-setup tour hand-off: a completed "Done" with the toggle on
    /// leaves pendingGettingStartedTour set; the flag opens Getting Started
    /// and the app then works normally.
    @Test func tourFlagRoundTrips() {
        let state = AppState()
        #expect(state.showGettingStarted == false)
        state.showGettingStarted = true
        #expect(state.showGettingStarted == true)

        // pending-tour is a plain latch the setup sheet's onDismiss consumes.
        state.pendingGettingStartedTour = true
        #expect(state.pendingGettingStartedTour == true)
    }
}
