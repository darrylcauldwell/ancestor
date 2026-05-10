import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for M8 W4 (Sessions) — startSession, recordSessionEvent counters,
/// resume window detection, summary text, and focus-set persistence.
struct SessionTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    // MARK: - Start + load

    @Test func startSession_persistsAndLoads() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        let loaded = try db.loadSession(id: session.id)
        #expect(loaded?.id == session.id)
        #expect(loaded?.profilesAdded == 0)
        #expect(loaded?.transactionIDs.isEmpty == true)
    }

    @Test func startSession_withFocusSetID_persistsLink() throws {
        let db = try makeTempDB()
        let focusID = UUID()
        let session = try db.startSession(focusSetID: focusID)
        #expect(try db.loadSession(id: session.id)?.focusSetID == focusID)
    }

    // MARK: - Counter events

    @Test func recordEvent_profileAdded_incrementsCounter() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        try db.recordSessionEvent(.profileAdded, sessionID: session.id)
        try db.recordSessionEvent(.profileAdded, sessionID: session.id)
        let loaded = try db.loadSession(id: session.id)
        #expect(loaded?.profilesAdded == 2)
    }

    @Test func recordEvent_allCountersIncrementIndependently() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        try db.recordSessionEvent(.profileEdited, sessionID: session.id)
        try db.recordSessionEvent(.disputeResolved, sessionID: session.id)
        try db.recordSessionEvent(.hypothesisCreated, sessionID: session.id)
        try db.recordSessionEvent(.hypothesisPromoted, sessionID: session.id)
        try db.recordSessionEvent(.questionCreated, sessionID: session.id)
        try db.recordSessionEvent(.questionResolved, sessionID: session.id)
        try db.recordSessionEvent(.noteCreated, sessionID: session.id)
        let loaded = try db.loadSession(id: session.id)
        #expect(loaded?.profilesEdited == 1)
        #expect(loaded?.disputesResolved == 1)
        #expect(loaded?.hypothesesCreated == 1)
        #expect(loaded?.hypothesesPromoted == 1)
        #expect(loaded?.questionsCreated == 1)
        #expect(loaded?.questionsResolved == 1)
        #expect(loaded?.notesCreated == 1)
    }

    @Test func recordEvent_transactionAppendsToList() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        let tx1 = UUID()
        let tx2 = UUID()
        try db.recordSessionEvent(.transactionRecorded(tx1), sessionID: session.id)
        try db.recordSessionEvent(.transactionRecorded(tx2), sessionID: session.id)
        let loaded = try db.loadSession(id: session.id)
        #expect(loaded?.transactionIDs == [tx1, tx2])
    }

    @Test func recordEvent_bumpsEndedAt() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        let initialEnded = try db.loadSession(id: session.id)?.endedAt
        // Tiny sleep to guarantee a measurable delta.
        Thread.sleep(forTimeInterval: 0.01)
        try db.recordSessionEvent(.profileAdded, sessionID: session.id)
        let bumped = try db.loadSession(id: session.id)?.endedAt
        #expect(bumped != nil && initialEnded != nil)
        #expect((bumped ?? .distantPast) > (initialEnded ?? .distantFuture))
    }

    // MARK: - Active vs resumable

    @Test func loadActiveSession_returnsLiveSession() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        try db.recordSessionEvent(.profileAdded, sessionID: session.id)
        // Just-recorded session is well within the idle threshold.
        let active = try db.loadActiveSession()
        #expect(active?.id == session.id)
    }

    @Test func loadActiveSession_returnsNilWhenIdleExceeded() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        // Manually backdate ended_at by writing directly via touchSession
        // followed by a SQL UPDATE. We use the public API path here.
        try db.recordSessionEvent(.profileAdded, sessionID: session.id)
        // Force ended_at into the deep past via a fresh touch + manual override.
        let ancient = Date().addingTimeInterval(-(ProjectDatabase.sessionIdleThreshold + 60))
        try setEndedAt(ancient, forSession: session.id, db: db)
        let active = try db.loadActiveSession()
        #expect(active == nil)
    }

    @Test func loadResumableSession_returnsSessionWithinResumeWindow() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        try db.recordSessionEvent(.profileAdded, sessionID: session.id)
        let pastButResumable = Date().addingTimeInterval(-(ProjectDatabase.sessionIdleThreshold + 600))
        try setEndedAt(pastButResumable, forSession: session.id, db: db)
        let resumable = try db.loadResumableSession()
        #expect(resumable?.id == session.id)
    }

    @Test func loadResumableSession_skipsNoActivitySession() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        // No counter increments → hasActivity is false → not resumable.
        let pastButResumable = Date().addingTimeInterval(-(ProjectDatabase.sessionIdleThreshold + 600))
        try setEndedAt(pastButResumable, forSession: session.id, db: db)
        #expect(try db.loadResumableSession() == nil)
    }

    @Test func loadResumableSession_returnsNilBeyondResumeWindow() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        try db.recordSessionEvent(.profileAdded, sessionID: session.id)
        let veryOld = Date().addingTimeInterval(-(ProjectDatabase.sessionResumeWindow + 60))
        try setEndedAt(veryOld, forSession: session.id, db: db)
        #expect(try db.loadResumableSession() == nil)
    }

    @Test func updateSessionFocus_persists() throws {
        let db = try makeTempDB()
        let session = try db.startSession()
        let focusID = UUID()
        try db.updateSessionFocus(sessionID: session.id, focusSetID: focusID)
        #expect(try db.loadSession(id: session.id)?.focusSetID == focusID)
    }

    // MARK: - Summary text

    @Test func summary_emptySession_saysNoActivity() {
        let session = ResearchSession(
            id: UUID(), startedAt: Date().addingTimeInterval(-300),
            endedAt: Date(), focusSetID: nil,
            profilesAdded: 0, profilesEdited: 0, disputesResolved: 0,
            hypothesesCreated: 0, hypothesesPromoted: 0,
            questionsCreated: 0, questionsResolved: 0, notesCreated: 0,
            transactionIDs: []
        )
        let summary = session.summary
        #expect(summary.contains("no recorded activity"))
    }

    @Test func summary_includesCountedActions() {
        let session = ResearchSession(
            id: UUID(), startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date(), focusSetID: nil,
            profilesAdded: 4, profilesEdited: 0, disputesResolved: 2,
            hypothesesCreated: 3, hypothesesPromoted: 1,
            questionsCreated: 0, questionsResolved: 0, notesCreated: 0,
            transactionIDs: []
        )
        let summary = session.summary
        #expect(summary.contains("4 profile"))
        #expect(summary.contains("2 dispute"))
        #expect(summary.contains("3 hypotheses"))
        #expect(summary.contains("(1 promoted)"))
    }

    @Test func hasActivity_falseWhenAllZero() {
        let session = ResearchSession(
            id: UUID(), startedAt: Date(), endedAt: nil, focusSetID: nil,
            profilesAdded: 0, profilesEdited: 0, disputesResolved: 0,
            hypothesesCreated: 0, hypothesesPromoted: 0,
            questionsCreated: 0, questionsResolved: 0, notesCreated: 0,
            transactionIDs: []
        )
        #expect(!session.hasActivity)
    }

    @Test func hasActivity_trueWithAnyCounter() {
        let session = ResearchSession(
            id: UUID(), startedAt: Date(), endedAt: nil, focusSetID: nil,
            profilesAdded: 0, profilesEdited: 0, disputesResolved: 0,
            hypothesesCreated: 0, hypothesesPromoted: 0,
            questionsCreated: 0, questionsResolved: 0, notesCreated: 1,
            transactionIDs: []
        )
        #expect(session.hasActivity)
    }

    // MARK: - Helpers

    /// Test helper for backdating `ended_at` so resume-window logic can be
    /// exercised without sleeping. Goes through the underscored
    /// `_unsafeSetSessionEndedAt` rather than touchSession (which always
    /// writes "now").
    private func setEndedAt(_ date: Date, forSession id: UUID, db: ProjectDatabase) throws {
        try db._unsafeSetSessionEndedAt(date, sessionID: id)
    }
}
