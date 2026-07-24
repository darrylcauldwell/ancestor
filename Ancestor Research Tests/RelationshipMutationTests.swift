import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// The relationship edit/delete mutations that back the edit-view controls:
/// `removeRelationship` (unlink), `setRelationshipMarriage` (overwrite marriage
/// date/place), and `setRelationshipRole` (correct a mis-roled parent edge).
@MainActor
struct RelationshipMutationTests {

    private func makeTempDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func profile(_ id: String, _ first: String) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: "Cauldwell",
            gender: .unknown, attributes: nil,
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func edge(_ id: UUID, _ from: String, _ to: String,
                      type: RelationshipType, role: ParentRole? = nil) -> Relationship {
        Relationship(id: id, from: from, to: to, type: type, role: role,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func year(_ y: Int) -> GenealogicalDate {
        GenealogicalDate(original: "\(y)", earliest: y, latest: y, isApproximate: false, qualifier: .exact)
    }

    @Test func setMarriageOverwritesDateAndLocation() throws {
        let db = try makeTempDB()
        let id = UUID()
        _ = try db.addFamily(
            profiles: [profile("a", "Joseph"), profile("b", "Elizabeth")],
            relationships: [edge(id, "a", "b", type: .spouse)], source: .manual)

        _ = try db.setRelationshipMarriage(relationshipID: id, date: year(1885), location: "Belper")
        let r1 = try db.buildSnapshot().relationships.first { $0.id == id }
        #expect(r1?.marriageDate?.bestYear == 1885)
        #expect(r1?.marriageLocation == "Belper")

        // Overwrite again — proves it replaces (not fill-only) and can clear.
        _ = try db.setRelationshipMarriage(relationshipID: id, date: year(1886), location: nil)
        let r2 = try db.buildSnapshot().relationships.first { $0.id == id }
        #expect(r2?.marriageDate?.bestYear == 1886)
        #expect((r2?.marriageLocation ?? "").isEmpty)
    }

    @Test func setRoleCorrectsParentRole() throws {
        let db = try makeTempDB()
        let id = UUID()
        _ = try db.addFamily(
            profiles: [profile("p", "Elizabeth"), profile("c", "Joseph")],
            relationships: [edge(id, "p", "c", type: .parent, role: .father)], source: .manual)

        _ = try db.setRelationshipRole(relationshipID: id, role: .mother)
        #expect(try db.buildSnapshot().relationships.first { $0.id == id }?.role == .mother)
    }

    @Test func removeRelationshipDeletesEdge() throws {
        let db = try makeTempDB()
        let id = UUID()
        _ = try db.addFamily(
            profiles: [profile("p", "John"), profile("c", "Joseph")],
            relationships: [edge(id, "p", "c", type: .parent, role: .father)], source: .manual)

        _ = try db.removeRelationship(id: id)
        #expect(try db.buildSnapshot().relationships.first { $0.id == id } == nil)
    }
}
