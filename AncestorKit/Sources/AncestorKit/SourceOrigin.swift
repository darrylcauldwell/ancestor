/// Source origin as a struct with static constants.
/// Adding a new source is one line — no schema migration, no Hashable trap.
public nonisolated struct SourceOrigin: Codable, Hashable, Sendable {
    public let identifier: String

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(identifier: String) {
        self.identifier = identifier
    }


    public static let gedcom = SourceOrigin(identifier: "gedcom")
    public static let wikitree = SourceOrigin(identifier: "wikitree")
    public static let freebmd = SourceOrigin(identifier: "freebmd")
    public static let freecen = SourceOrigin(identifier: "freecen")
    public static let freereg = SourceOrigin(identifier: "freereg")
    public static let familysearch = SourceOrigin(identifier: "familysearch")
    public static let cwgc = SourceOrigin(identifier: "cwgc")
    public static let manual = SourceOrigin(identifier: "manual")
    public static let manualMemory = SourceOrigin(identifier: "manual.memory")
    public static let manualDocument = SourceOrigin(identifier: "manual.document")
    public static let manualRecord = SourceOrigin(identifier: "manual.record")
    public static let manualEstimate = SourceOrigin(identifier: "manual.estimate")
    /// Internal engine-derived enrichment — used by the thin-placeholder
    /// write-back path (ENGINE_FOUNDATION_SPEC #Change2). Honest about
    /// provenance: the value was not asserted by any external source
    /// directly; the engine inferred it from consensus across multiple
    /// scored records.
    public static let engineEnrichment = SourceOrigin(identifier: "engine.enrichment")

    /// Whether this is any kind of manual source.
    public var isManual: Bool {
        identifier == "manual" || identifier.hasPrefix("manual.")
    }

    /// Three-tier model used by the apply-path overwrite policy for string
    /// fields (see ApplyEngine.shouldOverwriteStringField). The
    /// directional "Check Before Overwrite" rule (per
    /// feedback_check_before_overwrite.md) needs a precision axis to compare
    /// against — strings have none, so we substitute provenance:
    ///   - `userAuthoritative` (manual.*) — user investigated and decided.
    ///   - `researchSource` (freebmd, freecen, freereg, familysearch, cwgc,
    ///     parish, probate, engine.enrichment, …) — citation-grade evidence
    ///     from primary records.
    ///   - `initialImport` (gedcom, wikitree) — best-effort starting
    ///     point from third-party tree data; commonly wrong on places
    ///     (county instead of district, parish vs registration district).
    /// A higher tier overrides a lower tier. Same-tier candidates do not
    /// overwrite — they're recorded as alternative facts for evidence-log.
    public var tier: SourceTier {
        if isManual { return .userAuthoritative }
        if identifier == "gedcom" || identifier == "wikitree" { return .initialImport }
        return .researchSource
    }
}

/// Provenance tier for the apply-path string overwrite policy. See
/// `SourceOrigin.tier` for the categorisation.
public nonisolated enum SourceTier: Int, Comparable, Sendable {
    case initialImport = 1
    case researchSource = 2
    case userAuthoritative = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
