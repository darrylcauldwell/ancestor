import Foundation
import GRDB
import AncestorKit

/// PROFILE_SOURCES_LEDGER_SPEC Changes 1+3+4 — remove an applied evidence
/// record from a profile, reversing its absorption directionally and
/// remembering the rejection so future research runs don't re-add it.
///
/// Why plan-guided, not transaction-guided: one apply fans a record into MANY
/// unlinked `.manualEdit` transactions (one editProfile per overwritten field,
/// one recordAlternativeFact per refused field, a journal-less marriage fill,
/// citation attaches with no transaction at all, life events with a nil
/// transaction id) — so a record's transactions are unrecoverable after the
/// fact. What IS recoverable: the record's `absorptionPlan` re-enumerates every
/// (field, value) it could have written, and the apply path keys its
/// `field_sources` writes on exactly (profile, field, origin, raw). Removal
/// re-derives the same targets and inverts each against CURRENT state:
///
/// - **Row removal.** Delete the matching field_sources row(s) — unless another
///   kept record from the same source corroborates the same value (the
///   `recordAlternativeFact` dedup means such rows are genuinely shared).
/// - **Directional column revert.** Only when the profile column still equals
///   the record's value (if a later write displaced it, the column is not
///   ours to touch): restore the `field_changes.old_value` of the write that
///   set it; else fall back to the highest-tier surviving field_sources row;
///   else clear. Order-safe by construction — the equality guard means the
///   restored old_value is the true pre-record state.
/// - **Life events.** Ids are deterministic in (profileID, sourceRecordID)
///   with at most the bare/#occupation/#residence discriminators — recompute
///   and delete. (Events moved to another profile by a merge keep their
///   loser-derived ids and are not reachable here; neither is the record's
///   ledger entry post-merge, so the surfaces agree.)
/// - **Marriage fill.** The fill only ever wrote a strictly-narrower date or
///   filled an EMPTY location, and journalled nothing — clear each on exact
///   match with what this record would have written. (A wider pre-fill date is
///   the one documented loss.)
/// - **Disputes.** Open fieldValue disputes on touched fields are deleted; the
///   caller's force sweep re-derives any still justified by surviving rows.
///   Open spouseIdentity disputes are deleted for marriage records — the sweep
///   no longer resurrects them because discarded evidence is excluded from
///   conflict detection.
/// - **Rejection memory.** The same pair every discard path writes
///   (`user_status = 'discarded'` + `record_rejections`) — which also drops
///   the ledger entry (its filter is `savedAsLead`) and vetoes re-application.
///
/// The whole removal runs in ONE database transaction, journalled under a
/// single Transaction row (`.manualEdit`/`.replay`) with field_changes rows per
/// column change. Nothing is destroyed irrecoverably: the evidence record
/// itself survives with its full payload, so the full inverse of a removal is
/// re-applying the record from research (after resetting its rejection).
nonisolated struct RecordRemovalReport: Sendable, Equatable {
    /// Fields whose column value was reverted (the record's value was live).
    var revertedFields: [ProfileField] = []
    /// Fields where only the citation row was dropped (value kept — the
    /// record was corroborating/alternative, or a later write displaced it).
    var droppedCitationFields: [ProfileField] = []
    /// Fields whose row was KEPT because another kept record from the same
    /// source corroborates the same value.
    var sharedFields: [ProfileField] = []
    var deletedLifeEvents: Int = 0
    var clearedMarriageDate: Bool = false
    var clearedMarriageLocation: Bool = false
    var dissolvedDisputes: Int = 0
    var transactionID: UUID?
}

