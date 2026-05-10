import Testing
import Foundation
@testable import Ancestor_Research

/// M24 — pure tests for the high-contrast / colourblind accessibility pass.
///
/// Every state currently encoded only in colour has to also be readable in
/// monochrome. These tests cover the helpers that drive the non-colour
/// signals — glyph swap (sourcing dots), line-weight mapping (tree
/// completeness ring), and severity icon distinctness (audit list).
///
/// SwiftUI environment-driven rendering is fragile to test directly, so the
/// suite stays at the helper level. Where a glyph is already present in the
/// default rendering (severity icons, the `~` tentative tilde, the
/// well-evidenced seal) the helper path simply confirms each glyph is
/// distinct from its peers.
struct HighContrastTests {

    // MARK: - Audit severity icons

    /// Severity icons are the only signal a colourblind user has when
    /// scanning the audit list — the colour is incidental. Verify each
    /// severity owns a distinct SF Symbol so monochrome rendering still
    /// reads.
    @Test func auditSeverityIconsAreDistinct() {
        let error = Severity.error.iconName
        let warning = Severity.warning.iconName
        let info = Severity.info.iconName

        #expect(error != warning)
        #expect(warning != info)
        #expect(error != info)

        // Defensive — none should be empty / missing.
        #expect(!error.isEmpty)
        #expect(!warning.isEmpty)
        #expect(!info.isEmpty)
    }

    // MARK: - Tentative-fact non-colour signal

    /// Tentative facts already render with two non-colour signals: a dashed
    /// underline pattern in the inspector and a `~` tilde on the tree node.
    /// This test confirms the upstream `effectiveConfidence` predicate
    /// returns `.tentative` for a tentative-only source list — the same
    /// signal that drives both the colour AND the dashed/glyph rendering.
    @Test func tentativeRenderingHasNonColorSignal() {
        let now = Date()
        let tentativeSource = FieldSource(
            origin: .manual,
            raw: "raw",
            addedAt: now,
            confidence: .tentative
        )
        let standardSource = FieldSource(
            origin: .manual,
            raw: "raw2",
            addedAt: now,
            confidence: .standard
        )

        // Tentative-only — drives both colour AND non-colour signals.
        #expect(effectiveConfidence([tentativeSource]) == .tentative)

        // Mixed — standard wins, no tentative signal needed.
        #expect(effectiveConfidence([tentativeSource, standardSource]) != .tentative)
    }

    // MARK: - Completeness ring weight

    /// Tree node completeness must be readable without colour. The border
    /// line weight maps from completeness ratio: thicker for incomplete,
    /// thinner for complete. Verify the mapping is monotonic and clamped.
    @Test func completenessRingWeightDecreasesWithRatio() {
        let empty = HighContrastShape.completenessRingWeight(ratio: 0.0)
        let half = HighContrastShape.completenessRingWeight(ratio: 0.5)
        let full = HighContrastShape.completenessRingWeight(ratio: 1.0)

        // Strict ordering — thicker for incomplete, thinner for complete.
        #expect(empty > half)
        #expect(half > full)

        // Bounds — a complete profile should land at the thin end (1.0pt)
        // and an empty profile at the thick end (3.0pt).
        #expect(full == 1.0)
        #expect(empty == 3.0)

        // Out-of-range ratios clamp instead of producing wild line weights.
        #expect(HighContrastShape.completenessRingWeight(ratio: -0.5) == 3.0)
        #expect(HighContrastShape.completenessRingWeight(ratio: 1.5) == 1.0)
    }

    // MARK: - Glyph differentiator gate

    /// Sanity — when the user hasn't enabled Differentiate Without Colour,
    /// the helper returns `nil` and the view keeps its default (colour-only)
    /// rendering. The flag has to be the one and only switch that swaps in
    /// the glyph.
    @Test func colorDifferentiatorIsNilWhenAccessibilityFlagOff() {
        #expect(
            HighContrastShape.differentiator(
                for: .sourceConfidenceTentative,
                differentiateWithoutColor: false
            ) == nil
        )
        #expect(
            HighContrastShape.differentiator(
                for: .sourceConfidenceWellEvidenced,
                differentiateWithoutColor: false
            ) == nil
        )

        // And — flag on returns a non-nil, distinct glyph for each state.
        let tentative = HighContrastShape.differentiator(
            for: .sourceConfidenceTentative,
            differentiateWithoutColor: true
        )
        let wellEvidenced = HighContrastShape.differentiator(
            for: .sourceConfidenceWellEvidenced,
            differentiateWithoutColor: true
        )
        #expect(tentative != nil)
        #expect(wellEvidenced != nil)
        #expect(tentative != wellEvidenced)
    }
}
