import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the Census Transcription Mode in AddFamilyView (M16.4).
/// We don't unit-test the SwiftUI view itself — per project conventions
/// in `~/.claude/CLAUDE.md`, we test services + models. The save path
/// is exercised indirectly: we recreate the same `createLifeEvent`
/// loop the view runs after `addFamily`.
@MainActor
struct CensusTranscriptionTests {

    /// Build an AppState wired to a fresh in-memory project database.
    private func makeAppState() throws -> AppState {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let appState = AppState()
        appState.currentDatabase = db
        return appState
    }

    @Test func censusModeOnDefaultsSourceToManualRecord() {
        // Direct test of the foundation helper — census mode short-circuits
        // every context to .manualRecord regardless of the original.
        #expect(
            SourceDefaults.defaultSource(context: .homePerson, censusMode: true)
                == .manualRecord
        )
        #expect(
            SourceDefaults.defaultSource(context: .grandparent, censusMode: true)
                == .manualRecord
        )
        #expect(
            SourceDefaults.defaultSource(
                context: .relativeOf(profileID: "p1", primarySource: .gedcom),
                censusMode: true
            ) == .manualRecord
        )
    }

    @Test func censusModeCreatesLifeEventsForEachProfile() throws {
        let appState = try makeAppState()

        // Set up a 2-person family — father + child.
        let father = Profile(
            id: "f1", externalIDs: [:],
            firstName: "John", lastName: "Smith",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        let child = Profile(
            id: "c1", externalIDs: [:],
            firstName: "Mary", lastName: "Smith",
            gender: .female, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )

        appState.addFamily(
            profiles: [father, child],
            relationships: [],
            source: .manualRecord
        )

        // Mirror what AddFamilyView.attachCensusLifeEvents does after save:
        // a `.census` LifeEvent per resolved profile.
        let address = "42 King Street"
        let yearText = "1881"
        for profileID in ["f1", "c1"] {
            _ = appState.createLifeEvent(
                profileID: profileID,
                type: .census,
                date: GenealogicalDate(parsing: yearText),
                location: address,
                description: nil,
                sources: [],
                confidence: .standard
            )
        }

        let fatherEvents = appState.lifeEventsForProfile("f1")
        let childEvents = appState.lifeEventsForProfile("c1")
        #expect(fatherEvents.count == 1)
        #expect(childEvents.count == 1)
        #expect(fatherEvents.first?.type == .census)
        #expect(childEvents.first?.type == .census)
        #expect(fatherEvents.first?.location == address)
        #expect(fatherEvents.first?.date?.bestYear == 1881)
    }

    @Test func censusModeOffPreservesExistingBehaviour() throws {
        let appState = try makeAppState()
        let father = Profile(
            id: "f2", externalIDs: [:],
            firstName: "Henry", lastName: "Jones",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )

        // Census mode OFF — no life event creation step runs.
        appState.addFamily(
            profiles: [father],
            relationships: [],
            source: .manualMemory
        )

        let events = appState.lifeEventsForProfile("f2")
        #expect(events.isEmpty)
    }

    @Test func censusYearAndAgeComputeBirthYearWithinTolerance() {
        // Pure helper — birth year inferred from age + census year.
        // Census 1881, age 42 → 1839 (canonical), tolerance ±1 because
        // the census date isn't the subject's birthday.
        let birthYear = CensusType.computeBirthYear(censusYear: 1881, ageAtCensus: 42)
        #expect(birthYear == 1839)
        // Sanity check the tolerance band: any value in 1838...1840 is plausible.
        #expect((1838...1840).contains(birthYear))
    }
}
