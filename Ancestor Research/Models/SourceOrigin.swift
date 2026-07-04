/// Source origin as a struct with static constants.
/// Adding a new source is one line — no schema migration, no Hashable trap.
nonisolated struct SourceOrigin: Codable, Hashable, Sendable {
    let identifier: String

    static let gedcom = SourceOrigin(identifier: "gedcom")
    static let wikitree = SourceOrigin(identifier: "wikitree")
    static let freebmd = SourceOrigin(identifier: "freebmd")
    static let freecen = SourceOrigin(identifier: "freecen")
    static let freereg = SourceOrigin(identifier: "freereg")
    static let familysearch = SourceOrigin(identifier: "familysearch")
    static let cwgc = SourceOrigin(identifier: "cwgc")
    static let manual = SourceOrigin(identifier: "manual")
    static let manualMemory = SourceOrigin(identifier: "manual.memory")
    static let manualDocument = SourceOrigin(identifier: "manual.document")
    static let manualRecord = SourceOrigin(identifier: "manual.record")
    static let manualEstimate = SourceOrigin(identifier: "manual.estimate")
    /// Internal engine-derived enrichment — used by the thin-placeholder
    /// write-back path (ENGINE_FOUNDATION_SPEC #Change2). Honest about
    /// provenance: the value was not asserted by any external source
    /// directly; the engine inferred it from consensus across multiple
    /// scored records.
    static let engineEnrichment = SourceOrigin(identifier: "engine.enrichment")

    /// Whether this is any kind of manual source.
    var isManual: Bool {
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
    var tier: SourceTier {
        if isManual { return .userAuthoritative }
        if identifier == "gedcom" || identifier == "wikitree" { return .initialImport }
        return .researchSource
    }
}

/// Provenance tier for the apply-path string overwrite policy. See
/// `SourceOrigin.tier` for the categorisation.
nonisolated enum SourceTier: Int, Comparable, Sendable {
    case initialImport = 1
    case researchSource = 2
    case userAuthoritative = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
