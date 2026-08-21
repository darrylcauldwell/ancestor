import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Triage could not show a lead unless the profile had a research RUN.
///
/// `BulkReviewView` gathered leads inside its loop over
/// `CampaignReviewService.campaignEntries`, and that list is built purely from
/// `research_run_requests`. So a lead on a profile with no request in the
/// window was structurally invisible however new it was — and the loop
/// additionally `continue`s past any profile whose result cannot be
/// reconstructed, taking that profile's leads with it.
///
/// Several paths create a lead with no run at all: MCP `submit_lead`, household
/// absorption, manual entry. Owner report 2026-08-21 — two children found in a
/// 1901 census, submitted over MCP, absent from Triage, reachable only by
/// knowing which profile to open. That is not a surface.
///
/// A lead is a finding in its own right. `campaignLeads` therefore reads the
/// whole store and never consults run requests.
@MainActor
struct CampaignLeadVisibilityTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func lead(
        _ id: String, profileID: String = "@P1@",
        status: LeadStatus = .new, createdAt: Date
    ) -> Lead {
        Lead(id: id, profileID: profileID, name: "Lilian A Land",
             surname: "Land", givenName: "Lilian", birthYear: 1893, deathYear: nil,
             relationship: "child", source: .householdMember, status: status,
             evidence: "1901 census, Wirksworth — daughter aged 8", createdAt: createdAt)
    }

    // MARK: - The regression

    /// THE CASE. No run request exists for this profile at all — the state MCP
    /// submissions always leave behind, since MCP cannot create a run.
    @Test func aLeadIsVisibleWithNoRunRequestAtAll() throws {
        let db = try makeDB()
        try db.saveLead(lead("l1", createdAt: Date()))

        #expect(CampaignReviewService.campaignEntries(
            since: .distantPast, db: db).isEmpty,
            "premise: nothing has been researched, so Triage has no entries")

        let gathered = CampaignReviewService.campaignLeads(since: .distantPast, db: db)
        #expect(gathered.leads.map(\.id) == ["l1"],
                "the lead must surface anyway — it does not need a run to justify it")
    }

    /// Leads for MANY profiles surface together, none of them researched.
    /// The owner's actual case was two children on one profile; this pins that
    /// the gather is not accidentally per-profile.
    @Test func leadsAcrossSeveralUnresearchedProfilesAllSurface() throws {
        let db = try makeDB()
        try db.saveLead(lead("l1", profileID: "@P1@", createdAt: Date()))
        try db.saveLead(lead("l2", profileID: "@P1@", createdAt: Date()))
        try db.saveLead(lead("l3", profileID: "@P2@", createdAt: Date()))

        let gathered = CampaignReviewService.campaignLeads(since: .distantPast, db: db)
        #expect(Set(gathered.leads.map(\.id)) == ["l1", "l2", "l3"])
    }

    // MARK: - The window still applies

    @Test func aLeadOlderThanTheWindowIsExcluded() throws {
        let db = try makeDB()
        let old = Date().addingTimeInterval(-30 * 24 * 3600)
        try db.saveLead(lead("old", createdAt: old))
        try db.saveLead(lead("new", createdAt: Date()))

        let week = Date().addingTimeInterval(-7 * 24 * 3600)
        #expect(CampaignReviewService.campaignLeads(since: week, db: db)
            .leads.map(\.id) == ["new"])
        #expect(Set(CampaignReviewService.campaignLeads(since: .distantPast, db: db)
            .leads.map(\.id)) == ["old", "new"],
            "…and 'Show earlier findings' widens to everything")
    }

    // MARK: - Status routing is unchanged

    @Test func dismissedLeadsGoToTheirOwnBucket() throws {
        let db = try makeDB()
        try db.saveLead(lead("kept", status: .new, createdAt: Date()))
        try db.saveLead(lead("gone", status: .dismissed, createdAt: Date()))

        let gathered = CampaignReviewService.campaignLeads(since: .distantPast, db: db)
        #expect(gathered.leads.map(\.id) == ["kept"])
        #expect(gathered.dismissed.map(\.id) == ["gone"])
    }

    @Test func investigatedLeadsAwaitADecisionAndAreShown() throws {
        let db = try makeDB()
        try db.saveLead(lead("l1", status: .investigated, createdAt: Date()))
        #expect(CampaignReviewService.campaignLeads(since: .distantPast, db: db)
            .leads.map(\.id) == ["l1"])
    }

    /// In flight, or already a profile — neither is awaiting a decision, so
    /// neither belongs in a review queue.
    @Test func inFlightAndPromotedLeadsAreNotShown() throws {
        let db = try makeDB()
        try db.saveLead(lead("running", status: .investigating, createdAt: Date()))
        try db.saveLead(lead("done", status: .promoted, createdAt: Date()))

        let gathered = CampaignReviewService.campaignLeads(since: .distantPast, db: db)
        #expect(gathered.leads.isEmpty)
        #expect(gathered.dismissed.isEmpty)
    }

    @Test func anEmptyStoreYieldsNothing() throws {
        let gathered = try CampaignReviewService.campaignLeads(
            since: .distantPast, db: makeDB())
        #expect(gathered.leads.isEmpty)
        #expect(gathered.dismissed.isEmpty)
    }
}
