import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the lead-cleanup contract introduced when we discovered that
/// re-running research was resetting user-set lead statuses back to `.new`
/// (because `saveLead` used `INSERT OR REPLACE`), and that household-member
/// lead IDs used Swift's process-randomised `hashValue` — producing
/// different IDs every app launch and breaking cross-run dedup.
///
/// Invariants under test:
///   1. `saveLead` is `INSERT OR IGNORE` — re-creating a lead with the same
///      id preserves the existing row's status, evidence, and timestamps.
///   2. `upsertLead` is `INSERT OR REPLACE` — explicit transitions through
///      `updateStatus` / `promote` do overwrite the row.
///   3. Household-member lead IDs are deterministic across processes.
struct LeadStorePersistenceTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeLead(
        id: String = "lead_test",
        profileID: String = "p1",
        status: LeadStatus = .new,
        evidence: String = "original"
    ) -> Lead {
        Lead(
            id: id, profileID: profileID,
            name: "Test Person", surname: "Person", givenName: "Test",
            birthYear: 1900, deathYear: nil, relationship: nil,
            source: .scoredLead, status: status, evidence: evidence,
            createdAt: Date(), investigatedAt: nil, resolvedAt: nil,
            resolution: nil
        )
    }

    // MARK: - Invariant 1: saveLead preserves user state

    @Test func saveLeadIgnoresWhenRowExists_preservingUserStatus() throws {
        let db = try makeTempDB()
        let original = makeLead(status: .investigating, evidence: "user marked investigating")
        try db.saveLead(original)

        // Simulate a re-research pass surfacing the same record with status=.new
        let resurfaced = makeLead(status: .new, evidence: "fresh-run summary")
        try db.saveLead(resurfaced)

        let loaded = try db.loadLeads()
        #expect(loaded.count == 1)
        #expect(loaded.first?.status == .investigating,
                "saveLead must not clobber user-set status on re-emergence")
        #expect(loaded.first?.evidence == "user marked investigating",
                "evidence string should be preserved too — user state is sacred")
    }

    // MARK: - Invariant 2: upsertLead overwrites

    @Test func upsertLeadReplacesExistingRow() throws {
        let db = try makeTempDB()
        try db.saveLead(makeLead(status: .new))

        let promoted = makeLead(status: .promoted, evidence: "after promote")
        try db.upsertLead(promoted)

        let loaded = try db.loadLeads()
        #expect(loaded.count == 1)
        #expect(loaded.first?.status == .promoted)
        #expect(loaded.first?.evidence == "after promote")
    }

    // MARK: - v47: age-at-death + place survive persistence and status flips

    @Test func ageAtDeathAndPlaceRoundTripThroughDB() throws {
        let db = try makeTempDB()
        let lead = Lead(
            id: "lead_ap", profileID: "p1",
            name: "George Ward", surname: "Ward", givenName: "George",
            birthYear: nil, deathYear: 1960, ageAtDeath: 74, place: "Wollaton Cemetery",
            relationship: nil, source: .scoredLead, status: .new,
            evidence: "burial", createdAt: Date()
        )
        try db.saveLead(lead)

        let loaded = try #require(try db.loadLeads().first)
        #expect(loaded.ageAtDeath == 74)
        #expect(loaded.place == "Wollaton Cemetery")
        #expect(loaded.effectiveBirthYear == 1886)
    }

    @Test func statusFlipPreservesAgeAtDeathAndPlace() async throws {
        // The trap this whole change had to avoid: a reconstruction site
        // dropping the new fields on a status update. updateStatus rebuilds
        // the Lead — the age/place must survive.
        let db = try makeTempDB()
        let store = LeadStore(db: db)
        let lead = Lead(
            id: "lead_flip", profileID: "p1",
            name: "George Ward", surname: "Ward", givenName: "George",
            birthYear: nil, deathYear: 1960, ageAtDeath: 74, place: "Wollaton Cemetery",
            relationship: nil, source: .scoredLead, status: .new,
            evidence: "burial", createdAt: Date()
        )
        try db.saveLead(lead)
        try await store.loadAll()
        try await store.updateStatus("lead_flip", status: .investigated)

        let reloaded = try #require(try db.loadLeads().first)
        #expect(reloaded.status == .investigated)
        #expect(reloaded.ageAtDeath == 74, "age-at-death must survive a status flip")
        #expect(reloaded.place == "Wollaton Cemetery", "place must survive a status flip")
    }

    // MARK: - v48: backfill age/place from persisted source records

    @Test func backfillProjectsAgeAndPlaceFromEvidenceRecord() throws {
        let db = try makeTempDB()

        // A death record with an age + district, as it would already be
        // persisted in evidence_records for a pre-v47 lead.
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "rec_death_1", sourceID: "freebmd", rawFields: [:]),
            deathYear: 1960, age: 74, district: "Basford"
        ))
        let scored = ScoredRecord(id: "rec_death_1", record: record,
                                  verdict: .lead, gates: [], summary: "death")
        try db.saveEvidence(profileID: "p1", scored: scored,
                            citationFull: nil, citationURL: nil)

        // The lead as it exists pre-backfill: nil age/place, id embeds the
        // source-record id.
        let lead = Lead(
            id: "lead_rec_death_1", profileID: "p1",
            name: "George Ward", surname: "Ward", givenName: "George",
            birthYear: nil, deathYear: 1960, ageAtDeath: nil, place: nil,
            relationship: nil, source: .scoredLead, status: .new,
            evidence: "death", createdAt: Date()
        )
        try db.saveLead(lead)

        let updated = try db.runLeadAgePlaceBackfill()
        #expect(updated == 1)

        let reloaded = try #require(try db.loadLeads().first)
        #expect(reloaded.ageAtDeath == 74)
        #expect(reloaded.place == "Basford")
        #expect(reloaded.effectiveBirthYear == 1886, "implied birth now available for blocking")
    }

    @Test func backfillIsIdempotentAndSkipsAlreadyFilledLeads() throws {
        let db = try makeTempDB()
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "rec_death_2", sourceID: "freebmd", rawFields: [:]),
            deathYear: 1950, age: 60, district: "Belper"
        ))
        try db.saveEvidence(
            profileID: "p1",
            scored: ScoredRecord(id: "rec_death_2", record: record,
                                 verdict: .lead, gates: [], summary: "death"),
            citationFull: nil, citationURL: nil
        )
        // Lead already carries age/place (post-v47 creation) — must be left alone.
        try db.saveLead(Lead(
            id: "lead_rec_death_2", profileID: "p1",
            name: "Ann Ward", surname: "Ward", givenName: "Ann",
            birthYear: nil, deathYear: 1950, ageAtDeath: 60, place: "Belper",
            relationship: nil, source: .scoredLead, status: .new,
            evidence: "death", createdAt: Date()
        ))

        let updated = try db.runLeadAgePlaceBackfill()
        #expect(updated == 0, "already-filled leads are not re-touched")

        // Second pass finds nothing to do either.
        let again = try db.runLeadAgePlaceBackfill()
        #expect(again == 0)
    }

    // MARK: - Invariant 3: household-member id is deterministic

    @Test func householdMemberLeadIDIsDeterministicAcrossInstances() async throws {
        let db1 = try makeTempDB()
        let store1 = LeadStore(db: db1)
        let member = HouseholdMember(
            name: "John Smith", relationship: "son",
            age: 5, birthYear: 1906, birthPlace: nil,
            occupation: nil, sex: "M"
        )
        let lead1 = try await store1.createFromHouseholdMember(member, profileID: "p1", censusYear: 1911)

        let db2 = try makeTempDB()
        let store2 = LeadStore(db: db2)
        let lead2 = try await store2.createFromHouseholdMember(member, profileID: "p1", censusYear: 1911)

        #expect(lead1.id == lead2.id,
                "same name+year must produce same lead.id across LeadStore instances")
        #expect(!lead1.id.contains("-"),
                "id must not contain a negative-number marker (the old hashValue formula could produce these)")
    }
}
