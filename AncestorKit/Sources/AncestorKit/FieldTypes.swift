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

/// What shape of conflict a dispute represents (CONFLICT_LAYER_SPEC §3/§5).
/// `fieldValue` is the classic two-values-one-field dispute the v1 machinery
/// was built for; the other kinds are structural conflicts (timeline
/// impossibilities, two identities in one biological role, a record naming a
/// spouse the tree doesn't know) that share the same persistence + surfacing.
public nonisolated enum DisputeKind: String, Codable, Sendable, CaseIterable {
    case fieldValue
    case timeline
    case parentRole
    case spouseIdentity
}

/// Which producer detected a dispute (CONFLICT_LAYER_SPEC §4.3 ⟨G6⟩,
/// persisted in `field_disputes.detected_by`). Cheap provenance that lets
/// producer coverage be audited against the detection-completeness claim.
public nonisolated enum DisputeProducer: String, Codable, Sendable {
    case applyEngine
    case runSweep
    case consistencySweep
}

/// When sources disagree on a field value, the field is disputed.
/// Preserves all competing sources so undo can restore the dispute.
///
/// CONFLICT_LAYER_SPEC §5: `kind` / `severity` / `detectedBy` are additive
/// (decode-defaulted) so JSON written before the conflict layer still
/// decodes — old blobs read back as `.fieldValue` with no severity/producer.
public nonisolated struct FieldDispute: Codable, Hashable, Sendable {
    public let field: ProfileField
    public let reason: DisputeReason
    public let competingSources: [FieldSource]
    public let detectedAt: Date
    public var resolution: DisputeResolution?
    /// Conflict shape. Defaults to `.fieldValue` (the only kind the v1
    /// machinery ever modelled) when absent from decoded JSON.
    public var kind: DisputeKind
    /// Graded severity from `DiscrepancySeverityTable` (F1/F2) or the
    /// detector's own grading (structural kinds). Nil on pre-CL1 rows.
    public var severity: DiscrepancySeverity?
    /// Producer that wrote the dispute. Nil on pre-CL1 rows.
    public var detectedBy: DisputeProducer?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(
        field: ProfileField,
        reason: DisputeReason,
        competingSources: [FieldSource],
        detectedAt: Date,
        resolution: DisputeResolution? = nil,
        kind: DisputeKind = .fieldValue,
        severity: DiscrepancySeverity? = nil,
        detectedBy: DisputeProducer? = nil
    ) {
        self.field = field
        self.reason = reason
        self.competingSources = competingSources
        self.detectedAt = detectedAt
        self.resolution = resolution
        self.kind = kind
        self.severity = severity
        self.detectedBy = detectedBy
    }

    /// Decode-defaulted custom decoder: pre-conflict-layer JSON carries no
    /// `kind`/`severity`/`detectedBy` keys and must keep decoding (§5,
    /// Change 1 acceptance criterion 7).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.field = try c.decode(ProfileField.self, forKey: .field)
        self.reason = try c.decode(DisputeReason.self, forKey: .reason)
        self.competingSources = try c.decode([FieldSource].self, forKey: .competingSources)
        self.detectedAt = try c.decode(Date.self, forKey: .detectedAt)
        self.resolution = try c.decodeIfPresent(DisputeResolution.self, forKey: .resolution)
        self.kind = try c.decodeIfPresent(DisputeKind.self, forKey: .kind) ?? .fieldValue
        self.severity = try c.decodeIfPresent(DiscrepancySeverity.self, forKey: .severity)
        self.detectedBy = try c.decodeIfPresent(DisputeProducer.self, forKey: .detectedBy)
    }
}

public nonisolated enum DisputeReason: String, Codable, Sendable {
    case noOverlap
    case approximateOverlap
    case valueMismatch
}

/// How a dispute was closed. `.rule` is CONFLICT_LAYER_SPEC §4.6 — a
/// deterministic ladder rung fired and chose a value; the rule ID is
/// recorded so GPS criterion 4 can cite it ("resolved by R2a"). Additive
/// case: old JSON (accepted/manual/deferred) decodes unchanged. No rung
/// fires in CL1 (R0 ships CL4, R2 ships CL5), so nothing writes `.rule`
/// yet — the case exists so the persistence contract is stable from the
/// first migration.
public nonisolated enum DisputeResolution: Codable, Hashable, Sendable {
    case accepted(FieldSource)
    case manual(String)
    case deferred
    case rule(id: String, accepted: FieldSource)
}

public nonisolated enum Gender: String, Codable, Sendable {
    case male, female, other, unknown
}
