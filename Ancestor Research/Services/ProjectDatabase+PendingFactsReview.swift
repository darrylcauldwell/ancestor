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
    ///
    /// CONFLICT_LAYER_SPEC §4.4 T-A (pending-fact producer): because this
    /// path bypasses the overwrite policy, the F1/F2 incompatibility test
    /// runs *after* the write — the displaced value (still attested in
    /// `field_sources` and captured from the canonical column here) opens
    /// a `fieldValue` dispute when it genuinely conflicts with the value
    /// the human just accepted. The write itself is untouched.
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

        // Capture the value being displaced before the overwrite — the
        // conflict check below compares against it.
        let oldValue: String? = try dbQueue.write { writeDB in
            let previous = try String.fetchOne(
                writeDB,
                sql: "SELECT \(column) FROM profiles WHERE id = ?",
                arguments: [profileID]
            )
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
            return previous
        }

        try detectConflictForAcceptedPendingFact(
            profileID: profileID, field: field, value: value, displaced: oldValue
        )
    }

    /// Post-write F1/F2 hook for the pending-facts accept path. Separate
    /// from the write transaction: `upsertDispute` manages its own write,
    /// and a detection failure must never roll back a human-accepted fact.
    private func detectConflictForAcceptedPendingFact(
        profileID: String, field: String, value: String, displaced: String?
    ) throws {
        let profileField: ProfileField? = switch field {
        case "birthDate", "baptismDate": .birthDate
        case "deathDate", "burialDate": .deathDate
        case "birthLocation": .birthLocation
        case "deathLocation": .deathLocation
        default: nil
        }
        guard let profileField else { return }
        guard let profile = try loadProfile(id: profileID) else { return }

        // The displaced value joins the attested competitors so the
        // conflict is visible even when the audit log never journalled it.
        var attested = profile.sources[profileField] ?? []
        if let displaced, !displaced.trimmingCharacters(in: .whitespaces).isEmpty,
           !attested.contains(where: { $0.raw == displaced }) {
            attested.append(FieldSource(
                origin: SourceOrigin(identifier: "tree"),
                raw: displaced,
                addedAt: Date()
            ))
        }

        let origin = SourceOrigin(identifier: "field-researcher")
        let conflict: DetectedConflict? = switch profileField {
        case .birthDate, .deathDate:
            ConflictDetector.dateFieldConflict(
                field: profileField,
                existing: displaced.map { GenealogicalDate(parsing: $0) },
                existingSources: attested,
                candidate: GenealogicalDate(parsing: value),
                candidateOrigin: origin,
                profileID: profileID
            )
        default:
            ConflictDetector.stringFieldConflict(
                field: profileField,
                existing: displaced,
                existingSources: attested,
                candidate: value,
                candidateOrigin: origin,
                profileID: profileID
            )
        }
        guard let conflict else { return }
        _ = try upsertDispute(
            profileID: profileID,
            conflict: conflict,
            adjudication: DisputeResolver.adjudicate(conflict)
        )
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
