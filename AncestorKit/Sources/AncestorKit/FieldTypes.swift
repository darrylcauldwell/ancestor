import Foundation

/// Type-safe profile field identifiers.
public nonisolated enum ProfileField: String, Codable, CaseIterable, Hashable, Sendable {
    case firstName, middleName, lastName, marriedSurname, nickName, mothersMaidenName, gender
    case birthDate, birthLocation
    case deathDate, deathLocation
    case bio
}

/// Type-safe relationship field identifiers.
public nonisolated enum RelationshipField: String, Codable, Hashable, Sendable {
    case marriageDate, marriageLocation, divorceDate, subtype, role
}

/// Union of profile and relationship fields for FieldChange.
public nonisolated enum ChangeField: Codable, Hashable, Sendable {
    case profile(ProfileField)
    case relationship(RelationshipField)
}

/// A single source supporting a field value. Multiple sources per field
/// provide corroboration — "birth date confirmed by GEDCOM and FreeBMD".
///
/// Per DESIGN.md §5.12 + §5.14, a FieldSource may carry a structured
/// `Citation`, an `EvidenceQuality` rating, and a `FactConfidence`.
/// All three are optional — most manual entries skip them.
public nonisolated struct FieldSource: Codable, Hashable, Sendable {
    public let origin: SourceOrigin
    public let raw: String
    public let addedAt: Date
    public var citation: Citation?
    public var quality: EvidenceQuality?
    public var confidence: FactConfidence?

    /// Convenience init keeping existing call sites working — every new
    /// optional defaults to nil.
    public init(
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
public nonisolated struct FieldDispute: Codable, Hashable, Sendable {
    public let field: ProfileField
    public let reason: DisputeReason
    public let competingSources: [FieldSource]
    public let detectedAt: Date
    public var resolution: DisputeResolution?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(field: ProfileField, reason: DisputeReason, competingSources: [FieldSource], detectedAt: Date, resolution: DisputeResolution? = nil) {
        self.field = field
        self.reason = reason
        self.competingSources = competingSources
        self.detectedAt = detectedAt
        self.resolution = resolution
    }

}

public nonisolated enum DisputeReason: String, Codable, Sendable {
    case noOverlap
    case approximateOverlap
    case valueMismatch
}

public nonisolated enum DisputeResolution: Codable, Hashable, Sendable {
    case accepted(FieldSource)
    case manual(String)
    case deferred
}

public nonisolated enum Gender: String, Codable, Sendable {
    case male, female, other, unknown
}
