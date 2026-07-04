import Foundation

/// Match quality — answers "does this record describe the right person?"
///
/// One of three independent axes that together describe confidence in a piece
/// of research evidence. See `RESEARCH_CONFIDENCE_SPEC.md` for the full model.
///
/// Match quality is a thin façade over `RecordVerdict`:
///   - `.confirmed` — `RecordVerdict.fact` (all 4 gates pass, no soft fails)
///   - `.possible`  — `RecordVerdict.lead` (gates pass but ≥1 soft fail)
///   - `.wrong`     — `RecordVerdict.impossible` (name or date hard-fail)
///
/// Per-record-per-subject — the same FreeBMD record can be `.confirmed` for
/// one subject and `.wrong` for another. UI surfaces aggregate across a
/// cluster's records by taking the strongest match (`.confirmed` > `.possible`
/// > `.wrong`).
public nonisolated enum MatchQuality: String, Sendable, Codable, CaseIterable {
    case confirmed
    case possible
    case wrong

    /// Best-record-wins aggregation: returns the strongest match across
    /// the given inputs. `nil` only when the input is empty.
    public static func best(of values: [MatchQuality]) -> MatchQuality? {
        if values.contains(.confirmed) { return .confirmed }
        if values.contains(.possible)  { return .possible }
        if values.contains(.wrong)     { return .wrong }
        return nil
    }
}

nonisolated extension RecordVerdict {
    /// Map a scorer verdict to its UI-facing match-quality label.
    /// The two enums share shape but live in different namespaces — `RecordVerdict`
    /// is the scorer's output; `MatchQuality` is the UI aggregation. Keeping them
    /// distinct lets each evolve without dragging the other along.
    public var matchQuality: MatchQuality {
        switch self {
        case .fact:       return .confirmed
        case .lead:       return .possible
        case .impossible: return .wrong
        }
    }
}

/// Sourcing strength — answers "how many independent sources corroborate this?"
///
/// Computed by `ConvergenceEngine` from a cluster's member records. Lineage
/// independence is the convergence-aware count: two FreeBMD records of the
/// same event count as one lineage; a FreeBMD birth + a FindAGrave grave +
/// a parish baptism count as three.
///
/// Display rules (see `RESEARCH_CONFIDENCE_SPEC.md` §3.2):
///   - `sourceCount == 1`                                → "1 source"
///   - `sourceCount > 1, independentLineageCount == 1`   → "N sources · same lineage"
///   - `sourceCount > 1, independentLineageCount >= 2`   → "N sources · cross-referenced"
///   - `topTrustTier == .primary`                        → suffix "· primary record"
public nonisolated struct SourcingStrength: Sendable, Codable, Equatable {
    public let sourceCount: Int
    public let independentLineageCount: Int
    public let topTrustTier: SourceTrustTier

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(sourceCount: Int, independentLineageCount: Int, topTrustTier: SourceTrustTier) {
        self.sourceCount = sourceCount
        self.independentLineageCount = independentLineageCount
        self.topTrustTier = topTrustTier
    }


    /// Zero-source sentinel. Default for surfaces with no records to draw on
    /// (e.g. a ghost profile created by a parent inference before any
    /// secondary record corroborates it).
    public static let none = SourcingStrength(
        sourceCount: 0,
        independentLineageCount: 0,
        topTrustTier: .transcription
    )

    /// True when at least two independent lineages contribute. The UI uses
    /// this as the threshold for the "cross-referenced" suffix and as the
    /// promotion gate for sourcing-related visual emphasis.
    public var isCrossReferenced: Bool {
        independentLineageCount >= 2
    }
}

/// Inference depth — answers "how many derivational leaps did we make to get here?"
///
/// `steps` is the count of inference engines traversed between a directly-observed
/// record and this finding:
///   - 0 — direct fact (e.g. birth date read from a BMD index)
///   - 1 — one derivation (e.g. mother's identity inferred from a child's birth record)
///   - 2+ — nested derivation (e.g. grandparent inferred from a parent's inferred birth)
///
/// `chain` is a human-readable provenance trail used for tooltips and the
/// full-detail provenance view. Order: earliest derivation first; the directly-
/// observed record is the first entry when `steps > 0`.
public nonisolated struct InferenceDepth: Sendable, Codable, Equatable {
    public let steps: Int
    public let chain: [String]

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(steps: Int, chain: [String]) {
        self.steps = steps
        self.chain = chain
    }


    /// Direct evidence — no derivational steps; chain is empty. UI omits the
    /// inference badge entirely for direct facts.
    public static let direct = InferenceDepth(steps: 0, chain: [])

    /// True when at least one inference step separates this finding from a
    /// directly-observed record. UI shows the inference badge iff this is true.
    public var isInferred: Bool {
        steps > 0
    }
}

/// Combined three-axis confidence for a piece of evidence — a record, a
/// cluster, a profile, an inferred relative. The new badge primitive
/// (`ConfidenceBadgeView`, Change 3) renders all three axes side-by-side.
public nonisolated struct EvidenceConfidence: Sendable, Codable, Equatable {
    public let matchQuality: MatchQuality
    public let sourcing: SourcingStrength
    public let inference: InferenceDepth

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(matchQuality: MatchQuality, sourcing: SourcingStrength, inference: InferenceDepth) {
        self.matchQuality = matchQuality
        self.sourcing = sourcing
        self.inference = inference
    }

}
