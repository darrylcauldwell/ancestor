import Foundation

/// An edge in the family graph. UUID id is required because
/// FieldChange.entityID references this for relationship changes.
public nonisolated struct Relationship: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let from: String
    public let to: String
    public let type: RelationshipType
    public let role: ParentRole?
    public let subtype: RelationshipSubtype
    public let marriageDate: GenealogicalDate?
    public let marriageLocation: String?
    /// Structured gazetteer ID (e.g. "DBY:Crich") chosen via LocationPicker on
    /// the marriage location field. nil for freeform entries.
    public let marriageLocationCode: String?
    public let divorceDate: GenealogicalDate?

    /// Explicit memberwise init with `marriageLocationCode` defaulted so
    /// pre-existing call sites keep compiling without churn.
    public init(
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

public nonisolated enum RelationshipType: String, Codable, Sendable {
    case parent
    case spouse
}

public nonisolated enum ParentRole: String, Codable, Sendable {
    case father
    case mother
    case unspecified
}

public nonisolated enum RelationshipSubtype: String, Codable, Sendable {
    case biological
    case adoptive
    case step
    case unknown
}
