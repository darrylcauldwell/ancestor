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
