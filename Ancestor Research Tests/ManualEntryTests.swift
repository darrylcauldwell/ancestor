import Testing
import Foundation
@testable import Ancestor_Research

struct ManualEntryTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(
        id: String = UUID().uuidString,
        firstName: String? = "John",
        lastName: String? = "Smith",
        gender: Gender? = .male,
        birthDate: String? = nil,
        deathDate: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: gender,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    // MARK: - Add Profile

    @Test func addProfile_createsProfileInSnapshot() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "manual-1", firstName: "Alice", lastName: "Land")
        try db.addProfile(profile, source: .manualMemory)

        let snap = try db.buildSnapshot()
        #expect(snap.profiles.count == 1)
        #expect(snap.profiles["manual-1"]?.firstName == "Alice")
        #expect(snap.profiles["manual-1"]?.lastName == "Land")
    }

    @Test func addProfile_createsTransaction() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "manual-1")
        try db.addProfile(profile, source: .manualMemory)

        let txs = try db.loadTransactions()
        #expect(txs.count == 1)
        if case .addProfile(let pid) = txs.first?.kind {
            #expect(pid == "manual-1")
        } else {
            Issue.record("Expected addProfile transaction")
        }
    }

    @Test func addProfile_createsFieldSources() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "manual-1", firstName: "Alice", lastName: "Land")
        try db.addProfile(profile, source: .manualDocument)

        let snap = try db.buildSnapshot()
        let sources = snap.profiles["manual-1"]?.sources[.firstName] ?? []
        #expect(sources.count == 1)
        #expect(sources.first?.origin == .manualDocument)
        #expect(sources.first?.raw == "Alice")
    }

    @Test func addProfile_undoRemovesProfile() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "manual-1")
        let tx = try db.addProfile(profile, source: .manualMemory)

        try db.undoStructural(transactionID: tx.id)
        let snap = try db.buildSnapshot()
        #expect(snap.profiles.isEmpty)
    }

    // MARK: - Add Family

    @Test func addFamily_createsMultipleProfilesAndRelationships() throws {
        let db = try makeTempDB()
        let father = makeProfile(id: "father", firstName: "William", lastName: "Land")
        let mother = makeProfile(id: "mother", firstName: "Mary", lastName: "Slater", gender: .female)
        let child = makeProfile(id: "child", firstName: "Thomas", lastName: "Land")

        let spouseRel = Relationship(
            id: UUID(), from: "father", to: "mother",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let parentRel1 = Relationship(
            id: UUID(), from: "father", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let parentRel2 = Relationship(
            id: UUID(), from: "mother", to: "child",
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )

        try db.addFamily(
            profiles: [father, mother, child],
            relationships: [spouseRel, parentRel1, parentRel2],
            source: .manualMemory
        )

        let snap = try db.buildSnapshot()
        #expect(snap.profiles.count == 3)
        #expect(snap.relationships.count == 3)
        #expect(snap.parentsOf("child").count == 2)
    }

    @Test func addFamily_singleUndoRemovesAll() throws {
        let db = try makeTempDB()
        let father = makeProfile(id: "f")
        let child = makeProfile(id: "c")
        let rel = Relationship(
            id: UUID(), from: "f", to: "c",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )

        let tx = try db.addFamily(profiles: [father, child], relationships: [rel], source: .manualMemory)

        var snap = try db.buildSnapshot()
        #expect(snap.profiles.count == 2)

        try db.undoStructural(transactionID: tx.id)
        snap = try db.buildSnapshot()
        #expect(snap.profiles.isEmpty)
        #expect(snap.relationships.isEmpty)
    }

    // MARK: - Edit Profile

    @Test func editProfile_updatesFieldAndCreatesFieldChange() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "edit-1", firstName: "John")
        try db.addProfile(profile, source: .manualMemory)

        try db.editProfile(
            profileID: "edit-1",
            changes: [(.firstName, "John", "Jonathan")],
            dateChanges: [],
            source: .manualRecord
        )

        let snap = try db.buildSnapshot()
        #expect(snap.profiles["edit-1"]?.firstName == "Jonathan")

        // Should have 2 transactions: addProfile + manualEdit
        let txs = try db.loadTransactions()
        #expect(txs.count == 2)
    }

    @Test func editProfile_dateFieldUpdates4Columns() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "date-1", birthDate: "1887")
        try db.addProfile(profile, source: .manualMemory)

        let newDate = GenealogicalDate(parsing: "ABT 1890")
        try db.editProfile(
            profileID: "date-1",
            changes: [],
            dateChanges: [(.birthDate, profile.birthDate, newDate)],
            source: .manualRecord
        )

        let snap = try db.buildSnapshot()
        let birth = snap.profiles["date-1"]?.birthDate
        #expect(birth?.original == "ABT 1890")
        #expect(birth?.isApproximate == true)
        #expect(birth?.earliest == 1885)
        #expect(birth?.latest == 1895)
    }

    // MARK: - Soft Delete

    @Test func softDelete_hidesFromSnapshot() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "del-1")
        try db.addProfile(profile, source: .manualMemory)

        try db.softDeleteProfiles(ids: ["del-1"])

        let snap = try db.buildSnapshot()
        #expect(snap.profiles.isEmpty)
    }

    @Test func softDelete_preservesInDatabase() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "del-1")
        try db.addProfile(profile, source: .manualMemory)

        try db.softDeleteProfiles(ids: ["del-1"])

        let deleted = try db.loadDeletedProfiles()
        #expect(deleted.count == 1)
        #expect(deleted.first?.id == "del-1")
        #expect(deleted.first?.isDeleted == true)
    }

    @Test func restoreDeletedProfile_reappearsInSnapshot() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "del-1")
        try db.addProfile(profile, source: .manualMemory)
        try db.softDeleteProfiles(ids: ["del-1"])

        try db.restoreProfiles(ids: ["del-1"])

        let snap = try db.buildSnapshot()
        #expect(snap.profiles.count == 1)
        #expect(snap.profiles["del-1"]?.firstName == "John")

        let deleted = try db.loadDeletedProfiles()
        #expect(deleted.isEmpty)
    }

    // MARK: - Add/Remove Relationship

    @Test func addRelationship_createsEdge() throws {
        let db = try makeTempDB()
        let p1 = makeProfile(id: "p1")
        let p2 = makeProfile(id: "p2")
        try db.addProfile(p1, source: .manualMemory)
        try db.addProfile(p2, source: .manualMemory)

        let rel = Relationship(
            id: UUID(), from: "p1", to: "p2",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        try db.addRelationship(rel)

        let snap = try db.buildSnapshot()
        #expect(snap.relationships.count == 1)
        #expect(snap.parentsOf("p2").first?.id == "p1")
    }

    @Test func removeRelationship_deletesEdge() throws {
        let db = try makeTempDB()
        let p1 = makeProfile(id: "p1")
        let p2 = makeProfile(id: "p2")
        try db.addProfile(p1, source: .manualMemory)
        try db.addProfile(p2, source: .manualMemory)

        let relID = UUID()
        let rel = Relationship(
            id: relID, from: "p1", to: "p2",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        try db.addRelationship(rel)
        try db.removeRelationship(id: relID)

        let snap = try db.buildSnapshot()
        #expect(snap.relationships.isEmpty)
    }

    // MARK: - Home Person

    @Test func homePersonID_persistsAcrossReload() throws {
        let db = try makeTempDB()
        let project = Project(
            id: UUID(), name: "Test", source: .manual,
            homePersonID: nil, createdAt: Date(), lastRefreshed: nil
        )
        try db.saveProjectMeta(project)
        try db.setHomePerson(id: "person-1")

        let loaded = try db.loadProjectMeta()
        #expect(loaded?.homePersonID == "person-1")
    }

    @Test func dataSourceManual_persistsAcrossReload() throws {
        let db = try makeTempDB()
        let project = Project(
            id: UUID(), name: "Manual Tree", source: .manual,
            homePersonID: nil, createdAt: Date(), lastRefreshed: nil
        )
        try db.saveProjectMeta(project)

        let loaded = try db.loadProjectMeta()
        if case .manual = loaded?.source {
            // OK
        } else {
            Issue.record("Expected DataSource.manual, got \(String(describing: loaded?.source))")
        }
    }

    // MARK: - Person Attributes

    @Test func personAttributes_persistAsJSON() throws {
        let db = try makeTempDB()
        var profile = makeProfile(id: "attr-1")
        profile.attributes = PersonAttributes(
            nameStatus: .unknown,
            lifeStatus: .infantDeath,
            privacy: .livingPrivate
        )
        try db.addProfile(profile, source: .manualMemory)

        let snap = try db.buildSnapshot()
        let attrs = snap.profiles["attr-1"]?.resolvedAttributes
        #expect(attrs?.nameStatus == .unknown)
        #expect(attrs?.lifeStatus == .infantDeath)
        #expect(attrs?.privacy == .livingPrivate)
    }

    @Test func personAttributes_defaultsForExistingProfiles() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "old-1")  // attributes = nil
        try db.addProfile(profile, source: .manualMemory)

        let snap = try db.buildSnapshot()
        let attrs = snap.profiles["old-1"]?.resolvedAttributes
        #expect(attrs?.nameStatus == .known)
        #expect(attrs?.lifeStatus == .normal)
        #expect(attrs?.privacy == .normal)
    }

    // MARK: - Marriage Location

    @Test func marriageLocation_persistsOnRelationship() throws {
        let db = try makeTempDB()
        let p1 = makeProfile(id: "h")
        let p2 = makeProfile(id: "w", gender: .female)
        try db.addProfile(p1, source: .manualMemory)
        try db.addProfile(p2, source: .manualMemory)

        let rel = Relationship(
            id: UUID(), from: "h", to: "w",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: GenealogicalDate(parsing: "1858"),
            marriageLocation: "Belper, Derbyshire",
            divorceDate: nil
        )
        try db.addRelationship(rel)

        let snap = try db.buildSnapshot()
        let spouseRel = snap.relationships.first
        #expect(spouseRel?.marriageLocation == "Belper, Derbyshire")
        #expect(spouseRel?.marriageDate?.original == "1858")
    }

    // MARK: - Source Origin Subtypes

    @Test func manualSourceSubtypes_trackCorrectly() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "src-1", firstName: "Test")
        try db.addProfile(profile, source: .manualRecord)

        let snap = try db.buildSnapshot()
        let sources = snap.profiles["src-1"]?.sources[.firstName] ?? []
        #expect(sources.first?.origin == .manualRecord)
        #expect(sources.first?.origin.isManual == true)
    }

    // MARK: - Undo for Soft Delete

    @Test func undoSoftDelete_restoresProfile() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "undo-del-1")
        try db.addProfile(profile, source: .manualMemory)

        let delTx = try db.softDeleteProfiles(ids: ["undo-del-1"])

        // Profile should be hidden
        var snap = try db.buildSnapshot()
        #expect(snap.profiles.isEmpty)

        // Undo the soft delete
        try db.undoReplay(transactionID: delTx.id)
        snap = try db.buildSnapshot()
        #expect(snap.profiles.count == 1)
        #expect(snap.profiles["undo-del-1"]?.firstName == "John")
    }
}
