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
