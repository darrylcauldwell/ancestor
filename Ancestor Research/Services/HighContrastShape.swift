import Foundation

/// M24 — Pure helpers for high-contrast / colorblind accessibility.
///
/// Every state currently encoded only in colour (red/orange/green/blue/
/// purple/yellow) must also be readable in monochrome. These helpers
/// provide the *non-colour* signal alongside the existing colour: a glyph
/// name, a line-weight, or `nil` to indicate the default rendering is
/// already non-colour-only (e.g., audit severity icons).
///
/// SwiftUI views read `\.accessibilityDifferentiateWithoutColor` from the
/// environment and pass it in to decide whether to swap in a glyph. Where
/// the existing rendering is already glyph-bearing (audit severity icons,
/// the tentative tilde, the well-evidenced seal), the helper returns
/// `nil` and the view stays unchanged.
///
/// Pure / `nonisolated` so unit tests can exercise it without a MainActor
/// dance.
nonisolated enum HighContrastShape {

    /// State kinds that the app currently encodes with a colour-only signal.
    /// Listed here so the helper can map each one to its glyph alternative
    /// in one place.
    enum StateKind {
        /// A per-source confidence dot — currently a small orange dot.
        case sourceConfidenceTentative
        /// A per-source confidence dot — currently a small green dot.
        case sourceConfidenceWellEvidenced
    }

    /// SF Symbol name to render *in place of* the colour-only signal when
    /// the user has `accessibilityDifferentiateWithoutColor` enabled.
    /// Returns `nil` when the default rendering is already non-colour
    /// (e.g., severity icons that always carry a glyph).
    static func differentiator(
        for state: StateKind,
        differentiateWithoutColor: Bool
    ) -> String? {
        guard differentiateWithoutColor else { return nil }
        switch state {
        case .sourceConfidenceTentative: return "questionmark.circle.fill"
        case .sourceConfidenceWellEvidenced: return "checkmark.circle.fill"
        }
    }

    /// Map a 0…1 completeness ratio to a tree-node border line weight.
    /// Incomplete profiles get a thicker ring so the gradient (red → green)
    /// is no longer the only signal of "this profile needs work."
    ///
    /// - Default-contrast users see the existing red→green gradient AND a
    ///   subtly thicker border on incomplete profiles.
    /// - Colourblind / high-contrast users get the line-weight cue alone
    ///   and can still tell a complete profile from an incomplete one.
    ///
    /// 3.0pt at ratio 0 (totally empty) tapering down to 1.0pt at ratio 1
    /// (complete). The mapping is linear and clamps outside [0, 1].
    static func completenessRingWeight(ratio: Double) -> Double {
        let clamped = max(0, min(1, ratio))
        let maxWeight = 3.0
        let minWeight = 1.0
        return maxWeight - (maxWeight - minWeight) * clamped
    }
}
