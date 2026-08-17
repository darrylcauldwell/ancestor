import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Every structured place code is supposed to name a real `PlaceAuthority` —
/// a gazetteer place, a county, or a registration district. Nothing checked
/// that, and nothing could: `PlaceAuthority` is materialised from bundled JSON
/// at launch, not a table, so no foreign key is possible and "the schema will
/// stop it" is never true here.
///
/// A code that resolves to nothing is also invisible afterwards — the picker's
/// green chip renders only when `entry(forID:)` returns something, so a bogus
/// code looks exactly like no code at all.
@MainActor
struct PlaceCodeValidationTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func addPerson(_ db: ProjectDatabase, id: String) throws {
        _ = try db.addProfile(
            Profile(id: id, firstName: "Test", lastName: "Person", gender: .female,
                    birthDate: GenealogicalDate(parsing: "1861"),
                    birthLocation: "Wirksworth, Derbyshire",
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
    }

    // MARK: - The validator itself

    @Test func realIDsPass() throws {
        try ProjectDatabase.validatePlaceCode("DBY")                 // county
        try ProjectDatabase.validatePlaceCode("DBY:Belper-RD")       // district
        try ProjectDatabase.validatePlaceCode("DBY:MiddletonByWirksworth")  // gazetteer place
    }

    /// nil and empty are "no code", which is always allowed — unresolved places
    /// must keep working.
    @Test func absenceIsNotAnError() throws {
        try ProjectDatabase.validatePlaceCode(nil)
        try ProjectDatabase.validatePlaceCode("")
        try ProjectDatabase.validatePlaceCode("   ")
    }

    @Test func aMadeUpIDIsRejected() {
        #expect(throws: ProjectDatabase.PlaceCodeError.unknownPlaceAuthorityID("DBY:Notaplace-RD")) {
            try ProjectDatabase.validatePlaceCode("DBY:Notaplace-RD")
        }
    }

    /// The near-miss case: a real place dressed as a district it never was.
    /// Crich is a parish inside Belper RD; there has never been a Crich RD.
    ///
    /// Note the contrast with `DBY:Belper`, which IS valid — Belper is both a
    /// town (`DBY:Belper`) and a registration district (`DBY:Belper-RD`), and
    /// both ids name something real. The `-RD` suffix is not decoration.
    @Test func aRealPlaceDressedAsADistrictIsRejected() {
        #expect(throws: ProjectDatabase.PlaceCodeError.self) {
            try ProjectDatabase.validatePlaceCode("DBY:Crich-RD")
        }
        try? ProjectDatabase.validatePlaceCode("DBY:Belper")   // must NOT throw
    }

    // MARK: - Every writer refuses it

    @Test func setProfileLocationCodeRefusesAnUnknownID() throws {
        let db = try makeDB()
        try addPerson(db, id: "p")
        #expect(throws: ProjectDatabase.PlaceCodeError.self) {
            try db.setProfileLocationCode(profileID: "p", field: .birthLocation, code: "XXX:Nowhere")
        }
        #expect((try db.loadProfile(id: "p")?.birthLocationCode ?? "").isEmpty)
    }

    @Test func updateProfileLocationCodesRefusesAnUnknownID() throws {
        let db = try makeDB()
        try addPerson(db, id: "p")
        #expect(throws: ProjectDatabase.PlaceCodeError.self) {
            try db.updateProfileLocationCodes(profileID: "p", birthCode: "DBY:Belper-RD",
                                              deathCode: "XXX:Nowhere")
        }
        // Rejected before the write, so the good half is not applied either.
        #expect((try db.loadProfile(id: "p")?.birthLocationCode ?? "").isEmpty)
    }

    @Test func setBirthRegistrationDistrictRefusesAnUnknownID() throws {
        let db = try makeDB()
        try addPerson(db, id: "p")
        #expect(throws: ProjectDatabase.PlaceCodeError.self) {
            try db.setBirthRegistrationDistrictIfEmpty(profileID: "p", district: "DBY:Nowhere-RD")
        }
    }

    @Test func recordPlaceDecisionRefusesAnUnknownID() throws {
        let db = try makeDB()
        #expect(throws: ProjectDatabase.PlaceCodeError.self) {
            try db.recordPlaceDecision(PlaceDecision(
                id: "d", placeText: "x", displayText: "x", scopeField: nil,
                placeAuthorityID: "DBY:Nowhere-RD", yearFrom: nil, yearTo: nil,
                reason: "", decidedAt: Date(), supersededAt: nil))
        }
        #expect(try db.loadPlaceDecisions().isEmpty)
    }

    // MARK: - The real callers still work

    @Test func theNormalPathIsUnaffected() throws {
        let db = try makeDB()
        try addPerson(db, id: "p")
        try db.setProfileLocationCode(profileID: "p", field: .birthLocation, code: "DBY:Belper-RD")
        #expect(try db.loadProfile(id: "p")?.birthLocationCode == "DBY:Belper-RD")

        try db.setBirthRegistrationDistrictIfEmpty(profileID: "p", district: "DBY:Belper-RD")
        #expect(try db.loadProfile(id: "p")?.birthRegistrationDistrict == "DBY:Belper-RD")
    }
}

/// Promoting a census household member to a profile used to write the
/// transcribed birthplace and nothing else, so several profiles at a time
/// started life uncoded even when the place was one the app knows.
@MainActor
struct PromotedProfilePlaceTests {

    private func person(_ name: String, birthPlace: String?) -> AddRelationshipView.NewPerson {
        AddRelationshipView.NewPerson(
            name: name, birthYear: 1861, birthPlace: birthPlace, sex: "M", sourceID: nil)
    }

    @Test func anUnambiguousBirthplaceIsCoded() {
        let profile = AddRelationshipView.buildProfile(from: person("John Smith", birthPlace: "Crich"))
        #expect(profile.birthLocation == "Crich", "the transcription is preserved verbatim")
        #expect(profile.birthLocationCode?.hasPrefix("DBY:") == true,
                "got \(profile.birthLocationCode ?? "nil")")
    }

    /// `PlaceResolver.resolve` declines on ambiguity, so only certain cases fill
    /// in — "when in doubt, split".
    @Test func anUnknownBirthplaceStaysUncoded() {
        let profile = AddRelationshipView.buildProfile(from: person("Jane Doe", birthPlace: "Pilhough"))
        #expect(profile.birthLocation == "Pilhough")
        #expect(profile.birthLocationCode == nil)
    }

    @Test func noBirthplaceIsNotAProblem() {
        let profile = AddRelationshipView.buildProfile(from: person("No Place", birthPlace: nil))
        #expect(profile.birthLocationCode == nil)
    }

    @Test func blankBirthplaceIsNotCoded() {
        let profile = AddRelationshipView.buildProfile(from: person("Blank", birthPlace: "   "))
        #expect(profile.birthLocationCode == nil)
    }
}
