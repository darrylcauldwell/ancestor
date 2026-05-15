import Testing
import Foundation
@testable import Ancestor_Research

/// Regression for the spinner-then-green-tick oscillation users saw during
/// research — every individual `sourceQueryCompleted` event was flipping
/// the source-status card to `.complete`, even when subsequent queries
/// for the same source were still in flight. The fix: track in-flight
/// query count per source and only flip to `.complete` when it hits zero.
@MainActor
struct SourceStateOscillationTests {

    @Test func spinnerStaysWhileQueriesAreStillInFlight() async {
        let vm = ResearchViewModel()
        vm.sourceStatuses = [makeStatus(id: "freebmd")]

        // Three queries start in parallel — FreeBMD fans out across 3 districts.
        vm.applyActivityEvent(.sourceQueryStarted(sourceID: "freebmd", summary: "Belper"))
        vm.applyActivityEvent(.sourceQueryStarted(sourceID: "freebmd", summary: "Bakewell"))
        vm.applyActivityEvent(.sourceQueryStarted(sourceID: "freebmd", summary: "Derby"))

        // First two complete — but the third is still running.
        vm.applyActivityEvent(.sourceQueryCompleted(sourceID: "freebmd", summary: "Belper", resultCount: 2))
        vm.applyActivityEvent(.sourceQueryCompleted(sourceID: "freebmd", summary: "Bakewell", resultCount: 1))

        #expect(vm.sourceStatuses[0].state == .searching,
                "Spinner must stay while any query is still in flight; got \(vm.sourceStatuses[0].state)")
        #expect(vm.sourceStatuses[0].resultCount == 3,
                "Result count should accumulate across completed queries")
    }

    @Test func greenTickAppearsOnlyAfterLastQueryCompletes() async {
        let vm = ResearchViewModel()
        vm.sourceStatuses = [makeStatus(id: "freebmd")]

        vm.applyActivityEvent(.sourceQueryStarted(sourceID: "freebmd", summary: "Belper"))
        vm.applyActivityEvent(.sourceQueryStarted(sourceID: "freebmd", summary: "Bakewell"))
        vm.applyActivityEvent(.sourceQueryCompleted(sourceID: "freebmd", summary: "Belper", resultCount: 2))
        // Still searching after first completion.
        #expect(vm.sourceStatuses[0].state == .searching)
        vm.applyActivityEvent(.sourceQueryCompleted(sourceID: "freebmd", summary: "Bakewell", resultCount: 0))
        // Now done.
        #expect(vm.sourceStatuses[0].state == .complete)
        #expect(vm.sourceStatuses[0].resultCount == 2)
    }

    @Test func errorIsStickyEvenWithSubsequentSuccesses() async {
        let vm = ResearchViewModel()
        vm.sourceStatuses = [makeStatus(id: "cwgc")]

        vm.applyActivityEvent(.sourceQueryStarted(sourceID: "cwgc", summary: "WWI"))
        vm.applyActivityEvent(.sourceQueryStarted(sourceID: "cwgc", summary: "WWII"))
        vm.applyActivityEvent(.sourceError(sourceID: "cwgc", summary: "WWI", reason: "HTTP 500"))
        // First completed as an error; second still in flight.
        #expect(vm.sourceStatuses[0].state == .error)
        vm.applyActivityEvent(.sourceQueryCompleted(sourceID: "cwgc", summary: "WWII", resultCount: 1))
        // Error is sticky — even though the last query succeeded, the card
        // stays on .error so the user sees that something went wrong.
        #expect(vm.sourceStatuses[0].state == .error)
    }

    // MARK: - Helpers

    private func makeStatus(id: String) -> ResearchViewModel.SourceStatus {
        ResearchViewModel.SourceStatus(
            id: id,
            displayName: id.uppercased(),
            state: .pending,
            resultCount: 0,
            reason: nil
        )
    }
}
