/// Source origin as a struct with static constants.
/// Adding a new source is one line — no schema migration, no Hashable trap.
struct SourceOrigin: Codable, Hashable, Sendable {
    let identifier: String

    static let gedcom = SourceOrigin(identifier: "gedcom")
    static let wikitree = SourceOrigin(identifier: "wikitree")
    static let freebmd = SourceOrigin(identifier: "freebmd")
    static let freecen = SourceOrigin(identifier: "freecen")
    static let freereg = SourceOrigin(identifier: "freereg")
    static let familysearch = SourceOrigin(identifier: "familysearch")
    static let cwgc = SourceOrigin(identifier: "cwgc")
    static let manual = SourceOrigin(identifier: "manual")
}
