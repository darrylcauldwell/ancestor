import Testing
import Foundation
@testable import Ancestor_Research

/// Service-layer tests for the M12 LifeEvent CRUD flow exercised by the
/// `LifeEventEditorView` sheet. We don't unit-test the SwiftUI view itself —
/// per project conventions in `~/.claude/CLAUDE.md`, we test services + models.
@MainActor
struct LifeEventCRUDTests {

    // MARK: - Helpers

    /// Build an AppState wired to a fresh in-memory project database.
    /// Bypasses the on-disk ProjectStore so tests don't touch the user's
    /// projects directory.
    private func makeAppState() throws -> AppState {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let appState = AppState()
        appState.currentDatabase = db
        return appState
    }

    private let testProfileID = "p-test"

    // MARK: - Tests

    @Test func addingLifeEventPersists() throws {
        let appState = try makeAppState()
        let event = appState.createLifeEvent(
            profileID: testProfileID,
            type: .occupation,
            date: GenealogicalDate(parsing: "1887"),
            location: "Belper, Derbyshire",
            description: "Framework knitter",
            confidence: .standard
        )
        #expect(event != nil)

        let loaded = appState.lifeEventsForProfile(testProfileID)
        #expect(loaded.count == 1)
        #expect(loaded.first?.type == .occupation)
        #expect(loaded.first?.description == "Framework knitter")
        #expect(loaded.first?.location == "Belper, Derbyshire")
        #expect(loaded.first?.date?.bestYear == 1887)
    }

    @Test func updatingLifeEventPersistsChanges() throws {
        let appState = try makeAppState()
        guard var event = appState.createLifeEvent(
            profileID: testProfileID,
            type: .residence,
            date: GenealogicalDate(parsing: "1880"),
            location: "Belper",
            description: "42 King Street",
            confidence: .tentative
        ) else {
            Issue.record("Expected createLifeEvent to succeed")
            return
        }

        event.description = "44 Queen Street"
        event.location = "Wirksworth"
        event.confidence = .wellEvidenced
        event.endDate = GenealogicalDate(parsing: "1895")
        appState.updateLifeEvent(event)

        let loaded = appState.lifeEventsForProfile(testProfileID)
        #expect(loaded.count == 1)
        #expect(loaded.first?.description == "44 Queen Street")
        #expect(loaded.first?.location == "Wirksworth")
        #expect(loaded.first?.confidence == .wellEvidenced)
        #expect(loaded.first?.endDate?.bestYear == 1895)
    }

    @Test func deletingLifeEventRemovesIt() throws {
        let appState = try makeAppState()
        guard let event = appState.createLifeEvent(
            profileID: testProfileID,
            type: .baptism,
            date: GenealogicalDate(parsing: "1834"),
            location: "St Peter's, Belper"
        ) else {
            Issue.record("Expected createLifeEvent to succeed")
            return
        }

        #expect(appState.lifeEventsForProfile(testProfileID).count == 1)

        appState.deleteLifeEvent(id: event.id)

        #expect(appState.lifeEventsForProfile(testProfileID).isEmpty)
    }

    @Test func lifeEventTypesWithDurationFlagThemCorrectly() {
        // Duration-bearing types — endDate is meaningful.
        #expect(LifeEventType.residence.hasDuration)
        #expect(LifeEventType.occupation.hasDuration)
        #expect(LifeEventType.education.hasDuration)
        #expect(LifeEventType.militaryService.hasDuration)
        #expect(LifeEventType.religion.hasDuration)

        // Point-in-time types — no endDate.
        #expect(!LifeEventType.census.hasDuration)
        #expect(!LifeEventType.baptism.hasDuration)
        #expect(!LifeEventType.burial.hasDuration)
        #expect(!LifeEventType.probate.hasDuration)
        #expect(!LifeEventType.immigration.hasDuration)
        #expect(!LifeEventType.emigration.hasDuration)
        #expect(!LifeEventType.other.hasDuration)
    }
}
