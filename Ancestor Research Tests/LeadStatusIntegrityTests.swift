import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// CAMPAIGN_REVIEW_SPEC Change 1 — lead status integrity.
///
/// `saveLead` is INSERT OR IGNORE (deliberate: run-created leads must not
/// clobber user decisions), but three production status flips called it and
/// silently no-opped for existing rows: in-app promote (.promoted),
/// UnifiedTasksView dismiss (.dismissed), and the lead-run finalise
/// (.investigated) — dismissed leads resurrected as .new on every reload.
/// Separately, MCP promote_lead wrote status='resolved' (not a LeadStatus
/// rawValue), so promoted leads were silently DROPPED by the loaders'
/// status guard and vanished from every in-app surface.
struct LeadStatusIntegrityTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeLead(id: String = "lead_test_1", profileID: String = "@P1@",
                          status: LeadStatus = .new,
                          relationship: String? = nil) -> Lead {
        Lead(
            id: id, profileID: profileID,
            name: "George Keyworth", surname: "Keyworth", givenName: "George",
            birthYear: 1877, deathYear: nil,
            relationship: relationship, source: .scoredLead, status: status,
            evidence: "George Keyworth, census 1901",
            createdAt: Date(), investigatedAt: nil,
            resolvedAt: nil, resolution: nil
        )
    }

    private func insertProfile(id: String, into db: ProjectDatabase) throws {
        let profile = Profile(
            id: id, externalIDs: [:],
            firstName: "George", lastName: "Keyworth", gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1877"), birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
    }

    // MARK: - The core semantics

    @Test func upsertLeadFlipsStatusForExistingRow() throws {
        let db = try makeTempDB()
        try db.saveLead(makeLead())
        var flipped = makeLead(status: .dismissed)
        flipped.resolvedAt = Date()
        flipped.resolution = .dismissed
        try db.upsertLead(flipped)
        let reloaded = try db.loadLeads(profileID: "@P1@")
        #expect(reloaded.first?.status == .dismissed,
                "upsert must land the flip; got \(String(describing: reloaded.first?.status))")
    }

    @Test func saveLeadStillPreservesExistingRows() throws {
        // The OR-IGNORE contract saveLead keeps: run-created leads never
        // clobber an existing row (that is upsertLead's job).
        let db = try makeTempDB()
        var dismissed = makeLead(status: .dismissed)
        dismissed.resolution = .dismissed
        try db.upsertLead(dismissed)
        try db.saveLead(makeLead(status: .new))  // re-run recreates — must not resurrect
        let reloaded = try db.loadLeads(profileID: "@P1@")
        #expect(reloaded.first?.status == .dismissed,
                "saveLead must not resurrect a dismissed lead")
    }

    // MARK: - The three fixed flips, end to end

    @Test func promoteLeadToProfileMarksLeadPromoted() throws {
        let db = try makeTempDB()
        try insertProfile(id: "@P1@", into: db)
        let lead = makeLead(relationship: "father")
        try db.saveLead(lead)

        let ghostID = try db.promoteLeadToProfile(lead)
        #expect(!ghostID.isEmpty)

        let reloaded = try db.loadLeads(profileID: "@P1@")
        #expect(reloaded.first?.status == .promoted,
                "promotion must persist on the lead row; got \(String(describing: reloaded.first?.status))")
        #expect(reloaded.first?.resolution == .promoted)
    }

    @Test func finaliseInvestigatedFlipSurvivesReload() throws {
        // Mirrors the ResearchRunService finalise write (now upsertLead).
        let db = try makeTempDB()
        try db.saveLead(makeLead())
        var updated = makeLead(status: .investigated)
        updated.investigatedAt = Date()
        try db.upsertLead(updated)
        #expect(try db.loadLeads(profileID: "@P1@").first?.status == .investigated)
    }

    // MARK: - Legacy MCP 'resolved' rows

    @Test func legacyResolvedStatusMapsToPromotedInsteadOfDropping() throws {
        let db = try makeTempDB()
        try db.saveLead(makeLead())
        // Simulate the old MCP promote_lead write directly.
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                UPDATE leads SET status = 'resolved', resolution = 'promoted_to_@FR_X@'
                WHERE id = 'lead_test_1'
                """)
        }
        let reloaded = try db.loadLeads(profileID: "@P1@")
        #expect(reloaded.count == 1, "legacy 'resolved' rows must not vanish")
        #expect(reloaded.first?.status == .promoted)
        // Free-string audit resolution decodes leniently to nil — row kept.
        #expect(reloaded.first?.resolution == nil)
    }

    @Test func leadStatusRawMappingIsScopedToResolved() {
        #expect(ProjectDatabase.leadStatus(fromRaw: "resolved") == .promoted)
        #expect(ProjectDatabase.leadStatus(fromRaw: "promoted") == .promoted)
        #expect(ProjectDatabase.leadStatus(fromRaw: "dismissed") == .dismissed)
        #expect(ProjectDatabase.leadStatus(fromRaw: "garbage") == nil)
    }
}
