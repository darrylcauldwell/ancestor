import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// An accepted fact with no evidence record could never be removed.
///
/// The Sources & Records ledger — the only surface with a bin — was built
/// solely from `loadEvidenceForProfile(...).filter { $0.userStatus == .savedAsLead }`,
/// i.e. `evidence_records`. But the pending-facts accept path writes a profile
/// column plus a single `field_sources` row and creates no evidence record at
/// all. Such facts therefore appeared in no ledger and `removeAppliedRecord`
/// could not reach them: applying was one-way.
///
/// Live case 2026-08-21: the owner's own profile `John Cauldwell b.1861`
/// carried THREE accepted death dates — 1885, 1901 and 1929 — all written by
/// the app's own research pipeline in one run and all accepted in review. A man
/// cannot die three times, and there was no way to take any of them off.
///
/// The removal deliberately does NOT blank the column. It recomputes from
/// whatever provenance survives, because binning one of several sources must
/// never destroy a value another source still attests.
@MainActor
struct AppliedFactRemovalTests {

    // MARK: - Scaffolding

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        _ = try db.addProfile(
            Profile(id: "p", firstName: "John", lastName: "Cauldwell", gender: .male,
                    birthDate: GenealogicalDate(parsing: "1861"),
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        return db
    }

    /// Seed via the REAL accept path so the fixture has full fidelity — the
    /// bare column UPDATE with no transaction and no field_changes row is
    /// exactly what makes this case awkward to reverse.
    private func accept(
        _ db: ProjectDatabase, field: String, value: String,
        title: String = "freebmd", origin: String = "research-run",
        url: String? = nil
    ) throws {
        try db.applyAcceptedPendingFact(profileID: "p", field: field, value: value)
        try db.addAcceptedFactProvenance(
            profileID: "p", field: field, value: value,
            sourceTitle: title, sourceURL: url, origin: origin)
    }

    private func column(_ db: ProjectDatabase, _ sql: String) throws -> String? {
        try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT \(sql) FROM profiles WHERE id = 'p'")
        }
    }

    /// Only the REMOVABLE rows. `makeDB`'s `addProfile(source: .manual)` seeds
    /// manual-origin rows for the name and birth date, which are deliberately
    /// excluded from the bin — filter them here the same way the ledger does,
    /// so a count assertion means what it looks like it means.
    private func targets(_ db: ProjectDatabase) throws -> [AppliedFactTarget] {
        try db.appliedFactProvenanceRows(profileID: "p").filter {
            let origin = SourceOrigin(identifier: $0.origin)
            return origin.tier != .initialImport && !origin.isManual
        }
    }

    private func target(_ db: ProjectDatabase, field: String, value: String) throws -> AppliedFactTarget {
        try #require(try targets(db).first { $0.field == field && $0.value == value })
    }

    // MARK: - Ledger surfacing

    @Test func anAcceptedFactWithNoSourceRecordAppearsInTheLedger() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929")

