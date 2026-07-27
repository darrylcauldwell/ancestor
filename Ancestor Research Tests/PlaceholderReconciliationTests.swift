import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The sibling shortcut creates a blank placeholder parent so two people can
/// share an unknown parent. When the REAL parent is later established it must
/// REPLACE that placeholder — carrying every sibling that shared it — not
/// stack up as a 3rd/4th parent behind hidden blanks (owner report
/// 2026-07-15: research-found parents piled up behind placeholders and hid
/// the real ones on the canvas).
@MainActor
struct PlaceholderReconciliationTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func person(_ id: String, _ first: String, gender: Gender = .male,
                        placeholder: Bool = false) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: placeholder ? nil : first, lastName: placeholder ? nil : "Twyford",
            gender: placeholder ? nil : gender,
            attributes: placeholder
                ? PersonAttributes(nameStatus: .placeholder, lifeStatus: .normal, privacy: .normal)
                : PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: .normal),
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String, role: ParentRole = .unspecified) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: role,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    /// Elsie and her sibling Wilhemena share ONE blank placeholder parent
    /// (the sibling-shortcut artifact). Establishing the real father on Elsie
    /// must: delete the placeholder, and attach the real father to BOTH.
    @MainActor
    @Test func realParentReplacesSharedPlaceholderAndCarriesSiblings() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("elsie", "Elsie", gender: .female), source: .gedcom)
        _ = try db.addProfile(person("wil", "Wilhemena", gender: .female), source: .gedcom)
        _ = try db.addProfile(person("ph", "", placeholder: true), source: .manual)
        _ = try db.addProfile(person("abraham", "Abraham", gender: .male), source: .gedcom)
        _ = try db.addRelationship(parentEdge("ph", "elsie"))
        _ = try db.addRelationship(parentEdge("ph", "wil"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        // Establish Abraham as Elsie's real father, then reconcile.
        appState.addRelationship(parentEdge("abraham", "elsie", role: .father))
        appState.reconcilePlaceholderParent(childID: "elsie", realParentID: "abraham", role: .father)

        let snap = appState.snapshot
        // Placeholder retired.
        #expect(snap.profiles["ph"]?.isDeleted != false ? true : (snap.parentsOf("elsie").allSatisfy { $0.id != "ph" }),
                "placeholder must no longer parent Elsie")
        #expect(!snap.parentsOf("elsie").contains { $0.id == "ph" })
        #expect(!snap.parentsOf("wil").contains { $0.id == "ph" })
        // Abraham now parents BOTH — the sibling was carried across.
        #expect(snap.parentsOf("elsie").contains { $0.id == "abraham" })
        #expect(snap.parentsOf("wil").contains { $0.id == "abraham" },
                "the sibling sharing the placeholder must move onto the real parent")
        // No 4-parent tangle: Elsie has exactly one parent now (Abraham).
        #expect(snap.parentsOf("elsie").count == 1, "got \(snap.parentsOf("elsie").map(\.id))")
    }

    /// With TWO placeholders (father-slot + mother-slot, both role-unspecified),
    /// establishing a father then a mother must retire both in turn — no blanks
    /// left, no duplicates.
    @MainActor
    @Test func fatherThenMotherRetiresBothPlaceholders() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("elsie", "Elsie", gender: .female), source: .gedcom)
        _ = try db.addProfile(person("ph1", "", placeholder: true), source: .manual)
        _ = try db.addProfile(person("ph2", "", placeholder: true), source: .manual)
        _ = try db.addProfile(person("abraham", "Abraham", gender: .male), source: .gedcom)
        _ = try db.addProfile(person("wilhelmina", "Wilhelmina", gender: .female), source: .gedcom)
        _ = try db.addRelationship(parentEdge("ph1", "elsie"))
        _ = try db.addRelationship(parentEdge("ph2", "elsie"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        appState.addRelationship(parentEdge("abraham", "elsie", role: .father))
        appState.reconcilePlaceholderParent(childID: "elsie", realParentID: "abraham", role: .father)
        appState.addRelationship(parentEdge("wilhelmina", "elsie", role: .mother))
        appState.reconcilePlaceholderParent(childID: "elsie", realParentID: "wilhelmina", role: .mother)

        let parents = Set(appState.snapshot.parentsOf("elsie").map(\.id))
        #expect(parents == ["abraham", "wilhelmina"],
                "both blanks retired, both real parents present; got \(parents)")
    }

    @MainActor
    @Test func noPlaceholderIsANoOp() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("elsie", "Elsie", gender: .female), source: .gedcom)
        _ = try db.addProfile(person("abraham", "Abraham", gender: .male), source: .gedcom)
        _ = try db.addRelationship(parentEdge("abraham", "elsie", role: .father))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        appState.reconcilePlaceholderParent(childID: "elsie", realParentID: "abraham", role: .father)
        #expect(appState.snapshot.parentsOf("elsie").map(\.id) == ["abraham"])
    }

    /// A placeholder that has since been EDITED INTO A REAL PERSON keeps its
    /// `.placeholder` flag but now carries a real name — establishing a SECOND
    /// parent must NOT soft-delete it. Regression: Ruth Wheeldon b.1824 (a
    /// sibling-shortcut placeholder fleshed out into the real mother) was
    /// repeatedly auto-retired with her child edges stripped (2026-07-27).
    @MainActor
    @Test func namedPlaceholderSurvivesSecondParent() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("kezia", "Kezia", gender: .female), source: .gedcom)
        // Ruth: created as a placeholder, then edited into a real named person —
        // she KEEPS the `.placeholder` flag but now has a real name.
        let ruth = Profile(
            id: "ruth", externalIDs: [:],
            firstName: "Ruth", lastName: "Wheeldon", gender: .female,
            attributes: PersonAttributes(nameStatus: .placeholder, lifeStatus: .normal, privacy: .normal),
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(ruth, source: .manual)
        _ = try db.addProfile(person("john", "John", gender: .male), source: .gedcom)
        _ = try db.addRelationship(parentEdge("ruth", "kezia", role: .mother))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        // Establish John as Kezia's father, then reconcile. The pre-fix code
        // treated still-flagged Ruth as a blank placeholder and retired her.
        appState.addRelationship(parentEdge("john", "kezia", role: .father))
        appState.reconcilePlaceholderParent(childID: "kezia", realParentID: "john", role: .father)

        let snap = appState.snapshot
        #expect(snap.profiles["ruth"] != nil,
                "the named (real) placeholder must NOT be soft-deleted")
        #expect(snap.parentsOf("kezia").contains { $0.id == "ruth" },
                "Ruth must remain Kezia's mother")
        #expect(snap.parentsOf("kezia").contains { $0.id == "john" },
                "John added as father")
    }

    /// `isAnonymousStub` is about MISSING DATA, not the raw flag: a `.placeholder`
    /// profile that has gained a real name is no longer a stub, while a genuinely
    /// blank profile still is (flagged or not).
    @Test func isAnonymousStubIgnoresFlagWhenRealDataPresent() {
        func p(_ first: String?, _ last: String?, _ status: NameStatus) -> Profile {
            Profile(
                id: UUID().uuidString, externalIDs: [:],
                firstName: first, lastName: last, gender: nil,
                attributes: PersonAttributes(nameStatus: status, lifeStatus: .normal, privacy: .normal),
                birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
        }
        #expect(p(nil, nil, .placeholder).isAnonymousStub)          // blank placeholder → stub
        #expect(!p("Ruth", "Wheeldon", .placeholder).isAnonymousStub) // named placeholder → NOT a stub
        #expect(p(nil, nil, .known).isAnonymousStub)                // blank non-placeholder → stub
    }
}
