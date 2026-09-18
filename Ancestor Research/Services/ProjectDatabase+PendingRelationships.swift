import Foundation
import GRDB
import AncestorKit

/// A firewall-queued relationship proposal awaiting human review (#36).
///
/// `pending_relationships` had been an ORPHANED queue since v23: MCP's
/// `submit_relationship_proposal` wrote rows "for human review" but no app
/// surface ever read them — five approved-in-good-faith Wheeldon proposals
/// simply sat there while the user hunted for a review screen that did not
/// exist (owner, 2026-08-24). This file is the missing consumer.
nonisolated struct PendingRelationship: Identifiable, Sendable {
    let id: String
    let fromProfileID: String
    let toProfileID: String
    /// "parent" | "spouse" — enforced at submit time by the MCP server.
    let relType: String
    /// "father" | "mother" | nil (parent proposals only).
    let role: String?
    let subtype: String
    /// #36 — optional marriage details a spouse proposal carries.
    let marriageDate: String?
    let marriageLocation: String?
    let sourceURL: String?
    let sourceTitle: String?
    let evidenceText: String?
    let reasoning: String?
    let createdAt: Date
}

nonisolated extension ProjectDatabase {

    /// Pending proposals where this profile is EITHER endpoint — the block
    /// renders on both people's cards, so whichever profile the user is on,
    /// the proposal is visible.
    func pendingRelationships(touching profileID: String) throws -> [PendingRelationship] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_relationships
                WHERE review_status = 'pending'
                  AND (from_profile_id = ? OR to_profile_id = ?)
                ORDER BY created_at DESC
                """, arguments: [profileID, profileID])
            return rows.map { row in
                PendingRelationship(
                    id: row["id"],
                    fromProfileID: row["from_profile_id"],
                    toProfileID: row["to_profile_id"],
                    relType: row["rel_type"],
                    role: row["role"],
                    subtype: row["subtype"] ?? "biological",
                    marriageDate: row["marriage_date"],
                    marriageLocation: row["marriage_location"],
                    sourceURL: row["source_url"],
                    sourceTitle: row["source_title"],
                    evidenceText: row["evidence_text"],
                    reasoning: row["reasoning"],
                    createdAt: row["created_at"] ?? Date()
                )
            }
        }
    }

    /// Approve a proposal: ENSURE the edge exists, then mark the row
    /// approved. Deliberately idempotent — the stranded Wheeldon proposals'
    /// edges were later added by hand, and approving those must enrich or
    /// no-op, never duplicate (`addRelationshipIfAbsent` carries the dedup).
    ///
    /// For a spouse proposal carrying marriage details, the date/location
    /// fill goes through `fillRelationshipMarriage` whether the edge is new
    /// or pre-existing — one directional overwrite policy, no second rule.
    @discardableResult
    func approvePendingRelationship(id: String) throws -> Bool {
        guard let pending = try fetchPendingRelationship(id: id) else { return false }

        let role: ParentRole? = pending.relType == "parent"
            ? ParentRole(rawValue: pending.role ?? "") ?? .unspecified
            : nil
        let subtype = RelationshipSubtype(rawValue: pending.subtype) ?? .biological
        let rel = Relationship(
            id: UUID(),
            from: pending.fromProfileID, to: pending.toProfileID,
            type: pending.relType == "spouse" ? .spouse : .parent,
            role: role, subtype: subtype,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        // Provenance is honest about what this is: a reviewed proposal, with
        // the proposal's own evidence as the note. Source-URL trust stays
        // derivable from the cited URL, never asserted.
        let evidence: RelationshipExistenceEvidence = .origin(
            SourceOrigin(identifier: "relationship-proposal.\(pending.id.prefix(12))"),
            note: [pending.evidenceText, pending.sourceTitle]
                .compactMap { $0 }.joined(separator: " — ")
        )
        // EV27 — snapshot the PRE-state: the occupancy check must not see the
        // edge we are about to write.
        let pre = try buildSnapshot()
        let existingEdge = pre.relationships.first {
            $0.type == .parent
                && $0.from == pending.fromProfileID
                && $0.to == pending.toProfileID
        }
        let (edgeID, inserted) = try addRelationshipIfAbsent(rel, existenceEvidence: evidence)

        // EV27 (2026-08-26) — a parent proposal that names a role used to
        // create a SECOND parent edge for the same pair, because the dedup
        // was role-sensitive. The dedup is now (from, to, type), so the role
        // has to be reconciled here instead: fill an empty one, and record —
        // never silently apply — a genuine role CHANGE.
        if pending.relType == "parent", let proposed = role, proposed != .unspecified {
            // Review F06 (2026-08-26): `statesProposedRole` is the ONE
            // question that gates the F4a occupancy check — "when this
            // approval is finished, does an edge from this parent to this
            // child state `proposed`?" It used to be asked on the INSERT arm
            // only, so the check turned on an irrelevant precondition: an
            // external proposal naming M2 as C1's mother opened the dispute
            // when M2 had no prior edge, and opened NOTHING when M2 already
            // had a `role: .unspecified, subtype: .biological` edge — the
            // shape `ProjectDatabase+PromoteLead` (sibling/parent ghosts) and
            // `AppState.addCensusFamily` (roster row of unknown sex) both
            // produce routinely. The fill silently completed a two-mothers
            // state with no dispute recorded, invisible until the next
            // project open ran ConflictSweep, and `ExcessParentEdgesRule`
            // cannot see it either — that rule errors only above TWO parent
            // edges and warns only on an anonymous stub, so exactly two NAMED
            // mothers raises nothing at all.
            // External input must never be able to create a contradiction the
            // app does not record — so the fill arm now asks what the insert
            // arm asks, which is also what `ApplyEngine` does on BOTH its
            // `.matched` (link-existing) and `.noMatch` (create-new) arms.
            var statesProposedRole = inserted
            if !inserted, let existingEdge {
                switch existingEdge.role {
                case .none, .some(.unspecified):
                    // Fill-only: the check-before-overwrite rule's "only where
                    // the current value is empty" arm, the same policy
                    // `fillRelationshipMarriage` applies below.
                    _ = try setRelationshipRole(relationshipID: edgeID, role: proposed)
                    statesProposedRole = true
                case .some(let current) where current != proposed:
                    // A role CHANGE on an existing edge is neither a duplicate
                    // nor something an approval may do silently. Leave the
                    // edge alone and record the disagreement; the human
                    // re-roles with the in-row Father/Mother menu. The edge
                    // keeps `current`, so no NEW occupant of `proposed` is
                    // created — the F4a check deliberately does not run here.
                    try recordParentRoleDispute(
                        subjectID: pending.toProfileID, role: current,
                        occupantEdge: existingEdge,
                        occupant: pre.profiles[pending.fromProfileID],
                        proposedDescription: "same parent re-roled \(current.rawValue) → \(proposed.rawValue)",
                        pending: pending, reassignment: true)
                default:
                    // The edge already states `proposed` — nothing to write,
                    // but the state it affirms may still be two-mothers, and
                    // `upsertDispute` is idempotent on (entity, kind, field).
                    statesProposedRole = true
                }
            }
            if statesProposedRole,
               let occupied = ConflictDetector.occupiedBiologicalRole(
                   subjectID: pending.toProfileID, role: proposed,
                   excludingParentID: pending.fromProfileID, snapshot: pre) {
                // F4a parity with `ApplyEngine.openParentRoleDisputeIfOccupied`:
                // a SECOND, DIFFERENT person accepted into an occupied
                // biological role. Both edges stand (when in doubt, split) —
                // the two-mothers state just can no longer be invisible.
                try recordParentRoleDispute(
                    subjectID: pending.toProfileID, role: proposed,
                    occupantEdge: occupied.edge, occupant: occupied.occupant,
                    proposedDescription: pre.profiles[pending.fromProfileID]?.displayName
                        ?? pending.fromProfileID,
                    pending: pending, reassignment: false)
            }
        }

        if pending.relType == "spouse",
           pending.marriageDate != nil || pending.marriageLocation != nil {
            _ = try fillRelationshipMarriage(
                relationshipID: edgeID,
                candidateDate: pending.marriageDate.map { GenealogicalDate(parsing: $0) },
                candidateLocation: pending.marriageLocation
            )
        }

        try setPendingRelationshipStatus(id: id, status: "approved")
        return true
    }

    /// Reject a proposal — recorded verdict, never re-proposed (the submit
    /// path's idempotency key keeps a resubmission landing on this same,
    /// now-rejected row).
    func rejectPendingRelationship(id: String) throws {
        try setPendingRelationshipStatus(id: id, status: "rejected")
    }

    private func fetchPendingRelationship(id: String) throws -> PendingRelationship? {
        try pendingRelationshipsAll(matching: id).first
    }

    private func pendingRelationshipsAll(matching id: String) throws -> [PendingRelationship] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_relationships
                WHERE id = ? AND review_status = 'pending'
                """, arguments: [id])
            return rows.map { row in
                PendingRelationship(
                    id: row["id"],
                    fromProfileID: row["from_profile_id"],
                    toProfileID: row["to_profile_id"],
                    relType: row["rel_type"],
                    role: row["role"],
                    subtype: row["subtype"] ?? "biological",
                    marriageDate: row["marriage_date"],
                    marriageLocation: row["marriage_location"],
                    sourceURL: row["source_url"],
                    sourceTitle: row["source_title"],
                    evidenceText: row["evidence_text"],
                    reasoning: row["reasoning"],
                    createdAt: row["created_at"] ?? Date()
                )
            }
        }
    }

    /// SC-6 — pending-proposal counts per touched profile (both endpoints
    /// count), for the Workbench needs-attention router.
    func pendingRelationshipCountsByProfile() -> [String: Int] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT from_profile_id, to_profile_id FROM pending_relationships
                WHERE review_status = 'pending'
                """)
            var counts: [String: Int] = [:]
            for row in rows {
                counts[row["from_profile_id"] as String, default: 0] += 1
                counts[row["to_profile_id"] as String, default: 0] += 1
            }
            return counts
        }) ?? [:]
    }

    /// EV27 — open (or join) the parent-role dispute an approval surfaced.
    /// `reassignment` picks the shape: a re-role of the SAME parent's edge,
    /// or F4a's two-different-parents-in-one-role. Either way the proposal is
    /// still marked approved by the caller — the user acted, and leaving it
    /// pending would re-prompt forever.
    private func recordParentRoleDispute(
        subjectID: String, role: ParentRole,
        occupantEdge: Relationship, occupant: Profile?,
        proposedDescription: String, pending: PendingRelationship,
        reassignment: Bool
    ) throws {
        guard let occupant else { return }
        let origin = SourceOrigin(identifier: "relationship-proposal.\(pending.id.prefix(12))")
        let conflict = reassignment
            ? ConflictDetector.parentRoleReassignmentConflict(
                subjectID: subjectID, currentRole: role, occupant: occupant,
                occupantEdge: occupantEdge, proposedDescription: proposedDescription,
                proposedOrigin: origin)
            : ConflictDetector.parentRoleConflict(
                subjectID: subjectID, role: role, occupant: occupant,
                occupantEdge: occupantEdge,
                proposedParentDescription: proposedDescription,
                proposedParentOrigin: origin, evidenceRecordIDs: [])
        _ = try upsertDispute(
            profileID: subjectID, conflict: conflict,
            adjudication: DisputeResolver.adjudicate(conflict))
    }

    private func setPendingRelationshipStatus(id: String, status: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE pending_relationships SET review_status = ? WHERE id = ?
                """, arguments: [status, id])
        }
    }
}
