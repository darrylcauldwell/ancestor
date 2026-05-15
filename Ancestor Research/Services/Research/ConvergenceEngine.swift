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

        // Evidence directness cap
        return adjustForDirectness(base: baseLevel, records: records, sourceInfoMap: sourceInfoMap)
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
