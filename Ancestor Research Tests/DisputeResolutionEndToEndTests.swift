import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// CONFLICT_LAYER_SPEC §6 Change 1 AC4 + AC6 — end-to-end resolution:
/// pick-a-value → `resolveFieldDispute` transaction → canonical field
/// updated → dispute resolved `.accepted` → ONE undo restores both; and
/// the R3 shield holding across the whole producer path for
/// user-authoritative values.
@MainActor
struct DisputeResolutionEndToEndTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// Profile with canonical deathDate 1901 + a real apply-produced
    /// dispute against Dec 1900 (the DS-13 scenario, produced by the
    /// actual T-A hook rather than hand-seeded rows).
    private func seedConflictedProfile(_ db: ProjectDatabase) throws -> Profile {
        let profile = Profile(
            id: "p1", externalIDs: [:],
            firstName: "William", lastName: "Cauldwell",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1901"), deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [.deathDate: [FieldSource(origin: .gedcom, raw: "1901", addedAt: Date())]],
            disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", rawFields: [:]),
            deathYear: 1900, quarter: "Dec", district: "Belper"
        ))
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
        _ = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)
        return profile
    }

    // MARK: - AC4: resolve updates the canonical field, undo restores both

    @Test func pickAValueUpdatesCanonicalFieldAndResolvesDispute() throws {
        let db = try makeDB()
        let profile = try seedConflictedProfile(db)
        #expect(try db.openDisputes(profileID: profile.id).count == 1)

        let chosen = FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date())
        _ = try db.resolveFieldDispute(
            profileID: profile.id, field: .deathDate, resolution: .accepted(chosen)
        )

        // Canonical field updated to the picked value.
        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "Dec 1900")
        // Dispute resolved `.accepted`, resolved_at stamped.
        #expect(try db.openDisputes(profileID: profile.id).isEmpty)
        let all = try db.allDisputes(profileID: profile.id)
        #expect(all.count == 1)
        guard case .accepted(let stored) = all[0].resolution else {
            Issue.record("Expected .accepted, got \(String(describing: all[0].resolution))")
            return
        }
        #expect(stored.raw == "Dec 1900")
        #expect(all[0].resolvedAt != nil)
        // The snapshot view agrees.
        #expect(reloaded?.disputes[.deathDate]?.resolution != nil)
    }

    @Test func undoRestoresBothCanonicalFieldAndOpenDispute() throws {
        let db = try makeDB()
        let profile = try seedConflictedProfile(db)

        let chosen = FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date())
        let tx = try db.resolveFieldDispute(
            profileID: profile.id, field: .deathDate, resolution: .accepted(chosen)
        )
        #expect(try db.buildSnapshot().profiles[profile.id]?.deathDate?.original == "Dec 1900")

        // ONE undo (the resolve transaction's replay) restores both sides.
        try db.undoReplay(transactionID: tx.id)

        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "1901")
        let open = try db.openDisputes(profileID: profile.id)
        #expect(open.count == 1)
        #expect(open[0].resolution == nil)
        #expect(open[0].resolvedAt == nil)
    }

    @Test func deferredResolutionLeavesCanonicalFieldUntouched() throws {
        let db = try makeDB()
        let profile = try seedConflictedProfile(db)

        _ = try db.resolveFieldDispute(
            profileID: profile.id, field: .deathDate, resolution: .deferred
        )
        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "1901")
        let all = try db.allDisputes(profileID: profile.id)
        #expect(all[0].resolution == .deferred)
        #expect(all[0].resolvedAt != nil)
    }

    @Test func acceptingTheIncumbentValueResolvesWithoutAFieldWrite() throws {
        let db = try makeDB()
        let profile = try seedConflictedProfile(db)

        // Picking the value already on the profile: resolution persists,
        // no redundant canonical write happens.
        let incumbent = FieldSource(origin: .gedcom, raw: "1901", addedAt: Date())
        _ = try db.resolveFieldDispute(
            profileID: profile.id, field: .deathDate, resolution: .accepted(incumbent)
        )
        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "1901")
        #expect(try db.openDisputes(profileID: profile.id).isEmpty)
    }

    @Test func stringFieldResolutionUpdatesCanonicalColumn() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p2", externalIDs: [:],
            firstName: "Jane", lastName: "Doe",
            gender: .female, attributes: nil,
            birthDate: nil, birthLocation: "Belper",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [.birthLocation: [FieldSource(origin: .gedcom, raw: "Belper", addedAt: Date())]],
            disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
        let dispute = FieldDispute(
            field: .birthLocation, reason: .valueMismatch,
            competingSources: [
                FieldSource(origin: .gedcom, raw: "Belper", addedAt: Date()),
                FieldSource(origin: .freecen, raw: "Bakewell", addedAt: Date()),
            ],
            detectedAt: Date()
        )
        try db.addFieldDispute(profileID: "p2", dispute: dispute)

        _ = try db.resolveFieldDispute(
            profileID: "p2", field: .birthLocation,
            resolution: .accepted(dispute.competingSources[1])
        )
        let reloaded = try db.buildSnapshot().profiles["p2"]
        #expect(reloaded?.birthLocation == "Bakewell")
    }

    // MARK: - AC6: R3 — user-authoritative values are never auto-resolved

    @Test func conflictAgainstUserManualValueStaysOpenWithR3Trace() throws {
        let db = try makeDB()
        // Canonical deathDate typed by the user (manual origin in the
        // provenance journal).
        let profile = Profile(
            id: "p3", externalIDs: [:],
            firstName: "Robert", lastName: "Cauldwell",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1919"), deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [.deathDate: [FieldSource(origin: .manual, raw: "1919", addedAt: Date())]],
            disputes: [:]
        )
        _ = try db.addProfile(profile, source: .manual)
        let snapshot = try db.buildSnapshot()

        // A primary-tier record disagrees. Post-CL5 R2a might weigh
        // directness — but never against a user value (R3, in either
        // direction). In CL1 nothing auto-resolves anyway; the trace must
        // prove R3 fired and shielded the rungs.
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d9", sourceID: "cwgc", rawFields: [:]),
            deathYear: 1918, quarter: nil, district: nil
        ))
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
        _ = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)

        let open = try db.openDisputes(profileID: "p3")
        #expect(open.count == 1)
        #expect(open[0].resolution == nil)
        let trace = try JSONDecoder().decode(
            [DisputeResolver.RungEvaluation].self,
            from: Data((open[0].ladderTrace ?? "[]").utf8)
        )
        #expect(trace.contains { $0.rung == "R3" && $0.outcome == "fired" })
        // Canonical value untouched — the user's 1919 stands.
        #expect(try db.buildSnapshot().profiles["p3"]?.deathDate?.original == "1919")
    }

    // MARK: - AppState flow still works over producer-written disputes

    @Test func appStateResolveFlowWorksOverAnApplyProducedDispute() throws {
        let db = try makeDB()
        let profile = try seedConflictedProfile(db)

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        let dispute = appState.snapshot.profiles[profile.id]?.disputes[.deathDate]
        #expect(dispute != nil)
        #expect(dispute?.detectedBy == .applyEngine)

        appState.resolveDispute(
            profileID: profile.id, field: .deathDate,
            resolution: .accepted(FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date()))
        )
        // Snapshot rebuilt by the flow; canonical + resolution both visible.
        #expect(appState.snapshot.profiles[profile.id]?.deathDate?.original == "Dec 1900")
        #expect(appState.snapshot.profiles[profile.id]?.disputes[.deathDate]?.resolution != nil)
    }
}