/// Everything needed to invert ONE applied fact that has no evidence record.
///
/// The pending-facts accept path (`applyAcceptedPendingFact` +
/// `addAcceptedFactProvenance`), the MCP auto-approval commit and the
/// promote-lead path all write a profile column plus a single `field_sources`
/// row, and create no `evidence_records` row at all. `removeAppliedRecord`
/// derives every target from `record.absorptionPlan`, so with no record there
/// is nothing for it to invert — such a fact had no removal path anywhere in
/// the UI (owner dogfood 2026-08-21: three wrong death dates accepted in
/// review, none removable).
///
/// `rowID` is `field_sources.rowid`, which the schema declares as
/// `autoIncrementedPrimaryKey("rowid")` — a genuine identity, never reused.
/// That matters: the table carries no UNIQUE constraint and the accept path
/// has no dedup pre-check, so accepting the same fact twice writes two
/// byte-identical rows. A tuple-keyed DELETE has no `LIMIT` and would take
/// both; a rowid takes exactly one.
nonisolated struct AppliedFactTarget: Sendable, Equatable, Hashable {
    let rowID: Int64
    let profileID: String
    /// The RAW `field_sources.field` string, NOT a `ProfileField`. The table
    /// legitimately holds `occupation`, `residence`, `census`,
    /// `birthLocationCode` and others that `ProfileField(rawValue:)` rejects.
    let field: String
    let origin: String
    /// Exactly as stored. `addAcceptedFactProvenance` writes
    /// `"<value> [<sourceTitle>]"`.
    let raw: String
    /// `raw` with the trailing `" [title]"` stripped — the value actually
    /// sitting in the profile column.
    let value: String
    let sourceTitle: String?
    let citationURL: String?
    let addedAt: Date

    /// `"1929 [FreeBMD Death Index]"` → `("1929", "FreeBMD Death Index")`.
    /// Splits on the LAST `" ["` so a title containing `" ["` still parses.
    /// A raw with no bracket — every non-accept writer — parses to itself.
    static func parseRaw(_ raw: String) -> (value: String, title: String?) {
        guard raw.hasSuffix("]"),
              let open = raw.range(of: " [", options: .backwards)
        else { return (raw, nil) }
        let value = String(raw[raw.startIndex..<open.lowerBound])
        let title = String(raw[open.upperBound..<raw.index(before: raw.endIndex)])
        return (value, title.isEmpty ? nil : title)
    }
}

extension ProjectDatabase {

    /// One removal target: a (field, raw) pair the record may have landed.
    private struct RemovalTarget {
        let field: ProfileField
        let raw: String
        let isDate: Bool
    }

    /// Every (field, raw) pair `record` could have written through
    /// `applyFactToSubject`. The standard plan items are profile-independent;
    /// the name-enrichment items are re-derived unconditionally because the
    /// plan suppresses them once the profile already carries the fuller form
    /// (which is exactly the post-apply state removal runs against).
    private static func removalTargets(for record: SourceRecord, profileID: String) -> [RemovalTarget] {
        var targets: [RemovalTarget] = []
        for item in record.absorptionPlan(profileID: profileID) {
            switch item {
            case .dateField(let field, let date):
                targets.append(RemovalTarget(field: field, raw: date.original, isDate: true))
            case .stringField(let field, let value):
                targets.append(RemovalTarget(field: field, raw: value, isDate: false))
            case .spouseEdge, .lifeEvent:
                break  // handled by their own inversion arms
            }
        }
        // Name enrichment (AbsorptionPlan 1b) — candidate values, whether or
        // not the current profile state would still emit them.
        if !record.isCensus, let given = record.givenName?.trimmingCharacters(in: .whitespaces), !given.isEmpty {
            let first = given.split(separator: " ").first.map(String.init) ?? given
            targets.append(RemovalTarget(field: .firstName, raw: SourceRecord.recasedName(first), isDate: false))
            if let middle = RecordScorer.extractMiddleContent(from: given) {
                targets.append(RemovalTarget(field: .middleName, raw: SourceRecord.recasedName(middle), isDate: false))
            }
        }
        return targets
    }

