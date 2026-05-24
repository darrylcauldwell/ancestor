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
