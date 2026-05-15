import Foundation

/// What kind of relationship a proposal describes.
/// Only `.parentOf` is wired in Change 3; `.spouseOf` and `.childOf` are placeholders
/// for future inference rules (e.g. marriage records → spouse, baptism records → child).
nonisolated enum ProposedRelationship: Sendable, Hashable {
    case parentOf(String)
    case spouseOf(String)
    case childOf(String)

    var subjectID: String {
        switch self {
        case .parentOf(let id), .spouseOf(let id), .childOf(let id): return id
        }
    }
}

/// A relative the pipeline inferred from confirmed records but has not yet linked.
/// User accepts in cluster review → ghost Profile + Relationship edge created.
/// User rejects → id persisted in record_rejections so the same proposal will not reappear.
nonisolated struct ProposedRelative: Sendable, Identifiable {
    /// Deterministic id: same (subject, relationship, role, surname) always produces the same id.
    /// Used as the rejection key so re-runs honor previous rejections.
    let id: String
    let proposedSurname: String?
    /// Mutated by marriage-record enrichment when a unique marriage links the
    /// parent surname pair (e.g. Cauldwell × Holmes) within the plausible window.
    /// Stays nil if the BMD index alone can't identify the given name.
    var proposedGivenName: String?
    let gender: Gender?
    let birthYearLow: Int?
    let birthYearHigh: Int?
    let relationship: ProposedRelationship
    /// Source records that contributed to this proposal. Starts with the birth
    /// record that implied the surname; grows when marriage enrichment matches.
    var evidence: [ScoredRecord]
    /// Inference depth from a directly-observed record. Always `steps >= 1` for
    /// proposals — a `ProposedRelative` is by definition derived from some
    /// other record (the child's birth record, the spouse's marriage record).
    /// Chain captures the provenance trail rendered in tooltip + full-detail
    /// view. See `RESEARCH_CONFIDENCE_SPEC.md` §3.3.
    var inferenceDepth: InferenceDepth = InferenceDepth(steps: 1, chain: [])
    /// Candidate marriage records when enrichment found >1 plausible match and
    /// can't pick a given name automatically. Empty when enrichment was
    /// conclusive or didn't run. User picks one during accept.
    var ambiguousMarriages: [ScoredRecord] = []

    /// Three-axis confidence for a proposed relative — used by
    /// `ConfidenceBadgeView` in cluster review. Match quality aggregates
    /// across the evidence records; sourcing uses `ConvergenceEngine`'s
    /// lineage-grouped count; inference depth is the proposal's own.
    /// See `RESEARCH_CONFIDENCE_SPEC` §3.
    func evidenceConfidence(sourceInfoMap: [String: SourceInfo]) -> EvidenceConfidence {
        let match = MatchQuality.best(of: evidence.map { $0.verdict.matchQuality }) ?? .wrong
        let sourcing = ConvergenceEngine.sourcingStrength(
            records: evidence.map(\.record),
            sourceInfoMap: sourceInfoMap
        )
        return EvidenceConfidence(
            matchQuality: match,
            sourcing: sourcing,
            inference: inferenceDepth
        )
    }

    /// Build a stable id from the components that semantically identify this proposal.
    static func stableID(
        relationship: ProposedRelationship,
        gender: Gender?,
        surname: String?
    ) -> String {
        let relKey: String
        switch relationship {
        case .parentOf(let id): relKey = "parentOf:\(id)"
        case .spouseOf(let id): relKey = "spouseOf:\(id)"
        case .childOf(let id):  relKey = "childOf:\(id)"
        }
        let genderKey = gender?.rawValue ?? "unknown"
        let surnameKey = (surname ?? "").uppercased()
        return "\(relKey):\(genderKey):\(surnameKey)"
    }
}

