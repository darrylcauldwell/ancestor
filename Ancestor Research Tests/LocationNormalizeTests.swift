import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// Location model Part II, Slices D & E.
///   D — the picker's hierarchy line resolves a place to its registration
///       district via the shared resolver (`districtName`).
///   E — the batch normaliser proposes structured codes for freeform, code-less
///       location fields (deterministic, review-gated), applies only confident
///       proposals, and preserves display strings.
@MainActor
struct LocationNormalizeTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func profile(_ id: String, birth: String? = nil, birthCode: String? = nil,
                         death: String? = nil, deathCode: String? = nil) -> Profile {
        Profile(id: id, firstName: "P", lastName: id, gender: .male,
                birthLocation: birth, birthLocationCode: birthCode,
                deathLocation: death, deathLocationCode: deathCode,
                isDeleted: false, sources: [:], disputes: [:])
    }

    // MARK: - D: resolver districtName (picker hierarchy line)

    @Test func districtNameResolvesParishToRD() {
        // Hognaston is an Ashbourne parish (the B(i) invariant).
        #expect(RegistrationDistrictResolver.districtName(forPlace: "Hognaston", chapman: "DBY") == "Ashbourne")
        // A "Place, County" string uses the leading token.
        #expect(RegistrationDistrictResolver.districtName(forPlace: "Hognaston, Derbyshire", chapman: "DBY") == "Ashbourne")
        // FreeBMD's "Ashborne" spelling canonicalises to the catalogue name.
        #expect(RegistrationDistrictResolver.districtName(forPlace: "Ashborne", chapman: "DBY") == "Ashbourne")
    }

    @Test func districtNameDeclinesUnknownPlace() {
        #expect(RegistrationDistrictResolver.districtName(forPlace: "Nowhereville", chapman: "DBY") == nil)
    }

    // MARK: - E: report

    @Test func reportProposesConfidentMatchForCountyName() {
        let r = LocationNormalizer.report(for: [profile("a", birth: "Derbyshire")])
        let p = try! #require(r.deterministic.first)
        #expect(p.target == .profileField(.birthLocation))
        #expect(p.currentText == "Derbyshire")
        #expect(p.proposedCode == "DBY")     // the county node
        #expect(p.confident)
    }

    @Test func reportLeavesUnresolvableAsFreeform() {
        let r = LocationNormalizer.report(for: [profile("a", birth: "Qwxzptv Farm")])
        #expect(r.deterministic.isEmpty)
        let p = try! #require(r.leftFreeform.first)
        #expect(p.proposedCode == nil)
        #expect(!p.confident)
    }

    @Test func reportSkipsAlreadyCodedAndEmptyFields() {
        let r = LocationNormalizer.report(for: [
            profile("coded", birth: "Derbyshire", birthCode: "DBY"),   // already coded
            profile("empty"),                                          // no location
            profile("blank", birth: "   "),                            // whitespace only
        ])
        #expect(r.proposals.isEmpty)
        #expect(r.scannedFields == 0)
    }

    @Test func reportSkipsSoftDeleted() {
        var p = profile("gone", birth: "Derbyshire")
        p.isDeleted = true
        #expect(LocationNormalizer.report(for: [p]).proposals.isEmpty)
    }

    // MARK: - E: apply (review-gated, display preserved)

    @Test func applyWritesCodeAndPreservesDisplay() throws {
        let db = try makeDB()
        _ = try db.addProfile(profile("a", birth: "Derbyshire"), source: .gedcom)
        let r = LocationNormalizer.report(for: Array(try db.buildSnapshot().profiles.values))
        let p = try #require(r.deterministic.first { $0.profileID == "a" })

        try LocationNormalizer.apply(p, in: db)

        let after = try #require(try db.loadProfile(id: "a"))
        #expect(after.birthLocationCode == "DBY")
        #expect(after.birthLocation == "Derbyshire", "display string is preserved, only the code is added")
        #expect(after.deathLocationCode == nil, "the other field's code is untouched")
    }

    @Test func applyRefusesNonConfidentProposal() throws {
        let db = try makeDB()
        let freeform = LocationNormalizer.Proposal(
            id: "x|birthLocation", profileID: "x", profileName: "X",
            target: .profileField(.birthLocation),
            currentText: "Qwxzptv Farm", proposedCode: nil, proposedDisplay: nil, method: .leftFreeform)
        #expect(throws: LocationNormalizer.ApplyError.notConfident) {
            try LocationNormalizer.apply(freeform, in: db)
        }
    }

    // MARK: - E: life-event locations

    private func residence(_ profileID: String, location: String?, code: String? = nil) -> LifeEvent {
        LifeEvent(id: UUID(), profileID: profileID, type: .residence,
                  date: nil, endDate: nil, location: location, locationCode: code,
                  description: nil, details: nil, sources: [], confidence: .standard,
                  createdByTransactionID: nil)
    }

    @Test func reportProposesForLifeEventLocation() {
        let r = LocationNormalizer.report(
            for: [profile("a")],
            lifeEvents: [residence("a", location: "Derbyshire")])
        let p = try! #require(r.deterministic.first)
        if case .lifeEvent(_, let type) = p.target { #expect(type == "residence") }
        else { Issue.record("expected a life-event target") }
        #expect(p.proposedCode == "DBY")
        #expect(p.fieldLabel == "Residence")
    }

    @Test func reportSkipsCodedLifeEventAndDeletedOwner() {
        var gone = profile("gone")
        gone.isDeleted = true
        let r = LocationNormalizer.report(
            for: [profile("a"), gone],
            lifeEvents: [
                residence("a", location: "Derbyshire", code: "DBY"),  // already coded
                residence("gone", location: "Derbyshire"),            // owner soft-deleted
            ])
        #expect(r.proposals.isEmpty)
    }

    @Test func applyWritesLifeEventCodePreservingDisplay() throws {
        let db = try makeDB()
        _ = try db.addProfile(profile("a"), source: .gedcom)
        let event = residence("a", location: "Derbyshire")
        _ = try db.addLifeEvent(event)

        let r = LocationNormalizer.report(
            for: Array(try db.buildSnapshot().profiles.values),
            lifeEvents: try db.loadAllLifeEvents())
        let p = try #require(r.deterministic.first)
        try LocationNormalizer.apply(p, in: db)

        let after = try #require(try db.loadLifeEvents(profileID: "a").first)
        #expect(after.locationCode == "DBY")
        #expect(after.location == "Derbyshire", "life-event display string is preserved")
    }

    @Test func applyOnlyTouchesTheNamedField() throws {
        let db = try makeDB()
        // Death already coded; birth freeform. Applying the birth proposal must
        // not disturb the death code.
        _ = try db.addProfile(profile("a", birth: "Derbyshire", death: "Belper", deathCode: "DBY:Belper"),
                              source: .gedcom)
        let r = LocationNormalizer.report(for: Array(try db.buildSnapshot().profiles.values))
        let birthProp = try #require(r.deterministic.first { $0.profileID == "a" && $0.target == .profileField(.birthLocation) })
        try LocationNormalizer.apply(birthProp, in: db)

        let after = try #require(try db.loadProfile(id: "a"))
        #expect(after.birthLocationCode == "DBY")
        #expect(after.deathLocationCode == "DBY:Belper", "the pre-existing death code is preserved")
    }
}
