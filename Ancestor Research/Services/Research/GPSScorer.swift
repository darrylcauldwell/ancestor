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
        totalSourceCount: Int,
        openDisputes: [DisputeRow] = [],
        resolvedDisputes: [DisputeRow] = [],
        inconclusiveValueCandidateCount: Int = 0
    ) -> GPSScore {
        let criteria = [
            criterion1ExhaustiveSearch(result: result, searched: searchedSourceCount, total: totalSourceCount),
            criterion2Citations(result: result),
            criterion3Analysis(result: result, sourceInfoMap: sourceInfoMap),
            criterion4ConflictResolution(
                result: result, openDisputes: openDisputes,
                resolvedDisputes: resolvedDisputes,
                inconclusiveValueCandidateCount: inconclusiveValueCandidateCount),
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

    /// CL3 (DS-20/DS-24): correlation is scored PER ASSERTED VALUE via
    /// `ConvergenceEngine.scoreValueGroups` — contradicting values for one
    /// field can no longer pool into a single inflated level. Met when at
    /// least one value group reaches `.possible`; the reason string always
    /// reports per-value levels so a split vote is visible.
    /// (Interim lineage counting per §4.5; witness counting lands CL4.)
    private static func criterion3Analysis(
        result: ResearchResult?, sourceInfoMap: [String: SourceInfo]
    ) -> GPSCriterion {
        guard let result, !result.confirmedFacts.isEmpty else {
            return GPSCriterion(criterion: .analysisCorrelation, met: false, reason: "No facts to analyse")
        }
        let factRecords = result.confirmedFacts.map(\.record)
        let groups = ConvergenceEngine.scoreValueGroups(
            records: factRecords, sourceInfoMap: sourceInfoMap)
        let best = groups.map(\.level).max() ?? .uncorroborated
        let met = best >= .possible
        let perValue = groups
            .map { "\($0.key) at \($0.level.rawValue)" }
            .joined(separator: "; ")
        return GPSCriterion(
            criterion: .analysisCorrelation,
            met: met,
            reason: met
                ? "Per-value corroboration: \(perValue)"
                : "Insufficient corroboration (best \(best.rawValue)): \(perValue)"
        )
    }

    // MARK: - Criterion 4: Resolution of Conflicting Evidence

    /// CL3 rewrite (§4.8.3, DS-07/DS-14/DS-22): GPS element 4 can now
    /// actually fire. Met requires ALL of:
    ///   1. no open dispute rows on the subject,
    ///   2. no rival confirmed clusters (≥2 clusters at confirmed quality
    ///      asserting different implied birth years — the John 1840/41 pair),
    ///   3. no inconclusive value-candidate hypotheses,
    ///   4. no run discrepancy graded ≥ .conflict.
    /// Resolved disputes count TOWARD met with their evidence cited —
    /// "resolution of conflicting evidence" means documented resolution,
    /// not absence of conflict (⟨G2⟩ met-with-evidence framing).
    private static func criterion4ConflictResolution(
        result: ResearchResult?,
        openDisputes: [DisputeRow],
        resolvedDisputes: [DisputeRow],
        inconclusiveValueCandidateCount: Int
    ) -> GPSCriterion {
        guard let result else {
            return GPSCriterion(criterion: .conflictResolution, met: false, reason: "Not yet researched")
        }

        var unmet: [String] = []

        if !openDisputes.isEmpty {
            let fields = openDisputes.map { "\($0.kind.rawValue)/\($0.field)" }
                .joined(separator: ", ")
            unmet.append("\(openDisputes.count) unresolved conflict\(openDisputes.count == 1 ? "" : "s"): \(fields)")
        }

        // Rival confirmed clusters: ≥2 at confirmed quality with disjoint
        // identity anchors (differing implied birth years).
        let confirmed = result.clusters.filter { $0.matchQuality == .confirmed }
        let anchors = Set(confirmed.compactMap(\.impliedBirthYear))
        if confirmed.count >= 2 && anchors.count >= 2 {
            let years = anchors.sorted().map(String.init).joined(separator: " vs ")
            unmet.append("\(confirmed.count) rival confirmed clusters (implied births \(years))")
        }

        if inconclusiveValueCandidateCount > 0 {
            unmet.append("\(inconclusiveValueCandidateCount) value-candidate hypothes\(inconclusiveValueCandidateCount == 1 ? "is" : "es") still inconclusive")
        }

        let conflicting = result.discrepancies.filter { $0.severity >= .conflict }
        if !conflicting.isEmpty {
            unmet.append("\(conflicting.count) run discrepanc\(conflicting.count == 1 ? "y" : "ies") at conflict grade")
        }

        if !unmet.isEmpty {
            return GPSCriterion(
                criterion: .conflictResolution, met: false,
                reason: unmet.joined(separator: "; ")
            )
        }

        // Met — with evidence when conflicts were RESOLVED rather than
        // merely absent.
        if !resolvedDisputes.isEmpty {
            let cited = resolvedDisputes
                .map { "\($0.field)\($0.resolutionRuleLabel.map { rule in " by \(rule)" } ?? "")" }
                .joined(separator: ", ")
            return GPSCriterion(
                criterion: .conflictResolution, met: true,
                reason: "\(resolvedDisputes.count) conflict\(resolvedDisputes.count == 1 ? "" : "s") resolved: \(cited)"
            )
        }
        return GPSCriterion(
            criterion: .conflictResolution, met: true,
            reason: result.clusters.isEmpty ? "No evidence to conflict" : "No conflicting evidence found"
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
