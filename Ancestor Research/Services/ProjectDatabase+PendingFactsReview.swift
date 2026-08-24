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
    ///
    /// `sourceTitle`/`sourceURL` are the submission's own provenance. They are
    /// optional only so the profile-column path (which records provenance
    /// separately via `addAcceptedFactProvenance`) keeps its existing
    /// callers; the life-event path needs them, because a life event carries
    /// its citation on the event row itself and has nowhere else to put it.
    func applyAcceptedPendingFact(
        profileID: String, field: String, value: String, payloadJSON: String? = nil,
        sourceTitle: String? = nil, sourceURL: String? = nil
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
                    profileID: profileID, type: type, value: value, payloadJSON: payloadJSON,
                    sourceTitle: sourceTitle, sourceURL: sourceURL)
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
    ///
    /// The submission's citation rides onto the EVENT ROW, not just the
    /// profile. A life event is where its own provenance has to live: the
    /// profile-level `field_sources` row written alongside it is filed under a
    /// field name ("residence"), so with several residences on one profile
    /// nothing says which citation backs which event. Owner dogfood
    /// 2026-08-21: six Thompson-line ancestors took fifteen FamilySearch
    /// census events, every one landing with `sources: []` while the ark sat
    /// on the profile — an event that reads as uncited is an event a reader
    /// cannot check, which is the whole point of holding it.
    private func applyPendingFactAsLifeEvent(
        profileID: String, type: LifeEventType, value: String, payloadJSON: String?,
        sourceTitle: String? = nil, sourceURL: String? = nil
    ) throws {
        let payload: [String: Any] = payloadJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let eventDate = (payload["event_date"] as? String)
            .flatMap { $0.isEmpty ? nil : GenealogicalDate(parsing: $0) }
        let eventLocation = (payload["event_location"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        let source = Self.pendingFactEventSource(title: sourceTitle, url: sourceURL)

        // #24 — structured census context. When the submission carried a
        // household roster (and district/parish/address), project it into the
        // TYPED census details instead of leaving it as prose in the
        // description: the event then renders identically to an app-fetched
        // census, and the roster is readable by the family-context gate and
        // the cross-profile cite machinery (owner dogfood 2026-08-24: the
        // 1891 FreeCEN and 1901 FamilySearch censuses side by side on one
        // profile, one structured, one a text blob).
        let (subjectName, subjectMarriedSurname, subjectBirthYear): (String, String, Int?) = (try? dbQueue.read { readDB in
            try Row.fetchOne(readDB, sql: """
                SELECT TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')) AS name,
                       COALESCE(married_surname,'') AS married,
                       birth_date_earliest AS by_early, birth_date_latest AS by_late
                FROM profiles WHERE id = ?
                """, arguments: [profileID])
        }).flatMap { row in
            row.map { r -> (String, String, Int?) in
                // Midpoint of the stored range ≈ GEDCOMDate.bestYear — close
                // enough for the matcher's ±3 census-age discrimination.
                let early: Int? = r["by_early"], late: Int? = r["by_late"]
                let year = early.flatMap { e in late.map { l in (e + l) / 2 } } ?? early ?? late
                return (r["name"] as String? ?? "", r["married"] as String? ?? "", year)
            }
        } ?? ("", "", nil)
        let household = Self.pendingFactHousehold(
            payload: payload, subjectName: subjectName,
            subjectMarriedSurname: subjectMarriedSurname,
            subjectBirthYear: subjectBirthYear)
        var details: LifeEventDetails?
        if type == .census, !household.isEmpty {
            let own = household.first { $0.isTarget == true }
            details = .census(CensusDetails(
                occupation: own?.occupation,
                address: payload["address"] as? String,
                district: payload["district"] as? String,
                parish: payload["parish"] as? String,
                household: household))
        }

        // Deterministic id from (profile, type, date, value) so accepting the
        // same fact twice — or a resubmission upsert — cannot mint a duplicate
        // event. `addLifeEventIfAbsent` then makes the second accept a no-op.
        let fingerprint = "\(profileID)|\(type.rawValue)|\(eventDate?.original ?? "")|\(value)"
        var event = LifeEvent(
            id: Self.stableEventID(from: fingerprint),
            profileID: profileID,
            type: type,
            date: eventDate,
            location: eventLocation,
            description: value,
            sources: [source].compactMap { $0 }
        )
        event.details = details
        let inserted = try addLifeEventIfAbsent(event)

        // A structured census also lands as a first-class census EVIDENCE
        // record (same shape as an app-fetched one): the ledger shows its
        // roster, `confirmedCensusSources` reads it, and the household drives
        // cite offers for every relative it names. Idempotent via the
        // evidence upsert's composite id.
        if type == .census, !household.isEmpty,
           let year = eventDate?.bestYear {
            try saveAcceptedCensusEvidence(
                profileID: profileID, year: year, household: household,
                payload: payload, value: value,
                sourceTitle: sourceTitle, sourceURL: sourceURL,
                eventLocation: eventLocation)
        }

        if !inserted {
            // The event already existed — a re-accept or a resubmission
            // upsert. Two purely-additive upgrades are allowed: attaching a
            // citation it does not yet carry, and grafting structured census
            // details onto a prose-only event (the #24 backfill path — a
            // resubmission with a household must not be a no-op just because
            // the prose event landed first).
            if let source {
                try attachSourceToLifeEvent(id: event.id, profileID: profileID, source: source)
            }
            if let details,
               var existing = try loadLifeEvents(profileID: profileID)
                   .first(where: { $0.id == event.id }) {
                if existing.details == nil {
                    existing.details = details
                    _ = try updateLifeEvent(existing)
                } else if case .census(var stored)? = existing.details,
                          case .census(let fresh) = details,
                          !stored.household.contains(where: { $0.isTarget == true }),
                          let targetName = fresh.household.first(where: { $0.isTarget == true })?.name {
                    // #28 retrofit: the stored roster predates the
                    // married-surname target fix and marks nobody as the
                    // subject; a re-accept whose projection knows the
                    // subject's own row repairs it in place.
                    stored.household = stored.household.map { m in
                        guard m.name.lowercased() == targetName.lowercased() else { return m }
                        return HouseholdMember(
                            name: m.name, relationship: m.relationship,
                            age: m.age, birthYear: m.birthYear,
                            birthPlace: m.birthPlace, occupation: m.occupation,
                            sex: m.sex, maritalStatus: m.maritalStatus,
                            birthCounty: m.birthCounty, isTarget: true)
                    }
                    existing.details = .census(stored)
                    _ = try updateLifeEvent(existing)
                }
            }
        }
    }

    /// Parse the structured household from a pending fact's routing payload.
    /// `isTarget` is marked where a member's name loosely matches the subject
    /// profile — the same convention app-fetched rosters carry. Pure and
    /// testable: the caller supplies the subject's display name.
    ///
    /// #28: the tree stores married women under their MAIDEN surname while a
    /// census enumerates them under the MARRIED one (owner dogfood
    /// 2026-08-24: Ruth Brailsford's own row in her accepted 1871 household
    /// went unmarked because the schedule says Ruth Wheeldon). The suffix
    /// match accepts EITHER surname.
    ///
    /// #33: selection is `HouseholdRetarget.matchIndex` — the same rule the
    /// app-fetched roster path uses. Name matching alone double-marked a
    /// same-named father and son (John 37 / John 12 both flagged "this is
    /// you"); the shared rule adds birth-year discrimination and marks NOBODY
    /// when no single member can be identified.
    nonisolated static func pendingFactHousehold(
        payload: [String: Any], subjectName: String,
        subjectMarriedSurname: String = "",
        subjectBirthYear: Int? = nil
    ) -> [HouseholdMember] {
        guard let raw = payload["household"] as? [[String: Any]], !raw.isEmpty else { return [] }
        let members = raw.prefix(30).compactMap { m -> HouseholdMember? in
            guard let name = m["name"] as? String, !name.isEmpty,
                  let relationship = m["relationship"] as? String, !relationship.isEmpty
            else { return nil }
            return HouseholdMember(
                name: name,
                relationship: relationship,
                age: m["age"] as? Int,
                birthYear: m["birth_year"] as? Int,
                birthPlace: m["birth_place"] as? String,
                occupation: m["occupation"] as? String,
                sex: m["sex"] as? String,
                maritalStatus: m["marital_status"] as? String,
                birthCounty: m["birth_county"] as? String,
                isTarget: nil)
        }
        // The subject arrives as one display string; split it the way the
        // matcher expects (given = first token, surname = last token).
        let tokens = subjectName.split(separator: " ").map(String.init)
        let targetIndex = HouseholdRetarget.matchIndex(
            in: members,
            givenName: tokens.first ?? "",
            maidenSurname: tokens.count > 1 ? tokens.last! : "",
            marriedSurname: subjectMarriedSurname,
            birthYear: subjectBirthYear)
        guard let targetIndex else { return members }
        return members.enumerated().map { index, m in
            guard index == targetIndex else { return m }
            return HouseholdMember(
                name: m.name, relationship: m.relationship,
                age: m.age, birthYear: m.birthYear,
                birthPlace: m.birthPlace, occupation: m.occupation,
                sex: m.sex, maritalStatus: m.maritalStatus,
                birthCounty: m.birthCounty, isTarget: true)
        }
    }

    /// Persist an accepted structured census as a census evidence record —
    /// verdict `.fact` with a "you accepted this" gate, `savedAsLead` status
    /// (the apply path's stamp), the same shape `addVerifiedRecord` writes.
    private func saveAcceptedCensusEvidence(
        profileID: String, year: Int, household: [HouseholdMember],
        payload: [String: Any], value: String,
        sourceTitle: String?, sourceURL: String?, eventLocation: String?
    ) throws {
        let own = household.first { $0.isTarget == true }
        let recordID = "fieldresearcher_census_\(profileID)_\(year)"
        let common = RecordCommon(
            id: recordID,
            sourceID: "field-researcher",
            name: own?.name,
            detailURL: sourceURL,
            rawFields: [:])
        let record = SourceRecord.census(CensusRecord(
            common: common,
            censusYear: year,
            age: own?.age,
            birthYear: own?.birthYear,
            birthPlace: own?.birthPlace,
            birthCounty: own?.birthCounty,
            relationship: own?.relationship,
            occupation: own?.occupation,
            address: payload["address"] as? String,
            parish: payload["parish"] as? String,
            district: (payload["district"] as? String) ?? eventLocation,
            household: household))
        let scored = ScoredRecord(
            id: recordID, record: record, verdict: .fact,
            gates: [GateResult(gate: .name, outcome: .pass,
                               reason: "You accepted this record in Triage")],
            summary: value)
        let evidenceID = EvidenceRecord.compositeID(profileID: profileID, sourceRecordID: recordID)
        try saveEvidence(profileID: profileID, scored: scored,
                         citationFull: sourceTitle ?? value, citationURL: sourceURL)
        try updateEvidenceUserStatus(evidenceID: evidenceID, status: .savedAsLead)
        // This record is BORN applied — accepting the card wrote the census
        // life event in the same flow. Without the stamp the profile ledger
        // classified it "researched — not applied" and offered Apply on an
        // already-applied record: `wasApplied`'s citation fallback reads
        // `Profile.sources`, which drops event-shaped fields like census
        // (owner dogfood 2026-08-24: Ruth Wheeldon's accepted 1871).
        try markEvidenceApplied(evidenceID: evidenceID)
    }

    /// The accepted submission's provenance as a `FieldSource`. Nil when the
    /// submission carried neither a title nor a URL — an empty citation is
    /// worse than none, because it looks like the event was sourced.
    nonisolated static func pendingFactEventSource(
        title: String?, url: String?
    ) -> FieldSource? {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = !(title ?? "").isEmpty
        let hasURL = !(url ?? "").isEmpty
        guard hasTitle || hasURL else { return nil }
        return FieldSource(
            origin: SourceOrigin(identifier: "field-researcher"),
            raw: hasTitle ? title! : url!,
            addedAt: Date(),
            citation: Citation(
                title: hasTitle ? title : nil,
                url: hasURL ? url : nil,
                dateAccessed: Date()
            )
        )
    }

    /// Append a source to an existing life event unless it already holds one
    /// citing the same URL. Idempotent, so repeated accepts of the same
    /// resubmitted fact cannot stack duplicate citations onto one event.
    ///
    /// Citation CORRECTION (#27): a resubmission citing the same record —
    /// same origin, same citation title — at a DIFFERENT URL is a repaired
    /// link, and the stale variant(s) are replaced rather than accumulated.
    /// Owner dogfood 2026-08-24: FamilySearch search results carry internal
    /// persona ids whose ark URLs 404 in a browser; once the real ark is
    /// known, the dead link sitting next to the live one would read as two
    /// independent sources when it is one source cited twice.
    private func attachSourceToLifeEvent(
        id: UUID, profileID: String, source: FieldSource
    ) throws {
        guard var event = try loadLifeEvents(profileID: profileID)
            .first(where: { $0.id == id })
        else { return }
        let newURL = source.citation?.url ?? ""
        let newTitle = source.citation?.title ?? ""
        var changed = false
        if !newURL.isEmpty, !newTitle.isEmpty,
           let newHost = URL(string: newURL)?.host?.lowercased() {
            let before = event.sources.count
            // Same host is the discriminator between a correction and a
            // corroboration: the same record re-cited at a repaired address
            // stays on its site (familysearch → familysearch), while a second
            // independent source with the same generic title (FreeCEN next to
            // FamilySearch) lives on a different one and must be KEPT.
            event.sources.removeAll { existing in
                guard existing.origin.identifier == source.origin.identifier,
                      (existing.citation?.title ?? "") == newTitle,
                      let oldURL = existing.citation?.url, oldURL != newURL,
                      let oldHost = URL(string: oldURL)?.host?.lowercased()
                else { return false }
                return oldHost == newHost
            }
            changed = event.sources.count != before
        }
        let alreadyCited = event.sources.contains { existing in
            if !newURL.isEmpty {
                return existing.citation?.url == newURL
            }
            return existing.raw == source.raw
        }
        if !alreadyCited {
            event.sources.append(source)
            changed = true
        }
        if changed {
            _ = try updateLifeEvent(event)
        }
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
    ///
    /// `origin` MUST name the producer that actually submitted the fact — pass
    /// the pending fact's own `agentID`. This was hardcoded to the string
    /// literal `'field-researcher'`, so EVERY accepted fact wore that badge no
    /// matter where it came from: `research-run`, `subject-spouse-marriage`,
    /// `subject-self-narrowing`, `prose-extractor:<corpus>` — the app's own
    /// in-app producers were all attributed to the external MCP agent.
    ///
    /// Owner dogfood 2026-08-21: a death date of 1929 written by the app's own
    /// research pipeline (agent `research-run`, 27 Jul, run 679B3504) showed on
    /// the profile as field-researcher, so the owner reasonably concluded the
    /// assistant had submitted it. Misattributed provenance doesn't just
    /// mislabel a row, it sends the human to the wrong place to fix the cause.
    /// Same defect class as `promoteLeadToProfile`'s hardcoded `.freebmd`.
    ///
    /// `sourceURL` populates `citation_json`, so an accepted submission is
    /// citable the same way a FreeBMD or FreeCen fact is. Without it the row
    /// carried only a title glued into `raw`, which reads as provenance but
    /// links to nothing — and `certifiedFieldCount`-style queries that test
    /// `citation_json IS NOT NULL` skipped every accepted fact.
    func addAcceptedFactProvenance(
        profileID: String, field: String, value: String, sourceTitle: String,
        sourceURL: String? = nil, origin: String = "field-researcher"
    ) throws {
        let profileField: String = switch field {
        case "birthDate", "baptismDate": "birthDate"
        case "deathDate", "burialDate": "deathDate"
        case "birthLocation": "birthLocation"
        case "deathLocation": "deathLocation"
        default: field
        }

        let citationJSON = Self.pendingFactEventSource(title: sourceTitle, url: sourceURL)?
            .citation.map(Self.encodeJSON)

        // An empty or whitespace agent id must not write a blank origin — an
        // unattributed row is worse than a generically attributed one.
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedOrigin = trimmedOrigin.isEmpty ? "field-researcher" : trimmedOrigin

        try dbQueue.write { writeDB in
            // Citation correction (#27): a resubmission of the same fact from
            // the same producer with a REPAIRED citation URL updates the
            // existing provenance row(s) in place rather than stacking — the
            // stale row would keep pointing readers at a dead link. The
            // correction key is deliberately narrow: same raw, same origin,
            // and a cited URL on the SAME HOST that differs from the new one
            // (a repaired address stays on its site; a corroborating source
            // with the same title lives on a different host and is kept).
            // Identical re-accepts fall through to the append below — the
            // provenance table is a journal, two accepts are two attestation
            // rows, and the ledger/bin semantics depend on that.
            let raw = "\(value) [\(sourceTitle)]"
            var didCorrect = false
            if let citationJSON,
               let newURL = sourceURL, !newURL.isEmpty,
               let newHost = URL(string: newURL)?.host?.lowercased() {
                let rows = try Row.fetchAll(writeDB, sql: """
                    SELECT rowid, citation_json FROM field_sources
                    WHERE entity_id = ? AND entity_kind = 'profile'
                      AND field = ? AND origin = ? AND raw = ?
                    """, arguments: [profileID, profileField, resolvedOrigin, raw])
                for row in rows {
                    guard let existingJSON = row["citation_json"] as String?,
                          let data = existingJSON.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let oldURL = obj["url"] as? String, oldURL != newURL,
                          URL(string: oldURL)?.host?.lowercased() == newHost
                    else { continue }
                    try writeDB.execute(
                        sql: "UPDATE field_sources SET citation_json = ?, added_at = ? WHERE rowid = ?",
                        arguments: [citationJSON, Date(), row["rowid"] as Int64? ?? -1])
                    didCorrect = true
                }
            }
            if didCorrect { return }
            try writeDB.execute(sql: """
                INSERT INTO field_sources
                    (entity_id, entity_kind, field, origin, raw, added_at, citation_json)
                VALUES (?, 'profile', ?, ?, ?, ?, ?)
                """, arguments: [
                    profileID, profileField, resolvedOrigin,
                    raw,
                    Date(),
                    citationJSON,
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
