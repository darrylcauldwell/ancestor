import Foundation

/// Top-level container for a family tree research project.
/// Each project is a self-contained SQLite database.
public nonisolated struct Project: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var source: DataSource
    public var homePersonID: String?       // Anchor profile — the person whose tree this is
    public var createdAt: Date
    public var lastRefreshed: Date?
    public var archivedAt: Date?           // nil = active; non-nil = archived at that moment
    /// Project-wide Chapman code (e.g. "DBY", "YKS"). The user picks this
    /// at project creation as a hint for trees dominated by one historical
    /// county. nil = unset; per-subject derivation in `ResearchSubject`
    /// prefers the subject's own birth-location data and only falls back
    /// here when the profile carries no location. **No hardcoded
    /// Derbyshire default** — `feedback_no_hardcoded_regions`.
    public var homeChapmanCode: String?

    /// Per-project Discovery expansion bound (ENGINE_FOUNDATION_SPEC
    /// §Change7). nil = use the engine default (`ExpansionPolicy.default`,
    /// generational distance ≤ 4). Set here to override — the value is
    /// persisted in `project_meta.expansion_policy` as a compact wire
    /// string (e.g. `"collateral:2"`). Bounds how far from the probands
    /// Discovery is allowed to promote leads; never affects scorer
    /// verdicts.
    public var expansionPolicy: ExpansionPolicy?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, name: String, source: DataSource, homePersonID: String? = nil, createdAt: Date, lastRefreshed: Date? = nil, archivedAt: Date? = nil, homeChapmanCode: String? = nil, expansionPolicy: ExpansionPolicy? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.homePersonID = homePersonID
        self.createdAt = createdAt
        self.lastRefreshed = lastRefreshed
        self.archivedAt = archivedAt
        self.homeChapmanCode = homeChapmanCode
        self.expansionPolicy = expansionPolicy
    }

    /// The effective policy — the project override or the engine default.
    public var effectiveExpansionPolicy: ExpansionPolicy {
        expansionPolicy ?? .default
    }


    public var isArchived: Bool { archivedAt != nil }

    /// Resolved home Chapman code as a non-nil string. Empty string when
    /// the project has no chapman set — callers must handle empty
    /// gracefully (BiographicalFitEvaluator skips the chapman-anchor
    /// filter; SearchDispatcher / SourceParams may degrade to national
    /// scope or skip the chapman-coded probe entirely). Earlier
    /// implementations defaulted to "DBY" here, which silently misfiltered
    /// non-Derbyshire profiles (`feedback_no_hardcoded_regions`).
    public var resolvedHomeChapmanCode: String { homeChapmanCode ?? "" }
}

public nonisolated enum DataSource: Codable, Sendable {
    case gedcom(path: String)
    case wikitree(email: String)
    case manual                     // Started from scratch — no external source
}
