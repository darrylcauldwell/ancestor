import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The record already says where it is.
///
/// "Shining Row" is an address the gazetteer will never hold — but the 1891
/// schedule it sits on names Turnditch parish, Belper district, and that pair is
/// stored on the census life event. Asking the user to settle it was the app
/// declining to read its own evidence.
@MainActor
struct PlaceFromRecordTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func household(
        _ db: ProjectDatabase, profileID: String, address: String,
        parish: String, district: String, year: Int
    ) throws {
        _ = try db.addProfile(
            Profile(id: profileID, firstName: profileID, lastName: "Cauldwell", gender: .male,
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        _ = try db.addLifeEvent(LifeEvent(
            id: UUID(), profileID: profileID, type: .census,
            date: GenealogicalDate(parsing: String(year)),
            location: address,
            details: .census(CensusDetails(address: address, district: district, parish: parish))))
    }

    private func row(_ db: ProjectDatabase, _ text: String) throws -> PlaceInventory.Row? {
        PlaceInventory.build(
            profiles: Array(try db.buildSnapshot().profiles.values),
            lifeEvents: try db.loadAllLifeEvents(),
            decisions: PlaceDecisionSet(decisions: try db.loadPlaceDecisions())
        ).first { $0.text == text }
    }

    // MARK: - The case

    @Test func aCensusAddressResolvesFromItsOwnSchedule() throws {
        let db = try makeDB()
        try household(db, profileID: "john", address: "Shining Row",
                      parish: "Turnditch", district: "Belper", year: 1891)

        guard let row = try row(db, "Shining Row") else { Issue.record("row missing"); return }
        #expect(row.confidence == .high, "the record states it — that is evidence, not a guess")
        #expect(row.candidates.map(\.name) == ["Belper"], "got \(row.candidates.map(\.name))")
        #expect(row.needsDecision == false)
    }

    @Test func theReasonNamesTheRecordAndTheYear() throws {
        let db = try makeDB()
        try household(db, profileID: "john", address: "Shining Row",
                      parish: "Turnditch", district: "Belper", year: 1891)
        let reasons = try row(db, "Shining Row")?.reasons ?? []
        #expect(reasons.contains { $0.contains("1891") && $0.contains("Turnditch") }, "\(reasons)")
        #expect(reasons.contains { $0.contains("address") }, "\(reasons)")
    }

    /// The composed line is the owner's shape: street, parish, district, county.
    @Test func theChainReadsStreetParishDistrictCounty() throws {
        let db = try makeDB()
        try household(db, profileID: "john", address: "Shining Row",
                      parish: "Turnditch", district: "Belper", year: 1891)
        guard let parish = PlaceInventory.authorityForRecordPlace(
            parish: "Turnditch", district: "Belper", year: 1891) else {
            Issue.record("Turnditch parish not found"); return
        }
        let line = PlaceInventory.hierarchyDisplay(text: "Shining Row", placeAuthorityID: parish.id)
        #expect(line == "Shining Row, Turnditch, Belper, Derbyshire", "got \(line)")
    }

    // MARK: - When the records disagree

    /// The same address string in two parishes is a finding, not an answer.
    @Test func recordsThatDisagreeAreNotCollapsed() throws {
        let db = try makeDB()
        try household(db, profileID: "a", address: "Cottage",
                      parish: "Turnditch", district: "Belper", year: 1891)
        try household(db, profileID: "b", address: "Cottage",
                      parish: "Youlgreave", district: "Bakewell", year: 1901)

        guard let row = try row(db, "Cottage") else { Issue.record("row missing"); return }
        #expect(row.confidence == .unresolved, "two parishes for one word is not settled")
        #expect(row.recordPlaces.count == 2)
        #expect(row.reasons.contains { $0.contains("disagree") }, "\(row.reasons)")
    }

    /// A parish the catalogue does not know cannot be asserted from a record
    /// either — the record is evidence, not an override of the authority.
    @Test func anUnknownParishInTheRecordStillLeavesItUnresolved() throws {
        let db = try makeDB()
        try household(db, profileID: "a", address: "Somewhere Row",
                      parish: "Notaparish Magna", district: "Belper", year: 1891)
        #expect(try row(db, "Somewhere Row")?.confidence == .unresolved)
    }

    /// A profile birthplace carries no census schedule, so nothing changes for it.
    @Test func aPlainBirthplaceIsUnaffected() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "p", firstName: "P", lastName: "X", gender: .male,
                    birthLocation: "Pilhough", isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        #expect(try row(db, "Pilhough")?.confidence == .unresolved)
    }
}