    /// Remove an applied record from its profile. See the file header for the
    /// full inversion contract. The evidence row must be `savedAsLead`.
    func removeAppliedRecord(_ evidence: EvidenceRecord) throws -> RecordRemovalReport {
        let profileID = evidence.profileID
        let origin = evidence.sourceID
        let targets = Self.removalTargets(for: evidence.record, profileID: profileID)

        // (field, raw) pairs corroborated by OTHER kept records of the same
        // source — their shared field_sources rows must survive this removal.
        let siblingTargets: Set<String> = Set(
            try loadEvidenceForProfile(profileID)
                .filter { $0.userStatus == .savedAsLead && $0.sourceID == origin && $0.sourceRecordID != evidence.sourceRecordID }
                .flatMap { Self.removalTargets(for: $0.record, profileID: profileID) }
                .map { "\($0.field.rawValue)|\($0.raw)" }
        )

        let now = Date()
        let transaction = Transaction(
            id: UUID(), kind: .manualEdit, undoStrategy: .replay,
            startedAt: now, completedAt: now,
            changeCount: targets.count, profileCount: 1
        )
        var report = RecordRemovalReport(transactionID: transaction.id)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString, Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            var touchedFields: Set<ProfileField> = []

            for target in targets {
                let rowCount = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM field_sources
                    WHERE entity_id = ? AND entity_kind = 'profile' AND field = ? AND origin = ? AND raw = ?
                    """, arguments: [profileID, target.field.rawValue, origin, target.raw]) ?? 0
                guard rowCount > 0 else { continue }  // record never landed this item
                touchedFields.insert(target.field)

                if siblingTargets.contains("\(target.field.rawValue)|\(target.raw)") {
                    report.sharedFields.append(target.field)
                    continue  // another kept record corroborates this exact value
                }
                try db.execute(sql: """
                    DELETE FROM field_sources
                    WHERE entity_id = ? AND entity_kind = 'profile' AND field = ? AND origin = ? AND raw = ?
                    """, arguments: [profileID, target.field.rawValue, origin, target.raw])

                if try Self.revertColumnIfLive(
                    db: db, profileID: profileID, target: target,
                    removedOrigin: origin, transactionID: transaction.id
                ) {
                    report.revertedFields.append(target.field)
                } else {
                    report.droppedCitationFields.append(target.field)
                }
            }

            // Life events — recompute the record's deterministic ids.
            let recordID = evidence.sourceRecordID
            let eventIDs = [
                SourceRecord.deterministicID(profileID: profileID, sourceRecordID: recordID),
                SourceRecord.deterministicID(profileID: profileID, sourceRecordID: recordID, discriminator: "occupation"),
                SourceRecord.deterministicID(profileID: profileID, sourceRecordID: recordID, discriminator: "residence"),
            ]
            for id in eventIDs {
                let deleted = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM life_events WHERE id = ? AND profile_id = ?",
                                               arguments: [id.uuidString, profileID]) ?? 0
                if deleted > 0 {
                    try db.execute(sql: "DELETE FROM life_events WHERE id = ? AND profile_id = ?",
                                   arguments: [id.uuidString, profileID])
                    report.deletedLifeEvents += deleted
                }
            }

            // Marriage fill inversion — clear edge columns on exact match.
            if case .marriage(let m) = evidence.record {
                try Self.revertMarriageFill(db: db, profileID: profileID, marriage: m, report: &report)
                let dissolvedSpouse = try Self.deleteOpenDisputes(db: db, profileID: profileID, kind: "spouseIdentity", field: nil)
                report.dissolvedDisputes += dissolvedSpouse
            }

            // Open fieldValue disputes on touched fields: delete so a dispute
            // the removed record caused clears, then let the caller's force
            // sweep RE-DERIVE any still justified by surviving rows. This is
            // only self-healing for the fields ConflictSweep re-derives
            // (F1/F2 = birth/death date + location); scope the deletion to
            // exactly those so a still-valid dispute can never be lost. Name
            // fields never carry an absorption-created dispute anyway (the
            // isCompatibleNameForm carve-out suppresses them at apply), so
            // this excludes nothing real.
            let sweepRederivedFields: Set<ProfileField> = [.birthDate, .deathDate, .birthLocation, .deathLocation]
            for field in touchedFields where sweepRederivedFields.contains(field) {
                report.dissolvedDisputes += try Self.deleteOpenDisputes(
                    db: db, profileID: profileID, kind: "fieldValue", field: field.rawValue)
            }

            // Rejection memory — the same pair discardRecord writes, inline so
            // the whole removal is one atomic transaction.
            try db.execute(sql: "UPDATE evidence_records SET user_status = 'discarded' WHERE id = ?",
                           arguments: [evidence.id])
            try db.execute(sql: "INSERT OR IGNORE INTO record_rejections (profile_id, record_id, rejected_at) VALUES (?, ?, ?)",
                           arguments: [profileID, evidence.sourceRecordID, now])
        }
        return report
    }

    /// The `field|raw` keys `removeAppliedRecord` will try to delete for this
    /// record. Exposed so the ledger can tell a row that ALREADY has a bin
    /// (via its record's entry) from an orphan row that needs its own.
    static func removalTargetKeys(for record: SourceRecord, profileID: String) -> [String] {
        removalTargets(for: record, profileID: profileID).map { "\($0.field.rawValue)|\($0.raw)" }
    }

    /// Every profile-scoped `field_sources` row, with its rowid.
    ///
    /// Deliberately its own query rather than reading `Profile.sources`: the
    /// snapshot loader does not project rowid, so a `FieldSource` carries no
    /// row identity and cannot address a row for deletion. It also drops any
    /// field `ProfileField(rawValue:)` rejects, which silently hides exactly
    /// the event-shaped rows (occupation, residence, census) this needs.
    ///
    /// `entity_kind = 'profile'` is mandatory — relationship-existence
    /// provenance lives in the same table keyed by relationship UUID.
    func appliedFactProvenanceRows(profileID: String) throws -> [AppliedFactTarget] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, field, origin, raw, added_at, citation_json
                FROM field_sources
                WHERE entity_id = ? AND entity_kind = 'profile'
                ORDER BY added_at DESC, rowid DESC
                """, arguments: [profileID])
            .map { row in
                let raw: String = row["raw"] ?? ""
                let parsed = AppliedFactTarget.parseRaw(raw)
                let url = (row["citation_json"] as String?)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(Citation.self, from: $0) }?
                    .url
                return AppliedFactTarget(
                    rowID: row["rowid"] ?? 0,
                    profileID: profileID,
                    field: row["field"] ?? "",
                    origin: row["origin"] ?? "",
                    raw: raw,
                    value: parsed.value,
                    sourceTitle: parsed.title,
                    citationURL: (url?.isEmpty == false) ? url : nil,
                    addedAt: row["added_at"] ?? Date()
                )
            }
        }
    }

    /// Remove an applied fact that has NO evidence record — see
    /// `AppliedFactTarget` for why such facts exist and why they were
    /// unreachable.
    ///
    /// This cannot reuse `removeAppliedRecord`. That function derives its
    /// targets from `record.absorptionPlan` (there is no record), and its
    /// `revertColumnIfLive` demands positive proof of authorship from a
    /// `field_changes` row — which `applyAcceptedPendingFact` never writes, by
    /// its own documented design. Reusing it would return false every time:
    /// the citation row dropped, the wrong value left sitting on the profile,
    /// a Remove button that appears to work and doesn't. That silent-no-op
    /// class is the one this codebase keeps getting bitten by.
    ///
    /// The column is NOT blanked on removal. It is recomputed from whatever
    /// provenance survives, so taking off one of several sources cannot
    /// destroy a value another source still attests.
    @discardableResult
    func removeAppliedFact(_ target: AppliedFactTarget) throws -> RecordRemovalReport {
        let now = Date()
        let transaction = Transaction(
            id: UUID(), kind: .manualEdit, undoStrategy: .replay,
            startedAt: now, completedAt: now, changeCount: 1, profileCount: 1
        )
        var report = RecordRemovalReport()

        try dbQueue.write { db in
            // A stale click — the row went while the list was on screen (another
            // window, a merge purge) — is a clean no-op, not an error. Binding
            // entity_id as well as rowid means a rowid can never be applied to
            // a different profile.
            let exists = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM field_sources
                WHERE rowid = ? AND entity_id = ? AND entity_kind = 'profile'
                """, arguments: [target.rowID, target.profileID]) ?? 0
            guard exists == 1 else { return }

            report.transactionID = transaction.id
            try db.execute(sql: """
                INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    transaction.id.uuidString, Self.encodeJSON(transaction.kind),
                    transaction.undoStrategy.rawValue,
                    transaction.startedAt, transaction.completedAt,
                    transaction.changeCount, transaction.profileCount,
                ])

            // Delete BEFORE computing survivors, so the survivor query cannot
            // pick the row being removed.
            try db.execute(sql: "DELETE FROM field_sources WHERE rowid = ? AND entity_id = ?",
                           arguments: [target.rowID, target.profileID])

            if let mapping = Self.appliedFactColumn(target.field) {
                try Self.revertAppliedFactColumn(
                    db: db, target: target, mapping: mapping,
                    transactionID: transaction.id, report: &report)
            } else if let type = Self.lifeEventType(forPendingFactField: target.field) {
                // The event id is a hash over (profile, type, date, value) and
                // the provenance row carries no date, so it cannot be
                // recomputed. `life_events` stores the value verbatim in
                // `description`, so match on that instead.
                let deleted = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM life_events
                    WHERE profile_id = ? AND type = ? AND description = ?
                    """, arguments: [target.profileID, type.rawValue, target.value]) ?? 0
                if deleted > 0 {
                    try db.execute(sql: """
                        DELETE FROM life_events
                        WHERE profile_id = ? AND type = ? AND description = ?
                        """, arguments: [target.profileID, type.rawValue, target.value])
                    report.deletedLifeEvents += deleted
                }
            }

            // Dissolve disputes the accept opened, for exactly the fields the
            // conflict sweep re-derives — the caller's forced sweep restores
            // any still justified by surviving rows.
            if let pf = ProfileField(rawValue: target.field),
               [.birthDate, .deathDate, .birthLocation, .deathLocation].contains(pf) {
                report.dissolvedDisputes += try Self.deleteOpenDisputes(
                    db: db, profileID: target.profileID, kind: "fieldValue", field: pf.rawValue)
            }

            try Self.retirePendingFact(db: db, target: target, at: now)
        }
        return report
    }

    /// Profile-column mapping for an accepted-fact field. Wider than
    /// `profileFieldToColumn` because the accept path can write the two
    /// location-code fields, which that switch has no arm for.
    private static func appliedFactColumn(_ field: String) -> (column: String, datePrefix: String)? {
        switch field {
        case "birthDate": ("birth_date_original", "birth_date")
        case "deathDate": ("death_date_original", "death_date")
        case "birthLocationCode": ("birth_location_code", "")
        case "deathLocationCode": ("death_location_code", "")
        default: profileFieldToColumn(field).map { ($0, "") }
        }
    }

    /// Reverse the column write for a removed applied fact — but only when the
    /// column still holds that fact's value, and never by blanking a value
    /// another source still attests.
    private static func revertAppliedFactColumn(
        db: Database, target: AppliedFactTarget,
        mapping: (column: String, datePrefix: String),
        transactionID: UUID, report: inout RecordRemovalReport
    ) throws {
        let reportField = ProfileField(rawValue: target.field)
        let current = try String.fetchOne(
            db, sql: "SELECT \(mapping.column) FROM profiles WHERE id = ?",
            arguments: [target.profileID])

        // A later write owns the column, or it is already empty — dropping the
        // provenance row is the whole removal. Same directional rule that makes
        // record removal order-safe.
        guard let live = current?.trimmingCharacters(in: .whitespaces), !live.isEmpty,
              live.caseInsensitiveCompare(target.value.trimmingCharacters(in: .whitespaces)) == .orderedSame
        else {
            if let f = reportField { report.droppedCitationFields.append(f) }
            return
        }

        let survivor = try bestSurvivingValue(
            db: db, profileID: target.profileID, field: target.field,
            removedValue: target.value)

        // Another surviving source attests the SAME value — the fact is
        // corroborated, so the column stands and only the row went.
        if let survivor, survivor.caseInsensitiveCompare(target.value) == .orderedSame {
            if let f = reportField { report.sharedFields.append(f) }
            return
        }

        if !mapping.datePrefix.isEmpty {
            let p = mapping.datePrefix
            if let survivor {
                let date = GenealogicalDate(parsing: survivor)
                try db.execute(sql: """
                    UPDATE profiles SET \(p)_original = ?, \(p)_earliest = ?, \(p)_latest = ?, \(p)_qualifier = ?
                    WHERE id = ?
                    """, arguments: [date.original, date.earliest, date.latest,
                                     date.qualifier.rawValue, target.profileID])
            } else {
                // All four columns. The accept path set `_original` plus the
                // year bounds and never `_qualifier`, so nulling only
                // `_original` would leave stale bounds the scorer still reads.
                try db.execute(sql: """
                    UPDATE profiles SET \(p)_original = NULL, \(p)_earliest = NULL, \(p)_latest = NULL, \(p)_qualifier = NULL
                    WHERE id = ?
                    """, arguments: [target.profileID])
            }
        } else {
            try db.execute(sql: "UPDATE profiles SET \(mapping.column) = ? WHERE id = ?",
                           arguments: [survivor, target.profileID])
        }

        if let f = reportField { report.revertedFields.append(f) }
        try db.execute(sql: """
            INSERT INTO field_changes (id, transaction_id, entity_id, entity_kind, field, old_value, new_value, source, reason)
            VALUES (?, ?, ?, 'profile', ?, ?, ?, ?, 'applied-fact removal')
            """, arguments: [
                UUID().uuidString, transactionID.uuidString, target.profileID,
                target.field, target.value, survivor ?? "", target.origin,
            ])
    }

    /// The best value still attested for a field after a removal, or nil when
    /// nothing survives.
    ///
    /// Blanking on removal would be the obvious implementation and it destroys
    /// data: a GEDCOM or manual value that a second row still supports would
    /// vanish because an unrelated research row was binned. Ranking, highest
    /// first:
    ///   1. `SourceOrigin.tier` — userAuthoritative > researchSource > initialImport
    ///   2. not `manual.estimate` — an estimate must never displace a precise
    ///      value of the same tier (check-before-overwrite)
    ///   3. most recent `added_at`, then highest rowid
    ///
    /// Survivors whose value equals the removed one are NOT skipped — an equal
    /// survivor means the fact is corroborated, and the caller uses that to
    /// leave the column alone rather than rewrite it.
    private static func bestSurvivingValue(
        db: Database, profileID: String, field: String, removedValue: String
    ) throws -> String? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT rowid, origin, raw, added_at FROM field_sources
            WHERE entity_id = ? AND entity_kind = 'profile' AND field = ?
            """, arguments: [profileID, field])

        let ranked = rows.compactMap { row -> (tier: Int, precise: Int, at: Date, rowID: Int64, value: String)? in
            let originID: String = row["origin"] ?? ""
            let value = AppliedFactTarget.parseRaw(row["raw"] ?? "").value
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            let origin = SourceOrigin(identifier: originID)
            return (tier: origin.tier.rawValue,
                    precise: originID == "manual.estimate" ? 0 : 1,
                    at: row["added_at"] ?? Date.distantPast,
                    rowID: row["rowid"] ?? 0,
                    value: value)
        }
        .sorted {
            ($0.tier, $0.precise, $0.at, $0.rowID) > ($1.tier, $1.precise, $1.at, $1.rowID)
        }
        return ranked.first?.value
    }

    /// Put the originating `pending_facts` row back out of "accepted".
    ///
    /// Without this the fact stays `accepted` — invisible in Triage AND gone
    /// from the profile — and a resubmission upsert could silently re-land it.
    /// It goes to `rejected`, not `pending`: the user has now expressed an
    /// opinion twice, and re-queueing it for review would be nagging. The
    /// `record_rejections` row is the same key `rejectFinding` writes, so the
    /// fact cannot quietly return.
    private static func retirePendingFact(
        db: Database, target: AppliedFactTarget, at now: Date
    ) throws {
        // `addAcceptedFactProvenance` remaps baptismDate→birthDate and
        // burialDate→deathDate, so the originating row may be filed under
        // either name.
        let kinds: [String] = switch target.field {
        case "birthDate": ["birthDate", "baptismDate"]
        case "deathDate": ["deathDate", "burialDate"]
        default: [target.field]
        }
        let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
        var args: [DatabaseValueConvertible] = [target.profileID, target.value]
        args.append(contentsOf: kinds)

        guard let id = try String.fetchOne(db, sql: """
            SELECT id FROM pending_facts
            WHERE profile_id = ? AND value_json = ? AND review_status = 'accepted'
              AND fact_kind IN (\(placeholders))
            ORDER BY created_at DESC LIMIT 1
            """, arguments: StatementArguments(args))
        else { return }  // MCP-committed, or the queue row was purged

        try db.execute(sql: """
            UPDATE pending_facts SET review_status = 'rejected', reviewed_at = ? WHERE id = ?
            """, arguments: [now, id])
        try db.execute(sql: """
            INSERT OR IGNORE INTO record_rejections (profile_id, record_id, rejected_at)
            VALUES (?, ?, ?)
            """, arguments: [target.profileID, id, now])
    }

    /// If the profile column still holds the removed record's value, restore
    /// the pre-record state: `field_changes.old_value` of the write that set
    /// it, else the best surviving field_sources row, else empty. Returns true
    /// when the column changed. Journals the change under `transactionID`.
    private static func revertColumnIfLive(
        db: Database, profileID: String, target: RemovalTarget,
        removedOrigin: String, transactionID: UUID
    ) throws -> Bool {
        let current: String?
        if target.isDate {
            let prefix = target.field == .birthDate ? "birth_date" : "death_date"
            current = try String.fetchOne(db, sql: "SELECT \(prefix)_original FROM profiles WHERE id = ?",
                                          arguments: [profileID])
        } else {
            guard let column = profileFieldToColumn(target.field.rawValue) else { return false }
            current = try String.fetchOne(db, sql: "SELECT \(column) FROM profiles WHERE id = ?",
                                          arguments: [profileID])
        }
        guard let live = current?.trimmingCharacters(in: .whitespaces), !live.isEmpty,
              live.caseInsensitiveCompare(target.raw.trimmingCharacters(in: .whitespaces)) == .orderedSame
        else { return false }  // a later write owns the column, or it's empty

        // Positive proof this record's ORIGIN actually set the column: the
        // apply's overwrite/fill journals a field_changes row (source =
        // origin, new_value = the record's value). Without one, the record
        // landed as an alternative-only row — it never owned the column, so
        // dropping its row is the whole removal (return false). This is what
        // keeps a corroborating removal from clearing a value some OTHER
        // origin set, incl. the corrupt "column set, no field_sources row"
        // case that the surviving-rows fallback would have wrongly cleared.
        guard let change = try Row.fetchOne(db, sql: """
            SELECT old_value FROM field_changes
            WHERE entity_id = ? AND entity_kind = 'profile' AND field = ? AND new_value = ? AND source = ?
            ORDER BY rowid DESC LIMIT 1
            """, arguments: [profileID, target.field.rawValue, target.raw, removedOrigin])
        else { return false }

        // Pre-record value = the journalled old_value. Empty/nil → the record
        // filled an empty field, so revert to empty.
        let priorValue = (change["old_value"] as String?)?.trimmingCharacters(in: .whitespaces)
        let newValue = (priorValue?.isEmpty == false) ? priorValue : nil

        if target.isDate {
            let prefix = target.field == .birthDate ? "birth_date" : "death_date"
            if let raw = newValue {
                let date = GenealogicalDate(parsing: raw)
                try db.execute(sql: """
                    UPDATE profiles SET \(prefix)_original = ?, \(prefix)_earliest = ?, \(prefix)_latest = ?, \(prefix)_qualifier = ?
                    WHERE id = ?
                    """, arguments: [date.original, date.earliest, date.latest, date.qualifier.rawValue, profileID])
            } else {
                try db.execute(sql: """
                    UPDATE profiles SET \(prefix)_original = NULL, \(prefix)_earliest = NULL, \(prefix)_latest = NULL, \(prefix)_qualifier = NULL
                    WHERE id = ?
                    """, arguments: [profileID])
            }
        } else if let column = profileFieldToColumn(target.field.rawValue) {
            try db.execute(sql: "UPDATE profiles SET \(column) = ? WHERE id = ?",
                           arguments: [newValue, profileID])
        }

        // Journal so the removal itself is replayable (spec decision #5) —
        // no field_sources row is minted: a restore is not new provenance.
        try db.execute(sql: """
            INSERT INTO field_changes (id, transaction_id, entity_id, entity_kind, field, old_value, new_value, source, reason)
            VALUES (?, ?, ?, 'profile', ?, ?, ?, ?, 'record removal')
            """, arguments: [
                UUID().uuidString, transactionID.uuidString, profileID,
                target.field.rawValue, target.raw, newValue ?? "", removedOrigin,
            ])
        return true
    }

    /// Invert `fillRelationshipMarriage` for this record's matched spouse
    /// edge. The fill journalled nothing, but its policy bounds the inverse:
    /// location was only written when EMPTY (clearing = exact revert), the
    /// date only when strictly narrower (clearing loses a wider prior date —
    /// documented, rare). Both cleared only on exact match with what this
    /// record would have written.
    private static func revertMarriageFill(
        db: Database, profileID: String, marriage m: MarriageRecord, report: inout RecordRemovalReport
    ) throws {
        guard let spouseRaw = m.spouseName?.trimmingCharacters(in: .whitespaces), !spouseRaw.isEmpty else { return }
        let spouseSurname = (spouseRaw.split(separator: " ").last.map(String.init) ?? spouseRaw).uppercased()

        let edges = try Row.fetchAll(db, sql: """
            SELECT r.id, r.from_id, r.to_id, r.marriage_date_original, r.marriage_location
            FROM relationships r
            WHERE r.type = 'spouse' AND (r.from_id = ? OR r.to_id = ?)
            """, arguments: [profileID, profileID])
        for edge in edges {
            let fromID: String = edge["from_id"], toID: String = edge["to_id"]
            let otherID = fromID == profileID ? toID : fromID
            let otherSurname = try String.fetchOne(db, sql: "SELECT last_name FROM profiles WHERE id = ?",
                                                   arguments: [otherID]) ?? ""
            guard otherSurname.uppercased() == spouseSurname else { continue }

            let edgeID: String = edge["id"]
            let recordDate = ApplyEngine.bmdDate(year: m.marriageYear, quarter: m.quarter, exact: m.marriageDate)?.original
            if let recordDate, (edge["marriage_date_original"] as String?) == recordDate {
                try db.execute(sql: """
                    UPDATE relationships SET marriage_date_original = NULL, marriage_date_earliest = NULL,
                        marriage_date_latest = NULL, marriage_date_qualifier = NULL
                    WHERE id = ?
                    """, arguments: [edgeID])
                report.clearedMarriageDate = true
            }
            let recordPlace = (m.marriagePlace ?? m.district)?.trimmingCharacters(in: .whitespaces)
            if let recordPlace, !recordPlace.isEmpty,
               (edge["marriage_location"] as String?) == recordPlace {
                try db.execute(sql: "UPDATE relationships SET marriage_location = NULL WHERE id = ?",
                               arguments: [edgeID])
                report.clearedMarriageLocation = true
            }
            break  // apply matched at most one edge; mirror it
        }
    }

    /// Delete OPEN disputes of `kind` (optionally scoped to one field) for the
    /// profile, returning the count. Resolved rows are history and stay.
    private static func deleteOpenDisputes(
        db: Database, profileID: String, kind: String, field: String?
    ) throws -> Int {
        var sql = "SELECT COUNT(*) FROM field_disputes WHERE entity_id = ? AND entity_kind = 'profile' AND kind = ? AND resolution IS NULL"
        var args: [DatabaseValueConvertible] = [profileID, kind]
        if let field {
            sql += " AND field = ?"
            args.append(field)
        }
        let count = try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        guard count > 0 else { return 0 }
        try db.execute(sql: sql.replacingOccurrences(of: "SELECT COUNT(*) FROM", with: "DELETE FROM"),
                       arguments: StatementArguments(args))
        return count
    }
}

nonisolated extension SourceRecord {
    /// Whether this is a census record — name enrichment (and its removal
    /// inversion) excludes census names (household-HEAD fallback hazard).
    var isCensus: Bool {
        if case .census = self { return true }
        return false
    }
}
