import Testing
import Foundation
@testable import Ancestor_Research

/// M16.14 — regression tests for the dispute resolution write-back path.
/// Found INCOMPLETE during the audit (Resolve / Defer buttons in
/// ConflictResolutionView had empty closures). The fix wires
/// AppState.resolveDispute → ProjectDatabase.resolveFieldDispute → an
/// UPDATE on field_disputes.resolution. These tests pin the round-trip
/// so a future regression is caught immediately.
@MainActor
struct DisputeResolutionWriteBackTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// Build an AppState wired to a fresh in-memory project database.
    private func makeAppState() throws -> (AppState, ProjectDatabase, Profile, FieldDispute) {
        let db = try makeTempDB()
        let appState = AppState()
        appState.currentDatabase = db

        // Seed a profile with two competing sources for birthDate.
        let profile = Profile(
            id: "p1", externalIDs: [:],
            firstName: "Jane", lastName: "Doe",
            gender: .female, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1880"),
            birthLocation: "Wirksworth",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)

        let s1 = FieldSource(origin: .gedcom, raw: "1880", addedAt: Date())
        let s2 = FieldSource(origin: .freebmd, raw: "1881", addedAt: Date())
        let dispute = FieldDispute(
            field: .birthDate,
            reason: .valueMismatch,
            competingSources: [s1, s2],
            detectedAt: Date(),
            resolution: nil
        )
        try db.addFieldDispute(profileID: profile.id, dispute: dispute)

        // Refresh the snapshot so AppState sees the dispute.
        appState.snapshot = try db.buildSnapshot()
        return (appState, db, profile, dispute)
    }

    @Test func acceptingSourceUpdatesDisputeResolution() throws {
        let (appState, db, profile, dispute) = try makeAppState()
        let chosenSource = dispute.competingSources[1]   // 1881

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .accepted(chosenSource)
        )

        // Reload from disk to confirm the write hit SQLite.
        let reloaded = try db.buildSnapshot()
        let reloadedProfile = reloaded.profiles[profile.id]
        let resolved = reloadedProfile?.disputes[.birthDate]?.resolution
        guard case .accepted(let storedSource) = resolved else {
            Issue.record("Expected .accepted resolution, got \(String(describing: resolved))")
            return
        }
        #expect(storedSource.raw == "1881")
        #expect(storedSource.origin == .freebmd)
    }

    @Test func manualResolutionPersistsValue() throws {
        let (appState, db, profile, _) = try makeAppState()

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .manual("1880-1881")
        )

        let reloaded = try db.buildSnapshot()
        let resolution = reloaded.profiles[profile.id]?.disputes[.birthDate]?.resolution
        guard case .manual(let value) = resolution else {
            Issue.record("Expected .manual resolution, got \(String(describing: resolution))")
            return
        }
        #expect(value == "1880-1881")
    }

    @Test func deferredResolutionMarksDisputeDeferred() throws {
        let (appState, db, profile, _) = try makeAppState()

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .deferred
        )

        let reloaded = try db.buildSnapshot()
        let resolution = reloaded.profiles[profile.id]?.disputes[.birthDate]?.resolution
        #expect(resolution == .deferred)
    }

    @Test func resolveDisputeRecordsTransaction() throws {
        let (appState, db, profile, _) = try makeAppState()

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .deferred
        )

        // The resolution should write a transaction so undo can replay it.
        let txs = try db.loadTransactions(limit: 5)
        let resolveTx = txs.first {
            if case .resolveDispute = $0.kind { return true }
            return false
        }
        #expect(resolveTx != nil)
    }
}
