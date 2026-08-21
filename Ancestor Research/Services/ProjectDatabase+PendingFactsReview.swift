import Foundation
import CryptoKit
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

    /// Delete a narrative finding by id — the human-dismissal path for the
    /// firewall's `narrative_findings` queue. A stranded or wrong-profile
    /// finding (e.g. a namesake's evidence) must never reach bio synthesis, so
    /// this is a hard delete: a rejected narrative carries no value to retain,
    /// and leaving it `pending` risks polluting the assembled prose. Surfaced
    /// from the profile's Notes block because the pending badge counts only
    /// `pending_facts`, which left a narrative-only profile with no review path.
    func deleteNarrativeFinding(id: String) throws {
        try dbQueue.write { writeDB in
            try writeDB.execute(
                sql: "DELETE FROM narrative_findings WHERE id = ?",
                arguments: [id]
            )
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
    func applyAcceptedPendingFact(
        profileID: String, field: String, value: String, payloadJSON: String? = nil
    ) throws {
        // Map finding field to profile column.
        //
        // Only four fields used to map, and the default arm `return`ed. So a
        // submission for occupation — a field `submit_evidence` advertises —
        // was marked accepted, had provenance written into `field_sources`,
        // and changed nothing on the profile. Success reported, nothing done:
        // the same silent-no-op class as the applied marriage that wrote no
        // spouse. Everything the profiles table can actually hold is mapped
        // now, event-shaped fields route to `life_events` below, and anything
        // still unrecognised THROWS rather than lying.
        let (column, datePrefix): (String?, String) = switch field {
        case "birthDate", "baptismDate": ("birth_date_original", "birth_date")
        case "deathDate", "burialDate": ("death_date_original", "death_date")
        case "birthLocation": ("birth_location", "")
        case "deathLocation": ("death_location", "")
        case "firstName", "givenName": ("first_name", "")
        case "middleName": ("middle_name", "")
        case "lastName", "surname": ("last_name", "")
        case "nickName": ("nick_name", "")
        case "gender": ("gender", "")
        case "marriedSurname": ("married_surname", "")
        case "mothersMaidenName": ("mothers_maiden_name", "")
        case "bio": ("bio", "")
        case "birthLocationCode": ("birth_location_code", "")
        case "deathLocationCode": ("death_location_code", "")
        default: (nil, "")
        }

        guard let column else {
            // Event-shaped: becomes a life event, not a profile column.
            if let type = Self.lifeEventType(forPendingFactField: field) {
                try applyPendingFactAsLifeEvent(
                    profileID: profileID, type: type, value: value, payloadJSON: payloadJSON)
                return
            }
            throw UnsupportedPendingFactField(field: field)
        }

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

    /// A pending-fact field the accept path cannot land. Thrown rather than
    /// ignored: a fact marked accepted, with provenance written, that changed
    /// nothing is worse than a visible refusal — the user believes the tree
    /// holds something it does not.
    struct UnsupportedPendingFactField: Error, LocalizedError {
        let field: String
        var errorDescription: String? {
            "“\(field)” cannot be applied to a profile. It maps to no profile column "
            + "and no life-event type, so nothing would change. Submit it as one of the "
            + "supported fields, or record it as a workbench note."
        }
    }

    /// Event-shaped pending-fact fields → their life-event type. These describe
    /// something that HAPPENED at a time and place, so they belong in
    /// `life_events`, not in a profile column.
    nonisolated static func lifeEventType(forPendingFactField field: String) -> LifeEventType? {
        switch field {
        case "occupation": .occupation
        case "residence", "address": .residence
        case "census": .census
        case "baptism", "christening": .baptism
        case "burial": .burial
        case "probate": .probate
        case "military", "militaryService": .militaryService
        case "education": .education
        case "religion": .religion
        case "immigration": .immigration
        case "emigration": .emigration
        default: nil
        }
    }

    /// Land an event-shaped accepted fact as a life event.
    ///
    /// Date and location ride in the submission payload (`sources_json`) when
    /// the submitter supplied them — `submit_evidence` takes optional
    /// `event_date` / `event_location`. Both are optional here: an undated
    /// occupation ("lime stone quarry labourer") is still a true statement
    /// worth holding, and inventing a year to make the row look complete would
    /// be worse than leaving it open.
    private func applyPendingFactAsLifeEvent(
        profileID: String, type: LifeEventType, value: String, payloadJSON: String?
    ) throws {
        let payload: [String: Any] = payloadJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let eventDate = (payload["event_date"] as? String)
            .flatMap { $0.isEmpty ? nil : GenealogicalDate(parsing: $0) }
        let eventLocation = (payload["event_location"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        // Deterministic id from (profile, type, date, value) so accepting the
        // same fact twice — or a resubmission upsert — cannot mint a duplicate
        // event. `addLifeEventIfAbsent` then makes the second accept a no-op.
        let fingerprint = "\(profileID)|\(type.rawValue)|\(eventDate?.original ?? "")|\(value)"
        _ = try addLifeEventIfAbsent(LifeEvent(
            id: Self.stableEventID(from: fingerprint),
            profileID: profileID,
            type: type,
            date: eventDate,
            location: eventLocation,
            description: value
        ))
    }

    /// UUIDv5-shaped stable id: SHA256 of the fingerprint, first 16 bytes.
    nonisolated static func stableEventID(from fingerprint: String) -> UUID {
        var digest = SHA256.hash(data: Data(fingerprint.utf8)).makeIterator()
        var bytes = (0..<16).map { _ in digest.next() ?? 0 }
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
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
