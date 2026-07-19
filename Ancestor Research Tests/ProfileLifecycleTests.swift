import Testing
@testable import Ancestor_Research

/// PROFILE_LIFECYCLE_SPEC Change 3 — the derived stage function.
struct ProfileLifecycleTests {

    @Test func gedcomOnlyProfileIsImported() {
        let l = ProfileLifecycle.evaluate(
            hasResearchEvidence: false, pendingReview: 0, appliedRecords: 0, gpsStrong: false)
        #expect(l.stage == .imported)
        #expect(l.nextStep == "Research")
    }

    @Test func researchedButNothingAppliedIsResearching() {
        let l = ProfileLifecycle.evaluate(
            hasResearchEvidence: true, pendingReview: 6, appliedRecords: 0, gpsStrong: false)
        #expect(l.stage == .researching)
        #expect(l.headline.contains("6 to review"))
        #expect(l.nextStep == "Review")
    }

    @Test func appliedRecordsIsEvidenced() {
        let l = ProfileLifecycle.evaluate(
            hasResearchEvidence: true, pendingReview: 1, appliedRecords: 3, gpsStrong: false)
        #expect(l.stage == .evidenced)
        #expect(l.headline.contains("3 records applied"))
        #expect(l.nextStep == "Review")
    }

    @Test func appliedAndStrongAndClearIsVerified() {
        let l = ProfileLifecycle.evaluate(
            hasResearchEvidence: true, pendingReview: 0, appliedRecords: 3, gpsStrong: true)
        #expect(l.stage == .verified)
        #expect(l.nextStep == nil)   // done state — no nagging next step
    }

    @Test func strongButStillPendingIsNotVerified() {
        // GPS strong but review outstanding → still evidenced, not verified.
        let l = ProfileLifecycle.evaluate(
            hasResearchEvidence: true, pendingReview: 2, appliedRecords: 3, gpsStrong: true)
        #expect(l.stage == .evidenced)
    }
}
