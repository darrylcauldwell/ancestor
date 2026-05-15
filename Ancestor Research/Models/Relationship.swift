import Foundation

/// An edge in the family graph. UUID id is required because
/// FieldChange.entityID references this for relationship changes.
nonisolated struct Relationship: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let from: String
    let to: String
    let type: RelationshipType
    let role: ParentRole?
    let subtype: RelationshipSubtype
    let marriageDate: GenealogicalDate?
    let marriageLocation: String?
    /// Structured gazetteer ID (e.g. "DBY:Crich") chosen via LocationPicker on
    /// the marriage location field. nil for freeform entries.
    let marriageLocationCode: String?
    let divorceDate: GenealogicalDate?

    /// Explicit memberwise init with `marriageLocationCode` defaulted so
    /// pre-existing call sites keep compiling without churn.
    init(
        id: UUID,
        from: String,
        to: String,
        type: RelationshipType,
        role: ParentRole?,
        subtype: RelationshipSubtype,
        marriageDate: GenealogicalDate?,
        marriageLocation: String?,
        marriageLocationCode: String? = nil,
        divorceDate: GenealogicalDate?
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.type = type
        self.role = role
        self.subtype = subtype
        self.marriageDate = marriageDate
        self.marriageLocation = marriageLocation
        self.marriageLocationCode = marriageLocationCode
        self.divorceDate = divorceDate
    }
}

nonisolated enum RelationshipType: String, Codable, Sendable {
    case parent
    case spouse
}

nonisolated enum ParentRole: String, Codable, Sendable {
    case father
    case mother
    case unspecified
}

nonisolated enum RelationshipSubtype: String, Codable, Sendable {
    case biological
    case adoptive
    case step
    case unknown
}