/// Deterministic engine for inferring parents from confirmed records.
/// Pure function: takes facts + subject + dedup context → returns proposals.
/// No dependency on SearchDispatcher or any pipeline state, so unit-testable in isolation.
nonisolated enum ParentInferenceEngine {

    /// Infer parents from birth records that carry mothersMaidenName.
    ///
    /// **Accepts both `.fact` and `.lead` verdicts.** The `mothersMaidenName` field
    /// is a transcribed property of the BMD index itself — its reliability does not
    /// depend on whether geography or family-context gates passed. If we found a
    /// name + year match on a birth record, the parent surnames it implies are
    /// worth proposing. Confidence on the ProposedRelative reflects the source
    /// verdict so the user sees the strength behind each proposal.
    ///
    /// `.impossible` verdicts are skipped (name mismatch, temporally wrong).
    ///
    /// - Parameters:
    ///   - facts: scored records to scan (any verdict; impossible is filtered out).
    ///   - subject: the person being researched. Must have profileID for any proposal to be emitted.
    ///   - existingParents: parents already linked in the tree — used to dedup by surname+gender.
    ///   - sourceInfoMap: source metadata for the trust-tier gate.
    ///   - existing: proposals already in the state (preserves stability across iterations).
    /// - Returns: the combined proposal list (existing + new), deduplicated by stable id.
    static func infer(
        from facts: [ScoredRecord],
        subject: ResearchSubject,
        existingParents: [Profile],
        sourceInfoMap: [String: SourceInfo],
        existing: [ProposedRelative] = []
    ) -> [ProposedRelative] {
        guard let subjectID = subject.profileID else { return existing }

        // `existingParents` is intentionally unused by the engine. Earlier versions
        // silently dropped proposals matching existing parents, which made the
        // "Proposed Relatives" section vanish entirely on re-research after the
        // user had accepted them. The UI now joins against the live snapshot and
        // renders "Already linked" for matched entries — keeping the chain of
        // reasoning visible without offering duplicate Accept buttons.
        _ = existingParents

        var result = existing
        var seenIDs = Set(existing.map(\.id))

        for fact in facts {
            // Skip records the scorer ruled out entirely.
            guard fact.verdict != .impossible else { continue }
            guard case .birth(let birth) = fact.record else { continue }
            guard let maidenName = birth.mothersMaidenName?.trimmingCharacters(in: .whitespaces),
                  !maidenName.isEmpty else { continue }

            let sourceTier = sourceInfoMap[fact.record.sourceID]?.trustTier ?? .community
            guard sourceTier >= .transcription else { continue }

            let subjectBirthYear = birth.birthYear ?? subject.birthYearFrom
            let parentLow: Int? = subjectBirthYear.map { $0 - 45 }
            let parentHigh: Int? = subjectBirthYear.map { $0 - 18 }
            let rel = ProposedRelationship.parentOf(subjectID)
            _ = sourceTier  // Reserved for future per-source weighting; see RESEARCH_CONFIDENCE_SPEC
            // One inference step away from the birth record. Chain entry
            // names the source for tooltip / full-detail provenance.
            let depth = InferenceDepth(
                steps: 1,
                chain: ["Parent surname inferred from \(fact.record.sourceID) birth record"]
            )

            // Mother
            let motherID = ProposedRelative.stableID(relationship: rel, gender: .female, surname: maidenName)
            if !seenIDs.contains(motherID) {
                result.append(ProposedRelative(
                    id: motherID,
                    proposedSurname: maidenName,
                    proposedGivenName: nil,
                    gender: .female,
                    birthYearLow: parentLow,
                    birthYearHigh: parentHigh,
                    relationship: rel,
                    evidence: [fact],
                    inferenceDepth: depth
                ))
                seenIDs.insert(motherID)
            }

            // Father — surname inferred from subject (BMD index does not carry it directly)
            if let fatherSurname = subject.surname?.trimmingCharacters(in: .whitespaces),
               !fatherSurname.isEmpty {
                let fatherID = ProposedRelative.stableID(relationship: rel, gender: .male, surname: fatherSurname)
                if !seenIDs.contains(fatherID) {
                    result.append(ProposedRelative(
                        id: fatherID,
                        proposedSurname: fatherSurname,
                        proposedGivenName: nil,
                        gender: .male,
                        birthYearLow: parentLow,
                        birthYearHigh: parentHigh,
                        relationship: rel,
                        evidence: [fact],
                        inferenceDepth: depth
                    ))
                    seenIDs.insert(fatherID)
                }
            }
        }

        return result
    }
}
