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
    ///   - searchedSourceIDs: Which sources were searched (conclusively)
    ///   - totalSourceCount: How many sources are available
    ///   - relevantSourceIDs: Sources specifically relevant to this subject
    ///     that must be covered before the search counts as exhaustive (DS-22)
    static func score(
        result: ResearchResult?,
        sourceInfoMap: [String: SourceInfo],
        searchedSourceIDs: Set<String>,
        totalSourceCount: Int,
        relevantSourceIDs: Set<String> = [],
        openDisputes: [DisputeRow] = [],
        resolvedDisputes: [DisputeRow] = [],
        inconclusiveValueCandidateCount: Int = 0
    ) -> GPSScore {
        let criteria = [
            criterion1ExhaustiveSearch(result: result, searched: searchedSourceIDs, total: totalSourceCount, relevant: relevantSourceIDs),
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

    /// Met when at least 3 sources were searched (or all, if fewer exist)
    /// AND every source that is specifically relevant to THIS subject was
    /// among them (DS-22). A flat count called a WW1-eligible man who died
    /// in the war "exhaustively searched" off three unrelated sources while
    /// CWGC — the one place he'd actually be — was never run.
    private static func criterion1ExhaustiveSearch(
        result: ResearchResult?, searched: Set<String>, total: Int, relevant: Set<String>
    ) -> GPSCriterion {
        guard let result, !result.searchHistory.isEmpty else {
            return GPSCriterion(criterion: .exhaustiveSearch, met: false, reason: "Not yet researched")
        }
        let threshold = min(3, total)
        let countMet = searched.count >= threshold
        // Relevance gate: the subject-specific must-search sources have to be
        // covered before the search counts as reasonably exhaustive.
        let missingRelevant = relevant.subtracting(searched)
        if !missingRelevant.isEmpty {
            let names = missingRelevant.sorted().joined(separator: ", ")
            let label = missingRelevant.count == 1 ? "the most relevant source" : "relevant sources"
            return GPSCriterion(
                criterion: .exhaustiveSearch, met: false,
                reason: "Searched \(searched.count) of \(total), but \(label) for this subject not yet searched: \(names)")
        }
        return GPSCriterion(
            criterion: .exhaustiveSearch,
            met: countMet,
            reason: countMet
                ? "Searched \(searched.count) of \(total) sources"
                : "Only \(searched.count) of \(total) sources searched (need \(threshold))"
        )
    }

    /// Sources that SHOULD be searched for a subject given deterministic
    /// eligibility signals (DS-22), intersected with what the run could
    /// actually reach so we never demand an unavailable source:
    ///   • war graves (CWGC) — a non-female subject who was WW1/WW2 service-
    ///     age OR died inside a war window; the single most probative source
    ///     for a war-era death;
    ///   • a census source (FreeCen) — anyone alive across a public census;
    ///   • a parish source (FreeREG) — a pre-civil-registration (<1837) birth.
    static func relevantSourceIDs(
        birthYear: Int?, deathYear: Int?, gender: Gender?, available: Set<String>
    ) -> Set<String> {
        var relevant: Set<String> = []
        let inWarWindow = { (y: Int) in (1914...1918).contains(y) || (1939...1945).contains(y) }
        let eligibleByBirth = birthYear.map { !ScoringRules.militaryEligible(birthYear: $0, gender: gender).isEmpty } ?? false
        let diedInWar = deathYear.map(inWarWindow) ?? false
        if gender != .female, eligibleByBirth || diedInWar {
            relevant.insert("cwgc")
        }
        if let by = birthYear, by <= 1921 { relevant.insert("freecen") }
        if ScoringRules.preRegistrationBirth(birthYear) { relevant.insert("freereg") }
        return relevant.intersection(available)
    }

    // MARK: - Criterion 2: Complete and Accurate Citations

    /// Met if all confirmed facts have a *complete* citation — a resolvable
    /// locator, not merely a sourceID (DS-21).
    private static func criterion2Citations(result: ResearchResult?) -> GPSCriterion {
        guard let result, !result.confirmedFacts.isEmpty else {
            return GPSCriterion(criterion: .completeCitations, met: false, reason: "No confirmed facts")
        }
        let cited = result.confirmedFacts.filter { scored in
            !scored.record.sourceID.isEmpty && Self.hasCompleteCitation(scored.record)
        }
        let met = cited.count == result.confirmedFacts.count
        return GPSCriterion(
            criterion: .completeCitations,
            met: met,
            reason: met
                ? "All \(cited.count) facts have complete citations"
                : "\(cited.count) of \(result.confirmedFacts.count) facts have a complete citation (\(result.confirmedFacts.count - cited.count) missing a locator)"
        )
    }

    /// DS-21: a confirmed fact is *completely* cited only when it carries a
    /// resolvable locator, not just a sourceID — every plugin stamps a
    /// non-empty sourceID, so the old presence check degenerated to "has any
    /// confirmed fact". A detail URL always qualifies; otherwise the source's
    /// structured reference must be present: BMD volume+page (or district), a
    /// census district/address, a memorial/cemetery, a probate address/date, a
    /// parish, or a military service number / regiment / grave. Reporting-only
    /// (GPS is an audit surface, not an apply gate), so a missing locator
    /// lowers the reported score rather than blocking anything.
    static func hasCompleteCitation(_ record: SourceRecord) -> Bool {
        if let url = record.detailURL, !url.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        func present(_ s: String?) -> Bool {
            !(s ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        switch record {
        case .birth(let r):    return (present(r.volume) && present(r.page)) || present(r.district)
        case .death(let r):    return (present(r.volume) && present(r.page)) || present(r.district)
        case .marriage(let r): return (present(r.volume) && present(r.page)) || present(r.district)
        case .census(let r):   return present(r.district) || present(r.address)
        case .burial(let r):   return r.memorialID != nil || present(r.cemetery) || present(r.burialLocation)
        case .probate(let r):  return present(r.address) || present(r.probateDate)
        case .parish(let r):   return present(r.parish)
        case .military(let r): return present(r.serviceNumber) || present(r.regiment) || present(r.cemetery) || present(r.graveRef)
        default:               return !record.rawFields.isEmpty
        }
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
