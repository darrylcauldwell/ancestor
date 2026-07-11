import Foundation

/// GPS (Genealogical Proof Standard) criterion result.
nonisolated struct GPSCriterion: Sendable {
    let criterion: GPSCriterionType
    let met: Bool
    let reason: String
}

/// The five GPS criteria per the Board for Certification of Genealogists.
nonisolated enum GPSCriterionType: String, CaseIterable, Sendable {
    case exhaustiveSearch = "Reasonably exhaustive search"
    case completeCitations = "Complete and accurate citations"
    case analysisCorrelation = "Analysis and correlation"
    case conflictResolution = "Resolution of conflicting evidence"
    case soundConclusion = "Soundly reasoned conclusion"
}

/// GPS score for a profile — how well-researched it is.
nonisolated struct GPSScore: Sendable {
    let criteria: [GPSCriterion]

    var score: Int { criteria.filter(\.met).count }
    var maximum: Int { criteria.count }

    var label: String {
        switch score {
        case 5: "Proven"
        case 4: "Strong"
        case 3: "Adequate"
        case 2: "Partial"
        case 1: "Minimal"
        default: "Unresearched"
        }
    }
}

/// Scores a profile against the GPS five criteria.
/// Uses research results (if available) to determine how thoroughly
/// the profile has been researched.
nonisolated struct GPSScorer {

    /// Score a profile's GPS compliance.
    /// - Parameters:
    ///   - result: Research result for this profile (nil if never researched)
    ///   - sourceInfoMap: Source metadata for convergence checks
    ///   - searchedSourceCount: How many sources were searched
    ///   - totalSourceCount: How many sources are available
    static func score(
        result: ResearchResult?,
        sourceInfoMap: [String: SourceInfo],
        searchedSourceCount: Int,
        totalSourceCount: Int
    ) -> GPSScore {
        let criteria = [
            criterion1ExhaustiveSearch(result: result, searched: searchedSourceCount, total: totalSourceCount),
            criterion2Citations(result: result),
            criterion3Analysis(result: result, sourceInfoMap: sourceInfoMap),
            criterion4ConflictResolution(result: result),
            criterion5SoundConclusion(result: result),
        ]
        return GPSScore(criteria: criteria)
    }

    // MARK: - Criterion 1: Reasonably Exhaustive Search

    /// Which sources count as "searched" for criterion 1 (connector-audit
    /// T1-01 / FT-23). A source counts when it produced at least one
    /// CONCLUSIVE outcome — availability ok and not truncated — so a
    /// source that only ever errored, was blocked/throttled, or returned
    /// page-1-truncated answers no longer inflates "reasonably
    /// exhaustive search". Two fallbacks keep legacy behaviour intact:
    ///   • results with no outcome envelope at all (persisted pre-T1-01
    ///     runs, intermediate snapshots) fall back to the old
    ///     record-derived accounting;
    ///   • sources reached only outside the main fan-out (strategist
    ///     `dispatchOne`, pivots) carry no envelope, but a record in
    ///     hand proves the source was searched and answered.
    static func searchedSourceIDs(for result: ResearchResult) -> Set<String> {
        let recordSources = Set(result.allScoredRecords.map(\.record.sourceID))
        guard !result.searchOutcomes.isEmpty else {
            return recordSources
        }
        var searched = Set(
            result.searchOutcomes
                .filter { $0.outcome.isConclusive }
                .map(\.sourceID)
        )
        let envelopedSources = Set(result.searchOutcomes.map(\.sourceID))
        searched.formUnion(recordSources.subtracting(envelopedSources))
        return searched
    }

    /// Met if we searched at least 3 of the available sources, or all if fewer than 3 exist.
    private static func criterion1ExhaustiveSearch(
        result: ResearchResult?, searched: Int, total: Int
    ) -> GPSCriterion {
        guard let result, !result.searchHistory.isEmpty else {
            return GPSCriterion(criterion: .exhaustiveSearch, met: false, reason: "Not yet researched")
        }
        let threshold = min(3, total)
        let met = searched >= threshold
        return GPSCriterion(
            criterion: .exhaustiveSearch,
            met: met,
            reason: met
                ? "Searched \(searched) of \(total) sources"
                : "Only \(searched) of \(total) sources searched (need \(threshold))"
        )
    }

    // MARK: - Criterion 2: Complete and Accurate Citations

    /// Met if all confirmed facts have citation data (sourceID + detailURL or raw fields).
    private static func criterion2Citations(result: ResearchResult?) -> GPSCriterion {
        guard let result, !result.confirmedFacts.isEmpty else {
            return GPSCriterion(criterion: .completeCitations, met: false, reason: "No confirmed facts")
        }
        let cited = result.confirmedFacts.filter { scored in
            !scored.record.sourceID.isEmpty
        }
        let met = cited.count == result.confirmedFacts.count
        return GPSCriterion(
            criterion: .completeCitations,
            met: met,
            reason: met
                ? "All \(cited.count) facts have source citations"
                : "\(cited.count) of \(result.confirmedFacts.count) facts cited"
        )
    }

    // MARK: - Criterion 3: Analysis and Correlation

    /// Met if we have at least 2 corroborating facts from independent sources.
    private static func criterion3Analysis(
        result: ResearchResult?, sourceInfoMap: [String: SourceInfo]
    ) -> GPSCriterion {
        guard let result, !result.confirmedFacts.isEmpty else {
            return GPSCriterion(criterion: .analysisCorrelation, met: false, reason: "No facts to analyse")
        }
        let factRecords = result.confirmedFacts.map(\.record)
        let convergence = ConvergenceEngine.score(records: factRecords, sourceInfoMap: sourceInfoMap)
        let met = convergence >= .possible
        return GPSCriterion(
            criterion: .analysisCorrelation,
            met: met,
            reason: met
                ? "Evidence corroborated at \(convergence.rawValue) level"
                : "Insufficient corroboration (\(convergence.rawValue))"
        )
    }

    // MARK: - Criterion 4: Resolution of Conflicting Evidence

    /// Met if no unresolved conflicts exist, OR if there are no conflicts at all.
    private static func criterion4ConflictResolution(result: ResearchResult?) -> GPSCriterion {
        guard let result else {
            return GPSCriterion(criterion: .conflictResolution, met: false, reason: "Not yet researched")
        }
        // RESEARCH_CONFIDENCE_SPEC §4 — "ambiguous" was the pre-Change-5 tier
        // for clusters with internal contradictions. The new model surfaces
        // the same signal as "any .impossible record present in the cluster"
        // (mirrors BulkReviewView.frictionTier).
        let ambiguous = result.clusters.filter { cluster in
            cluster.records.contains { $0.verdict == .impossible }
        }
        if ambiguous.isEmpty {
            return GPSCriterion(
                criterion: .conflictResolution,
                met: true,
                reason: result.clusters.isEmpty ? "No evidence to conflict" : "No conflicting evidence found"
            )
        }
        return GPSCriterion(
            criterion: .conflictResolution,
            met: false,
            reason: "\(ambiguous.count) cluster\(ambiguous.count == 1 ? "" : "s") with unresolved contradictions"
        )
    }

    // MARK: - Criterion 5: Soundly Reasoned Conclusion

    /// Met if we have at least one strong or moderate cluster.
    private static func criterion5SoundConclusion(result: ResearchResult?) -> GPSCriterion {
        guard let result, !result.clusters.isEmpty else {
            return GPSCriterion(criterion: .soundConclusion, met: false, reason: "No clusters to evaluate")
        }
        // RESEARCH_CONFIDENCE_SPEC §4 — pre-Change-5 "moderate+" tier meant
        // "has fact records and ≥2 records overall". The new model treats
        // those signals as separate: a cluster qualifies as "sound" if its
        // match quality is .confirmed (≥1 fact record) AND it has more than
        // one record to corroborate.
        let strong = result.clusters.filter { cluster in
            cluster.matchQuality == .confirmed && cluster.records.count >= 2
        }
        let met = !strong.isEmpty
        return GPSCriterion(
            criterion: .soundConclusion,
            met: met,
            reason: met
                ? "\(strong.count) cluster\(strong.count == 1 ? "" : "s") with confirmed identity and corroboration"
                : "No corroborated confirmed-identity clusters"
        )
    }
}
