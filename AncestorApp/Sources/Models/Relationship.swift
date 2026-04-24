import Foundation

/// An edge in the family graph. UUID id is required because
/// FieldChange.entityID references this for relationship changes.
struct Relationship: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let from: String
    let to: String
    let type: RelationshipType
    let role: ParentRole?
    let subtype: RelationshipSubtype
    let marriageDate: GenealogicalDate?
    let divorceDate: GenealogicalDate?
}

enum RelationshipType: String, Codable, Sendable {
    case parent
    case spouse
}

enum ParentRole: String, Codable, Sendable {
    case father
    case mother
    case unspecified
}

enum RelationshipSubtype: String, Codable, Sendable {
    case biological
    case adoptive
    case step
    case unknown
}
