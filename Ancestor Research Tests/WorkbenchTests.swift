import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for M8 W1 (Notes) and W2 (Questions) — migration v7, CRUD,
/// FTS search, attachment lookups, status transitions.
struct WorkbenchTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    // MARK: - Migration v7 — schema present after open

    @Test func migrationV7_workbenchTablesExist() throws {
        let db = try makeTempDB()
        // Round-trip: insert one of each entity. If migration ran, the writes
        // succeed; if not, GRDB throws "no such table".
        let note = WorkbenchNote(
            id: UUID(), content: "test", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(note)

        let question = OpenQuestion(
            id: UUID(), text: "test?", profileIDs: [],
            priority: .medium, status: .open,
            triedSources: nil, promotedFrom: .manual,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        try db.addQuestion(question)
    }

    // MARK: - Notes CRUD

    @Test func addNote_persistsAndLoads() throws {
        let db = try makeTempDB()
        let note = WorkbenchNote(
            id: UUID(), content: "Searched FreeBMD 1810-1820",
            tag: .sourceLog, attachedTo: .project,
            createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(note)

        let loaded = try db.loadNotes()
        #expect(loaded.count == 1)
        #expect(loaded.first?.content == "Searched FreeBMD 1810-1820")
        #expect(loaded.first?.tag == .sourceLog)
    }

    @Test func updateNote_changesContentAndBumpsUpdatedAt() throws {
        let db = try makeTempDB()
        let note = WorkbenchNote(
            id: UUID(), content: "first", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(note)

        var revised = note
        revised.content = "second"
        try db.updateNote(revised)

        let loaded = try db.loadNotes()
        #expect(loaded.first?.content == "second")
    }

    @Test func deleteNote_removesFromTable() throws {
        let db = try makeTempDB()
        let note = WorkbenchNote(
            id: UUID(), content: "delete me", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(note)

        try db.deleteNote(id: note.id)
        #expect(try db.loadNotes().isEmpty)
    }

    @Test func loadNotes_byAttachment_filtersToProfile() throws {
        let db = try makeTempDB()
        let aliceNote = WorkbenchNote(
            id: UUID(), content: "alice note", tag: .observation,
            attachedTo: .profile(id: "alice"),
            createdAt: Date(), updatedAt: Date()
        )
        let projectNote = WorkbenchNote(
            id: UUID(), content: "project note", tag: .observation,
            attachedTo: .project,
            createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(aliceNote)
        try db.addNote(projectNote)

        let aliceNotes = try db.loadNotes(attachedToKind: "profile", id: "alice")
        #expect(aliceNotes.count == 1)
        #expect(aliceNotes.first?.content == "alice note")

        let bobNotes = try db.loadNotes(attachedToKind: "profile", id: "bob")
        #expect(bobNotes.isEmpty)
    }

    @Test func loadNotes_projectAttachment_skipsProfileNotes() throws {
        let db = try makeTempDB()
        let projectNote = WorkbenchNote(
            id: UUID(), content: "project", tag: .meta,
            attachedTo: .project, createdAt: Date(), updatedAt: Date()
        )
        let profileNote = WorkbenchNote(
            id: UUID(), content: "profile", tag: .meta,
            attachedTo: .profile(id: "p"), createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(projectNote)
        try db.addNote(profileNote)

        let projectScoped = try db.loadNotes(attachedToKind: "project", id: nil)
        #expect(projectScoped.count == 1)
        #expect(projectScoped.first?.content == "project")
    }

    // MARK: - FTS search

    @Test func searchNotes_findsMatchingPhrase() throws {
        let db = try makeTempDB()
        try db.addNote(WorkbenchNote(
            id: UUID(), content: "Searched Wirksworth parish 1815",
            tag: .sourceLog, attachedTo: .project,
            createdAt: Date(), updatedAt: Date()
        ))
        try db.addNote(WorkbenchNote(
            id: UUID(), content: "Belper census 1851 had nothing",
            tag: .sourceLog, attachedTo: .project,
            createdAt: Date(), updatedAt: Date()
        ))

        let hits = try db.searchNotes(query: "Wirksworth")
        #expect(hits.count == 1)
        #expect(hits.first?.content.contains("Wirksworth") == true)
    }

    @Test func searchNotes_emptyQueryReturnsEmpty() throws {
        let db = try makeTempDB()
        try db.addNote(WorkbenchNote(
            id: UUID(), content: "anything", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date()
        ))
        #expect(try db.searchNotes(query: "").isEmpty)
        #expect(try db.searchNotes(query: "   ").isEmpty)
    }

    @Test func searchNotes_indexUpdatesAfterEdit() throws {
        let db = try makeTempDB()
        let note = WorkbenchNote(
            id: UUID(), content: "Original phrase",
            tag: .observation, attachedTo: .project,
            createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(note)
        #expect(try db.searchNotes(query: "Original").count == 1)

        var revised = note
        revised.content = "Replaced phrase"
        try db.updateNote(revised)

        // Old text no longer matches; new text does.
        #expect(try db.searchNotes(query: "Original").isEmpty)
        #expect(try db.searchNotes(query: "Replaced").count == 1)
    }

    @Test func searchNotes_indexUpdatesAfterDelete() throws {
        let db = try makeTempDB()
        let note = WorkbenchNote(
            id: UUID(), content: "Soon to vanish",
            tag: .observation, attachedTo: .project,
            createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(note)
        try db.deleteNote(id: note.id)
        #expect(try db.searchNotes(query: "vanish").isEmpty)
    }

    // MARK: - Questions CRUD

    @Test func addQuestion_persistsAndLoads() throws {
        let db = try makeTempDB()
        let q = OpenQuestion(
            id: UUID(), text: "Who were William's parents?",
            profileIDs: ["william"],
            priority: .high, status: .open,
            triedSources: "FreeBMD 1810",
            promotedFrom: .fromAudit(ruleID: "missingParents"),
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        try db.addQuestion(q)

        let loaded = try db.loadQuestions()
        #expect(loaded.count == 1)
        #expect(loaded.first?.text == "Who were William's parents?")
        #expect(loaded.first?.profileIDs == ["william"])
        #expect(loaded.first?.triedSources == "FreeBMD 1810")
    }

    @Test func resolveQuestion_setsStatusAndTimestamp() throws {
        let db = try makeTempDB()
        let q = OpenQuestion(
            id: UUID(), text: "Test?", profileIDs: [],
            priority: .low, status: .open,
            triedSources: nil, promotedFrom: .manual,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        try db.addQuestion(q)
        try db.resolveQuestion(id: q.id, resolution: "Found in 1851 census")

        let loaded = try db.loadQuestion(id: q.id)
        #expect(loaded?.status == .resolved)
        #expect(loaded?.resolvedAt != nil)
        #expect(loaded?.resolution == "Found in 1851 census")
    }

    @Test func loadQuestions_forProfile_filters() throws {
        let db = try makeTempDB()
        let q1 = OpenQuestion(
            id: UUID(), text: "About alice", profileIDs: ["alice"],
            priority: .medium, status: .open,
            triedSources: nil, promotedFrom: .manual,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        let q2 = OpenQuestion(
            id: UUID(), text: "About bob", profileIDs: ["bob"],
            priority: .medium, status: .open,
            triedSources: nil, promotedFrom: .manual,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        try db.addQuestion(q1)
        try db.addQuestion(q2)

        let aliceQs = try db.loadQuestions(forProfile: "alice")
        #expect(aliceQs.count == 1)
        #expect(aliceQs.first?.text == "About alice")
    }

    @Test func deleteQuestion_removes() throws {
        let db = try makeTempDB()
        let q = OpenQuestion(
            id: UUID(), text: "?", profileIDs: [],
            priority: .low, status: .open,
            triedSources: nil, promotedFrom: nil,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        try db.addQuestion(q)
        try db.deleteQuestion(id: q.id)
        #expect(try db.loadQuestions().isEmpty)
    }

    @Test func questionPriority_sortWeightOrdersHighFirst() {
        let weights = QuestionPriority.allCases.map { $0.sortWeight }
        let high = QuestionPriority.high.sortWeight
        let medium = QuestionPriority.medium.sortWeight
        let low = QuestionPriority.low.sortWeight
        #expect(high < medium && medium < low)
        #expect(weights.contains(0))
    }

    @Test func questionOrigin_roundTripsThroughJSON() throws {
        let originals: [QuestionOrigin] = [
            .manual,
            .fromAudit(ruleID: "missingParents"),
            .fromGap(profileID: "p1", field: .birthDate),
            .fromResearch(hypothesisID: UUID()),
        ]
        for origin in originals {
            let data = try JSONEncoder().encode(origin)
            let decoded = try JSONDecoder().decode(QuestionOrigin.self, from: data)
            #expect(decoded == origin)
        }
    }
}
