import Testing
import Foundation
@testable import Ancestor_Research

/// Integration tests for Phase 5: GraphConnectivity, PlaceholderResolver,
/// AddRelationship logic, soft-delete branch, AuditEngine.guidanceMessage,
/// and GEDCOMExporter.excludeLiving.
struct ManualEntryIntegrationTests {

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        gender: Gender? = nil,
        birthYear: Int? = nil,
        privacy: Privacy = .normal,
        nameStatus: NameStatus = .known
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: gender,
            attributes: PersonAttributes(
                nameStatus: nameStatus, lifeStatus: .normal, privacy: privacy
            ),
            birthDate: birthYear.map { GenealogicalDate(parsing: "\($0)") },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentEdge(_ from: String, _ to: String,
                             role: ParentRole = .unspecified,
                             subtype: RelationshipSubtype = .biological) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: role, subtype: subtype,
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

    private func snap(_ profiles: [Profile], _ rels: [Relationship] = []) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: rels)
    }

    // MARK: - GraphConnectivity

    @Test func emptySnapshot_hasNoComponents() {
        let groups = GraphConnectivity.connectedComponents(.empty)
        #expect(groups.isEmpty)
    }

    @Test func singleProfile_isOneComponent() {
        let p = makeProfile(id: "a")
        let groups = GraphConnectivity.connectedComponents(snap([p]))
        #expect(groups.count == 1)
        #expect(groups.first == ["a"])
    }

    @Test func disconnectedPair_givesTwoComponents() {
        let a = makeProfile(id: "a")
        let b = makeProfile(id: "b")
        let groups = GraphConnectivity.connectedComponents(snap([a, b]))
        #expect(groups.count == 2)
    }

    @Test func parentEdgeJoinsComponents() {
        let parent = makeProfile(id: "p")
        let child = makeProfile(id: "c")
        let groups = GraphConnectivity.connectedComponents(
            snap([parent, child], [parentEdge("p", "c")])
        )
        #expect(groups.count == 1)
        #expect(Set(groups.first ?? []) == ["p", "c"])
    }

    @Test func spouseEdgeJoinsComponents() {
        let a = makeProfile(id: "a")
        let b = makeProfile(id: "b")
        let groups = GraphConnectivity.connectedComponents(
            snap([a, b], [spouseEdge("a", "b")])
        )
        #expect(groups.count == 1)
    }

    @Test func isDisconnected_falseForConnectedTree() {
        let p = makeProfile(id: "p")
        let c = makeProfile(id: "c")
        #expect(!GraphConnectivity.isDisconnected(snap([p, c], [parentEdge("p", "c")])))
    }

    @Test func isDisconnected_trueForTwoIslands() {
        let a = makeProfile(id: "a")
        let b = makeProfile(id: "b")
        #expect(GraphConnectivity.isDisconnected(snap([a, b])))
    }

    @Test func components_largestFirst() {
        let p1 = makeProfile(id: "p1")
        let p2 = makeProfile(id: "p2")
        let p3 = makeProfile(id: "p3")
        let lone = makeProfile(id: "z")
        let groups = GraphConnectivity.connectedComponents(
            snap([p1, p2, p3, lone],
                 [parentEdge("p1", "p2"), parentEdge("p1", "p3")])
        )
        #expect(groups.first?.count == 3)
        #expect(groups.last == ["z"])
    }

    // MARK: - PlaceholderParentRepair (excessParentEdges auto-fix)

    @Test func placeholderRepair_absorbsSharedStubsIntoRealParents() {
        // The Elsie regression: 2 real parents + 2 blank stubs, each stub shared
        // with one orphaned sibling. One stub is `.placeholder`, one is a blank
        // `.known` stub — both must be caught.
        let elsie = makeProfile(id: "elsie", firstName: "Elsie", lastName: "T")
        let abe = makeProfile(id: "abe", firstName: "Abe", lastName: "T", gender: .male)
        let wright = makeProfile(id: "wright", firstName: "Wil", lastName: "W", gender: .female)
        let connie = makeProfile(id: "connie", firstName: "Connie", lastName: "T")
        let wilma = makeProfile(id: "wilma", firstName: "Wilma", lastName: "T")
        let s1 = makeProfile(id: "s1", nameStatus: .placeholder)
        let s2 = makeProfile(id: "s2", nameStatus: .known)

        let abeE = parentEdge("abe", "elsie", role: .father)
        let wrightE = parentEdge("wright", "elsie", role: .mother)
        let s1E = parentEdge("s1", "elsie")
        let s1C = parentEdge("s1", "connie")
        let s2E = parentEdge("s2", "elsie")
        let s2W = parentEdge("s2", "wilma")

        let snapshot = snap(
            [elsie, abe, wright, connie, wilma, s1, s2],
            [abeE, wrightE, s1E, s1C, s2E, s2W]
        )

        let plan = PlaceholderParentRepair.plan(childID: "elsie", snapshot: snapshot)
        #expect(plan != nil)
        guard let plan else { return }

        // Connie & Wilma re-homed onto BOTH real parents; Elsie already has them
        // so she is not re-added.
        let rehomeSet = Set(plan.rehome.map { "\($0.childID)->\($0.parentID)" })
        #expect(rehomeSet == ["connie->abe", "connie->wright", "wilma->abe", "wilma->wright"])
        #expect(!plan.rehome.contains { $0.childID == "elsie" })
        // Role carried through from the real parent edge.
        #expect(plan.rehome.first { $0.childID == "connie" && $0.parentID == "abe" }?.role == .father)

        // All four stub edges removed; both stubs deleted.
        #expect(Set(plan.removeEdgeIDs) == Set([s1E.id, s1C.id, s2E.id, s2W.id]))
        #expect(plan.deleteStubIDs == ["s1", "s2"])
    }

    @Test func placeholderRepair_noRealParents_returnsNil() {
        // Two parentless siblings sharing ONE unknown-couple placeholder — valid,
        // nothing to absorb into.
        let a = makeProfile(id: "a")
        let b = makeProfile(id: "b")
        let stub = makeProfile(id: "stub", nameStatus: .placeholder)
        let snapshot = snap([a, b, stub], [parentEdge("stub", "a"), parentEdge("stub", "b")])
        #expect(PlaceholderParentRepair.plan(childID: "a", snapshot: snapshot) == nil)
    }

    @Test func placeholderRepair_noStubs_returnsNil() {
        // Two clean named parents — nothing to repair (also the George-Wheeldon
        // shape once you strip the third named parent: no stubs → nil).
        let child = makeProfile(id: "c")
        let f = makeProfile(id: "f", firstName: "F", lastName: "X", gender: .male)
        let m = makeProfile(id: "m", firstName: "M", lastName: "X", gender: .female)
        let snapshot = snap([child, f, m],
                            [parentEdge("f", "c", role: .father), parentEdge("m", "c", role: .mother)])
        #expect(PlaceholderParentRepair.plan(childID: "c", snapshot: snapshot) == nil)
    }

    // MARK: - PlaceholderResolver

    @Test func placeholders_returnsPlaceholderProfiles() {
        let real = makeProfile(id: "r", firstName: "Real")
        let placeholder = makeProfile(id: "ph", nameStatus: .placeholder)
        let result = PlaceholderResolver.placeholders(in: snap([real, placeholder]))
        #expect(result.count == 1)
        #expect(result.first?.placeholderID == "ph")
    }

    @Test func placeholders_listsAffectedChildren() {
        let placeholder = makeProfile(id: "ph", nameStatus: .placeholder)
        let child1 = makeProfile(id: "c1")
        let child2 = makeProfile(id: "c2")
        let result = PlaceholderResolver.placeholders(in: snap(
            [placeholder, child1, child2],
            [parentEdge("ph", "c1"), parentEdge("ph", "c2")]
        ))
        #expect(Set(result.first?.affectedChildIDs ?? []) == ["c1", "c2"])
    }

    @Test func placeholderParent_returnsIDIfPresent() {
        let placeholder = makeProfile(id: "ph", nameStatus: .placeholder)
        let child = makeProfile(id: "c")
        let id = PlaceholderResolver.placeholderParent(of: "c", in: snap(
            [placeholder, child], [parentEdge("ph", "c")]
        ))
        #expect(id == "ph")
    }

    @Test func placeholderParent_returnsNilWhenAllParentsAreReal() {
        let parent = makeProfile(id: "p", firstName: "Real")
        let child = makeProfile(id: "c")
        let id = PlaceholderResolver.placeholderParent(of: "c", in: snap(
            [parent, child], [parentEdge("p", "c")]
        ))
        #expect(id == nil)
    }

    // MARK: - AuditEngine.guidanceMessage

    @Test func guidanceMessage_promptsForBirthYearWhenMissing() {
        let p = makeProfile(id: "p")
        let msg = AuditEngine.guidanceMessage(for: p)
        #expect(msg?.contains("birth date") == true)
    }

    @Test func guidanceMessage_routesToParishRegistersFor1700() {
        let p = makeProfile(id: "p", birthYear: 1700)
        let msg = AuditEngine.guidanceMessage(for: p) ?? ""
        #expect(msg.contains("parish registers") || msg.contains("FreeREG"))
    }

    @Test func guidanceMessage_routesToCensusFor1880() {
        let p = makeProfile(id: "p", birthYear: 1880)
        let msg = AuditEngine.guidanceMessage(for: p) ?? ""
        #expect(msg.contains("FreeBMD") || msg.contains("FreeCEN"))
    }

    @Test func guidanceMessage_routesToLivingMemoryForVeryRecent() {
        let p = makeProfile(id: "p", birthYear: 2000)
        let msg = AuditEngine.guidanceMessage(for: p) ?? ""
        #expect(msg.contains("living"))
    }

    // MARK: - GEDCOMExporter.excludeLiving

    @Test func gedcomExport_omitsLivingPrivateWhenExcluded() {
        let alive = makeProfile(id: "alive", firstName: "Alive", privacy: .livingPrivate)
        let dead = makeProfile(id: "dead", firstName: "Dead", privacy: .normal)
        let result = GEDCOMExporter.export(snap([alive, dead]), excludeLiving: true)
        #expect(!result.content.contains("Alive"))
        #expect(result.content.contains("Dead"))
        #expect(result.individualCount == 1)
    }

    @Test func gedcomExport_includesLivingPrivateWithRESNByDefault() {
        let alive = makeProfile(id: "alive", firstName: "Alive", privacy: .livingPrivate)
        let result = GEDCOMExporter.export(snap([alive]))
        #expect(result.content.contains("RESN privacy"))
        #expect(result.individualCount == 1)
    }

    @Test func gedcomExport_dropsRelationshipsTouchingExcludedProfile() {
        let alive = makeProfile(id: "alive", firstName: "Alive", privacy: .livingPrivate)
        let parent = makeProfile(id: "parent", firstName: "Parent")
        let result = GEDCOMExporter.export(
            snap([alive, parent], [parentEdge("parent", "alive")]),
            excludeLiving: true
        )
        // No FAM record should be emitted.
        #expect(!result.content.contains("0 @F"))
    }

    // MARK: - Soft delete branch via AppState — round-trip through DB

    @Test func softDeleteBranch_descendants_removesSubtree() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)

        let root = makeProfile(id: "root", firstName: "Root")
        let child = makeProfile(id: "child", firstName: "Child")
        let grand = makeProfile(id: "grand", firstName: "Grand")

        try db.addFamily(
            profiles: [root, child, grand],
            relationships: [parentEdge("root", "child"), parentEdge("child", "grand")],
            source: .manualMemory
        )
        var snapshot = try db.buildSnapshot()
        let descendants = ["child", "grand"] + snapshot.descendantsOf("child", depth: 50).map(\.id)
        try db.softDeleteProfiles(ids: descendants)

        snapshot = try db.buildSnapshot()
        #expect(snapshot.profiles["child"] == nil)
        #expect(snapshot.profiles["grand"] == nil)
        #expect(snapshot.profiles["root"] != nil)
    }
}
