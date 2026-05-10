import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the Top-5 spec-gap fixes:
/// 1. Session.transactionIDs are recorded on every mutation
/// 2. notesForHypothesis / notesForQuestion attachment lookups
/// 3. GEDCOM import refuses to duplicate into a non-empty tree
struct AuditTopFiveTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    // MARK: - 1. Transaction id recording

    @Test func session_transactionRecorded_appendsToList() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        let tx1 = UUID(), tx2 = UUID(), tx3 = UUID()
        try db.recordSessionEvent(.transactionRecorded(tx1), sessionID: session.id)
        try db.recordSessionEvent(.transactionRecorded(tx2), sessionID: session.id)
        try db.recordSessionEvent(.transactionRecorded(tx3), sessionID: session.id)
        let loaded = try db.loadSession(id: session.id)
        #expect(loaded?.transactionIDs == [tx1, tx2, tx3])
    }

    // MARK: - 2. Attachment lookups by kind

    private func makeNote(kind: String, attachmentID: String?) -> WorkbenchNote {
        let attachment: NoteAttachment
        switch kind {
        case "hypothesis": attachment = .hypothesis(id: UUID(uuidString: attachmentID!) ?? UUID())
        case "question": attachment = .question(id: UUID(uuidString: attachmentID!) ?? UUID())
        case "profile": attachment = .profile(id: attachmentID ?? "")
        default: attachment = .project
        }
        return WorkbenchNote(
            id: UUID(),
            content: "for-\(kind)",
            tag: .observation,
            attachedTo: attachment,
            createdAt: Date(), updatedAt: Date()
        )
    }

    @Test func loadNotes_byHypothesisAttachment_filters() throws {
        let db = try makeTempDB()
        let hypoID = UUID()
        let other = UUID()
        let attached = makeNote(kind: "hypothesis", attachmentID: hypoID.uuidString)
        let elsewhere = makeNote(kind: "hypothesis", attachmentID: other.uuidString)
        try db.addNote(attached)
        try db.addNote(elsewhere)

        let hits = try db.loadNotes(attachedToKind: "hypothesis", id: hypoID.uuidString)
        #expect(hits.count == 1)
        #expect(hits.first?.content == "for-hypothesis")
    }

    @Test func loadNotes_byQuestionAttachment_filters() throws {
        let db = try makeTempDB()
        let qID = UUID()
        let attached = makeNote(kind: "question", attachmentID: qID.uuidString)
        try db.addNote(attached)

        let hits = try db.loadNotes(attachedToKind: "question", id: qID.uuidString)
        #expect(hits.count == 1)
    }

    @Test func loadNotes_kindIsolation() throws {
        let db = try makeTempDB()
        let id = UUID()
        // Same UUID, different kinds — must not cross-contaminate.
        try db.addNote(makeNote(kind: "hypothesis", attachmentID: id.uuidString))
        try db.addNote(makeNote(kind: "question", attachmentID: id.uuidString))

        let hypoHits = try db.loadNotes(attachedToKind: "hypothesis", id: id.uuidString)
        let qHits = try db.loadNotes(attachedToKind: "question", id: id.uuidString)
        #expect(hypoHits.count == 1)
        #expect(qHits.count == 1)
        #expect(hypoHits.first?.id != qHits.first?.id)
    }

    // MARK: - 3. GEDCOM error type

    @Test func gedcomImportError_targetNotEmpty_messageMentionsCounts() {
        let err = GEDCOMImportError.targetNotEmpty(existingCount: 7, incomingCount: 13)
        let msg = err.errorDescription ?? ""
        #expect(msg.contains("7"))
        #expect(msg.contains("13"))
        #expect(msg.contains("merge") || msg.contains("Import"))
    }

    // MARK: - 4. QuestionOrigin shape (used by audit/gap promote)

    @Test func questionOrigin_fromAudit_carriesRuleID() {
        let origin = QuestionOrigin.fromAudit(ruleID: "missingParents")
        if case .fromAudit(let id) = origin {
            #expect(id == "missingParents")
        } else {
            Issue.record("Expected .fromAudit case")
        }
    }

    @Test func questionOrigin_fromGap_carriesProfileAndField() {
        let origin = QuestionOrigin.fromGap(profileID: "p1", field: .birthDate)
        if case .fromGap(let pid, let field) = origin {
            #expect(pid == "p1")
            #expect(field == .birthDate)
        } else {
            Issue.record("Expected .fromGap case")
        }
    }
}
