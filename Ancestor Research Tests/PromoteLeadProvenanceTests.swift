import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Promoting a lead stamped its profile fields as FreeBMD-sourced.
///
/// `promoteLeadToProfile` passed `source: .freebmd` to `addFamily` regardless of
/// where the lead came from — a census household, a FindAGrave memorial, an MCP
/// submission. That is fabricated provenance, and it actively misleads.
///
/// Live case 2026-08-21: George W Land was promoted from a lead whose birth year
/// the owner's assistant had derived by arithmetic from a census age (3 on
/// 31 Mar 1901 → born Apr 1897–Mar 1898, stamped as a flat 1898). The review
/// surface then told the owner that estimate was "evidence-backed (freebmd)"
/// and warned AGAINST a real FreeBMD registration — George Wilfred Land, Sep
/// 1897, Belper 7b/661 — which actually fitted the census window and whose
/// middle name confirmed the initial. The fabricated badge outranked the record.
///
/// The relationship edge in the same function always got this right, and says
/// why: a lead is a research HINT, not a record snapshot, so its origin is named
/// honestly rather than dressed as a citation. The profile now matches.
@MainActor
struct PromoteLeadProvenanceTests {

    private func makeDB() throws -> ProjectDatabase {
        let db = try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
        _ = try db.addProfile(
            Profile(id: "@P1@", firstName: "George", lastName: "Land", gender: .male,
                    birthDate: GenealogicalDate(parsing: "1864"),
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        return db
    }

    /// Every field-source origin recorded against the promoted profile.
    private func origins(of profileID: String, in db: ProjectDatabase) throws -> [String] {
        (try db.loadProfile(id: profileID)?.sources.values.flatMap { $0 } ?? [])
            .map(\.origin.identifier)
    }

    private func lead(source: LeadSource) -> Lead {
        Lead(id: "l1", profileID: "@P1@", name: "George W Land",
             surname: "Land", givenName: "George", birthYear: 1898, deathYear: nil,
             relationship: "child", source: source, status: .new,
             evidence: "1901 census, Wirksworth — son aged 3", createdAt: Date())
    }

    /// The provenance must name the LEAD, never a source the data did not come
    /// from. `householdMember` is the census case that produced the live bug.
    @Test func promotedProfileFieldsAreNotStampedFreeBMD() throws {
        let db = try makeDB()
        let ghostID = try db.promoteLeadToProfile(lead(source: .householdMember))

        let origins = try origins(of: ghostID, in: db)
        #expect(!origins.isEmpty, "the promote must record some provenance")
        #expect(!origins.contains("freebmd"),
                "a census-derived estimate must not wear a FreeBMD badge")
        #expect(origins.allSatisfy { $0 == "lead.householdMember" })
    }

    /// The identifier carries the lead's own source, so its trust tier stays
    /// derivable rather than asserted.
    @Test func theOriginNamesTheLeadsOwnSource() throws {
        for source in [LeadSource.householdMember, .discovery, .scoredLead, .ghostNode] {
            let db = try makeDB()
            let ghostID = try db.promoteLeadToProfile(lead(source: source))
            let origins = Set(try origins(of: ghostID, in: db))
            #expect(origins == ["lead.\(source.rawValue)"],
                    "expected lead.\(source.rawValue), got \(origins)")
        }
    }

    /// A lead promoted from an MCP submission is `discovery` — the case that
    /// created both Land children.
    @Test func anMCPSubmittedLeadIsRecordedAsDiscovery() throws {
        let db = try makeDB()
        let ghostID = try db.promoteLeadToProfile(lead(source: .discovery))
        #expect(try origins(of: ghostID, in: db).allSatisfy { $0 == "lead.discovery" })
    }

    /// The profile itself is still created correctly — this changes only how its
    /// provenance is labelled.
    @Test func theProfileIsStillBuiltFromTheLead() throws {
        let db = try makeDB()
        let ghostID = try db.promoteLeadToProfile(lead(source: .householdMember))
        let ghost = try db.loadProfile(id: ghostID)
        #expect(ghost?.firstName == "George")
        #expect(ghost?.lastName == "Land")
        #expect(ghost?.birthDate?.bestYear == 1898)
    }
}
