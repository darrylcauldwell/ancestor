import Testing
import Foundation
@testable import Ancestor_Research

/// M18 — Audit-rule overrides (DESIGN.md §13).
///
/// These tests cover the override system end-to-end:
///   - DB round-trip
///   - global mute through `AuditEngine.audit`
///   - snooze expiry honoured by `now:` time travel
///   - profile-scoped mute applies to that profile only
///   - tunable threshold overrides (parent age gap)
///   - AppState convenience snooze helper persists
@MainActor
struct AuditRuleOverrideTests {

    // MARK: - Helpers

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeAppState(db: ProjectDatabase? = nil) throws -> AppState {
        let database = try db ?? makeTempDB()
        let appState = AppState()
        appState.currentDatabase = database
        return appState
    }

    private func makeProfile(
        id: String,
        firstName: String? = "Test",
        lastName: String? = "Person",
        birthDate: String? = nil,
        deathDate: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func makeSnapshot(
        profiles: [Profile],
        relationships: [Relationship] = []
    ) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: relationships)
    }

    // MARK: - Tests

    @Test func overrideRoundTripsThroughDatabase() throws {
        let db = try makeTempDB()
        let id = UUID()
        let original = AuditRuleOverride(
            id: id,
            ruleID: "lifespan",
            scope: .global,
            enabled: false,
            snoozedUntil: nil,
            thresholds: ["maxLifespan": 95]
        )
        try db.upsertAuditRuleOverride(original)

        let all = try db.loadAuditRuleOverrides()
        #expect(all.count == 1)
        let loaded = try #require(all.first)
        #expect(loaded.id == id)
        #expect(loaded.ruleID == "lifespan")
        #expect(loaded.enabled == false)
        #expect(loaded.scope == .global)
        #expect(loaded.thresholds["maxLifespan"] == 95)

        // Update path: same id, different fields.
        var updated = loaded
        updated.enabled = true
        updated.thresholds["maxLifespan"] = 105
        try db.upsertAuditRuleOverride(updated)

        let after = try db.loadAuditRuleOverrides()
        #expect(after.count == 1)            // still one row, not two
        #expect(after.first?.enabled == true)
        #expect(after.first?.thresholds["maxLifespan"] == 105)
    }

    @Test func globalOverrideMutesRule() {
        // ParentAgeGap fires when parent born 1874, child born 1887 (gap 13 < 14).
        let parent = makeProfile(id: "parent", birthDate: "1874")
        let child = makeProfile(id: "child", birthDate: "1887")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])

        // Without override: rule fires.
        let baseline = AuditEngine.audit(snapshot)
        #expect(baseline.contains { $0.ruleID == "parentAgeGap" })

        // With global mute: rule does not fire.
        let muteOverride = AuditRuleOverride(
            id: UUID(),
            ruleID: "parentAgeGap",
            scope: .global,
            enabled: false,
            snoozedUntil: nil,
            thresholds: [:]
        )
        let muted = AuditEngine.audit(snapshot, overrides: [muteOverride])
        #expect(!muted.contains { $0.ruleID == "parentAgeGap" })
    }

    @Test func snoozedOverrideMutesUntilExpiry() {
        let profile = makeProfile(id: "p", birthDate: "1800", deathDate: "1920")
        let snapshot = makeSnapshot(profiles: [profile])

        // Lifespan rule fires on a 120-year span.
        let baseline = AuditEngine.audit(snapshot)
        #expect(baseline.contains { $0.ruleID == "lifespan" })

        // Snooze until +1 day from a fixed reference time.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snoozeUntil = now.addingTimeInterval(86400)
        let snooze = AuditRuleOverride(
            id: UUID(),
            ruleID: "lifespan",
            scope: .global,
            enabled: true,
            snoozedUntil: snoozeUntil,
            thresholds: [:]
        )

        // Inside the snooze window: muted.
        let duringSnooze = AuditEngine.audit(snapshot, overrides: [snooze], now: now)
        #expect(!duringSnooze.contains { $0.ruleID == "lifespan" })

        // After expiry: fires again.
        let afterSnooze = AuditEngine.audit(
            snapshot,
            overrides: [snooze],
            now: snoozeUntil.addingTimeInterval(60)
        )
        #expect(afterSnooze.contains { $0.ruleID == "lifespan" })
    }

    @Test func profileScopedOverrideMutesOnlyThatProfile() {
        // Two profiles each violate Lifespan; a profile-scoped override
        // for P1 should silence the rule for P1 only.
        let p1 = makeProfile(id: "P1", firstName: "Anna", birthDate: "1800", deathDate: "1920")
        let p2 = makeProfile(id: "P2", firstName: "Bert", birthDate: "1700", deathDate: "1820")
        let snapshot = makeSnapshot(profiles: [p1, p2])

        let baseline = AuditEngine.audit(snapshot)
        let baselineLifespan = baseline.filter { $0.ruleID == "lifespan" }
        #expect(baselineLifespan.count == 2)

        let p1Override = AuditRuleOverride(
            id: UUID(),
            ruleID: "lifespan",
            scope: .profile(id: "P1"),
            enabled: false,
            snoozedUntil: nil,
            thresholds: [:]
        )
        let muted = AuditEngine.audit(snapshot, overrides: [p1Override])
        let mutedLifespan = muted.filter { $0.ruleID == "lifespan" }
        #expect(mutedLifespan.count == 1)
        #expect(mutedLifespan.first?.profileID == "P2")
    }

    @Test func parentAgeGapHonoursOverriddenThreshold() {
        // Parent 1874, child 1886 → gap 12. With default minGap=14: ERROR.
        // With overridden minGap=10: no fire.
        let parent = makeProfile(id: "parent", birthDate: "1874")
        let child = makeProfile(id: "child", birthDate: "1886")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])

        let baseline = AuditEngine.audit(snapshot)
        #expect(baseline.contains { $0.ruleID == "parentAgeGap" })

        let lowered = AuditRuleOverride(
            id: UUID(),
            ruleID: "parentAgeGap",
            scope: .global,
            enabled: true,
            snoozedUntil: nil,
            thresholds: ["minYearsGap": 10]
        )
        let withOverride = AuditEngine.audit(snapshot, overrides: [lowered])
        #expect(!withOverride.contains { $0.ruleID == "parentAgeGap" })
    }

    @Test func appStateSnoozeRoundTrip() throws {
        let appState = try makeAppState()
        appState.snoozeAuditRule(ruleID: "missingBirthDate", scope: .global, days: 7)

        let loaded = appState.loadAuditRuleOverrides()
        #expect(loaded.count == 1)
        let ov = try #require(loaded.first)
        #expect(ov.ruleID == "missingBirthDate")
        #expect(ov.scope == .global)
        let until = try #require(ov.snoozedUntil)
        let secondsFromNow = until.timeIntervalSinceNow
        // ~7 days = 604_800s. Allow +/- a minute of slack for test slowness.
        #expect(secondsFromNow > 7 * 86400 - 60)
        #expect(secondsFromNow < 7 * 86400 + 60)
    }

    @Test func globalOverrideThresholdsCarryThroughEngineMerge() {
        // Lifespan: 100-year span at default 110 max → no fire. Lower max to 90
        // via override → fires.
        let profile = makeProfile(id: "p", birthDate: "1800", deathDate: "1900")
        let snapshot = makeSnapshot(profiles: [profile])

        let baseline = AuditEngine.audit(snapshot)
        #expect(!baseline.contains { $0.ruleID == "lifespan" })

        let lowered = AuditRuleOverride(
            id: UUID(),
            ruleID: "lifespan",
            scope: .global,
            enabled: true,
            snoozedUntil: nil,
            thresholds: ["maxLifespan": 90]
        )
        let withOverride = AuditEngine.audit(snapshot, overrides: [lowered])
        #expect(withOverride.contains { $0.ruleID == "lifespan" })
    }

    @Test func priorityRulesExposeTunableThresholds() {
        // Sanity check that the three priority rules expose the documented
        // thresholds — the Settings UI relies on this.
        let parentAgeGap = ParentAgeGapRule().tunableThresholds
        #expect(parentAgeGap.contains { $0.key == "minYearsGap" && $0.defaultValue == 14 })

        let lifespan = LifespanRule().tunableThresholds
        #expect(lifespan.contains { $0.key == "maxLifespan" && $0.defaultValue == 110 })

        let parentOld = ParentSuspiciouslyOldRule().tunableThresholds
        #expect(parentOld.contains { $0.key == "maxYearsGap" && $0.defaultValue == 55 })
    }
}
