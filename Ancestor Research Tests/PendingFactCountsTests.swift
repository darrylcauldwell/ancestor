import Testing
import Foundation
@testable import Ancestor_Research

/// `ProjectDatabase.pendingFactCountsByProfile()` — the one-query GROUP BY
/// that drives the Triage selector's row badges and needs-review-first sort.
/// Found the morning after the first overnight campaign: 31 runs bridged
/// findings across dozens of profiles and the selector was an unmarked list
/// of 212 names.
struct PendingFactCountsTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func fact(id: String, profileID: String, value: String) -> PendingFact {
        PendingFact(
            id: id, profileID: profileID,
            field: "deathDate", value: value,
            sourceURL: "https://www.familysearch.org/ark:/61903/1:1:\(id)",
            sourceTitle: "Test collection",
            evidenceText: "evidence", reasoning: "reasoning",
            confidence: "high", agentID: "research-run",
            submittedAt: Date(), verificationStatus: .pending
        )
    }

    @Test func groupsPendingCountsPerProfileExcludingReviewed() throws {
        let db = try makeTempDB()

        // Profile A: two pending + one already accepted (must not count).
        try db.savePendingFact(fact(id: "a1", profileID: "@A@", value: "1901"))
        try db.savePendingFact(fact(id: "a2", profileID: "@A@", value: "1902"))
        try db.savePendingFact(fact(id: "a3", profileID: "@A@", value: "1903"))
        try db.updatePendingFactStatus(id: "a3", status: "accepted", verificationStatus: "verified")
        // Profile B: one pending.
        try db.savePendingFact(fact(id: "b1", profileID: "@B@", value: "1911"))
        // Profile C: none.

        let counts = db.pendingFactCountsByProfile()
        #expect(counts["@A@"] == 2)
        #expect(counts["@B@"] == 1)
        #expect(counts["@C@"] == nil, "zero-pending profiles must be absent, not zero")
    }

    @Test func emptyTableYieldsEmptyDictionary() throws {
        let db = try makeTempDB()
        #expect(db.pendingFactCountsByProfile().isEmpty)
    }
}
