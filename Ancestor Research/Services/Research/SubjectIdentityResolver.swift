import Foundation

/// Result of trying to pin a subject's identity to exactly one source record.
nonisolated enum SubjectIdentityResolution: Sendable, Equatable {
    /// Exactly one candidate survived all filters — the subject's identity is
    /// uniquely pinned to this birth record. Safe for downstream auto-promote.
    case resolved(birthRecordID: String, districtName: String)

    /// More than one candidate is plausible. Caller must defer to human review
    /// — auto-promote should NOT fire because we can't tell which record is
    /// the right anchor for the subject.
    case ambiguous(candidateIDs: [String], reason: String)

    /// No candidate birth records at all, or no geographic signal to filter on.
    /// Treat as "identity not resolved" — downstream inference (parents,
    /// marriages, etc.) shouldn't be auto-promoted because we have no anchor.
    case unresolved(reason: String)

    /// Convenience — `true` only for `.resolved`.
    var isResolved: Bool {
        if case .resolved = self { return true }
        return false
    }
}

/// Pure inference: given a set of candidate birth-fact records for the subject
/// and a ranked list of geographic hypotheses, decide whether the subject's
/// identity is uniquely pinned.
///
/// Designed to close the Colin-Holmes failure mode: when there are multiple
/// same-name birth records and no district anchor on the subject's profile,
/// the existing scorer treats all of them as candidate facts. Downstream
/// inference (parents from `mothersMaidenName`, marriage enrichment) then
/// silently picks the first/wrong one and promotes a wrong family. This
/// resolver makes that ambiguity explicit and refuses to resolve unless a
/// geographic hypothesis filters cleanly to exactly one candidate.
nonisolated enum SubjectIdentityResolver {

    /// Minimum hypothesis weight required before we let it filter candidates.
    /// Weights are split when a parish maps to multiple districts (see
    /// `GeographicHypothesisGenerator.addLocationSignal`), so the threshold
    /// has to be low enough that a single signal still trips it. Two
    /// corroborating signals or one direct signal at full weight clears it.
    static let defaultMinimumHypothesisWeight: Double = 0.25

    /// Resolve the subject's identity by filtering candidate birth-fact
    /// records against the top geographic hypothesis.
    ///
    /// Algorithm:
    ///   1. Zero candidates → `.unresolved` (no birth anchor to choose from).
    ///   2. One candidate → `.resolved` (no ambiguity to resolve).
    ///   3. ≥2 candidates and no usable hypothesis → `.ambiguous`.
    ///   4. ≥2 candidates and a strong-enough hypothesis → filter by district
    ///      match. One match → `.resolved`. Multiple or zero matches →
    ///      `.ambiguous`.
    ///
    /// - Parameters:
    ///   - candidateBirthFacts: birth records the scorer accepted as `.fact`
    ///     for the subject. Caller filters from the full result set.
    ///   - hypotheses: ranked output of `GeographicHypothesisGenerator`. Only
    ///     the top entry is used today; future versions may combine the top
    ///     few if their weights are close.
    ///   - minimumHypothesisWeight: top hypothesis must score at or above
    ///     this to filter. Below it we keep the ambiguity rather than guess.
    /// - Returns: a `SubjectIdentityResolution` recording the outcome.
    static func resolve(
        candidateBirthFacts: [ScoredRecord],
        hypotheses: [GeographicHypothesis],
        minimumHypothesisWeight: Double = SubjectIdentityResolver.defaultMinimumHypothesisWeight
    ) -> SubjectIdentityResolution {
        if candidateBirthFacts.isEmpty {
            return .unresolved(reason: "no candidate birth records")
        }
        if candidateBirthFacts.count == 1 {
            let only = candidateBirthFacts[0]
            return .resolved(
                birthRecordID: only.id,
                districtName: birthDistrict(of: only) ?? "(unknown)"
            )
        }

        guard let top = hypotheses.first else {
            return .ambiguous(
                candidateIDs: candidateBirthFacts.map(\.id),
                reason: "\(candidateBirthFacts.count) candidate births, no geographic hypothesis to disambiguate"
            )
        }
        guard top.weight >= minimumHypothesisWeight else {
            return .ambiguous(
                candidateIDs: candidateBirthFacts.map(\.id),
                reason: "top hypothesis (\(top.districtName), weight \(String(format: "%.2f", top.weight))) below minimum \(minimumHypothesisWeight)"
            )
        }

        let topDistrictLower = top.districtName.lowercased()
        let matching = candidateBirthFacts.filter { record in
            guard let district = birthDistrict(of: record) else { return false }
            return district.lowercased() == topDistrictLower
        }

        if matching.count == 1 {
            return .resolved(birthRecordID: matching[0].id, districtName: top.districtName)
        }
        if matching.isEmpty {
            return .ambiguous(
                candidateIDs: candidateBirthFacts.map(\.id),
                reason: "no candidate matches top hypothesis district \(top.districtName)"
            )
        }
        return .ambiguous(
            candidateIDs: matching.map(\.id),
            reason: "\(matching.count) candidates match district \(top.districtName)"
        )
    }

    /// Extract a candidate's birth registration district, when present.
    /// Only birth records carry district at the source-record level —
    /// other record types are filtered out by the caller before invoking
    /// `resolve`, so we only need the birth case here.
    private static func birthDistrict(of scored: ScoredRecord) -> String? {
        if case .birth(let birth) = scored.record {
            return birth.district?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
