import Testing
import Foundation
@testable import Ancestor_Research

struct UndoTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(id: String = "test-1") -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: "John", lastName: "Smith", gender: .male,
            birthDate: GenealogicalDate(parsing: "1887"),
            birthLocation: "Belper", deathDate: nil,
            deathLocation: nil, bio: nil,
            sources: [:], disputes: [:]
        )
    }

    @Test func structuralUndoRemovesAllEntities() throws {
        let db = try makeTempDB()
        let p1 = makeProfile(id: "a")
        let p2 = makeProfile(id: "b")
        let rel = Relationship(id: UUID(), from: "a", to: "b", type: .parent, role: .father, subtype: .biological, marriageDate: nil, divorceDate: nil)
        let snapshot = FamilyGraphSnapshot(profiles: ["a": p1, "b": p2], relationships: [rel])
        let tx = try db.importSnapshot(snapshot, source: "/test.ged")

        // Before undo
        var rebuilt = try db.buildSnapshot()
        #expect(rebuilt.profiles.count == 2)
        #expect(rebuilt.relationships.count == 1)

        // Undo
        try db.undoStructural(transactionID: tx.id)

        // After undo
        rebuilt = try db.buildSnapshot()
        #expect(rebuilt.profiles.isEmpty)
        #expect(rebuilt.relationships.isEmpty)
    }

    @Test func transactionSaveAndLoad() throws {
        let db = try makeTempDB()
        let tx = Transaction(
            id: UUID(), kind: .manualEdit, undoStrategy: .replay,
            startedAt: Date(), completedAt: Date(),
            changeCount: 3, profileCount: 1
        )
        try db.saveTransaction(tx)

        let loaded = try db.loadTransactions()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == tx.id)
        #expect(loaded.first?.changeCount == 3)
    }

    @Test func undoTransactionIsPersisted() throws {
        let db = try makeTempDB()
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(profiles: ["test-1": profile], relationships: [])
        let importTx = try db.importSnapshot(snapshot, source: "/test.ged")

        // Record undo as its own transaction
        let undoTx = Transaction(
            id: UUID(), kind: .undo(ofTransactionID: importTx.id),
            undoStrategy: .replay, startedAt: Date(), completedAt: Date(),
            changeCount: 0, profileCount: 1
        )
        try db.saveTransaction(undoTx)

        let transactions = try db.loadTransactions()
        #expect(transactions.count == 2)
        // Most recent first
        if case .undo(let originalID) = transactions.first?.kind {
            #expect(originalID == importTx.id)
        } else {
            Issue.record("Expected undo transaction as most recent")
        }
    }
}
