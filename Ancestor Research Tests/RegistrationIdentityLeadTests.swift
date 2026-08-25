import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// EV10 (owner dogfood 2026-08-25) — one GRO registration, many index rows.
///
/// "Emma Gladwin, Dec 1865, Chesterfield 7b/515" was discarded as FreeBMD row
/// …39326572 and a later run re-created the SAME registration as …39324032.
/// `saveLead`'s `INSERT OR IGNORE` dedupes on the lead id, which is derived
/// from the SOURCE ROW id, so the twin sailed straight past it — and the five
/// leads whose evidence rows the user had already discarded were all still
/// sitting at status `new`.
struct RegistrationIdentityLeadTests {

    private let profileID = "@P1@"

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func gladwinBirth(
        rowID: String, page: String = "515", quarter: String? = "Dec",
        volume: String? = "7b"
    ) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: "freebmd_birth_7b_\(page)_\(rowID)", sourceID: "freebmd",
                surname: "Gladwin", givenName: "Emma", rawFields: [:]),
            birthYear: 1865, quarter: quarter, district: "Chesterfield",
            volume: volume, page: page))
    }

    private func scored(_ record: SourceRecord) -> ScoredRecord {
        ScoredRecord(id: record.id, record: record, verdict: .lead, gates: [],
                     summary: "Emma Gladwin, Dec 1865, Chesterfield 7b/515")
    }

    private func lead(for record: SourceRecord) -> Lead {
        Lead(
            id: "lead_\(record.id)", profileID: profileID,
            name: "Emma Gladwin", surname: "Gladwin", givenName: "Emma",
            birthYear: 1865, deathYear: nil,
            relationship: nil, source: .scoredLead, status: .new,
            evidence: "Emma Gladwin, Dec 1865, Chesterfield 7b/515",
            createdAt: Date())
    }

    private func persist(_ record: SourceRecord, in db: ProjectDatabase) throws {
        try db.saveEvidence(
            profileID: profileID, scored: scored(record),
            citationFull: nil, citationURL: nil)
    }

    // MARK: - The discard cascade

    @Test func discardingEvidenceDismissesItsLead() throws {
        let db = try makeDB()
        let record = gladwinBirth(rowID: "39326572")
        try persist(record, in: db)
        try db.saveLead(lead(for: record))
        let before = try db.loadLeads(profileID: profileID)
        #expect(before.first?.status == .new)

        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [record.id], status: .discarded)

        let after = try db.loadLeads(profileID: profileID)
        #expect(after.count == 1)
        #expect(after.first?.status == .dismissed,
                "a discarded record's lead stayed live in Triage: \(String(describing: after.first?.status))")
        #expect(after.first?.resolution == .dismissed)
    }

    /// The cascade reaches the OTHER index rows of the same registration too —
    /// that is how Emma ended up with five `new` leads for one rejected entry.
    /// Seeded with `upsertLead` because those rows predate the suppression the
    /// second half of this suite covers.
    @Test func discardDismissesLeadsOfTheSameRegistrationsTwins() throws {
        let db = try makeDB()
        let first = gladwinBirth(rowID: "39326572")
        let twin = gladwinBirth(rowID: "39324032")
        try persist(first, in: db)
        try persist(twin, in: db)
        try db.upsertLead(lead(for: first))
        try db.upsertLead(lead(for: twin))

        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [first.id], status: .discarded)

        let live = try db.loadLeads(profileID: profileID).filter { $0.status == .new }
        #expect(live.isEmpty, "twin index rows of a rejected registration stayed live: \(live.map(\.id))")
    }

    /// A promotion is the stronger, later decision and is never taken back.
    @Test func discardLeavesAPromotedLeadAlone() throws {
        let db = try makeDB()
        let record = gladwinBirth(rowID: "39326572")
        try persist(record, in: db)
        try db.upsertLead(lead(for: record).with(status: .promoted, resolvedAt: Date(), resolution: .promoted))

        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [record.id], status: .discarded)

        let reloaded = try db.loadLeads(profileID: profileID)
        #expect(reloaded.first?.status == .promoted)
    }

    // MARK: - Suppression on re-run

    @Test func aDiscardedRegistrationDoesNotReturnUnderANewRowID() throws {
        let db = try makeDB()
        let first = gladwinBirth(rowID: "39326572")
        try persist(first, in: db)
        try db.saveLead(lead(for: first))
        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [first.id], status: .discarded)

        let twin = gladwinBirth(rowID: "39324032")
        try persist(twin, in: db)
        try db.saveLead(lead(for: twin))

        let ids = Set(try db.loadLeads(profileID: profileID).map(\.id))
        #expect(!ids.contains("lead_\(twin.id)"),
                "the rejected registration came back wearing a new row id: \(ids)")
    }

    /// Even without a discard, two index rows of one registration are one
    /// candidate — the second must not add a second Triage row.
    @Test func aSecondIndexRowOfTheSameRegistrationDoesNotDuplicateTheLead() throws {
        let db = try makeDB()
        let first = gladwinBirth(rowID: "39326572")
        let twin = gladwinBirth(rowID: "39324032")
        try persist(first, in: db)
        try db.saveLead(lead(for: first))
        try persist(twin, in: db)
        try db.saveLead(lead(for: twin))

        let reloaded = try db.loadLeads(profileID: profileID)
        #expect(reloaded.count == 1)
    }

    /// The guard must not swallow a genuinely different registration.
    @Test func aDifferentRegistrationStillGetsItsOwnLead() throws {
        let db = try makeDB()
        let first = gladwinBirth(rowID: "39326572")
        try persist(first, in: db)
        try db.saveLead(lead(for: first))
        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [first.id], status: .discarded)

        let other = gladwinBirth(rowID: "40000001", page: "601")
        try persist(other, in: db)
        try db.saveLead(lead(for: other))

        let ids = Set(try db.loadLeads(profileID: profileID).map(\.id))
        #expect(ids.contains("lead_\(other.id)"))
    }

    /// No volume/page — no registration identity. Those records keep the
    /// row-id behaviour exactly as before.
    @Test func aRecordWithoutVolumeOrPageFallsBackToRowIdentity() throws {
        let db = try makeDB()
        let first = gladwinBirth(rowID: "a", volume: nil)
        try persist(first, in: db)
        try db.saveLead(lead(for: first))
        try db.updateEvidenceUserStatus(
            profileID: profileID, sourceRecordIDs: [first.id], status: .discarded)

        let second = gladwinBirth(rowID: "b", volume: nil)
        try persist(second, in: db)
        try db.saveLead(lead(for: second))

        let ids = Set(try db.loadLeads(profileID: profileID).map(\.id))
        #expect(ids.contains("lead_\(second.id)"))
    }

    // MARK: - The identity rule itself

    /// FreeBMD volume/page numbering restarts each quarter, so a stated
    /// quarter is part of the registration's identity.
    @Test func differentQuartersAreDifferentRegistrations() {
        let dec = gladwinBirth(rowID: "1", quarter: "Dec")
        let mar = gladwinBirth(rowID: "2", quarter: "Mar")
        #expect(!RecordScorer.isSameRegistration(dec, mar))
    }

    /// A row that OMITS the quarter cannot be told apart on that basis and
    /// must not be split off for the omission.
    @Test func anAbsentQuarterDoesNotSplitARegistration() {
        let stated = gladwinBirth(rowID: "1", quarter: "Dec")
        let silent = gladwinBirth(rowID: "2", quarter: nil)
        #expect(RecordScorer.isSameRegistration(stated, silent))
    }

    @Test func quarterComparisonIgnoresCaseAndPadding() {
        let a = gladwinBirth(rowID: "1", quarter: "Dec")
        let b = gladwinBirth(rowID: "2", quarter: " DEC ")
        #expect(RecordScorer.isSameRegistration(a, b))
    }
}
