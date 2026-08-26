import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// Thrown deliberately to force a rollback in the atomicity test below.
private struct RolledBack: Error {}

/// EV33 (owner dogfood 2026-08-26), app-side half — refusing a research
/// finding must clear BOTH of its representations.
///
/// A finding exists twice: as a suggestion row in `leads` and as a scored row
/// in `evidence_records`. The 2026-08-25 dogfood found Emma Gladwin with five
/// leads still reading `new` whose evidence rows were already
/// `user_status = 'discarded'` — so the user was being asked to re-decide
/// things she had already rejected. EV10 built the cascade; EV33 closes the
/// two holes left in it:
///
///  1. the status write and the dismissal ran as separate queue operations,
///     so a partial failure re-created the exact divergence; and
///  2. `removeAppliedRecord` (the Remove / un-apply button) writes
///     `discarded` in raw SQL and never entered the cascade at all.
///
/// Everything here touches `user_status` and `leads` only. `user_status` is
/// META — the human's review verdict on a machine-owned table — and a lead is
/// a suggestion, so none of it asserts a genealogical fact. The scorer's
/// `verdict`, gates and scores are asserted UNCHANGED throughout: the
/// deterministic sandwich is not what this sync touches.
@MainActor
struct EvidenceLeadSyncTests {

    private let profileID = "@P1@"

    // MARK: - Scaffolding

