import SwiftUI

// SC-9 — extracted from BulkReviewView.swift when the Triage tab retired:
// the friction routing is a tested policy seam (GPSConflictReportingTests),
// not view code, and per-profile surfaces may reuse it for row severity.

/// Review friction per §20.6 — how much user effort is needed to process a finding.
/// Higher friction = more attention required. Sorted highest-first in bulk review.
nonisolated enum ReviewFriction: Int, CaseIterable, Sendable {
    case autoStage = 0          // Refinements — applied with undo, user glances
    case batchReview = 1        // Confirmations — "Accept all N" button
    case individualReview = 2   // Corrections — old→new comparison per item
    case mustResolve = 3        // Conflicts — cannot commit until resolved
    case newFinding = 4         // Discoveries — novel information for user attention
}

nonisolated enum FrictionTier: String, CaseIterable, Sendable {

    /// CL3 (DS-14) — pure routing, extracted so the .conflict tier's
    /// reachability is testable. Conflict wins over everything; the rest
    /// preserves the pre-CL3 mapping.
    static func route(
        hasImpossible: Bool, hasFacts: Bool,
        recordCount: Int, hasConflictSignal: Bool
    ) -> FrictionTier {
        if hasImpossible || hasConflictSignal { return .conflict }
        if !hasFacts { return .correction }
        if recordCount <= 1 { return .confirmation }
        return .refinement
    }

    case conflict = "Conflict"
    case correction = "Correction"
    case confirmation = "Confirmation"
    case refinement = "Refinement"

    var sortOrder: Int {
        switch self {
        case .conflict: 0
        case .correction: 1
        case .confirmation: 2
        case .refinement: 3
        }
    }

    var color: Color {
        switch self {
        case .conflict: .red
        case .correction: .orange
        case .confirmation: .blue
        case .refinement: .green
        }
    }

    /// Map to the spec's ReviewFriction level.
    var reviewFriction: ReviewFriction {
        switch self {
        case .conflict: .mustResolve
        case .correction: .individualReview
        case .confirmation: .batchReview
        case .refinement: .autoStage
        }
    }
}
