import Foundation

/// Computes discrepancy severity based on source trust tier, value delta, and convergence.
///
/// Each threshold is justified:
/// - FreeBMD birth ±2: registration quarter vs actual birth date
/// - FreeCen census age ±3: self-reported by household head, 1841 rounds to nearest 5
/// - FreeBMD death age ±1: informant-reported, usually accurate
/// - Find a Grave ±2: volunteer-transcribed from weathered headstones
/// - CWGC ±0: official military records — if CWGC says 14 July 1918, it is
///
/// Convergence can upgrade severity but never downgrade (deterministic floor).
nonisolated struct DiscrepancySeverityTable {

    /// Compute severity for a year-valued discrepancy from a given source.
    ///
    /// `sourceID` and `recordType` narrow the tolerance to the specific
    /// source (§10.3) — CWGC is ±0 while FreeBMD births tolerate a ±2
    /// registration-quarter slip; sources without a specific band fall back
    /// to the trust-tier band.
    static func severity(
        sourceID: String,
        sourceTier: SourceTrustTier,
        recordType: RecordType?,
        absDelta: Int,
        convergence: ConvergenceLevel
    ) -> (severity: DiscrepancySeverity, reasoning: String) {
        let base = baseSeverity(sourceID: sourceID, tier: sourceTier, recordType: recordType, absDelta: absDelta)
        let upgraded = applyConvergenceUpgrade(base: base, convergence: convergence)
        let reasoning = explanation(sourceID: sourceID, tier: sourceTier, absDelta: absDelta,
                                    convergence: convergence, base: base, final: upgraded)
        return (upgraded, reasoning)
    }

    // MARK: - Base Severity — per-source band (§10.3), tier fallback

    private static func baseSeverity(sourceID: String, tier: SourceTrustTier, recordType: RecordType?, absDelta: Int) -> DiscrepancySeverity {
        switch sourceID.lowercased() {
        case "cwgc":
            // Official military record — ±0. "If CWGC says 14 July 1918, it
            // is" — any disagreement is a correction, not a refinement.
            return absDelta == 0 ? .none : .correction
        case "freebmd":
            // Registration quarter can slip a year on a birth (±2); a death
            // is informant-reported at the event and tighter (±1). Beyond
            // tolerance the transcription disagrees materially → conflict.
            let tol = (recordType == .death || recordType == .burial) ? 1 : 2
            return band(absDelta: absDelta, tolerance: tol, exceedance: .conflict)
        case "freecen":
            // Census age is self-reported by the household head and 1841
            // rounds to the nearest 5 → ±3.
            return band(absDelta: absDelta, tolerance: 3, exceedance: .conflict)
        case "findagrave", "find a grave":
            // Volunteer-transcribed from weathered headstones — ±2, and a
            // soft note rather than a refinement within tolerance.
            return absDelta <= 2 ? .note : .conflict
        default:
            return tierBand(tier: tier, absDelta: absDelta)
        }
    }

    /// Band for a source with a `tolerance`-year expected-noise window:
    /// comfortably inside → `.none`, at the edge of tolerance → `.refinement`,
    /// beyond → `exceedance` (`.conflict` for transcription, `.correction`
    /// for primary).
    private static func band(absDelta: Int, tolerance: Int, exceedance: DiscrepancySeverity) -> DiscrepancySeverity {
        if absDelta < tolerance { return .none }
        if absDelta == tolerance { return .refinement }
        return exceedance
    }

    /// Fallback band for sources without a specific §10.3 entry
    /// (FreeREG, Wirksworth, FamilySearch, field-researcher submissions).
    private static func tierBand(tier: SourceTrustTier, absDelta: Int) -> DiscrepancySeverity {
        switch (tier, absDelta) {
        // Primary sources (official registers) — tight tolerance
        case (.primary, 0): return .none
        case (.primary, 1...2): return .refinement
        case (.primary, _): return .correction  // primary source disagrees significantly

        // Transcription sources — moderate tolerance
        case (.transcription, 0...1): return .none
        case (.transcription, 2...3): return .refinement
        case (.transcription, _): return .conflict

        // Community sources — wide tolerance
        case (.community, 0...2): return .note
        case (.community, _): return .conflict
        }
    }

    // MARK: - Convergence Upgrade (never downgrade)

    private static func applyConvergenceUpgrade(
        base: DiscrepancySeverity,
        convergence: ConvergenceLevel
    ) -> DiscrepancySeverity {
        switch convergence {
        case .confirmed: return max(base, .correction)
        case .probable: return max(base, .conflict)
        case .possible, .singleSource, .uncorroborated: return base
        }
    }

    // MARK: - Reasoning Trace

    private static func explanation(
        sourceID: String,
        tier: SourceTrustTier,
        absDelta: Int,
        convergence: ConvergenceLevel,
        base: DiscrepancySeverity,
        final: DiscrepancySeverity
    ) -> String {
        var parts: [String] = []
        let label = sourceID.isEmpty ? "tier \(tier.rawValue)" : "\(sourceID) (tier \(tier.rawValue))"
        parts.append("Source \(label) with delta \(absDelta) years → base \(base.rawValue)")
        if final != base {
            parts.append("Convergence \(convergence.rawValue) upgraded to \(final.rawValue)")
        }
        return parts.joined(separator: ". ")
    }
}
