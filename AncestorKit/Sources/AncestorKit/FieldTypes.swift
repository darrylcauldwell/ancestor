import Foundation

/// Type-safe profile field identifiers.
public nonisolated enum ProfileField: String, Codable, CaseIterable, Hashable, Sendable {
    case firstName, middleName, lastName, marriedSurname, nickName, mothersMaidenName, gender
    case birthDate, birthLocation
    case deathDate, deathLocation
    case bio
    /// Typed repeatable name forms (MODEL_EVOLUTION_SPEC §Change2 / E2 AC5).
    /// Present so `Profile.nameForms` provenance is journalled at a single
    /// whole-list granularity through `field_sources`/`field_changes`, exactly
    /// like every other field. It is **not** a scalar string field and **not** a
    /// completeness target: the string-projection switches return `nil` for it
    /// (as they already do for date fields), and the completeness engine's
    /// curated missing-field list never includes it, so no spurious "missing
    /// name variants" task is generated.
    case nameForms
}

/// Type-safe relationship field identifiers.
public nonisolated enum RelationshipField: String, Codable, Hashable, Sendable {
    case marriageDate, marriageLocation, divorceDate, subtype, role
    /// Provenance for the edge existing *at all* — MODEL_EVOLUTION_SPEC
    /// §Change4 / E4. Not a value-carrying field: `existence` rows in
    /// `field_sources` answer "why do we believe this parent/spouse/child
    /// edge exists?" by citing the driving record. Additive raw value —
    /// Codable-safe, and decoded only when an existence row is present, so
    /// legacy edges (which have none) are unaffected. Written **forward-only**
    /// (decision log #4): edges created before E4 are never backfilled, which
    /// would fabricate evidence never captured.
    case existence
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
