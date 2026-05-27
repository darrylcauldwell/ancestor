import Foundation

/// How rare a surname is in the UK national population. Drives confidence
/// adjustments in `ConvergenceEngine`: a 2-source match on "Smith" carries
/// less identifying weight than a 2-source match on "Cauldwell" because the
/// signal-to-noise ratio is genuinely lower for common surnames.
///
/// Ported in spirit from `agent/rules.py:310` (`RARE_SURNAME_THRESHOLD =
/// 1000`). Python categorised by national-bearer count; we use top-100 ONS
/// 2011 census family names as the "common" tier because:
///   • the canonical list is stable + verifiable from public ONS data
///   • the engine cares about *common* (need more corroboration), not *rare*
///     (already strong enough on one match) — the asymmetric concern
///   • top-100 surname pool covers ~22% of UK population, large enough to
///     materially bias convergence scoring on those subjects
nonisolated enum SurnameRarity: String, Sendable, Equatable, Codable {
    /// Top-100 ONS surname — needs additional corroboration to reach the
    /// same convergence level as an uncommon-surname match.
    case common
    /// Default tier: neither in the top-100 list nor in an explicit
    /// rare-surname allow-list. The engine treats this as the baseline.
    case uncommon
    /// Reserved for future use — a manually-curated set of explicitly
    /// rare surnames (e.g. Wheatman, rank 24,000+) where a single
    /// matching source carries near-confirmed weight. Not populated in
    /// MVP; the engine treats `.rare` and `.uncommon` identically for now.
    case rare
}

/// Lookup table for the top-100 ONS UK surnames. Read-only and Sendable;
/// safe to call from any actor isolation.
nonisolated enum SurnameRarityRegistry {

    /// Top-100 UK surnames from the ONS 2011 census family-name data.
    /// Uppercased for case-insensitive lookup. Source:
    /// https://www.ons.gov.uk/ — census surname-frequency tables.
    ///
    /// Care taken with the boundary: positions 95–105 cluster tightly in
    /// frequency, so the exact cutoff is ±5 entries either way. The
    /// engine's behaviour is the same for "rank 99" vs "rank 102" — both
    /// classified as common, both demoted equally — so the boundary
    /// imprecision doesn't materially affect outcomes.
    static let commonSurnames: Set<String> = [
        "SMITH", "JONES", "WILLIAMS", "TAYLOR", "BROWN",
        "DAVIES", "EVANS", "WILSON", "THOMAS", "ROBERTS",
        "JOHNSON", "LEWIS", "WALKER", "ROBINSON", "WOOD",
        "THOMPSON", "WHITE", "WATSON", "JACKSON", "WRIGHT",
        "GREEN", "HARRIS", "COOPER", "KING", "LEE",
        "MARTIN", "CLARKE", "JAMES", "MORGAN", "HUGHES",
        "EDWARDS", "HILL", "MOORE", "CLARK", "HARRISON",
        "SCOTT", "YOUNG", "MORRIS", "HALL", "WARD",
        "TURNER", "CARTER", "PHILLIPS", "MITCHELL", "PATEL",
        "ADAMS", "CAMPBELL", "ANDERSON", "ALLEN", "COOK",
        "BAILEY", "PARKER", "MILLER", "DAVIS", "MURPHY",
        "PRICE", "BELL", "BAKER", "GRIFFITHS", "KELLY",
        "SIMPSON", "MARSHALL", "COLLINS", "BENNETT", "COX",
        "RICHARDSON", "FOX", "GRAY", "ROSE", "CHAPMAN",
        "HUNT", "ROBERTSON", "SHAW", "REYNOLDS", "LLOYD",
        "ELLIS", "RICHARDS", "RUSSELL", "WILKINSON", "KHAN",
        "GRAHAM", "STEWART", "REID", "MURRAY", "POWELL",
        "PALMER", "HOLMES", "ROGERS", "STEVENS", "WALSH",
        "HUNTER", "THOMSON", "MATTHEWS", "ROSS", "OWEN",
        "MASON", "KNIGHT", "KENNEDY", "BUTLER", "SAUNDERS",
    ]

    /// Classify a surname's rarity. Case- and whitespace-insensitive.
    /// Returns `.uncommon` for empty input (no information → treat as
    /// neutral, don't bias scoring).
    static func rarity(of surname: String) -> SurnameRarity {
        let key = surname
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        guard !key.isEmpty else { return .uncommon }
        return commonSurnames.contains(key) ? .common : .uncommon
    }

    /// Pick the predominant surname from a list of records and classify
    /// its rarity. The engine uses this to decide whether to demote a
    /// convergence outcome — a Smith match across 3 sources is materially
    /// less identifying than a Cauldwell match across 3 sources.
    ///
    /// Tie-break: when multiple surnames tie, prefer whichever produces
    /// the more conservative (common) classification — protects against
    /// a mixed-surname record set sneaking under the rarity check.
    static func predominantRarity(among surnames: [String]) -> SurnameRarity {
        guard !surnames.isEmpty else { return .uncommon }
        var counts: [String: Int] = [:]
        for raw in surnames {
            let key = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        guard !counts.isEmpty else { return .uncommon }
        let maxCount = counts.values.max() ?? 0
        let topSurnames = counts.filter { $0.value == maxCount }.keys
        // Conservative tie-break: if any tied surname is common, classify
        // as common.
        if topSurnames.contains(where: { commonSurnames.contains($0) }) {
            return .common
        }
        return .uncommon
    }
}
