import Foundation

/// Type-safe profile field identifiers.
nonisolated enum ProfileField: String, Codable, CaseIterable, Hashable, Sendable {
    case firstName, lastName, gender
    case birthDate, birthLocation
    case deathDate, deathLocation
    case bio
}

/// Type-safe relationship field identifiers.
nonisolated enum RelationshipField: String, Codable, Hashable, Sendable {
    case marriageDate, divorceDate, subtype, role
}

/// Union of profile and relationship fields for FieldChange.
nonisolated enum ChangeField: Codable, Hashable, Sendable {
    case profile(ProfileField)
    case relationship(RelationshipField)
}

/// A single source supporting a field value. Multiple sources per field
/// provide corroboration — "birth date confirmed by GEDCOM and FreeBMD".
nonisolated struct FieldSource: Codable, Hashable, Sendable {
    let origin: SourceOrigin
    let raw: String
    let addedAt: Date
}

/// When sources disagree on a field value, the field is disputed.
/// Preserves all competing sources so undo can restore the dispute.
nonisolated struct FieldDispute: Codable, Hashable, Sendable {
    let field: ProfileField
    let reason: DisputeReason
    let competingSources: [FieldSource]
    let detectedAt: Date
    var resolution: DisputeResolution?
}

nonisolated enum DisputeReason: String, Codable, Sendable {
    case noOverlap
    case approximateOverlap
    case valueMismatch
}

nonisolated enum DisputeResolution: Codable, Hashable, Sendable {
    case accepted(FieldSource)
    case manual(String)
    case deferred
}

nonisolated enum Gender: String, Codable, Sendable {
    case male, female, unknown
}
