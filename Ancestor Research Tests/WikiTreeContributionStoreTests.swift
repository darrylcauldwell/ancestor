import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
@testable import AncestorKit

/// v54 contribution log (WT4 — WIKITREE_MERGEEDIT_SPEC §5): offers round-trip
/// newest-first, cascade with profile deletion, and record "offered" semantics
/// (no saved/committed state exists — that truth only arrives via twin sync).
struct WikiTreeContributionStoreTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func seedProfile(_ id: String, into db: ProjectDatabase) throws {
        let profile = Profile(
            id: id, firstName: "Ernest", lastName: "Cauldwell", gender: .male,
            deathDate: GenealogicalDate(parsing: "1955"),
            isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
    }

    @Test func contributionsRoundTripNewestFirst() throws {
        let db = try makeTempDB()
        try seedProfile("@I1@", into: db)
        try db.recordWikiTreeContribution(
            profileID: "@I1@", wikiTreeID: "Cauldwell-171",
            fieldsJSON: #"{"BirthDate":"1887"}"#, bioAppended: true,
            summary: "Sourced update", at: Date(timeIntervalSince1970: 100))
        try db.recordWikiTreeContribution(
            profileID: "@I1@", wikiTreeID: "Cauldwell-171",
            fieldsJSON: #"{"DeathLocation":"Derby"}"#, bioAppended: false,
            summary: nil, at: Date(timeIntervalSince1970: 200))

        let records = try db.wikiTreeContributions(profileID: "@I1@")
        #expect(records.count == 2)
        #expect(records[0].fieldsJSON.contains("DeathLocation"))   // newest first
        #expect(records[0].bioAppended == false)
        #expect(records[1].bioAppended == true)
        #expect(records[1].summary == "Sourced update")
        #expect(records[1].wikiTreeID == "Cauldwell-171")
        #expect(try db.wikiTreeContributions(profileID: "@OTHER@").isEmpty)
    }

    @Test func contributionsCascadeWithProfileDeletion() throws {
        let db = try makeTempDB()
        try seedProfile("@I1@", into: db)
        try db.recordWikiTreeContribution(
            profileID: "@I1@", wikiTreeID: "Cauldwell-171",
            fieldsJSON: "{}", bioAppended: false, summary: nil)
        try db.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM profiles WHERE id = '@I1@'")
        }
        #expect(try db.wikiTreeContributions(profileID: "@I1@").isEmpty)
    }
}
