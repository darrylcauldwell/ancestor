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

    /// Whether this is any kind of manual source.
    var isManual: Bool {
        identifier == "manual" || identifier.hasPrefix("manual.")
    }
}
