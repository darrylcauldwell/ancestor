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
    static func severity(
        sourceTier: SourceTrustTier,
        absDelta: Int,
        convergence: ConvergenceLevel
    ) -> (severity: DiscrepancySeverity, reasoning: String) {
        let base = baseSeverity(tier: sourceTier, absDelta: absDelta)
        let upgraded = applyConvergenceUpgrade(base: base, convergence: convergence)
        let reasoning = explanation(tier: sourceTier, absDelta: absDelta,
                                    convergence: convergence, base: base, final: upgraded)
        return (upgraded, reasoning)
    }

    // MARK: - Base Severity from Source Trust

    private static func baseSeverity(tier: SourceTrustTier, absDelta: Int) -> DiscrepancySeverity {
        switch (tier, absDelta) {
        // Primary sources (CWGC, official registers) — tight tolerance
        case (.primary, 0): return .none
        case (.primary, 1...2): return .refinement
        case (.primary, _): return .correction  // primary source disagrees significantly

        // Transcription sources (FreeBMD, FreeCen, FreeREG) — moderate tolerance
        case (.transcription, 0...1): return .none
        case (.transcription, 2...3): return .refinement
        case (.transcription, _): return .conflict

        // Community sources (FamilySearch, Find a Grave) — wide tolerance
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
        tier: SourceTrustTier,
        absDelta: Int,
        convergence: ConvergenceLevel,
        base: DiscrepancySeverity,
        final: DiscrepancySeverity
    ) -> String {
        var parts: [String] = []
        parts.append("Source tier \(tier.rawValue) (\(tier)) with delta \(absDelta) years → base \(base.rawValue)")
        if final != base {
            parts.append("Convergence \(convergence.rawValue) upgraded to \(final.rawValue)")
        }
        return parts.joined(separator: ". ")
    }
}
