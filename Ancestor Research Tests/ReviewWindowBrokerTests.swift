import Testing
import Foundation
@testable import Ancestor_Research

/// ReviewWindowBroker — the app-level bridge that lets the detached Record
/// Review window borrow the main window's AppState and receive the live
/// ResearchResult at pop-out.
@MainActor
struct ReviewWindowBrokerTests {

    private func emptyResult() -> ResearchResult {
        ResearchResult(
            confirmedFacts: [], leads: [], allScoredRecords: [], clusters: [],
            discrepancies: [], householdMembers: [], searchHistory: [])
    }

    /// Handoff is take-once: the second take returns nil, so a stale result
    /// can never be re-served to a later window for the same person.
    @Test func handoffIsTakeOnce() {
        let broker = ReviewWindowBroker()
        broker.stageHandoff(profileID: "p1", result: emptyResult())
        #expect(broker.takeHandoff(profileID: "p1") != nil)
        #expect(broker.takeHandoff(profileID: "p1") == nil)
    }

    @Test func takeForUnknownProfileIsNil() {
        let broker = ReviewWindowBroker()
        #expect(broker.takeHandoff(profileID: "nobody") == nil)
    }

    /// Handoffs are keyed per profile — staging one person never affects
    /// another's.
    @Test func handoffsAreKeyedPerProfile() {
        let broker = ReviewWindowBroker()
        broker.stageHandoff(profileID: "p1", result: emptyResult())
        #expect(broker.takeHandoff(profileID: "p2") == nil)
        #expect(broker.takeHandoff(profileID: "p1") != nil)
    }

    /// Every stage bumps the per-profile generation — the review window keys
    /// its hydration on this, so re-popping an already-open person re-fires
    /// hydration and consumes the FRESH handoff instead of showing the stale
    /// review (macOS focuses the existing window for the same value).
    @Test func stagingBumpsGeneration() {
        let broker = ReviewWindowBroker()
        #expect(broker.generation(for: "p1") == 0)
        broker.stageHandoff(profileID: "p1", result: emptyResult())
        #expect(broker.generation(for: "p1") == 1)
        broker.stageHandoff(profileID: "p1", result: emptyResult())
        #expect(broker.generation(for: "p1") == 2)
        #expect(broker.generation(for: "p2") == 0, "generations are per-profile")
        // Taking the handoff does NOT reset the generation — it's a stamp,
        // not a queue depth.
        _ = broker.takeHandoff(profileID: "p1")
        #expect(broker.generation(for: "p1") == 2)
    }

    /// Re-staging replaces the pending handoff (last writer wins) — the
    /// window must never consume an older result after a newer pop-out.
    @Test func restagingReplacesPendingHandoff() {
        let broker = ReviewWindowBroker()
        broker.stageHandoff(profileID: "p1", result: emptyResult())
        broker.stageHandoff(profileID: "p1", result: emptyResult())
        #expect(broker.takeHandoff(profileID: "p1") != nil)
        #expect(broker.takeHandoff(profileID: "p1") == nil, "only ONE (the latest) is pending")
    }

    /// The AppState reference is weak — closing the main window (deallocating
    /// its AppState) must not be prevented by the broker, and the review
    /// window sees nil rather than a zombie.
    @Test func appStateReferenceIsWeak() {
        let broker = ReviewWindowBroker()
        var appState: AppState? = AppState()
        broker.activeAppState = appState
        #expect(broker.activeAppState != nil)
        appState = nil
        #expect(broker.activeAppState == nil)
    }
}
