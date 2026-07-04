import Foundation
import GRDB

/// Persistence for the pending-facts review flow (`PendingFactsReviewView`).
/// Extracted from the view (Phase 1 slice 1, ARCHITECTURE_REVIEW_2026-07.md)
/// so no SwiftUI view executes SQL directly — ProjectDatabase(+extensions)
/// is the single persistence seam.
extension ProjectDatabase {

    /// Narrative findings submitted for one profile, newest first.
    func loadNarrativeFindingRows(profileID: String) throws -> [NarrativeFindingRow] {
        try dbQueue.read { readDB in
            let rows = try Row.fetchAll(readDB, sql: """
                SELECT * FROM narrative_findings WHERE profile_id = ? ORDER BY submitted_at DESC
                """, arguments: [profileID])
            return rows.map { row in
                NarrativeFindingRow(
                    id: row["id"] as String? ?? UUID().uuidString,
                    category: row["category"] as String? ?? "",
                    description: row["description"] as String? ?? "",
                    dateOrPeriod: row["date_or_period"] as String?,
                    sourceURL: row["source_url"] as String? ?? "",
                    sourceTitle: row["source_title"] as String? ?? "",
                    evidenceText: row["evidence_text"] as String? ?? "",
                    agentID: row["agent_id"] as String? ?? "unknown"
                )
            }
        }
    }

    /// Write a human-accepted pending fact straight onto the profile columns.
    ///
    /// NOTE: deliberately bypasses `editProfile` — no `transactions`/
    /// `field_changes` undo entry and no directional-overwrite policy.
    /// That is the pre-existing accept-flow behaviour (the human has just
    /// reviewed this exact value); unifying it with the ApplyEngine
    /// overwrite policy is Phase 1 slice 3+ scope, not this seam move.
    func applyAcceptedPendingFact(profileID: String, field: String, value: String) throws {
        // Map finding field to profile column
        let (column, datePrefix): (String?, String) = switch field {
        case "birthDate", "baptismDate": ("birth_date_original", "birth_date")
        case "deathDate", "burialDate": ("death_date_original", "death_date")
        case "birthLocation": ("birth_location", "")
        case "deathLocation": ("death_location", "")
        default: (nil, "")
        }

        guard let column else { return } // Narrative-only fields (occupation/address) have no profile column

        try dbQueue.write { writeDB in
            try writeDB.execute(
                sql: "UPDATE profiles SET \(column) = ? WHERE id = ?",
                arguments: [value, profileID]
            )

            // If it's a date field, also update the year columns
            if !datePrefix.isEmpty, let year = EvidenceFirewall.extractYear(from: value) {
                try writeDB.execute(
                    sql: "UPDATE profiles SET \(datePrefix)_earliest = ?, \(datePrefix)_latest = ? WHERE id = ?",
                    arguments: [year, year, profileID]
                )
            }
        }
    }

    /// Provenance row for a field written via the pending-facts accept flow.
    func addFieldResearcherProvenance(profileID: String, field: String, value: String, sourceTitle: String) throws {
        let profileField: String = switch field {
        case "birthDate", "baptismDate": "birthDate"
        case "deathDate", "burialDate": "deathDate"
        case "birthLocation": "birthLocation"
        case "deathLocation": "deathLocation"
        default: field
        }

        try dbQueue.write { writeDB in
            try writeDB.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at)
                VALUES (?, 'profile', ?, 'field-researcher', ?, ?)
                """, arguments: [
                    profileID, profileField,
                    "\(value) [\(sourceTitle)]",
                    Date(),
                ])
        }
    }
}

/// Row projection of `narrative_findings` for the review UI.
struct NarrativeFindingRow: Identifiable {
    let id: String
    let category: String
    let description: String
    let dateOrPeriod: String?
    let sourceURL: String
    let sourceTitle: String
    let evidenceText: String
    /// Agent that produced the narrative. Drives the
    /// `PendingFactsReviewView` filter chip — narratives carrying
    /// `prose-extractor:<corpus_id>` come from the prose-corpus
    /// subsystem; everything else comes from the MCP field-researcher
    /// or in-app submissions.
    let agentID: String
}
