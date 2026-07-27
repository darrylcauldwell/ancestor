import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// `MissingCoParentRule` — a child with exactly one parent whose sibling has a
/// second parent (the known parent's spouse) is very likely missing that
/// co-parent. Sibling-corroborated so it doesn't misfire on genuine single
/// parents or step-relationships; ambiguous remarriage cases stay silent.
struct MissingCoParentRuleTests {

    private func person(_ id: String, _ first: String, gender: Gender, birthYear: Int? = nil) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: "Wheeldon", gender: gender,
            attributes: PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: .normal),
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func makeTempDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    /// Kezia has both parents; Hannah has only Ruth → John (Ruth's spouse, Kezia's
    /// parent) is the corroborated co-parent for Hannah.
    private func lopsidedFamily() -> (snapshot: FamilyGraphSnapshot, hannah: Profile) {
        let ruth = person("ruth", "Ruth", gender: .female)
        let john = person("john", "John", gender: .male)
        let kezia = person("kezia", "Kezia", gender: .female)
        let hannah = person("hannah", "Hannah", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ruth": ruth, "john": john, "kezia": kezia, "hannah": hannah],
            relationships: [spouseEdge("ruth", "john"),
                            parentEdge("ruth", "kezia"), parentEdge("john", "kezia"),
                            parentEdge("ruth", "hannah")],   // Hannah lacks John
            lifeEvents: [:])
        return (snapshot, hannah)
    }

    @Test func suggestsSiblingCorroboratedCoParent() {
        let (snapshot, hannah) = lopsidedFamily()
        let s = try! #require(MissingCoParentRule.suggestion(for: hannah, in: snapshot))
        #expect(s.coParent.id == "john")
        #expect(s.knownParent.id == "ruth")
        #expect(s.corroboratingSibling.id == "kezia")

        let results = MissingCoParentRule().evaluate(profile: hannah, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.relatedProfileIDs == ["john"])
        #expect(results.first?.severity == .warning)
        #expect(results.first?.category == .issue)
    }

    /// The finding surfaces the child's and sibling's birth years so the
    /// chronology can be checked before accepting; a dated child needs no nudge.
    @Test func messageSurfacesBirthYears() {
        let ruth = person("ruth", "Ruth", gender: .female)
        let john = person("john", "John", gender: .male, birthYear: 1824)
        let kezia = person("kezia", "Kezia", gender: .female, birthYear: 1862)
        let hannah = person("hannah", "Hannah", gender: .female, birthYear: 1853)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ruth": ruth, "john": john, "kezia": kezia, "hannah": hannah],
            relationships: [spouseEdge("ruth", "john"),
                            parentEdge("ruth", "kezia"), parentEdge("john", "kezia"),
                            parentEdge("ruth", "hannah")],
            lifeEvents: [:])
        let message = try! #require(MissingCoParentRule().evaluate(profile: hannah, snapshot: snapshot).first?.message)
        #expect(message.contains("b.1853"))       // the child's year
        #expect(message.contains("b.1862"))       // the corroborating sibling's year
        #expect(!message.contains("Confirm"))     // dated → no nudge
    }

    /// When the child has NO birth year, the finding says so and nudges the user
    /// to confirm one first — the date check can't be made from the finding alone.
    @Test func messageNudgesWhenChildUndated() {
        let (snapshot, hannah) = lopsidedFamily()   // undated people
        let message = try! #require(MissingCoParentRule().evaluate(profile: hannah, snapshot: snapshot).first?.message)
        #expect(message.contains("no birth date"))
        #expect(message.contains("Confirm Hannah's birth year before accepting"))
    }

    @Test func doesNotFireWhenBothParentsPresent() {
        let (snapshot, _) = lopsidedFamily()
        let kezia = try! #require(snapshot.profiles["kezia"])
        #expect(MissingCoParentRule.suggestion(for: kezia, in: snapshot) == nil)
    }

    /// Ruth's spouse John parents NO sibling of Hannah (Hannah is an only child) →
    /// no corroboration → don't guess.
    @Test func doesNotFireWithoutSiblingCorroboration() {
        let ruth = person("ruth", "Ruth", gender: .female)
        let john = person("john", "John", gender: .male)
        let hannah = person("hannah", "Hannah", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ruth": ruth, "john": john, "hannah": hannah],
            relationships: [spouseEdge("ruth", "john"), parentEdge("ruth", "hannah")],
            lifeEvents: [:])
        #expect(MissingCoParentRule.suggestion(for: hannah, in: snapshot) == nil)
    }

    /// Ruth remarried: John parents Kezia, Bob parents Alice — both are Hannah's
    /// siblings, so the co-parent is ambiguous (possible remarriage) → stay silent.
    @Test func ambiguousMultipleSpouseCandidatesStaySilent() {
        let ruth = person("ruth", "Ruth", gender: .female)
        let john = person("john", "John", gender: .male)
        let bob = person("bob", "Bob", gender: .male)
        let kezia = person("kezia", "Kezia", gender: .female)
        let alice = person("alice", "Alice", gender: .female)
        let hannah = person("hannah", "Hannah", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ruth": ruth, "john": john, "bob": bob,
                       "kezia": kezia, "alice": alice, "hannah": hannah],
            relationships: [spouseEdge("ruth", "john"), spouseEdge("ruth", "bob"),
                            parentEdge("ruth", "kezia"), parentEdge("john", "kezia"),
                            parentEdge("ruth", "alice"), parentEdge("bob", "alice"),
                            parentEdge("ruth", "hannah")],
            lifeEvents: [:])
        #expect(MissingCoParentRule.suggestion(for: hannah, in: snapshot) == nil)
    }

    @MainActor
    @Test func addCoParentLinksTheParent() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("ruth", "Ruth", gender: .female), source: .gedcom)
        _ = try db.addProfile(person("john", "John", gender: .male), source: .gedcom)
        _ = try db.addProfile(person("kezia", "Kezia", gender: .female), source: .gedcom)
        _ = try db.addProfile(person("hannah", "Hannah", gender: .female), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("ruth", "john"))
        _ = try db.addRelationship(parentEdge("ruth", "kezia"))
        _ = try db.addRelationship(parentEdge("john", "kezia"))
        _ = try db.addRelationship(parentEdge("ruth", "hannah"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        appState.addCoParent(childID: "hannah", coParentID: "john")

        #expect(appState.snapshot.parentsOf("hannah").contains { $0.id == "john" })
        // Idempotent: a second call adds no duplicate.
        appState.addCoParent(childID: "hannah", coParentID: "john")
        #expect(appState.snapshot.parentsOf("hannah").filter { $0.id == "john" }.count == 1)
    }
}
