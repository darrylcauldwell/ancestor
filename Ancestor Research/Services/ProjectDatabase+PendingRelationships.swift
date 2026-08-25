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
        let (edgeID, _) = try addRelationshipIfAbsent(rel, existenceEvidence: evidence)

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

    private func setPendingRelationshipStatus(id: String, status: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE pending_relationships SET review_status = ? WHERE id = ?
                """, arguments: [status, id])
        }
    }
}
