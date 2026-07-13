import Foundation

/// Metadata about a source needed for convergence scoring.
/// Extracted from the registry at the call site (on MainActor)
/// and passed to the nonisolated scoring functions.
nonisolated struct SourceInfo: Sendable {
    let sourceID: String
    let lineage: SourceLineage
    let trustTier: SourceTrustTier
    let directness: EvidenceDirectness
}

/// Scores corroboration between sources, accounting for source independence.
/// Two FreeBMD entries from different districts are ONE lineage.
/// FreeBMD + FamilySearch are TWO lineages.
/// Three derivative sources agreeing is weaker than one primary source.
nonisolated struct ConvergenceEngine {

    /// Score how strongly a value is corroborated by the supporting records.
    /// `sourceInfoMap` provides source metadata keyed by sourceID.
    static func score(
        records: [SourceRecord],
        sourceInfoMap: [String: SourceInfo]
    ) -> ConvergenceLevel {
        guard !records.isEmpty else { return .uncorroborated }
        if records.count == 1 { return .singleSource }

        // Group by source lineage — independent agreements count
        let lineageSet: Set<SourceLineage> = Set(records.compactMap { record in
            sourceInfoMap[record.common.sourceID]?.lineage
        })

        // Trust-weighted score
        let trustScore = records.reduce(0.0) { sum, record in
            sum + Double(sourceInfoMap[record.common.sourceID]?.trustTier.rawValue ?? 1)
        }

        let independentCount = lineageSet.count

        // Base level from independence and trust
        let baseLevel: ConvergenceLevel
        switch (independentCount, trustScore) {
        case (let n, _) where n >= 3: baseLevel = .confirmed
        case (2, let s) where s >= 4: baseLevel = .probable
        case (2, _): baseLevel = .possible
        case (1, _) where records.count >= 2: baseLevel = .possible
        default: baseLevel = .singleSource
        }

        // Slice 7: surname-rarity demotion. Common-surname matches need
        // more corroboration than the baseline because the signal-to-
        // noise ratio is genuinely lower — many people are called Smith,
        // so 3 lineages agreeing on "Smith Belper 1885" carry less
        // identifying weight than 3 lineages agreeing on "Cauldwell
        // Belper 1885". Demote one level for common surnames.
        let surnames = records.compactMap { $0.common.surname }
        let rarity = SurnameRarityRegistry.predominantRarity(among: surnames)
        let rarityAdjusted = applyRarityDemotion(baseLevel, rarity: rarity)

        // Evidence directness cap
        return adjustForDirectness(base: rarityAdjusted, records: records, sourceInfoMap: sourceInfoMap)
    }

    /// Demote one convergence level when the predominant surname is in
    /// the top-100 common-surname tier. Floor at `.singleSource` —
    /// rarity never makes a multi-record set look worse than a
    /// single-source claim.
    private static func applyRarityDemotion(
        _ base: ConvergenceLevel,
        rarity: SurnameRarity
    ) -> ConvergenceLevel {
        guard rarity == .common else { return base }
        switch base {
        case .confirmed:    return .probable
        case .probable:     return .possible
        case .possible:     return .singleSource
        case .singleSource, .uncorroborated:
            return base
        }
    }

    /// Produce a `SourcingStrength` summary for a set of source records.
    /// `RESEARCH_CONFIDENCE_SPEC` §3.2 — one of three independent confidence
    /// axes, surfaced directly in the new ConfidenceBadgeView. Uses the same
    /// lineage-grouping rules as `score(records:sourceInfoMap:)` so the
    /// "cross-referenced" threshold aligns across all consumers.
    static func sourcingStrength(
        records: [SourceRecord],
        sourceInfoMap: [String: SourceInfo]
    ) -> SourcingStrength {
        let lineageSet: Set<SourceLineage> = Set(records.compactMap { record in
            sourceInfoMap[record.common.sourceID]?.lineage
        })
        let topTier: SourceTrustTier = records.reduce(.community) { acc, record in
            let tier = sourceInfoMap[record.common.sourceID]?.trustTier ?? .community
            return max(acc, tier)
        }
        return SourcingStrength(
            sourceCount: records.count,
            independentLineageCount: lineageSet.count,
            topTrustTier: topTier
        )
    }

    /// Cluster-shaped overload — delegates to the record-array path. Kept so
    /// existing callers (LifeCluster.evidenceConfidence) don't have to know
    /// the projection.
    static func sourcingStrength(
        for cluster: LifeCluster,
        sourceInfoMap: [String: SourceInfo]
    ) -> SourcingStrength {
        sourcingStrength(records: cluster.records.map(\.record), sourceInfoMap: sourceInfoMap)
    }

    /// Cap convergence level if all supporting evidence is derivative.
    private static func adjustForDirectness(
        base: ConvergenceLevel,
        records: [SourceRecord],
        sourceInfoMap: [String: SourceInfo]
    ) -> ConvergenceLevel {
        let directnessScores = records.compactMap { record in
            sourceInfoMap[record.common.sourceID]?.directness
        }
        let hasPrimaryOrDirect = directnessScores.contains { $0 >= .directTranscription }
        let hasPrimary = directnessScores.contains { $0 == .primary }

        // All derivative → cap at .possible
        if !hasPrimaryOrDirect && base > .possible { return .possible }
        // No primary → cap at .probable
        if !hasPrimary && base > .probable { return .probable }
        return base
    }
}

