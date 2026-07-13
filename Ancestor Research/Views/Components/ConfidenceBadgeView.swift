import SwiftUI

/// Three-axis confidence badge — the canonical surface for the new
/// `EvidenceConfidence` model. Replaces the single tier badge that used to
/// render `ClusterConfidence` (weak / moderate / strong). See
/// `RESEARCH_CONFIDENCE_SPEC.md` §4 for the locked visual contract.
///
/// Layout: horizontal row of three elements, primary → tertiary.
///
/// ```
/// [✓ Confirmed] [3 sources · cross-referenced · primary] [Inferred — 1 step]
///    match              sourcing                                 inference
/// ```
///
/// The inference pill is rendered only when `confidence.inference.isInferred`
/// — direct facts get no inference label. Each axis carries its own tooltip
/// and accessibility text so the meaning is never colour-only.
struct ConfidenceBadgeView: View {
    let confidence: EvidenceConfidence

    var body: some View {
        HStack(spacing: 6) {
            matchQualityBadge
            sourcingChip
            if confidence.inference.isInferred {
                inferencePill
            }
        }
    }

    // MARK: - Match quality (primary)

    private var matchQualityBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: matchSymbol)
                .imageScale(.small)
            Text(matchLabel)
                .font(AppTypography.badge)
        }
        .foregroundStyle(matchColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
        .help(matchTooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Match: \(matchLabel)")
        .accessibilityHint(matchTooltip)
    }

    private var matchSymbol: String {
        switch confidence.matchQuality {
        case .confirmed: return "checkmark.circle.fill"
        case .possible:  return "questionmark.circle.fill"
        case .wrong:     return "xmark.circle.fill"
        }
    }

    private var matchLabel: String {
        switch confidence.matchQuality {
        case .confirmed: return "Confirmed"
        case .possible:  return "Possible"
        case .wrong:     return "Wrong person"
        }
    }

    private var matchColor: Color {
        switch confidence.matchQuality {
        case .confirmed: return .green
        case .possible:  return .orange
        case .wrong:     return .red
        }
    }

    private var matchTooltip: String {
        switch confidence.matchQuality {
        case .confirmed:
            return "All scoring gates passed — name, date, geography, and family context all consistent."
        case .possible:
            return "The record matched on name and date but at least one gate soft-failed."
        case .wrong:
            return "Hard fail on name or date — the record describes someone else."
        }
    }

    // MARK: - Sourcing strength (secondary)

    private var sourcingChip: some View {
        Text(sourcingText)
            .font(AppTypography.badge)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
            .overlay(
                Capsule()
                    .stroke(confidence.sourcing.isCrossReferenced ? Color.green.opacity(0.5) : Color.clear,
                            lineWidth: 1)
            )
            .help(sourcingTooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sourcing: \(sourcingText)")
            .accessibilityHint(sourcingTooltip)
    }

    /// Display rules from `RESEARCH_CONFIDENCE_SPEC` §3.2 — case-by-case so the
    /// rendered text is exactly what the spec contract names.
    private var sourcingText: String {
        let s = confidence.sourcing
        let primary = s.topTrustTier == .primary
        let primarySuffix = primary ? " · primary record" : ""

        // CL4 AC6 — witness count (independent register entries), not
        // lineage count: transcription copies no longer read as
        // cross-referencing. Zero means legacy/unavailable — fall back.
        let witnesses = s.independentWitnessCount > 0 ? s.independentWitnessCount : s.independentLineageCount
        switch (s.sourceCount, witnesses) {
        case (0, _):
            return "No sources"
        case (1, _):
            return "1 source\(primarySuffix)"
        case (let n, let lineages) where lineages >= 2:
            return "\(n) sources · cross-referenced\(primarySuffix)"
        case (let n, _):
            return "\(n) sources · same lineage\(primarySuffix)"
        }
    }

    private var sourcingTooltip: String {
        let s = confidence.sourcing
        let witnesses = s.independentWitnessCount > 0 ? s.independentWitnessCount : s.independentLineageCount
        return "\(s.sourceCount) records contribute, from \(witnesses) independent witnesses (underlying register entries). Cross-referenced means at least 2 witnesses agree."
    }

    // MARK: - Inference depth (tertiary, conditional)

    private var inferencePill: some View {
        Text(inferenceText)
            .font(AppTypography.badge)
            .italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
            .help(inferenceTooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Inference depth: \(inferenceText)")
            .accessibilityHint(inferenceTooltip)
    }

    private var inferenceText: String {
        let steps = confidence.inference.steps
        return steps == 1 ? "Inferred — 1 step" : "Inferred — \(steps) steps"
    }

    private var inferenceTooltip: String {
        let chain = confidence.inference.chain
        if chain.isEmpty {
            return "This finding was derived from a directly-observed record. Each step adds derivation distance from primary evidence."
        }
        return "Provenance: \(chain.joined(separator: " → "))"
    }
}
