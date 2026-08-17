import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// LOCATION_MODEL_SPEC Part III, Slice A — what happens when the human decides.
///
/// A row leaves the queue exactly two ways: someone binds a district, or someone
/// says the text names no place. Nothing leaves silently, and nothing already
/// settled is overwritten on the way.
@MainActor
struct PlaceInventoryDecisionTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func addPerson(
        _ db: ProjectDatabase, id: String, birthLocation: String?, birthCode: String? = nil
    ) throws -> Profile {
        let p = Profile(id: id, firstName: "Test", lastName: "Person", gender: .female,
                        birthDate: GenealogicalDate(parsing: "1861"),
                        birthLocation: birthLocation, birthLocationCode: birthCode,
                        isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(p, source: .manual)
        return p
    }

    private func rows(_ db: ProjectDatabase) throws -> [PlaceInventory.Row] {
        let dismissed = Set(try db.loadCleanseUnresolvableFlags().map { "\($0.profileID)|\($0.field)" })
        return PlaceInventory.build(profiles: Array(try db.buildSnapshot().profiles.values),
                                    lifeEvents: (try? db.loadAllLifeEvents()) ?? [],
                                    dismissed: dismissed)
    }

    // MARK: - Binding

    @Test func bindingWritesTheCodeToEveryUseOfTheString() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        _ = try addPerson(db, id: "b", birthLocation: "Middleton, Derbyshire")

        guard let row = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        let written = try PlaceInventory.bindAll(row, to: "DBY:Ashbourne-RD", in: db)

        #expect(written == 2, "one decision settles every use of the same string")
        #expect(try db.loadProfile(id: "a")?.birthLocationCode == "DBY:Ashbourne-RD")
        #expect(try db.loadProfile(id: "b")?.birthLocationCode == "DBY:Ashbourne-RD")
    }

    /// Check-before-overwrite. A code someone set earlier — by any route — is not
    /// clobbered by a later decision about the same text.
    @Test func bindingLeavesAnAlreadyCodedFieldAlone() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "settled", birthLocation: "Middleton, Derbyshire",
                          birthCode: "DBY:Bakewell-RD")
        _ = try addPerson(db, id: "open", birthLocation: "Middleton, Derbyshire")

        guard let row = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        let written = try PlaceInventory.bindAll(row, to: "DBY:Ashbourne-RD", in: db)

        #expect(written == 1)
        #expect(try db.loadProfile(id: "settled")?.birthLocationCode == "DBY:Bakewell-RD",
                "an existing code must survive a decision about the same string")
        #expect(try db.loadProfile(id: "open")?.birthLocationCode == "DBY:Ashbourne-RD")
    }

    @Test func aBoundRowLeavesTheQueue() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        guard let before = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        #expect(before.needsDecision)

        try PlaceInventory.bindAll(before, to: "DBY:Ashbourne-RD", in: db)
        let after = try rows(db).first { $0.text == "Middleton, Derbyshire" }
        #expect(after?.needsDecision == false)
    }

    // MARK: - Per-field binding

    /// The reason `bind` takes explicit ids. Two unrelated people can both be
    /// born in "a Middleton" and mean different villages; settling one must not
    /// silently settle the other.
    @Test func bindingOneFieldLeavesTheOtherUsesUntouched() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        _ = try addPerson(db, id: "b", birthLocation: "Middleton, Derbyshire")

        guard let row = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }),
              let justA = row.occurrences.first(where: { $0.profileID == "a" }) else {
            Issue.record("row missing"); return
        }
        let written = try PlaceInventory.bind(row, occurrenceIDs: [justA.id],
                                              to: "DBY:Ashbourne-RD", in: db)

        #expect(written == 1)
        #expect(try db.loadProfile(id: "a")?.birthLocationCode == "DBY:Ashbourne-RD")
        #expect((try db.loadProfile(id: "b")?.birthLocationCode ?? "").isEmpty,
                "the other person's Middleton is a separate decision")
    }

    /// A partially-bound row still owes a decision — otherwise settling one
    /// person would quietly drop everyone else off the queue.
    @Test func aPartiallyBoundRowStaysInTheQueue() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        _ = try addPerson(db, id: "b", birthLocation: "Middleton, Derbyshire")

        guard let row = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }),
              let justA = row.occurrences.first(where: { $0.profileID == "a" }) else {
            Issue.record("row missing"); return
        }
        try PlaceInventory.bind(row, occurrenceIDs: [justA.id], to: "DBY:Ashbourne-RD", in: db)

        #expect(try rows(db).first { $0.text == "Middleton, Derbyshire" }?.needsDecision == true)
    }

    @Test func bindingAnEmptySelectionWritesNothing() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        guard let row = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        #expect(try PlaceInventory.bind(row, occurrenceIDs: [], to: "DBY:Ashbourne-RD", in: db) == 0)
        #expect((try db.loadProfile(id: "a")?.birthLocationCode ?? "").isEmpty)
    }

    // MARK: - The national escape hatch

    /// The stated county is normally the best constraint available, but it is
    /// sometimes wrong — emigrants, transcription errors, moved boundaries. A
    /// list locked to it would trap exactly those cases.
    @Test func theNationalListIgnoresTheStatedCounty() {
        let scoped = RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: "Middleton, Derbyshire", chapman: nil, year: 1861)?.districts ?? []
        let national = RegistrationDistrictResolver.nationalCandidates(
            forPlaceOrDistrict: "Middleton, Derbyshire")

        #expect(national.count > scoped.count, "widening must actually widen")
        let counties = Set(national.map { String($0.id.split(separator: ":").first ?? "") })
        #expect(counties.count > 1, "got only \(counties)")
        #expect(counties.contains("LAN"), "Lancashire's Middleton must be reachable: \(counties.sorted())")
    }

    /// It also ignores dates — a district ruled out by the event year is still
    /// offered, because the year can be wrong too.
    @Test func theNationalListIgnoresValidityWindows() {
        let national = RegistrationDistrictResolver.nationalCandidates(
            forPlaceOrDistrict: "Middleton, Derbyshire").map(\.id)
        #expect(national.contains { $0.contains("Bakewell") },
                "Bakewell is era-eliminated for 1824 but must remain reachable: \(national)")
    }

    // MARK: - Not a place

    @Test func settingAsideRemovesTheRowFromTheQueueReversibly() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Darley Hall")

        guard let row = try rows(db).first(where: { $0.text == "Darley Hall" }) else {
            Issue.record("row missing"); return
        }
        #expect(row.needsDecision)

        try PlaceInventory.markNotAPlace(row, in: db)
        let aside = try rows(db).first { $0.text == "Darley Hall" }
        #expect(aside?.isNotAPlace == true)
        #expect(aside?.needsDecision == false)
        // Still listed — set aside, not deleted. Hiding it would make the
        // decision unreviewable.
        #expect(aside != nil)

        try PlaceInventory.clearNotAPlace(aside!, in: db)
        #expect(try rows(db).first { $0.text == "Darley Hall" }?.needsDecision == true)
    }

    /// Setting aside must not touch the tree's text. Correcting a typo is a
    /// different decision from saying it cannot be resolved, and conflating them
    /// would edit genealogical data from a triage screen.
    @Test func settingAsideNeverRewritesTheProfile() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Ashborne")

        guard let row = try rows(db).first(where: { $0.text == "Ashborne" }) else {
            Issue.record("row missing"); return
        }
        try PlaceInventory.markNotAPlace(row, in: db)

        let profile = try db.loadProfile(id: "a")
        #expect(profile?.birthLocation == "Ashborne")
        #expect((profile?.birthLocationCode ?? "").isEmpty)
    }

    /// Binding answers the question the set-aside flag was raised about, so the
    /// flag must not linger and re-suppress a row that now has an answer.
    @Test func bindingClearsAPriorSetAside() throws {
        let db = try makeDB()
        _ = try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")

        guard let row = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        try PlaceInventory.markNotAPlace(row, in: db)
        guard let aside = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        try PlaceInventory.bindAll(aside, to: "DBY:Ashbourne-RD", in: db)

        let after = try rows(db).first { $0.text == "Middleton, Derbyshire" }
        #expect(after?.isNotAPlace == false, "a bound row is answered, not set aside")
    }
}
