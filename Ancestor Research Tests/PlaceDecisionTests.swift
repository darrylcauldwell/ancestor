import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// LOCATION_MODEL_SPEC Part III, Slice A deferred item — recording the reason
/// with the choice, and the user-built layer over the bundled gazetteer.
@MainActor
struct PlaceDecisionTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func addPerson(_ db: ProjectDatabase, id: String, birthLocation: String?,
                           year: String = "1861") throws {
        _ = try db.addProfile(
            Profile(id: id, firstName: "Test", lastName: "Person", gender: .female,
                    birthDate: GenealogicalDate(parsing: year),
                    birthLocation: birthLocation, isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
    }

    private func rows(_ db: ProjectDatabase) throws -> [PlaceInventory.Row] {
        PlaceInventory.build(
            profiles: Array(try db.buildSnapshot().profiles.values),
            dismissed: Set(try db.loadCleanseUnresolvableFlags().map { "\($0.profileID)|\($0.field)" }),
            decisions: PlaceDecisionSet(decisions: try db.loadPlaceDecisions()))
    }

    // MARK: - Canonical key

    @Test func spacingAndCaseDoNotMakeADifferentDecision() {
        #expect(PlaceDecision.canonicalKey("Middleton,  Derbyshire ")
                == PlaceDecision.canonicalKey("middleton, derbyshire"))
    }

    /// But the county is part of the identity. "Middleton" and "Middleton,
    /// Derbyshire" are different questions and must not share an answer.
    @Test func droppingTheCountyIsADifferentString() {
        #expect(PlaceDecision.canonicalKey("Middleton") != PlaceDecision.canonicalKey("Middleton, Derbyshire"))
    }

    // MARK: - The reason

    @Test func theReasonIsStoredAndComesBack() throws {
        let db = try makeDB()
        try addPerson(db, id: "ruth", birthLocation: "Middleton, Derbyshire", year: "1824")
        guard let row = try rows(db).first(where: { $0.text == "Middleton, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        try PlaceInventory.bindAll(row, to: "DBY:Ashbourne-RD",
                                   reason: "Her father's 1841 census entry is Middleton by Wirksworth.",
                                   in: db)

        let settled = try rows(db).first { $0.text == "Middleton, Derbyshire" }
        #expect(settled?.needsDecision == false)
        #expect(settled?.occurrences.first?.decision?.reason.contains("1841 census") == true)
        #expect(settled?.occurrences.first?.decision?.placeAuthorityID == "DBY:Ashbourne-RD")
    }

    /// The display text is kept verbatim so the record shows what the user was
    /// actually looking at, not the folded lookup key.
    @Test func theDecisionRemembersWhatTheUserSaw() throws {
        let db = try makeDB()
        try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        try PlaceInventory.bindAll(row, to: "DBY:Bakewell-RD", reason: "x", in: db)

        let stored = try db.loadPlaceDecisions().first
        #expect(stored?.displayText == "Middleton, Derbyshire")
        #expect(stored?.placeText == "middleton, derbyshire")
    }

    // MARK: - The era window

    /// The bug that started this work, made structurally unreachable. Bakewell RD
    /// began in 1839, so a decision naming it cannot govern an 1824 birth even if
    /// someone binds it — the window comes from the district itself.
    @Test func aDecisionInheritsItsDistrictsValidityWindow() throws {
        let db = try makeDB()
        try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire", year: "1861")
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        try PlaceInventory.bindAll(row, to: "DBY:Bakewell-RD", reason: "1861 census", in: db)

        let decision = try db.loadPlaceDecisions().first
        #expect(decision?.yearFrom == 1839, "got \(decision?.yearFrom.map(String.init) ?? "nil")")
        #expect(decision?.applies(year: 1861) == true)
        #expect(decision?.applies(year: 1824) == false, "Bakewell RD did not exist in 1824")
    }

    /// THE ORIGINAL BUG, refused at the point the human tries it. Bakewell RD
    /// began in 1839 and Ruth Brailsford was born in 1824.
    @Test func bindingADistrictThatCannotHoldTheYearIsRefused() throws {
        let db = try makeDB()
        try addPerson(db, id: "ruth", birthLocation: "Middleton, Derbyshire", year: "1824")
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!

        #expect(throws: PlaceInventory.BindError.self) {
            try PlaceInventory.bindAll(row, to: "DBY:Bakewell-RD", reason: "hunch", in: db)
        }
        #expect(try db.loadPlaceDecisions().isEmpty, "nothing is written when the bind is refused")
    }

    @Test func theRefusalSaysWhy() {
        let error = PlaceInventory.BindError.districtCannotHoldYears(
            district: "Bakewell", validFrom: 1839, validTo: nil, years: [1824])
        #expect(error.message.contains("Bakewell"))
        #expect(error.message.contains("1839"))
        #expect(error.message.contains("1824"))
    }

    /// A windowed decision DOES cover an undated event. The first cut had this
    /// inverted, which made the feature inert precisely where it is needed:
    /// almost every district is windowed, and undated events are exactly the
    /// ones the deterministic resolver already declines on.
    @Test func aWindowedDecisionCoversAnUndatedEvent() {
        let decision = PlaceDecision(
            id: "d", placeText: "x", displayText: "x", scopeField: nil,
            placeAuthorityID: "DBY:Bakewell-RD", yearFrom: 1839, yearTo: nil,
            reason: "", decidedAt: Date(), supersededAt: nil)
        #expect(decision.applies(year: nil) == true)
        #expect(decision.applies(year: 1900) == true)
        #expect(decision.applies(year: 1800) == false, "a year outside the window is still refused")
    }

    @Test func anUndatedRowCanBeSettled() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "nodate", firstName: "No", lastName: "Date", gender: .male,
                    birthLocation: "Middleton, Derbyshire", isDeleted: false,
                    sources: [:], disputes: [:]),
            source: .manual)
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        #expect(try PlaceInventory.bindAll(row, to: "DBY:Bakewell-RD", in: db) == 1)
        #expect(try rows(db).first { $0.text == "Middleton, Derbyshire" }?.needsDecision == false,
                "an undated row must be settleable, or the queue never empties")
    }

    @Test func anUnwindowedDecisionCoversEverything() {
        let decision = PlaceDecision(
            id: "d", placeText: "x", displayText: "x", scopeField: nil,
            placeAuthorityID: "DBY:Ashbourne-RD", yearFrom: nil, yearTo: nil,
            reason: "", decidedAt: Date(), supersededAt: nil)
        #expect(decision.applies(year: nil))
        #expect(decision.applies(year: 1700))
    }

    // MARK: - History

    /// Changing your mind is a fact worth keeping — it is what makes "why is
    /// this recorded as Ashbourne?" answerable later.
    @Test func changingYourMindSupersedesRatherThanErases() throws {
        let db = try makeDB()
        try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!

        try PlaceInventory.bindAll(row, to: "DBY:Bakewell-RD", reason: "first guess", in: db,
                                   now: Date(timeIntervalSince1970: 1_000))
        let afterFirst = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        try PlaceInventory.unbind(afterFirst,
                                  decisions: PlaceDecisionSet(decisions: try db.loadPlaceDecisions()),
                                  in: db)
        let reopened = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        try PlaceInventory.bindAll(reopened, to: "DBY:Ashbourne-RD", reason: "found the census",
                                   in: db, now: Date(timeIntervalSince1970: 2_000))

        #expect(try db.loadPlaceDecisions().count == 1, "exactly one live decision")
        #expect(try db.loadPlaceDecisions().first?.placeAuthorityID == "DBY:Ashbourne-RD")

        let history = try db.placeDecisionHistory(forText: "Middleton, Derbyshire")
        #expect(history.count == 2, "the earlier answer is kept, not erased")
        #expect(history.contains { $0.reason == "first guess" && !$0.isLive })
    }

    @Test func onlyOneLiveDecisionPerStringAndScope() throws {
        let db = try makeDB()
        try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!

        try PlaceInventory.bindAll(row, to: "DBY:Bakewell-RD", in: db,
                                   now: Date(timeIntervalSince1970: 1_000))
        // Rebuild: the first decision now marks the occurrence bound, so a
        // second bind of the same field is a no-op rather than a duplicate.
        let again = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        #expect(try PlaceInventory.bindAll(again, to: "DBY:Ashbourne-RD", in: db) == 0)
        #expect(try db.loadPlaceDecisions().count == 1)
    }

    @Test func unbindingPutsTheRowBackInTheQueue() throws {
        let db = try makeDB()
        try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        try PlaceInventory.bindAll(row, to: "DBY:Bakewell-RD", in: db)
        #expect(try rows(db).first { $0.text == "Middleton, Derbyshire" }?.needsDecision == false)

        let bound = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        try PlaceInventory.unbind(bound,
                                  decisions: PlaceDecisionSet(decisions: try db.loadPlaceDecisions()),
                                  in: db)
        #expect(try rows(db).first { $0.text == "Middleton, Derbyshire" }?.needsDecision == true)
    }

    // MARK: - The data-loss path this storage exists to close

    /// A decision must not live in `birth_location_code`. LocationPicker's
    /// onChange clears any code the 275-entry gazetteer cannot resolve, and a
    /// registration-district id is never in it — so a decision stored there is
    /// erased the moment someone edits the field. Binding must leave the profile
    /// columns alone entirely.
    @Test func bindingDoesNotTouchTheProfilesLocationColumns() throws {
        let db = try makeDB()
        try addPerson(db, id: "a", birthLocation: "Middleton, Derbyshire")
        let row = try rows(db).first { $0.text == "Middleton, Derbyshire" }!
        try PlaceInventory.bindAll(row, to: "DBY:Ashbourne-RD", reason: "census", in: db)

        let profile = try db.loadProfile(id: "a")
        #expect(profile?.birthLocation == "Middleton, Derbyshire", "display text untouched")
        #expect((profile?.birthLocationCode ?? "").isEmpty,
                "a district id in birthLocationCode is erased by the picker's onChange")
    }

    // MARK: - Scope

    @Test func aFieldScopedDecisionBeatsATextWideOne() {
        let now = Date()
        let set = PlaceDecisionSet(decisions: [
            PlaceDecision(id: "wide", placeText: "middleton, derbyshire", displayText: "Middleton, Derbyshire",
                          scopeField: nil, placeAuthorityID: "DBY:Bakewell-RD",
                          yearFrom: nil, yearTo: nil, reason: "", decidedAt: now, supersededAt: nil),
            PlaceDecision(id: "narrow", placeText: "middleton, derbyshire", displayText: "Middleton, Derbyshire",
                          scopeField: "p1|birthLocation", placeAuthorityID: "DBY:Ashbourne-RD",
                          yearFrom: nil, yearTo: nil, reason: "", decidedAt: now, supersededAt: nil),
        ])
        #expect(set.decision(for: "Middleton, Derbyshire", occurrenceID: "p1|birthLocation")?
            .placeAuthorityID == "DBY:Ashbourne-RD", "the narrower judgement is the more considered")
        #expect(set.decision(for: "Middleton, Derbyshire", occurrenceID: "p2|birthLocation")?
            .placeAuthorityID == "DBY:Bakewell-RD")
    }

    @Test func supersededDecisionsAreNeverConsulted() {
        let set = PlaceDecisionSet(decisions: [
            PlaceDecision(id: "old", placeText: "x", displayText: "x", scopeField: nil,
                          placeAuthorityID: "DBY:Bakewell-RD", yearFrom: nil, yearTo: nil,
                          reason: "", decidedAt: Date(), supersededAt: Date()),
        ])
        #expect(set.decision(for: "x") == nil)
        #expect(set.isEmpty)
    }
}
