import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the spec-compliance cleanup pass: name-length validation,
/// maiden-name suggestions, and the recordAlternativeFact DB primitive.
/// The Add Parent / Add Sibling fix (ex-popover; actions now on the context menu + card) is exercised via behaviour
/// — addFamily is the chosen primitive — so tests there assert the
/// resulting graph shape rather than view internals.
struct CleanupPassTests {

    // MARK: - Name length validation

    @Test func normaliseName_rejectsBeyondHardLimit() {
        let tooLong = String(repeating: "a", count: AutoSuggestService.nameHardLimitLength + 1)
        #expect(AutoSuggestService.normaliseName(tooLong) == nil)
    }

    @Test func normaliseName_acceptsAtHardLimit() {
        let atLimit = String(repeating: "a", count: AutoSuggestService.nameHardLimitLength)
        #expect(AutoSuggestService.normaliseName(atLimit)?.count == AutoSuggestService.nameHardLimitLength)
    }

    @Test func nameWarning_silentBelowSoft() {
        let short = String(repeating: "a", count: AutoSuggestService.nameSoftWarningLength)
        #expect(AutoSuggestService.nameWarning(short) == nil)
    }

    @Test func nameWarning_warnsAboveSoft() {
        let longish = String(repeating: "a", count: AutoSuggestService.nameSoftWarningLength + 5)
        #expect(AutoSuggestService.nameWarning(longish) != nil)
    }

    @Test func nameWarning_distinctMessageAtHardLimit() {
        let tooLong = String(repeating: "a", count: AutoSuggestService.nameHardLimitLength + 1)
        let msg = AutoSuggestService.nameWarning(tooLong) ?? ""
        #expect(msg.contains("maximum") || msg.contains("Too long"))
    }

    // MARK: - Maiden-name suggestions

    private func profile(id: String, last: String?, gender: Gender) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: nil, lastName: last, gender: gender,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    @Test func maidenSurnames_returnsOnlyFemaleSurnames() {
        let snap = FamilyGraphSnapshot(
            profiles: [
                "1": profile(id: "1", last: "Smith", gender: .female),
                "2": profile(id: "2", last: "Cauldwell", gender: .male),
                "3": profile(id: "3", last: "Smith", gender: .female),
            ],
            relationships: []
        )
        let result = AutoSuggestService.maidenSurnames(snapshot: snap)
        #expect(result.contains("Smith"))
        #expect(!result.contains("Cauldwell"))
    }

    @Test func maidenSurnames_emptyWhenNoFemales() {
        let snap = FamilyGraphSnapshot(
            profiles: ["1": profile(id: "1", last: "Smith", gender: .male)],
            relationships: []
        )
        #expect(AutoSuggestService.maidenSurnames(snapshot: snap).isEmpty)
    }

    @Test func maidenSurnames_rankedByFrequency() {
        let snap = FamilyGraphSnapshot(
            profiles: [
                "1": profile(id: "1", last: "Smith", gender: .female),
                "2": profile(id: "2", last: "Smith", gender: .female),
                "3": profile(id: "3", last: "Brown", gender: .female),
            ],
            relationships: []
        )
        let result = AutoSuggestService.maidenSurnames(snapshot: snap)
        #expect(result.first == "Smith")
    }

    // MARK: - recordAlternativeFact

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func basicProfile(id: String) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: "Alice", lastName: "Smith", gender: .female,
            attributes: nil,
            birthDate: nil, birthLocation: "Derby",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    @Test func recordAlternativeFact_appendsSourceWithoutChangingValue() throws {
        let db = try makeTempDB()
        let profile = basicProfile(id: "p")
        try db.addProfile(profile, source: .gedcom)

        try db.recordAlternativeFact(
            profileID: "p", field: .birthLocation,
            rawValue: "Belper", source: .manualMemory
        )

        let snap = try db.buildSnapshot()
        // Column value untouched.
        #expect(snap.profiles["p"]?.birthLocation == "Derby")
        // Two sources now exist for birthLocation.
        let sources = snap.profiles["p"]?.sources[.birthLocation] ?? []
        #expect(sources.count == 2)
        #expect(sources.contains { $0.raw == "Derby" })
        #expect(sources.contains { $0.raw == "Belper" })
    }

    @Test func recordAlternativeFact_undoStructuralRemovesAddedSource() throws {
        let db = try makeTempDB()
        let profile = basicProfile(id: "p")
        try db.addProfile(profile, source: .gedcom)

        let tx = try #require(try db.recordAlternativeFact(
            profileID: "p", field: .birthLocation,
            rawValue: "Belper", source: .manualMemory
        ))
        try db.undoStructural(transactionID: tx.id)

        let snap = try db.buildSnapshot()
        let sources = snap.profiles["p"]?.sources[.birthLocation] ?? []
        #expect(sources.count == 1)
        #expect(sources.first?.raw == "Derby")
    }

    // MARK: - Add Parent / Sibling linking — graph-shape assertions

    @Test func addFamily_inverseParentEdgeProducesCorrectAncestry() throws {
        // Mirrors what AddPersonView does for relation == .parent: the new
        // profile is the parent of the existing context.
        let db = try makeTempDB()
        let alice = basicProfile(id: "alice")
        try db.addProfile(alice, source: .manualMemory)

        let newParent = Profile(
            id: "newParent", externalIDs: [:],
            firstName: "Eleanor", lastName: "Smith", gender: .female,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        let edge = Relationship(
            id: UUID(), from: "newParent", to: "alice",
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )

        try db.addFamily(
            profiles: [newParent],
            relationships: [edge],
            source: .manualMemory
        )

        let snap = try db.buildSnapshot()
        let parents = snap.parentsOf("alice")
        #expect(parents.count == 1)
        #expect(parents.first?.id == "newParent")
    }

    @Test func addFamily_siblingShortcutAttachesViaSharedParents() throws {
        // Mirrors AddPersonView for relation == .sibling when anchor has parents.
        let db = try makeTempDB()
        let parent = Profile(
            id: "parent", externalIDs: [:],
            firstName: "Mum", lastName: "Smith", gender: .female,
            attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        let alice = basicProfile(id: "alice")
        let parentEdge = Relationship(
            id: UUID(), from: "parent", to: "alice",
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        try db.addFamily(profiles: [parent, alice], relationships: [parentEdge], source: .manualMemory)

        // Now add Alice's sibling Bob — should share parent.
        let bob = Profile(
            id: "bob", externalIDs: [:],
            firstName: "Bob", lastName: "Smith", gender: .male,
            attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        let bobEdge = Relationship(
            id: UUID(), from: "parent", to: "bob",
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        try db.addFamily(profiles: [bob], relationships: [bobEdge], source: .manualMemory)

        let snap = try db.buildSnapshot()
        let aliceSiblings = snap.siblingsOf("alice").map(\.id)
        #expect(aliceSiblings == ["bob"])
    }
}