    private func makeDB() throws -> ProjectDatabase {
        let db = try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO project_meta (id, name, source_kind, source_value, created_at)
                    VALUES ('t','T','manual','',?)
                    """,
                arguments: [Date()])
        }
        return db
    }

    private func subject() -> Profile {
        Profile(id: profileID, externalIDs: [:], firstName: "Emma", middleName: nil,
                lastName: "Gladwin", gender: .female, attributes: nil,
                birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// A FreeBMD birth index row. `page` is what makes two rows the SAME GRO
    /// registration, so distinct pages here keep each test's records
    /// independent — the same-registration fan-out is EV10's suite, not this
    /// one's.
    private func birth(rowID: String, page: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: "freebmd_birth_7b_\(page)_\(rowID)", sourceID: "freebmd",
                surname: "Gladwin", givenName: "Emma", rawFields: [:]),
            birthYear: 1865, quarter: "Dec", district: "Chesterfield",
            volume: "7b", page: page))
    }

    private func scored(_ record: SourceRecord, verdict: RecordVerdict = .fact) -> ScoredRecord {
        ScoredRecord(id: record.id, record: record, verdict: verdict, gates: [],
                     summary: "Emma Gladwin, Dec 1865, Chesterfield")
    }

    @discardableResult
    private func persist(
        _ record: SourceRecord, verdict: RecordVerdict = .fact, in db: ProjectDatabase
    ) throws -> EvidenceRecord {
        try db.saveEvidence(profileID: profileID, scored: scored(record, verdict: verdict),
                            citationFull: "test citation", citationURL: nil)
        return try #require(try db.loadEvidenceForProfile(profileID)
            .first { $0.sourceRecordID == record.id })
    }

    private func lead(for record: SourceRecord, status: LeadStatus = .new) -> Lead {
        Lead(
            id: "lead_\(record.id)", profileID: profileID,
            name: "Emma Gladwin", surname: "Gladwin", givenName: "Emma",
            birthYear: 1865, deathYear: nil,
            relationship: nil, source: .scoredLead, status: status,
            evidence: "Emma Gladwin, Dec 1865, Chesterfield",
            createdAt: Date())
    }

    private func evidenceRow(
        _ db: ProjectDatabase, sourceRecordID: String
    ) throws -> EvidenceRecord {
        try #require(try db.loadEvidenceForProfile(profileID)
            .first { $0.sourceRecordID == sourceRecordID })
    }

    private func leadRow(_ db: ProjectDatabase, id: String) throws -> Lead {
        try #require(try db.loadLeads(profileID: profileID).first { $0.id == id })
    }

    // MARK: - The in-app Reject, single record

    /// The profile card's Reject button → `AppState.rejectEvidenceRecord` →
    /// `updateEvidenceUserStatus(evidenceID:status:)`. The lead joins on
    /// `"lead_" + source_record_id`, the convention the v48 backfill and
    /// `LeadStore` also use.
    @Test func rejectingARecordDismissesItsLead() throws {
        let db = try makeDB()
        let record = birth(rowID: "39326572", page: "515")
        let evidence = try persist(record, in: db)
        try db.upsertLead(lead(for: record))
        #expect(try leadRow(db, id: "lead_\(record.id)").status == .new)

        try db.updateEvidenceUserStatus(evidenceID: evidence.id, status: .discarded)

        let after = try leadRow(db, id: "lead_\(record.id)")
        #expect(after.status == .dismissed,
                "rejected in the app, still 'new' in Triage: \(after.status)")
        #expect(after.resolution == .dismissed)
        #expect(after.resolvedAt != nil)
    }

    /// Most records never produced a lead. Rejecting one must be a plain
    /// success — no throw, nothing invented.
    @Test func rejectingARecordWithNoLeadSucceeds() throws {
        let db = try makeDB()
        let record = birth(rowID: "39324032", page: "513")
        let evidence = try persist(record, in: db)
        #expect(try db.loadLeads(profileID: profileID).isEmpty)

        try db.updateEvidenceUserStatus(evidenceID: evidence.id, status: .discarded)

        #expect(try db.loadLeads(profileID: profileID).isEmpty)
        #expect(try evidenceRow(db, sourceRecordID: record.id).userStatus == .discarded)
    }

    /// Regression — the cascade is an ADDITION. The reject must still do
    /// exactly what it did before: stamp `user_status = 'discarded'`.
    @Test func rejectStillWritesDiscardedUserStatus() throws {
        let db = try makeDB()
        let record = birth(rowID: "39326572", page: "515")
        let evidence = try persist(record, in: db)
        try db.upsertLead(lead(for: record))
        #expect(try evidenceRow(db, sourceRecordID: record.id).userStatus == .unreviewed)

        try db.updateEvidenceUserStatus(evidenceID: evidence.id, status: .discarded)

        #expect(try evidenceRow(db, sourceRecordID: record.id).userStatus == .discarded)
        // And it still suppresses the record for future runs.
        #expect(try db.loadDiscardedSourceRecordIDs(profileID: profileID).contains(record.id))
    }

    /// Deterministic sandwich — the human layer writes `user_status`, never
    /// the scorer's answer. A reject leaves verdict, gates and summary exactly
    /// as the scorer left them, so the next run re-stomps them unaffected.
    @Test func rejectLeavesTheScorerVerdictUntouched() throws {
        let db = try makeDB()
        let record = birth(rowID: "39326572", page: "515")
        let evidence = try persist(record, verdict: .fact, in: db)
        try db.upsertLead(lead(for: record))
        #expect(evidence.verdict == .fact)

        try db.updateEvidenceUserStatus(evidenceID: evidence.id, status: .discarded)

        let after = try evidenceRow(db, sourceRecordID: record.id)
        #expect(after.verdict == .fact, "the reject moved a scorer-owned verdict")
        #expect(after.gates.count == evidence.gates.count)
        #expect(after.summary == evidence.summary)
    }

    /// The guard is narrowed, not removed: a promotion is the stronger, later
    /// decision, so a promoted lead is left alone.
    @Test func rejectDoesNotReopenAPromotedLead() throws {
        let db = try makeDB()
        let record = birth(rowID: "39326572", page: "515")
        let evidence = try persist(record, in: db)
        try db.upsertLead(lead(for: record, status: .promoted))

        try db.updateEvidenceUserStatus(evidenceID: evidence.id, status: .discarded)

        #expect(try leadRow(db, id: "lead_\(record.id)").status == .promoted)
    }

    /// Keeping a record must not touch its lead — only a refusal cascades.
    @Test func savingAsLeadDoesNotDismissAnything() throws {
        let db = try makeDB()
        let record = birth(rowID: "39326572", page: "515")
        let evidence = try persist(record, in: db)
        try db.upsertLead(lead(for: record))

        try db.updateEvidenceUserStatus(evidenceID: evidence.id, status: .savedAsLead)

        #expect(try leadRow(db, id: "lead_\(record.id)").status == .new)
    }

    // MARK: - The bulk path: Discard cluster

    /// `ResearchViewModel.rejectCluster` flips every record in the cluster
    /// through the batch overload. All their leads must go with them —
    /// dismissing half a cluster's leads is worse than dismissing none,
    /// because the survivors look reviewed.
    @Test func discardingAClusterDismissesEveryLeadInIt() throws {
        let db = try makeDB()
        let records = [
            birth(rowID: "a", page: "511"),
            birth(rowID: "b", page: "512"),
            birth(rowID: "c", page: "513"),
        ]
        for record in records {
            try persist(record, in: db)
            try db.upsertLead(lead(for: record))
        }

        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: records.map(\.id), status: .discarded)

        for record in records {
            #expect(try leadRow(db, id: "lead_\(record.id)").status == .dismissed,
                    "\(record.id) left its lead live")
            #expect(try evidenceRow(db, sourceRecordID: record.id).userStatus == .discarded)
        }
    }

    /// A cluster where only some records ever produced a lead: the ones
    /// without must not break the ones with.
    @Test func discardingAClusterWithSomeLeadlessRecordsSucceeds() throws {
        let db = try makeDB()
        let withLead = birth(rowID: "a", page: "511")
        let withoutLead = birth(rowID: "b", page: "512")
        try persist(withLead, in: db)
        try persist(withoutLead, in: db)
        try db.upsertLead(lead(for: withLead))

        try db.updateEvidenceUserStatus(
            profileID: profileID,
            sourceRecordIDs: [withLead.id, withoutLead.id],
            status: .discarded)

        #expect(try leadRow(db, id: "lead_\(withLead.id)").status == .dismissed)
        #expect(try db.loadLeads(profileID: profileID).count == 1)
        #expect(try evidenceRow(db, sourceRecordID: withoutLead.id).userStatus == .discarded)
    }

    // MARK: - The un-apply path

    /// EV33's second hole. `removeAppliedRecord` writes
    /// `user_status = 'discarded'` in raw SQL inside its own transaction, so
    /// it bypassed `updateEvidenceUserStatus` and never cascaded: un-applying
    /// a record left its lead in Triage at `new`, inviting the user to
    /// re-decide the thing she had just reversed.
    @Test func unApplyingARecordDismissesItsLead() throws {
        let db = try makeDB()
        try db.addProfile(subject(), source: .gedcom)
        let record = birth(rowID: "39326572", page: "515")
        let scoredRecord = scored(record)
        try db.saveEvidence(profileID: profileID, scored: scoredRecord,
                            citationFull: "test citation", citationURL: nil)
        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [record.id], status: .savedAsLead)
        let live = try #require(try db.loadProfile(id: profileID))
        _ = ApplyEngine.applyFactToSubject(
            scoredRecord, profile: live, snapshot: try db.buildSnapshot(), db: db)
        try db.upsertLead(lead(for: record))
        let evidence = try evidenceRow(db, sourceRecordID: record.id)

        let report = try db.removeAppliedRecord(evidence)

        #expect(report.dismissedLeads == 1)
        #expect(try evidenceRow(db, sourceRecordID: record.id).userStatus == .discarded)
        #expect(try leadRow(db, id: "lead_\(record.id)").status == .dismissed,
                "un-applying left the lead live in Triage")
        // The removal is still verdict-neutral.
        #expect(try evidenceRow(db, sourceRecordID: record.id).verdict == .fact)
    }

    /// An applied record that never had a lead removes cleanly.
    @Test func unApplyingARecordWithNoLeadSucceeds() throws {
        let db = try makeDB()
        try db.addProfile(subject(), source: .gedcom)
        let record = birth(rowID: "39324032", page: "513")
        let scoredRecord = scored(record)
        try db.saveEvidence(profileID: profileID, scored: scoredRecord,
                            citationFull: "test citation", citationURL: nil)
        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [record.id], status: .savedAsLead)
        let live = try #require(try db.loadProfile(id: profileID))
        _ = ApplyEngine.applyFactToSubject(
            scoredRecord, profile: live, snapshot: try db.buildSnapshot(), db: db)
        let evidence = try evidenceRow(db, sourceRecordID: record.id)

        let report = try db.removeAppliedRecord(evidence)

        #expect(report.dismissedLeads == 0)
        #expect(try evidenceRow(db, sourceRecordID: record.id).userStatus == .discarded)
        #expect(try db.loadLeads(profileID: profileID).isEmpty)
    }

    // MARK: - Atomicity

    /// The pair must live or die together. `dismissLeadsForDiscardedEvidence`
    /// now runs on the CALLER's open `Database` rather than opening its own
    /// write, so a failure anywhere in the enclosing transaction rolls back
    /// both halves — the record stays reviewable and its lead stays live,
    /// rather than the record being refused and its lead surviving.
    ///
    /// Before EV33 this test could not even be written: the only available
    /// form took the queue, and calling it from inside a write would deadlock.
    @Test func theStatusWriteAndTheLeadDismissalRollBackTogether() throws {
        let db = try makeDB()
        let record = birth(rowID: "39326572", page: "515")
        try persist(record, in: db)
        try db.upsertLead(lead(for: record))
        let evidenceID = EvidenceRecord.compositeID(
            profileID: profileID, sourceRecordID: record.id)

        #expect(throws: RolledBack.self) {
            try db.dbQueue.write { conn in
                try conn.execute(
                    sql: "UPDATE evidence_records SET user_status = 'discarded' WHERE id = ?",
                    arguments: [evidenceID])
                _ = try ProjectDatabase.dismissLeadsForDiscardedEvidence(
                    db: conn, profileID: profileID, sourceRecordIDs: [record.id])
                throw RolledBack()
            }
        }

        #expect(try evidenceRow(db, sourceRecordID: record.id).userStatus == .unreviewed,
                "the status write survived a rolled-back transaction")
        #expect(try leadRow(db, id: "lead_\(record.id)").status == .new,
                "the lead dismissal survived a rolled-back transaction")
    }

    /// The committed case of the same shape — proof the cascade genuinely
    /// works on an already-open connection and is not silently a no-op there.
    @Test func theCascadeRunsOnAnAlreadyOpenTransaction() throws {
        let db = try makeDB()
        let record = birth(rowID: "39326572", page: "515")
        try persist(record, in: db)
        try db.upsertLead(lead(for: record))
        let evidenceID = EvidenceRecord.compositeID(
            profileID: profileID, sourceRecordID: record.id)

        let dismissed = try db.dbQueue.write { conn -> Int in
            try conn.execute(
                sql: "UPDATE evidence_records SET user_status = 'discarded' WHERE id = ?",
                arguments: [evidenceID])
            return try ProjectDatabase.dismissLeadsForDiscardedEvidence(
                db: conn, profileID: profileID, sourceRecordIDs: [record.id])
        }

        #expect(dismissed == 1)
        #expect(try leadRow(db, id: "lead_\(record.id)").status == .dismissed)
    }

    // MARK: - Cross-package: the MCP half's refusal reason must reach the human

    /// EV33 verification (2026-08-26). The MCP half makes `reason` mandatory on
    /// `discard_scored_record` on the grounds that a discarded record is never
    /// re-proposed, so an unexplained discard buries evidence permanently — and
    /// it files that reason as a `workbench_notes` row. That argument only holds
    /// if the reason actually surfaces in the app.
    ///
    /// It did not. The note shipped tagged `'discard'`, which is not a `NoteTag`
    /// case; `noteFromRow` guards `NoteTag(rawValue:)` and returns nil on a
    /// miss, so `loadNotes` silently dropped every refusal reason while MCP's
    /// own raw-SQL `get_workbench_notes` still returned it. Two packages, no
    /// shared type, no compiler check — so this test replays the MCP INSERT
    /// verbatim against a REAL migrated schema and reads it back through the
    /// app's real loader.
    @Test func anMCPRefusalReasonNoteIsReadableInTheApp() throws {
        let db = try makeDB()
        let profileID = subject().id
        let now = Date()
        // Byte-for-byte the statement in MCPHandler.writeRefusalReasonNote —
        // same column list, same omission of `sensitive` (NOT NULL, DEFAULT 0).
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT OR IGNORE INTO workbench_notes
                (id, content, tag, attached_to, attachment_kind, attachment_id,
                 created_at, updated_at)
                VALUES (?, ?, ?, ?, 'profile', ?, ?, ?)
                """, arguments: [
                    UUID().uuidString,
                    "Discarded scored record freebmd_death_7b_1527_179857986 via MCP "
                        + "discard_scored_record: namesake — this is the Belper Sarah.",
                    "meta",
                    #"{"profile":{"id":"\#(profileID)"}}"#,
                    profileID, now, now,
                ])
        }

        let notes = try db.loadNotes(attachedToKind: "profile", id: profileID)
        #expect(notes.count == 1)
        #expect(notes.first?.content.contains("Belper Sarah") == true)
        #expect(notes.first?.tag == .meta)
        #expect(notes.first?.attachedTo == .profile(id: profileID))
    }

    /// Pins the `attached_to` contract from the app's side, so the literal the
    /// MCP package hard-codes is checked against the real encoder rather than
    /// against another hand-written string (EV33, 2026-08-26).
    @Test func noteAttachmentEncodesKeyedByCaseName() throws {
        let encoded = ProjectDatabase.encodeJSON(NoteAttachment.profile(id: "ABC-123"))
        #expect(encoded == #"{"profile":{"id":"ABC-123"}}"#)
    }

    /// The negative half of the above: pins the exact failure mode, so nobody
    /// re-introduces an invented tag believing the app will cope. `'discard'`
    /// is written successfully — SQLite has no enum — and then vanishes on
    /// read. Silent, which is what made it worth a test (EV33, 2026-08-26).
    @Test func aNoteTaggedWithANonNoteTagValueIsSilentlyDroppedOnRead() throws {
        let db = try makeDB()
        let profileID = subject().id
        let now = Date()
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO workbench_notes
                (id, content, tag, attached_to, attachment_kind, attachment_id,
                 created_at, updated_at)
                VALUES (?, ?, 'discard', ?, 'profile', ?, ?, ?)
                """, arguments: [
                    UUID().uuidString, "reason the user will never see",
                    // Deliberately the CORRECT attachment shape, so the tag is
                    // the only thing that can fail the decode.
                    #"{"profile":{"id":"\#(profileID)"}}"#,
                    profileID, now, now,
                ])
        }

        let rawCount = try db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM workbench_notes") ?? 0
        }
        #expect(rawCount == 1, "the row is really there")
        #expect(try db.loadNotes(attachedToKind: "profile", id: profileID).isEmpty,
                "but the app cannot decode its tag, so the human never sees it")
    }
}