/// Extension on SourceRegistry to extract SourceInfo map on MainActor.
extension SourceRegistry {
    /// Build a SourceInfo lookup map from the registry.
    /// Call this on MainActor, then pass to nonisolated convergence functions.
    func buildSourceInfoMap() -> [String: SourceInfo] {
        var map: [String: SourceInfo] = [:]
        for (id, source) in sources {
            map[id] = SourceInfo(
                sourceID: id,
                lineage: source.dataLineage,
                trustTier: source.trustTier,
                directness: source.evidenceDirectness
            )
        }
        return map
    }
}


// MARK: - Value-group scoring (CONFLICT_LAYER_SPEC CL3, DS-20/DS-24)

nonisolated extension ConvergenceEngine {

    /// One asserted value and the convergence its OWN records earn.
    struct ValueGroup: Sendable {
        let key: String              // "birth:1881", "death:1905", "marriage:?"
        let records: [SourceRecord]
        let level: ConvergenceLevel
    }

    /// Partition records by the VALUE they assert, then score each group
    /// independently — contradicting values can no longer pool into one
    /// inflated convergence level (DS-24: birth 1881 + census-implied 1895
    /// previously counted as mutual corroboration).
    ///
    /// Interim note (§4.5, stated per spec): group scoring still uses
    /// lineage counting; witness-counted convergence arrives with CL4.
    static func scoreValueGroups(
        records: [SourceRecord],
        sourceInfoMap: [String: SourceInfo]
    ) -> [ValueGroup] {
        var groups: [String: [SourceRecord]] = [:]
        for record in records {
            groups[valueKey(for: record), default: []].append(record)
        }
        return groups
            .map { key, members in
                ValueGroup(key: key, records: members,
                           level: score(records: members, sourceInfoMap: sourceInfoMap))
            }
            .sorted { $0.key < $1.key }
    }

    /// Deterministic value key: event shape + the year the record asserts
    /// for that shape. Census records assert an IMPLIED BIRTH year — the
    /// exact channel DS-24 showed pooling against contradicting birth
    /// records. Unknown years form their own per-shape bucket.
    static func valueKey(for record: SourceRecord) -> String {
        switch record {
        case .birth(let r):    return "birth:\(r.birthYear.map(String.init) ?? "?")"
        case .census(let r):   return "birth:\(r.birthYear.map(String.init) ?? "?")"
        case .death(let r):    return "death:\(r.deathYear.map(String.init) ?? "?")"
        case .burial(let r):   return "death:\(r.deathYear.map(String.init) ?? "?")"
        case .marriage(let r): return "marriage:\(r.marriageYear.map(String.init) ?? "?")"
        case .parish(let r):
            let kind = (r.eventType ?? "parish").lowercased()
            let shape = kind == "baptism" ? "birth" : kind
            return "\(shape):\(r.eventYear.map(String.init) ?? "?")"
        default:
            return "other:\(record.id)"
        }
    }
}
