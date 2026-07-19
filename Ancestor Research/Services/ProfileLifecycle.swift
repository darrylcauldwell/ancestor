import Foundation

/// PROFILE_LIFECYCLE_SPEC Change 3 — a person's stage on the journey from raw
/// GEDCOM import to a verified, evidence-backed profile. Always DERIVED from
/// data already present (never stored, so it can't go stale), and paired with a
/// plain-language next step so the app guides rather than leaves the user to
/// infer state from scattered counts and green ticks.
nonisolated enum ProfileLifecycleStage: String, Sendable {
    case imported      // GEDCOM only — no research yet
    case researching   // research has run; findings await review
    case evidenced     // ≥1 research record applied to the profile
    case verified      // evidence applied AND GPS-strong AND nothing pending
}

nonisolated struct ProfileLifecycle: Sendable, Equatable {
    let stage: ProfileLifecycleStage
    /// Short status line ("Imported — not yet researched", "3 to review").
    let headline: String
    /// The obvious next action's label, or nil when the person is in a done
    /// (verified) state. The host maps this to a button.
    let nextStep: String?

    /// Derive the stage from signals the profile view already holds. Pure so it
    /// is unit-tested without the app. `gpsStrong` is optional context: when the
    /// caller can't compute GPS yet it passes false and "verified" is simply
    /// never reached (the person rests at "evidenced") — honest, never wrong.
    static func evaluate(
        hasResearchEvidence: Bool,
        pendingReview: Int,
        appliedRecords: Int,
        gpsStrong: Bool
    ) -> ProfileLifecycle {
        // Imported: nothing researched, nothing applied.
        if !hasResearchEvidence && appliedRecords == 0 {
            return .init(stage: .imported,
                         headline: "Imported — not yet researched",
                         nextStep: "Research")
        }
        // Verified: evidence on the profile, GPS strong, nothing left to review.
        if appliedRecords > 0 && gpsStrong && pendingReview == 0 {
            return .init(stage: .verified,
                         headline: "Verified — evidence cross-referenced",
                         nextStep: nil)
        }
        // Evidenced: at least one record applied; guide toward review/more research.
        if appliedRecords > 0 {
            let recs = "\(appliedRecords) record\(appliedRecords == 1 ? "" : "s") applied"
            return .init(stage: .evidenced,
                         headline: pendingReview > 0 ? "\(recs) · \(pendingReview) to review" : recs,
                         nextStep: pendingReview > 0 ? "Review" : "Research")
        }
        // Researching: research ran but nothing applied yet.
        return .init(stage: .researching,
                     headline: pendingReview > 0 ? "\(pendingReview) to review" : "Researched — review the findings",
                     nextStep: "Review")
    }
}
