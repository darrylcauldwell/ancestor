import Testing
import Foundation
@testable import Ancestor_Research

struct ProjectDatabaseTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(id: String = "test-1", firstName: String = "John", lastName: String = "Smith") -> Profile {
        Profile(
            id: id, externalIDs: ["gedcom": "@I1@"],
            firstName: firstName, lastName: lastName, gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1887"),
            birthLocation: "Belper, Derbyshire", deathDate: nil,
            deathLocation: nil, bio: nil, isDeleted: false,
            sources: [.birthDate: [FieldSource(origin: .gedcom, raw: "1887", addedAt: Date())]],
            disputes: [:]
        )
    }

    @Test func saveAndLoadProjectMeta() throws {
        let db = try makeTempDB()
        let project = Project(id: UUID(), name: "Test Project", source: .gedcom(path: "/test.ged"), homePersonID: nil, createdAt: Date(), lastRefreshed: nil)
        try db.saveProjectMeta(project)
        let loaded = try db.loadProjectMeta()
        #expect(loaded != nil)
        #expect(loaded?.name == "Test Project")
        #expect(loaded?.id == project.id)
    }

    @Test func importAndBuildSnapshot() throws {
        let db = try makeTempDB()
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(profiles: ["test-1": profile], relationships: [])
        let tx = try db.importSnapshot(snapshot, source: "/test.ged")
        #expect(tx.profileCount == 1)

        let rebuilt = try db.buildSnapshot()
        #expect(rebuilt.profiles.count == 1)
        #expect(rebuilt.profiles["test-1"]?.firstName == "John")
    }

    @Test func importPreservesSourceProvenance() throws {
        let db = try makeTempDB()
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(profiles: ["test-1": profile], relationships: [])
        _ = try db.importSnapshot(snapshot, source: "/test.ged")

        let rebuilt = try db.buildSnapshot()
        let sources = rebuilt.profiles["test-1"]?.sources[.birthDate] ?? []
        #expect(sources.count == 1)
        #expect(sources.first?.origin == .gedcom)
        #expect(sources.first?.raw == "1887")
    }

    @Test func importPreservesRelationships() throws {
        let db = try makeTempDB()
        let parent = makeProfile(id: "parent", firstName: "David")
        let child = makeProfile(id: "child", firstName: "Darryl")
        let rel = Relationship(id: UUID(), from: "parent", to: "child", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        let snapshot = FamilyGraphSnapshot(profiles: ["parent": parent, "child": child], relationships: [rel])
        _ = try db.importSnapshot(snapshot, source: "/test.ged")

        let rebuilt = try db.buildSnapshot()
        #expect(rebuilt.relationships.count == 1)
        #expect(rebuilt.parentsOf("child").count == 1)
        #expect(rebuilt.parentsOf("child").first?.firstName == "David")
    }

    @Test func persistenceAcrossReload() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db1 = try ProjectDatabase(path: path)
        let project = Project(id: UUID(), name: "Persist Test", source: .gedcom(path: "/test.ged"), homePersonID: nil, createdAt: Date(), lastRefreshed: nil)
        try db1.saveProjectMeta(project)
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(profiles: ["test-1": profile], relationships: [])
        _ = try db1.importSnapshot(snapshot, source: "/test.ged")

        // Reopen the same database file
        let db2 = try ProjectDatabase(path: path)
        let reloaded = try db2.loadProjectMeta()
        #expect(reloaded?.name == "Persist Test")
        let rebuilt = try db2.buildSnapshot()
        #expect(rebuilt.profiles.count == 1)
    }

    @Test func transactionRecorded() throws {
        let db = try makeTempDB()
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(profiles: ["test-1": profile], relationships: [])
        _ = try db.importSnapshot(snapshot, source: "/test.ged")

        let transactions = try db.loadTransactions()
        #expect(transactions.count == 1)
        if case .importGEDCOM = transactions.first?.kind {
            // correct
        } else {
            Issue.record("Expected importGEDCOM transaction kind")
        }
    }

    @Test func structuralUndo() throws {
        let db = try makeTempDB()
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(profiles: ["test-1": profile], relationships: [])
        let tx = try db.importSnapshot(snapshot, source: "/test.ged")

        // Verify data exists
        var rebuilt = try db.buildSnapshot()
        #expect(rebuilt.profiles.count == 1)

        // Undo the import
        try db.undoStructural(transactionID: tx.id)

        // Verify data is gone
        rebuilt = try db.buildSnapshot()
        #expect(rebuilt.profiles.isEmpty)
    }
}
