import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The third answer.
///
/// `Ashborne` is a misspelling of a district the app knows perfectly well, and
/// `-` is a stray character. Neither "this isn't a place" nor binding a district
/// is TRUE of them — the text itself is wrong, and until now the tab offered
/// nothing that was honest for either.
///
/// This is the one action in the Places tab that edits the tree, so it goes
/// through the same transaction and `field_changes` machinery as any profile
/// edit rather than a bare UPDATE.
@MainActor
struct PlaceTextCorrectionTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func addPerson(_ db: ProjectDatabase, _ id: String, _ place: String?) throws {
        _ = try db.addProfile(
            Profile(id: id, firstName: id, lastName: "X", gender: .male,
                    birthDate: GenealogicalDate(parsing: "1905"),
                    birthLocation: place, isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
    }

    private func rows(_ db: ProjectDatabase) throws -> [PlaceInventory.Row] {
        PlaceInventory.build(
            profiles: Array(try db.buildSnapshot().profiles.values),
            decisions: PlaceDecisionSet(decisions: try db.loadPlaceDecisions()))
    }

    // MARK: - The typo

    /// "Ashborne" is one letter from Ashbourne. Correcting it makes the row
    /// resolve on its own — no binding needed, because the place was always real.
    @Test func correctingATypoMakesTheRowResolve() throws {
        let db = try makeDB()
        try addPerson(db, "a", "Ashborne")
        try addPerson(db, "b", "Ashborne")

        #expect(try rows(db).first { $0.text == "Ashborne" }?.confidence == .unresolved)

        let n = try db.correctLocationText(
            profileFields: [("a", .birthLocation), ("b", .birthLocation)],
            lifeEventIDs: [], to: "Ashbourne")
        #expect(n == 2)

        #expect(try rows(db).first { $0.text == "Ashborne" } == nil, "the old spelling is gone")
        let fixed = try rows(db).first { $0.text == "Ashbourne" }
        #expect(fixed != nil)
        #expect(fixed?.confidence != .unresolved, "it resolves now — it was always a real place")
    }

    // MARK: - The junk

    /// "-" is not a place, a house or a street. Clearing is the only true answer.
    @Test func clearingJunkEmptiesTheFieldAndDropsTheRow() throws {
        let db = try makeDB()
        try addPerson(db, "a", "-")
        try addPerson(db, "b", "-")
        #expect(try rows(db).contains { $0.text == "-" })

        let n = try db.correctLocationText(
            profileFields: [("a", .birthLocation), ("b", .birthLocation)],
            lifeEventIDs: [], to: "   ")
        #expect(n == 2)

        #expect(try db.loadProfile(id: "a")?.birthLocation == nil)
        #expect(try rows(db).contains { $0.text == "-" } == false,
                "an empty place is not a row — nothing to decide about it")
    }

    // MARK: - It is a real edit, recorded like one

    @Test func theCorrectionIsRecordedAsATransaction() throws {
        let db = try makeDB()
        try addPerson(db, "a", "Ashborne")
        let before = try db.loadTransactions().count

        try db.correctLocationText(
            profileFields: [("a", .birthLocation)], lifeEventIDs: [], to: "Ashbourne")

        #expect(try db.loadTransactions().count == before + 1,
                "a tree edit must be undoable, not a bare UPDATE")
    }

    /// Nothing else on the profile is touched — this changes one field's words.
    @Test func onlyTheNamedFieldChanges() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "a", firstName: "Annie", lastName: "Cauldwell", gender: .female,
                    birthDate: GenealogicalDate(parsing: "1905"),
                    birthLocation: "Ashborne", deathDate: nil, deathLocation: "Belper",
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)

        try db.correctLocationText(
            profileFields: [("a", .birthLocation)], lifeEventIDs: [], to: "Ashbourne")

        let p = try db.loadProfile(id: "a")
        #expect(p?.birthLocation == "Ashbourne")
        #expect(p?.deathLocation == "Belper", "the other place is untouched")
        #expect(p?.firstName == "Annie")
    }

    @Test func rewritingToTheSameTextChangesNothing() throws {
        let db = try makeDB()
        try addPerson(db, "a", "Ashbourne")
        #expect(try db.correctLocationText(
            profileFields: [("a", .birthLocation)], lifeEventIDs: [], to: "Ashbourne") == 0)
    }

    /// A life event's structured code is cleared with the text. It was resolved
    /// from the OLD words; leaving it would attach the previous place's identity
    /// to different ones.
    @Test func aLifeEventsCodeIsClearedWithItsText() throws {
        let db = try makeDB()
        try addPerson(db, "a", "Ashbourne")
        let event = try db.addLifeEvent(LifeEvent(
            id: UUID(), profileID: "a", type: .residence,
            date: GenealogicalDate(parsing: "1911"),
            location: "Ashborne", locationCode: "DBY:Ashbourne",
            description: nil, sources: []))

        try db.correctLocationText(profileFields: [], lifeEventIDs: [event.id], to: "Ashbourne")

        let after = try db.loadAllLifeEvents().first { $0.id == event.id }
        #expect(after?.location == "Ashbourne")
        #expect(after?.locationCode == nil, "a code resolved from the old text cannot survive it")
    }
}
