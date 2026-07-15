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
}
