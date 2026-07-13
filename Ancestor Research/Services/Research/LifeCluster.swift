import Foundation

/// A candidate life — a group of records believed to be about the same person.
/// The pipeline outputs clusters, not raw records.
///
/// Confidence is no longer a stored single-tier enum — RESEARCH_CONFIDENCE_SPEC
/// Change 5 removed `ClusterConfidence` in favour of the three-axis
/// `EvidenceConfidence` model. Callers derive confidence on demand via
/// `matchQuality` (pure) or `evidenceConfidence(sourceInfoMap:)` (full).
nonisolated struct LifeCluster: Identifiable, Sendable {
    let id: String
    var records: [ScoredRecord]
    var lifespanStart: Int
    var lifespanEnd: Int
    var mergeCandidate: String?  // ID of another cluster that might be the same person
    /// CONFLICT_LAYER_SPEC CL2 T-D ⟨G13⟩ — set when this cluster was split
    /// off by a contradiction rule (e.g. same-enumeration-year census);
    /// rendered as a badge in ClusterReviewView.
    var splitReason: String? = nil

    /// The implied birth year from the seed record.
    var impliedBirthYear: Int? {
        for record in records {
            switch record.record {
            case .birth(let r): return r.birthYear
            case .parish(let r) where r.eventType?.lowercased() == "baptism": return r.eventYear
            default: continue
            }
        }
        // Fallback: census-derived birth year
        for record in records {
            if case .census(let r) = record.record, let by = r.birthYear {
                return by
            }
        }
        return nil
    }

    /// The implied death year from records.
    var impliedDeathYear: Int? {
        for record in records {
            switch record.record {
            case .death(let r): return r.deathYear
            case .burial(let r): return r.deathYear
            case .military(let r): return r.deathYear
            case .probate(let r): return r.deathYear
            default: continue
            }
        }
        return nil
    }

    /// All districts mentioned in this cluster's records.
    var districts: Set<String> {
        var result: Set<String> = []
        for record in records {
            if let d = extractDistrict(from: record.record), !d.isEmpty {
                result.insert(d.uppercased())
            }
        }
        return result
    }

    /// Known household members from census records in this cluster.
    var householdMembers: [HouseholdMember] {
        records.compactMap { scored in
            if case .census(let r) = scored.record { return r.household }
            return nil
        }.flatMap { $0 }
    }

    /// Display name from the best record.
    var displayName: String {
        for record in records {
            let name = [record.record.givenName, record.record.surname]
                .compactMap { $0 }
                .joined(separator: " ")
            if !name.isEmpty { return name }
        }
        return "Unknown"
    }

    /// Aggregate match quality across the cluster's records — strongest wins.
    /// nil only when the cluster is empty. See `RESEARCH_CONFIDENCE_SPEC` §3.1.
    /// Match quality is computable from records alone — no `sourceInfoMap`
    /// dependency — so it lives on the cluster as a pure property.
    var matchQuality: MatchQuality? {
        MatchQuality.best(of: records.map { $0.verdict.matchQuality })
    }

    /// True when at least one record in the cluster is a marriage whose
    /// `familyContext` gate explicitly passed because the spouse matches
    /// the subject's known spouse. Lets cluster review surface an "Apply"
    /// action on otherwise-`.possible` clusters whose verdict was dragged
    /// down by FreeBMD transcription gaps (e.g. blank surname/district),
    /// when there's a strong independent signal (familyContext) that the
    /// record describes the subject's existing marriage.
    var hasKnownSpouseMarriage: Bool {
        records.contains { scored in
            guard case .marriage = scored.record else { return false }
            return scored.gates.contains { $0.gate == .familyContext && $0.outcome == .pass }
        }
    }

    /// Full three-axis confidence for this cluster. Requires `sourceInfoMap`
    /// to compute the sourcing axis (lineage independence + top trust tier).
    /// Cluster records are direct evidence; inference depth is always
    /// `.direct` here — `ProposedRelative` carries depth on its own field for
    /// inferred entities. See `RESEARCH_CONFIDENCE_SPEC` §3.
    func evidenceConfidence(sourceInfoMap: [String: SourceInfo]) -> EvidenceConfidence {
        let sourcing = ConvergenceEngine.sourcingStrength(for: self, sourceInfoMap: sourceInfoMap)
        return EvidenceConfidence(
            matchQuality: matchQuality ?? .wrong,
            sourcing: sourcing,
            inference: .direct
        )
    }

    /// Hypothesis verdict — treats the cluster as a working hypothesis about
    /// one life and grades the supporting evidence. Lifts the decision from
    /// "best-of-record match quality" (which gives any single `.fact` record
    /// `.confirmed`) up to "is this hypothesis strongly enough corroborated
    /// to auto-promote?".
    ///
    /// Gates by:
    ///   • Independent source lineages (via `ConvergenceEngine.sourcingStrength`)
    ///   • Number of records that fully passed all 4 gates (`verdict == .fact`)
    ///   • Whether the records agree on key facts (cluster splitting already
    ///     handles most contradiction; here we treat conflicting birth or
    ///     death years inside one cluster as `.contradicted`).
    ///
    /// `RESEARCH_HYPOTHESIS_VERDICT` is the auto-promote gate (replaces the
    /// looser "any .confirmed proposed relative" gate). Used by the
    /// `AUTOMATION_AUTO_ACCEPT` build path.
    func hypothesisVerdict(sourceInfoMap: [String: SourceInfo]) -> HypothesisVerdict {
        let factRecords = records.filter { $0.verdict == .fact }
        let lineages = ConvergenceEngine.sourcingStrength(for: self, sourceInfoMap: sourceInfoMap)

        if hasContradictoryFacts {
            return .contradicted
        }

        switch (lineages.independentLineageCount, factRecords.count) {
        case (let lineageCount, let factCount) where lineageCount >= 2 && factCount >= 1:
            return .stronglySupported
        case (let lineageCount, _) where lineageCount >= 2:
            return .supported
        case (1, let factCount) where factCount >= 2:
            return .supported
        case (_, let factCount) where factCount >= 1:
            return .weak
        default:
            return .weak
        }
    }

    /// True when records inside this cluster disagree on a hard fact —
    /// different birth years on two birth records, different death years on
    /// two death records, etc. Clustering normally splits these into
    /// separate clusters during the SPLIT step, so this fires only for
    /// edge cases where a contradictory record snuck in via assignment.
    private var hasContradictoryFacts: Bool {
        // Birth-year conflict: more than one distinct birthYear across all
        // birth records in this cluster.
        let birthYears = Set(records.compactMap { scored -> Int? in
            if case .birth(let r) = scored.record { return r.birthYear }
            return nil
        })
        if birthYears.count > 1 { return true }

        // Death-year conflict: same shape.
        let deathYears = Set(records.compactMap { scored -> Int? in
            if case .death(let r) = scored.record { return r.deathYear }
            return nil
        })
        if deathYears.count > 1 { return true }

        return false
    }
}

/// Aggregated verdict on a cluster-as-hypothesis. Drives auto-promote +
/// next-step suggestions. See `LifeCluster.hypothesisVerdict(sourceInfoMap:)`.
nonisolated enum HypothesisVerdict: String, Sendable, Codable {
    /// Multiple independent sources agree and at least one record passed
    /// all four scoring gates. Auto-promote gate.
    case stronglySupported = "strongly_supported"
    /// Either multiple independent sources or multiple corroborating facts
    /// from one source — corroborated but not strongly enough for unattended
    /// acceptance.
    case supported
    /// Single record or single lineage with no cross-corroboration — needs
    /// further evidence (e.g. hypothesis-guided second pass) or human review.
    case weak
    /// Records inside the cluster disagree on a hard fact (different birth
    /// or death years). Must be resolved by the user before promotion.
    case contradicted
}

/// Extract district from a source record.
private nonisolated func extractDistrict(from record: SourceRecord) -> String? {
    switch record {
    case .birth(let r): return r.district
    case .death(let r): return r.district
    case .marriage(let r): return r.district
    case .census(let r): return r.district
    default: return nil
    }
}
