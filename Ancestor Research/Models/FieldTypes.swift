import Foundation

/// Type-safe profile field identifiers.
nonisolated enum ProfileField: String, Codable, CaseIterable, Hashable, Sendable {
    case firstName, middleName, lastName, marriedSurname, nickName, mothersMaidenName, gender
    case birthDate, birthLocation
    case deathDate, deathLocation
    case bio
}

/// Type-safe relationship field identifiers.
nonisolated enum RelationshipField: String, Codable, Hashable, Sendable {
    case marriageDate, marriageLocation, divorceDate, subtype, role
}

/// Union of profile and relationship fields for FieldChange.
nonisolated enum ChangeField: Codable, Hashable, Sendable {
    case profile(ProfileField)
    case relationship(RelationshipField)
}

/// A single source supporting a field value. Multiple sources per field
/// provide corroboration — "birth date confirmed by GEDCOM and FreeBMD".
///
/// Per DESIGN.md §5.12 + §5.14, a FieldSource may carry a structured
/// `Citation`, an `EvidenceQuality` rating, and a `FactConfidence`.
/// All three are optional — most manual entries skip them.
nonisolated struct FieldSource: Codable, Hashable, Sendable {
    let origin: SourceOrigin
    let raw: String
    let addedAt: Date
    var citation: Citation?
    var quality: EvidenceQuality?
    var confidence: FactConfidence?

    /// Convenience init keeping existing call sites working — every new
    /// optional defaults to nil.
    init(
        origin: SourceOrigin,
        raw: String,
        addedAt: Date,
        citation: Citation? = nil,
        quality: EvidenceQuality? = nil,
        confidence: FactConfidence? = nil
    ) {
        self.origin = origin
        self.raw = raw
        self.addedAt = addedAt
        self.citation = citation
        self.quality = quality
        self.confidence = confidence
    }
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
    case male, female, other, unknown
}
