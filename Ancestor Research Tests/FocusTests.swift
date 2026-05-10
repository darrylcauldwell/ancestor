import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for M8 W3 (Focus Sets) — DB CRUD, lastActiveAt ordering, and the
/// snapshot's `focusFilteredIDs` helper that drives the Tree's focus filter.
struct FocusTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(id: String) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: "P", lastName: id, gender: nil,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    private func parentEdge(_ from: String, _ to: String) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: .unspecified, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(
            id: UUID(), from: a, to: b,
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    // MARK: - CRUD

    @Test func addFocusSet_persistsAndLoads() throws {
        let db = try makeTempDB()
        let now = Date()
        let set = FocusSet(
            id: UUID(), title: "Land family",
            profileIDs: ["p1", "p2"],
            createdAt: now, lastActiveAt: now
        )
        try db.addFocusSet(set)

        let loaded = try db.loadFocusSets()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Land family")
        #expect(loaded.first?.profileIDs == ["p1", "p2"])
    }

    @Test func updateFocusSet_changesProfileIDsAndTitle() throws {
        let db = try makeTempDB()
        let set = FocusSet(
            id: UUID(), title: "Original",
            profileIDs: ["p1"],
            createdAt: Date(), lastActiveAt: Date()
        )
        try db.addFocusSet(set)

        var revised = set
        revised.title = "Revised"
        revised.profileIDs = ["p1", "p2", "p3"]
        try db.updateFocusSet(revised)

        let loaded = try db.loadFocusSets()
        #expect(loaded.first?.title == "Revised")
        #expect(loaded.first?.profileIDs.count == 3)
    }

    @Test func deleteFocusSet_removes() throws {
        let db = try makeTempDB()
        let set = FocusSet(
            id: UUID(), title: nil, profileIDs: [],
            createdAt: Date(), lastActiveAt: Date()
        )
        try db.addFocusSet(set)
        try db.deleteFocusSet(id: set.id)
        #expect(try db.loadFocusSets().isEmpty)
    }

    @Test func loadFocusSets_orderedByLastActive() throws {
        let db = try makeTempDB()
        let now = Date()
        let older = FocusSet(
            id: UUID(), title: "Older", profileIDs: [],
            createdAt: now, lastActiveAt: now.addingTimeInterval(-3600)
        )
        let newer = FocusSet(
            id: UUID(), title: "Newer", profileIDs: [],
            createdAt: now, lastActiveAt: now
        )
        try db.addFocusSet(older)
        try db.addFocusSet(newer)

        let loaded = try db.loadFocusSets()
        #expect(loaded.first?.title == "Newer")
        #expect(loaded.last?.title == "Older")
    }

    @Test func touchFocusSet_promotesToFront() throws {
        let db = try makeTempDB()
        let now = Date()
        // Both seeded in the past so a touch (which writes the current Date)
        // beats them. A is older than B.
        let a = FocusSet(id: UUID(), title: "A", profileIDs: [],
                         createdAt: now, lastActiveAt: now.addingTimeInterval(-7200))
        let b = FocusSet(id: UUID(), title: "B", profileIDs: [],
                         createdAt: now, lastActiveAt: now.addingTimeInterval(-3600))
        try db.addFocusSet(a)
        try db.addFocusSet(b)

        // B is front initially (less stale).
        #expect(try db.loadFocusSets().first?.title == "B")

        // Touch A → A should come first.
        try db.touchFocusSet(id: a.id)
        #expect(try db.loadFocusSets().first?.title == "A")
    }

    @Test func emptyProfileIDsArrayRoundTrips() throws {
        let db = try makeTempDB()
        let set = FocusSet(
            id: UUID(), title: nil, profileIDs: [],
            createdAt: Date(), lastActiveAt: Date()
        )
        try db.addFocusSet(set)
        let loaded = try db.loadFocusSets().first
        #expect(loaded?.profileIDs.isEmpty == true)
    }

    // MARK: - focusFilteredIDs (drives Tree filter)

    @Test func focusFilter_includesFocusedProfiles() {
        let p1 = makeProfile(id: "p1")
        let p2 = makeProfile(id: "p2")
        let snap = FamilyGraphSnapshot(
            profiles: ["p1": p1, "p2": p2],
            relationships: []
        )
        let visible = snap.focusFilteredIDs(focus: ["p1"])
        #expect(visible == ["p1"])
    }

    @Test func focusFilter_includesParentsChildrenSpouses() {
        let parent = makeProfile(id: "parent")
        let me = makeProfile(id: "me")
        let child = makeProfile(id: "child")
        let spouse = makeProfile(id: "spouse")
        let stranger = makeProfile(id: "stranger")
        let snap = FamilyGraphSnapshot(
            profiles: [
                "parent": parent, "me": me, "child": child,
                "spouse": spouse, "stranger": stranger,
            ],
            relationships: [
                parentEdge("parent", "me"),
                parentEdge("me", "child"),
                spouseEdge("me", "spouse"),
            ]
        )
        let visible = snap.focusFilteredIDs(focus: ["me"])
        #expect(visible == ["me", "parent", "child", "spouse"])
        #expect(!visible.contains("stranger"))
    }

    @Test func focusFilter_skipsMissingProfileIDs() {
        let p1 = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": p1], relationships: [])
        let visible = snap.focusFilteredIDs(focus: ["p1", "ghost"])
        #expect(visible == ["p1"])
    }

    @Test func focusFilter_emptyInputReturnsEmpty() {
        let snap = FamilyGraphSnapshot.empty
        #expect(snap.focusFilteredIDs(focus: []).isEmpty)
    }
}
