import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the per-field source picker in EditPersonView (M17.2).
///
/// We don't unit-test the SwiftUI view itself — per project conventions
/// we test services and the AppState wiring. The save path is exercised
/// through AppState's extended `editProfile(sourceByField:)` API.
@MainActor
struct EditPersonPerFieldSourceTests {

    private func makeAppState() throws -> AppState {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let state = AppState()
        state.currentDatabase = db
        // Fire-and-forget initial snapshot — empty for a fresh DB.
        state.snapshot = (try? db.buildSnapshot()) ?? .empty
        return state
    }

    private func makeProfile(id: String = "p1") -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: "Original", lastName: "Surname",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: "Old Town",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    @Test func editPersonPersistsPerFieldSourcesIndependently() throws {
        let state = try makeAppState()
        let profile = makeProfile()
        state.addProfile(profile, source: .manualMemory, relatedTo: nil)

        // Edit two fields with two different sources.
        let perField: [ProfileField: SourceOrigin] = [
            .firstName: .manualDocument,
            .birthLocation: .manualRecord,
        ]
        state.editProfile(
            id: profile.id,
            changes: [
                (.firstName, "Original", "Updated"),
                (.birthLocation, "Old Town", "New Town"),
            ],
            dateChanges: [],
            source: .manualMemory,
            sourceByField: perField
        )

        let updated = state.snapshot.profiles[profile.id]
        #expect(updated?.firstName == "Updated")
        #expect(updated?.birthLocation == "New Town")

        // Each field's most recent FieldSource should match the per-field
        // origin we passed — proves the dispatcher routed each field into
        // the right manualEdit transaction.
        let firstNameSources = updated?.sources[.firstName] ?? []
        let birthLocSources = updated?.sources[.birthLocation] ?? []
        #expect(firstNameSources.last?.origin == .manualDocument)
        #expect(birthLocSources.last?.origin == .manualRecord)
    }

    @Test func unchangedFieldsRetainOriginalSource() throws {
        let state = try makeAppState()
        let profile = makeProfile()
        state.addProfile(profile, source: .manualMemory, relatedTo: nil)

        // Touch only the firstName field with a Document source — lastName
        // and birthLocation should keep their original .manualMemory rows
        // because we never include them in `changes`.
        state.editProfile(
            id: profile.id,
            changes: [(.firstName, "Original", "Updated")],
            dateChanges: [],
            source: .manualMemory,
            sourceByField: [.firstName: .manualDocument]
        )

        let updated = state.snapshot.profiles[profile.id]
        let lastNameSources = updated?.sources[.lastName] ?? []
        let birthLocSources = updated?.sources[.birthLocation] ?? []
        #expect(lastNameSources.allSatisfy { $0.origin == .manualMemory })
        #expect(birthLocSources.allSatisfy { $0.origin == .manualMemory })
        #expect(updated?.lastName == "Surname")
        #expect(updated?.birthLocation == "Old Town")
    }

    @Test func defaultPerFieldSourceMatchesSourceDefaults() {
        // Sanity check on the seed used by EditPersonView.loadIfNeeded:
        // for a profile whose primary source is a Document, the default
        // for an edit on that profile should inherit Document — that's
        // exactly the relativeOf-with-manual-source contract.
        let result = SourceDefaults.defaultSource(
            context: .relativeOf(profileID: "p1", primarySource: .manualDocument)
        )
        #expect(result == .manualDocument)

        // And for a profile whose primary source is a structured import
        // (e.g. GEDCOM), the default falls back to .manualMemory because
        // the new edit isn't from the original import.
        let gedcomResult = SourceDefaults.defaultSource(
            context: .relativeOf(profileID: "p1", primarySource: .gedcom)
        )
        #expect(gedcomResult == .manualMemory)
    }
}
