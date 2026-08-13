import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// Narrative-finding deletion (owner dogfood 2026-08-13). A firewall-queued
/// narrative finding must be removable from the profile: the pending badge
/// counts only `pending_facts`, so a narrative-only profile was a review
/// dead-end, and a stranded or wrong-profile finding (e.g. a namesake's
/// evidence) could otherwise pollute assembled biographical prose.
@MainActor
struct NarrativeFindingDeleteTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeFinding(id: String, profileID: String) -> NarrativeFinding {
        NarrativeFinding(
            id: id, profileID: profileID, category: "inscription",
            description: "Kitchen maid at Burbage Hall",
            dateOrPeriod: "1891",
            sourceURL: "https://www.freecen.org.uk/x",
            sourceTitle: "1891 Census",
            evidenceText: "Mary Thompson, servant, age 17",
            reasoning: "namesake — belongs to the wrong Mary",
            agentID: "field-researcher",
            submittedAt: Date(),
            verificationStatus: .pending)
    }

    @Test func deleteRemovesOnlyTheTargetedFinding() throws {
        let db = try makeDB()
        try db.saveNarrativeFinding(makeFinding(id: "fr_1", profileID: "p1"))
        try db.saveNarrativeFinding(makeFinding(id: "fr_2", profileID: "p1"))
        #expect(try db.loadNarrativeFindingRows(profileID: "p1").count == 2)

        try db.deleteNarrativeFinding(id: "fr_1")

        let remaining = try db.loadNarrativeFindingRows(profileID: "p1")
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == "fr_2")
    }

    @Test func deleteOfUnknownIDIsANoOp() throws {
        let db = try makeDB()
        try db.saveNarrativeFinding(makeFinding(id: "fr_keep", profileID: "p1"))

        try db.deleteNarrativeFinding(id: "fr_does_not_exist")

        #expect(try db.loadNarrativeFindingRows(profileID: "p1").count == 1)
    }
}
