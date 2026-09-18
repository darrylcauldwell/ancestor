import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// SC-consolidation follow-up (review C7). `3356bbb` deleted Triage/
/// ResearchView — the only surfaces that rendered the main vm's
/// `currentResult` — while lead-investigation runs stayed reachable
/// (ProfileLeadsBlock's "Research" button). The SC-3 post-run handoff
/// required `selectedProfile?.id`, which `startResearch(lead:)` deliberately
/// nils, so a completed lead run routed NOWHERE: "Review results" silently
/// closed the progress sheet, the memory-only evidence was destroyed by the
/// next run, and the create-on-accept promote path was unreachable — every
/// volunteer-source query the run spent, wasted.
///
/// The repair routes completed runs through
/// `ResearchViewModel.completedReviewRoute`: profile runs keep the detached
/// record-review window (SC-3), lead runs present the in-window
/// `LeadReviewSheet` over the SAME vm — the only place `selectedLead` and
/// `currentResult` coexist, which Apply → `materialiseLeadSubjectIfNeeded`
/// → `promoteLeadToProfile` requires. These pin the routing seam
/// ContentView consumes; the leadSheet case FAILS on the pre-fix vm (the
/// route did not exist — lead runs fell through the profile-only check).
@MainActor
struct LeadRunReviewRouteTests {

    // MARK: - Fixtures (synthetic; no real family data)

    private func makeLead(relationship: String? = nil) -> Lead {
        Lead(
            id: "lead-1", profileID: "@GEN@", name: "George H Land",
            surname: "LAND", givenName: "GEORGE H", birthYear: 1866,
            deathYear: nil, relationship: relationship, source: .scoredLead,
            status: .investigated, evidence: "Birth Dec 1866 Rotherham",
            createdAt: Date())
    }

    private func makeProfile() -> Profile {
        Profile(id: "@P1@", firstName: "George", lastName: "Land",
                isDeleted: false, sources: [:], disputes: [:])
    }

    // MARK: - The defect

    /// A finished lead run must route to the lead-review sheet — the
    /// pre-consolidation behaviour was to route nowhere and discard the
    /// run's evidence.
    @Test func completedLeadRunRoutesToTheLeadSheet() {
        let vm = ResearchViewModel()
        vm.selectedProfile = nil
        vm.selectedLead = makeLead()
        vm.currentResult = .empty
        vm.isResearching = false

        #expect(vm.completedReviewRoute == .leadSheet)
    }

    /// A record-candidate lead (no kin claim) is the only lead kind whose
    /// sole offered action is "Research" — the exact case that dead-ended.
    @Test func recordCandidateLeadOffersOnlyResearch() {
        let lead = makeLead(relationship: nil)
        #expect(CampaignReviewService.addAction(for: lead) == nil)
    }

    // MARK: - Guard rails around the repair

    /// SC-3 unchanged: profile runs keep the detached-window handoff, and
    /// the profile branch wins outright (subject identity is mutually
    /// exclusive by `startResearch`, but a stale lead must never hijack a
    /// profile run's review).
    @Test func completedProfileRunRoutesToTheDetachedWindow() {
        let vm = ResearchViewModel()
        vm.selectedProfile = makeProfile()
        vm.selectedLead = makeLead()
        vm.currentResult = .empty
        vm.isResearching = false

        #expect(vm.completedReviewRoute == .profileWindow(profileID: "@P1@"))
    }

    /// No result — run still going, or it produced nothing — routes nowhere:
    /// the progress sheet's Done just closes, matching the profile path.
    @Test func runInFlightOrWithoutResultRoutesNowhere() {
        let vm = ResearchViewModel()
        vm.selectedLead = makeLead()

        vm.currentResult = nil
        vm.isResearching = false
        #expect(vm.completedReviewRoute == ResearchViewModel.ReviewRoute.none)

        vm.currentResult = .empty
        vm.isResearching = true
        #expect(vm.completedReviewRoute == ResearchViewModel.ReviewRoute.none)
    }

    /// `reset()` (fired when the review sheet closes) ends the session: the
    /// route decays to `.none`, so a later presentation pass can't act on a
    /// stale lead identity.
    @Test func resetClearsTheRoute() {
        let vm = ResearchViewModel()
        vm.selectedLead = makeLead()
        vm.currentResult = .empty
        #expect(vm.completedReviewRoute == .leadSheet)

        vm.reset()

        #expect(vm.completedReviewRoute == ResearchViewModel.ReviewRoute.none)
        #expect(vm.selectedLead == nil)
        #expect(vm.currentResult == nil)
    }
}