        let entries = try ProfileSourcesLedger.entries(for: "p", db: db)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(!entry.isSourceRecord)
        #expect(entry.recordType == nil, "an applied fact never met the scorer")
        #expect(entry.verdict == nil)
        #expect(entry.id.hasPrefix("fs:"), "id namespace must not collide with record ids")
        #expect(entry.establishes == ["death date 1929"])
    }

    /// The user's own data has no re-apply route if deleted and Edit already
    /// covers it — a bin next to it would be a one-way destroy button.
    @Test func importedAndManualProvenanceCarryNoBin() throws {
        let db = try makeDB()
        for origin in ["gedcom", "wikitree", "manual", "manual.memory", "manual.estimate"] {
            try db.addAcceptedFactProvenance(
                profileID: "p", field: "birthLocation", value: "Windley",
                sourceTitle: "t", origin: origin)
        }
        #expect(try ProfileSourcesLedger.entries(for: "p", db: db).isEmpty)
    }

    /// Two identical accepts write two byte-identical rows with distinct
    /// rowids. The list must not show a phantom duplicate.
    @Test func twoIdenticalAcceptsCollapseToOneLedgerRow() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929")
        try accept(db, field: "deathDate", value: "1929")

        #expect(try targets(db).count == 2, "both rows exist in the table")
        #expect(try ProfileSourcesLedger.entries(for: "p", db: db).count == 1,
                "but the ledger shows one")
    }

    /// The direct query must see rows `ProfileField(rawValue:)` rejects —
    /// `Profile.sources` silently drops them, which is exactly how event-shaped
    /// facts became invisible.
    @Test func anAcceptedOccupationSurfacesEvenThoughProfileSourcesDropsIt() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "p", field: "occupation", value: "Ag Lab",
            payloadJSON: #"{"event_date":"1871","event_location":"Mugginton"}"#)
        try db.addAcceptedFactProvenance(
            profileID: "p", field: "occupation", value: "Ag Lab",
            sourceTitle: "1871 census", origin: "field-researcher")

        #expect(ProfileField(rawValue: "occupation") == nil, "precondition")
        let entries = try ProfileSourcesLedger.entries(for: "p", db: db)
        #expect(entries.count == 1)
        #expect(entries.first?.establishes == ["occupation Ag Lab"])
    }

    // MARK: - Removal: the owner's case

    @Test func removingTheAcceptedDeathDateTakesItOffTheProfile() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929")
        #expect(try column(db, "death_date_original") == "1929")

        let report = try db.removeAppliedFact(try target(db, field: "deathDate", value: "1929"))

        #expect(try column(db, "death_date_original") == nil)
        #expect(report.revertedFields == [.deathDate])
        #expect(report.transactionID != nil)
        #expect(try targets(db).isEmpty)
    }

    /// Three contradictory dates, exactly as the owner's profile held them.
    /// Removing the live one falls back to the next attested value rather than
    /// blanking — and three clicks empties the field without inventing anything.
    @Test func removingTheNewestOfThreeAcceptedDatesFallsBackToTheNextAttested() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1885")
        try accept(db, field: "deathDate", value: "1901")
        try accept(db, field: "deathDate", value: "1929")
        #expect(try column(db, "death_date_original") == "1929")

        try db.removeAppliedFact(try target(db, field: "deathDate", value: "1929"))
        #expect(try column(db, "death_date_original") == "1901")

        try db.removeAppliedFact(try target(db, field: "deathDate", value: "1901"))
        #expect(try column(db, "death_date_original") == "1885")

        try db.removeAppliedFact(try target(db, field: "deathDate", value: "1885"))
        #expect(try column(db, "death_date_original") == nil)
        #expect(try targets(db).isEmpty)
    }

    /// THE DATA-LOSS GUARD. A GEDCOM value the user imported must survive the
    /// removal of an unrelated research row that displaced it.
    @Test func removalNeverBlanksAValueAnotherSourceStillAttests() throws {
        let db = try makeDB()
        try db.addAcceptedFactProvenance(
            profileID: "p", field: "deathDate", value: "1901",
            sourceTitle: "GEDCOM import", origin: "gedcom")
        try accept(db, field: "deathDate", value: "1929")
        #expect(try column(db, "death_date_original") == "1929")

        try db.removeAppliedFact(try target(db, field: "deathDate", value: "1929"))

        #expect(try column(db, "death_date_original") == "1901",
                "the gedcom value must come back, not be blanked")
        let rows = try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT origin FROM field_sources WHERE entity_id = 'p' AND field = 'deathDate'")
                .map { $0["origin"] as String? ?? "" }
        }
        #expect(rows == ["gedcom"], "the gedcom provenance row must survive")
    }

    /// A corroborating removal drops the row and keeps the value — the column
    /// is still supported, so touching it would be wrong.
    @Test func aCorroboratingRemovalDropsTheRowAndKeepsTheValue() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929", title: "freebmd", origin: "research-run")
        try accept(db, field: "deathDate", value: "1929", title: "freecen", origin: "field-researcher")

        let report = try db.removeAppliedFact(
            try #require(try targets(db).first { $0.origin == "field-researcher" }))

        #expect(try column(db, "death_date_original") == "1929")
        #expect(report.sharedFields == [.deathDate])
        #expect(report.revertedFields.isEmpty)
    }

    /// Order safety: a later write owns the column, so removal drops only the
    /// provenance row.
    @Test func removalNeverTouchesAColumnALaterWriteOwns() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929")
        let t = try target(db, field: "deathDate", value: "1929")
        try db.applyAcceptedPendingFact(profileID: "p", field: "deathDate", value: "1931")

        let report = try db.removeAppliedFact(t)

        #expect(try column(db, "death_date_original") == "1931")
        #expect(report.droppedCitationFields == [.deathDate])
        #expect(report.revertedFields.isEmpty)
    }

    /// An estimate must never be installed over a precise value of the same
    /// tier by a removal — check-before-overwrite.
    @Test func anEstimateNeverDisplacesAPreciseValueOfTheSameTier() throws {
        let db = try makeDB()
        try db.addAcceptedFactProvenance(
            profileID: "p", field: "birthLocation", value: "Windley, Derbyshire",
            sourceTitle: "1871 census", origin: "manual.record")
        try db.addAcceptedFactProvenance(
            profileID: "p", field: "birthLocation", value: "Derbyshire",
            sourceTitle: "guess", origin: "manual.estimate")
        try accept(db, field: "birthLocation", value: "Mugginton")

        try db.removeAppliedFact(try target(db, field: "birthLocation", value: "Mugginton"))

        #expect(try column(db, "birth_location") == "Windley, Derbyshire",
                "the precise manual.record value must win over manual.estimate")
    }

    // MARK: - Removal: other landings and bookkeeping

    @Test func removingAnAcceptedOccupationDeletesItsLifeEvent() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "p", field: "occupation", value: "Ag Lab",
            payloadJSON: #"{"event_date":"1871","event_location":"Mugginton"}"#)
        try db.addAcceptedFactProvenance(
            profileID: "p", field: "occupation", value: "Ag Lab",
            sourceTitle: "1871 census", origin: "field-researcher")
        #expect(try db.loadLifeEvents(profileID: "p").count == 1)

        let report = try db.removeAppliedFact(try target(db, field: "occupation", value: "Ag Lab"))

        #expect(try db.loadLifeEvents(profileID: "p").isEmpty)
        #expect(report.deletedLifeEvents == 1)
    }

    /// Without this the fact would be invisible in Triage AND gone from the
    /// profile, and a resubmission upsert could silently re-land it.
    @Test func removingAnAcceptedFactPutsThePendingFactBackToRejected() throws {
        let db = try makeDB()
        let fact = PendingFact(
            id: "pf1", profileID: "p", field: "deathDate", value: "1929",
            sourceURL: "", sourceTitle: "freebmd", evidenceText: "e",
            reasoning: "r", confidence: "high", agentID: "research-run",
            submittedAt: Date(), verificationStatus: .verified)
        try db.savePendingFact(fact)
        try db.updatePendingFactStatus(id: "pf1", status: "accepted", verificationStatus: "verified")
        try accept(db, field: "deathDate", value: "1929")

        try db.removeAppliedFact(try target(db, field: "deathDate", value: "1929"))

        let status = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT review_status FROM pending_facts WHERE id = 'pf1'")
        }
        #expect(status == "rejected")
        let rejected = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM record_rejections WHERE profile_id = 'p' AND record_id = 'pf1'")
        }
        #expect(rejected == 1, "rejection memory must stop it returning")
    }

    /// A stale click — the row went while the list was on screen — must be a
    /// clean no-op, not a crash and not a phantom transaction.
    @Test func removalOfAnAlreadyDeletedRowIsANoOp() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929")
        let t = try target(db, field: "deathDate", value: "1929")
        try db.removeAppliedFact(t)

        let report = try db.removeAppliedFact(t)

        #expect(report.transactionID == nil)
        #expect(report.revertedFields.isEmpty)
        #expect(try column(db, "death_date_original") == nil)
    }

    /// The rowid-versus-tuple guard. `field_sources` has no UNIQUE constraint
    /// and a tuple-keyed DELETE has no LIMIT, so it would take both rows.
    @Test func theBinRemovesExactlyOneOfTwoIdenticalProvenanceRows() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929")
        try accept(db, field: "deathDate", value: "1929")
        #expect(try targets(db).count == 2)

        try db.removeAppliedFact(try #require(try targets(db).first))

        #expect(try targets(db).count == 1, "exactly one row removed, not both")
        #expect(try column(db, "death_date_original") == "1929",
                "the surviving duplicate still attests the value")
    }

    /// A removal must not leave stale date bounds behind: the accept path sets
    /// `_original`, `_earliest` and `_latest` but never `_qualifier`, and the
    /// scorer reads the bounds even when `_original` is null.
    @Test func removingTheLastAcceptedDateClearsAllFourDateColumns() throws {
        let db = try makeDB()
        try accept(db, field: "deathDate", value: "1929")
        try db.removeAppliedFact(try target(db, field: "deathDate", value: "1929"))

        let row = try db.dbQueue.read { d in
            try Row.fetchOne(d, sql: "SELECT death_date_original, death_date_earliest, death_date_latest, death_date_qualifier FROM profiles WHERE id = 'p'")
        }
        let r = try #require(row)
        #expect(r["death_date_original"] == nil)
        #expect(r["death_date_earliest"] == nil)
        #expect(r["death_date_latest"] == nil)
        #expect(r["death_date_qualifier"] == nil)
    }

    // MARK: - Raw parsing

    /// `addAcceptedFactProvenance` stores `"<value> [<title>]"`, so the value
    /// has to be recovered before it can be compared with the profile column.
    @Test func rawWithABracketedTitleParsesBackToTheBareValue() throws {
        #expect(AppliedFactTarget.parseRaw("1929 [freebmd]").value == "1929")
        #expect(AppliedFactTarget.parseRaw("1929 [freebmd]").title == "freebmd")
        // A title that itself contains " [" — split on the LAST one.
        let nested = AppliedFactTarget.parseRaw("1929 [census [1871] household]")
        #expect(nested.value == "1929 [census")
        #expect(nested.title == "1871] household")
        // No bracket at all — every non-accept writer.
        #expect(AppliedFactTarget.parseRaw("1929").value == "1929")
        #expect(AppliedFactTarget.parseRaw("1929").title == nil)
    }
}
