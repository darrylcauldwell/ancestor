import Foundation
import AncestorKit

/// CONFLICT_LAYER_SPEC — the deterministic logic behind every conflict-
/// resolution control in the UI pass (choose-parent, discard-event,
/// clear-death, G12 proposal derivation). Views call these; tests pin
/// them. Every action resolves the owning dispute in the same user
/// action and, where a candidate group is linked, contradicts rivals —
/// no partial states.

@MainActor
enum ConflictResolutionActions {

    // MARK: - F4a: choose-parent (two-mothers / two-fathers)

    /// Keep one biological parent, remove the rival edge (transaction-
    /// backed via `removeRelationship` — undo-compatible, CL6 AC5),
    /// resolve the parentRole dispute, and contradict the rival identity
    /// candidates in the linked group.
    static func chooseParent(
        subjectID: String,
        role: ParentRole,
        keepParentID: String,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws {
        let rivalEdges = snapshot.relationships.filter {
            $0.type == .parent && $0.to == subjectID
                && $0.subtype == .biological && $0.role == role
                && $0.from != keepParentID
        }
        for edge in rivalEdges {
            _ = try db.removeRelationship(id: edge.id)
        }
        let keptName = snapshot.profiles[keepParentID]?.displayName ?? keepParentID
        try db.resolveStructuralDispute(
            profileID: subjectID, kind: .parentRole, fieldKey: role.rawValue,
            resolution: .manual("kept \(role.rawValue) '\(keptName)'; rival edge(s) removed (undo-compatible)"))

        // Contradict rival identity candidates; the kept candidate's row
        // stays at its graded verdict (the human decision is recorded on
        // the dispute, not forged into a hypothesis verdict).
        let groupID = HypothesisEngine.parentIdentityGroupID(
            profileID: subjectID, role: role.rawValue)
        let keptCandidateID = HypothesisKind.parentIdentityCandidate(
            profileID: subjectID, role: role.rawValue, candidateName: keptName
        ).identityKey(subjectProfileID: subjectID)
        try db.contradictRivals(inCandidateGroup: groupID, acceptedID: keptCandidateID)
    }

    /// Keep BOTH parents (e.g. one adoptive): the tree stays as-is, the
    /// dispute records the deliberate decision so it never re-opens for
    /// these same edges (reopen is witness/value-gated).
    static func keepBothParents(
        subjectID: String,
        role: ParentRole,
        db: ProjectDatabase
    ) throws {
        try db.resolveStructuralDispute(
            profileID: subjectID, kind: .parentRole, fieldKey: role.rawValue,
            resolution: .manual("both \(role.rawValue) edges kept deliberately (e.g. biological + adoptive) — user decision"))
    }

    // MARK: - F3 / T-D: timeline resolutions

    /// The recorded death is wrong — clear the death date (the attested
    /// sources stay in field_sources as history) and resolve the timeline
    /// dispute.
    static func clearDeathDate(
        profile: Profile,
        db: ProjectDatabase
    ) throws {
        if let existing = profile.deathDate {
            _ = try db.editProfile(
                profileID: profile.id, changes: [],
                dateChanges: [(.deathDate, existing, nil)],
                source: SourceOrigin(identifier: "manual.conflict-resolution"))
        }
        try db.resolveStructuralDispute(
            profileID: profile.id, kind: .timeline, fieldKey: "death-vs-alive",
            resolution: .manual("death date cleared — the later alive-evidence stands; attested death values remain in field_sources"))
    }

    /// The offending life event belongs to someone else (wrong-person
    /// record) — delete it and resolve the owning timeline dispute.
    static func discardLifeEvent(
        _ event: LifeEvent,
        disputeFieldKey: String,
        db: ProjectDatabase
    ) throws {
        try db.deleteLifeEvent(id: event.id)
        try db.resolveStructuralDispute(
            profileID: event.profileID, kind: .timeline, fieldKey: disputeFieldKey,
            resolution: .manual("\(event.type.rawValue) \(event.date?.original ?? "") discarded — not the same person"))
    }

    // MARK: - spouseIdentity / any structural: defer + dismiss

    static func deferDispute(
        profileID: String, kind: DisputeKind, fieldKey: String,
        db: ProjectDatabase
    ) throws {
        try db.resolveStructuralDispute(
            profileID: profileID, kind: kind, fieldKey: fieldKey,
            resolution: .deferred)
    }

    static func dismissNotSamePerson(
        profileID: String, kind: DisputeKind, fieldKey: String,
        db: ProjectDatabase
    ) throws {
        try db.resolveStructuralDispute(
            profileID: profileID, kind: kind, fieldKey: fieldKey,
            resolution: .manual("dismissed — the conflicting record is not the same person"))
    }

    // MARK: - G12: proposed resolution derivation

    struct ProposedResolution: Sendable, Equatable {
        let hypothesisID: String
        let field: ProfileField
        let label: String       // "Accept 1913 — hypothesis supported (alive at 1911)"
    }

    /// ⟨G12⟩ — when an open date dispute's linked candidate group has
    /// exactly ONE `.supported` member and every rival is `.contradicted`,
    /// surface a PROPOSED resolution. Computed at display time; nothing is
    /// written until the human clicks Accept (which routes through the
    /// existing accept flow).
    static func proposedResolution(
        for disputeField: ProfileField,
        profileID: String,
        db: ProjectDatabase
    ) -> ProposedResolution? {
        let groupPrefix: String
        switch disputeField {
        case .birthDate: groupPrefix = "birthYear:"
        case .deathDate: groupPrefix = "deathYear:"
        default: return nil
        }
        guard let group = try? db.hypotheses(inCandidateGroup: groupPrefix + profileID),
              group.count >= 2 else { return nil }
        let supported = group.filter { $0.verdict == .supported }
        let contradicted = group.filter { $0.verdict == .contradicted }
        guard supported.count == 1,
              supported.count + contradicted.count == group.count,
              let winner = supported.first else { return nil }
        let valueLabel: String
        switch winner.kind {
        case .birthYearCandidate(_, let year), .deathYearCandidate(_, let year):
            valueLabel = String(year)
        default:
            return nil
        }
        return ProposedResolution(
            hypothesisID: winner.id,
            field: disputeField,
            label: "Accept \(valueLabel) — hypothesis supported (\(winner.reasoning.prefix(80)))")
    }
}
