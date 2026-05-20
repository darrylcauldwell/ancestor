import Foundation

/// Static catchment map for England & Wales District Probate Registries.
/// Each registry maps to the set of UK Chapman codes whose probate grants
/// typically pass through it.
///
/// Used by `RecordScorer.checkGeography` to validate Probate Calendar
/// records when the Nuxeo response omits the estate address — common for
/// post-1996 digital grants. The registry name (`registryofficename` in
/// the Nuxeo response → `ProbateRecord.registry`) gives us record-side
/// geographic context that the address field doesn't.
///
/// Data is approximate. Registry catchments evolved over time and grants
/// can be filed at any registry on request, so absence of overlap is a
/// soft signal, not a hard fail. The conservative rule:
/// - catchment overlaps subject's home Chapman code → pass
/// - catchment exists but doesn't overlap → fall through to weaker
///   signals (deathLocation match, soft-fail "no location data") rather
///   than hard-failing
/// - registry not in our table → fall through identically
///
/// Sources: HMCRS public catchment guidance (post-2014 reorganisation)
/// and historical district probate registry geography. Codes use the
/// UK Chapman scheme (DBY = Derbyshire, LAN = Lancashire, etc).
nonisolated struct ProbateRegistryCatchment {

    /// Lowercased registry name → set of Chapman codes covered.
    nonisolated static let catchments: [String: Set<String>] = [
        "birmingham": ["WAR", "STS", "WOR"],
        "bristol":    ["SOM", "GLS", "DEV", "DOR", "WIL", "CON"],
        "cardiff":    ["GLA", "MON", "BRE", "CMN", "CAE", "PEM",
                       "RAD", "MGY", "DEN", "FLN", "AGY", "MER"],
        "ipswich":    ["SFK", "NFK"],
        "leeds":      ["ERY", "NRY", "WRY", "YKS"],
        "liverpool":  ["LAN", "CHS"],
        "london":     ["LND", "MDX", "KEN", "SRY", "ESS", "HAM"],
        "manchester": ["LAN", "CHS", "DBY", "CUL", "WES", "GTM"],
        "newcastle":  ["NBL", "DUR"],
        "oxford":     ["OXF", "BKM", "BRK"],
        "winchester": ["HAM", "DOR", "IOW"],
    ]

    /// Returns the catchment for a registry name, case-insensitive.
    /// Returns `nil` when the registry isn't in our table — callers
    /// fall back to other geographic signals rather than treating an
    /// unknown registry as a fail.
    nonisolated static func chapmanCodes(forRegistry registry: String?) -> Set<String>? {
        guard let raw = registry?
            .trimmingCharacters(in: .whitespaces)
            .lowercased(), !raw.isEmpty else { return nil }
        // Some registry names have qualifiers (e.g. "Manchester District
        // Probate Registry"). Try the full string first, then fall back
        // to the leading token.
        if let direct = catchments[raw] { return direct }
        let firstToken = raw.split(separator: " ").first.map(String.init) ?? raw
        return catchments[firstToken]
    }

    /// True when the named registry's catchment overlaps the subject's
    /// home Chapman code. Returns false when the registry is unknown or
    /// the catchment doesn't include the subject — caller should fall
    /// through to weaker signals rather than treating false as a hard fail.
    nonisolated static func overlaps(registry: String?, homeChapmanCode: String) -> Bool {
        guard let catchment = chapmanCodes(forRegistry: registry) else { return false }
        return catchment.contains(homeChapmanCode.uppercased())
    }
}
