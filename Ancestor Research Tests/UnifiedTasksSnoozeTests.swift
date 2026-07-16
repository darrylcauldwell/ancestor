import Testing
import Foundation
@testable import Ancestor_Research

/// M18 — integration-flavoured tests covering the per-profile / global
/// "snooze this rule" flow as it surfaces through the Tasks aggregator.
///
/// These exercise the same wiring `AppState.snoozeAuditRule(...)` triggers:
/// an `AuditRuleOverride` is added, the AuditEngine re-runs with `overrides:`,
/// and the UnifiedTaskAggregator re-derives. We bypass the SQLite layer here
/// (Agent HH owns ProjectDatabase + AppState) and assert the override semantics
/// against the engine + aggregator directly, which is what `runPostLoadAudit`
/// would do under the hood.
struct UnifiedTasksSnoozeTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String,
        firstName: String? = "Jane",
        lastName: String? = "Doe",
        birthDate: String? = "1880",
        deathDate: String? = "1950",
        birthLocation: String? = "Derby",
        deathLocation: String? = "Derby",
        // UnsourcedBioRule (warning, ISSUE) is the deterministic audit fire
        // across these tests — a >50-char bio with no citations. An issue-class
        // rule is used deliberately: gap-class rules (missing-*) no longer
        // surface as audit issues (they route to the Gaps view), so the snooze
        // mechanism must be exercised through a rule that still appears.
        bio: String? = "A sample biography comfortably longer than fifty characters, carrying no citations at all."
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .female,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            bio: bio,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func snapshot(_ profiles: [Profile]) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    /// Build the override AppState would create when the user taps "Snooze
    /// 7d" on a row. Mirrors `AppState.snoozeAuditRule(...)`.
    private func makeSnooze(
        ruleID: String,
        scope: AuditOverrideScope,
        days: Int = 7,
        from now: Date = Date()
    ) -> AuditRuleOverride {
        let until = Calendar.current.date(byAdding: .day, value: days, to: now)
            ?? now.addingTimeInterval(TimeInterval(days * 86_400))
        return AuditRuleOverride(
            id: UUID(),
            ruleID: ruleID,
            scope: scope,
            enabled: true,
            snoozedUntil: until,
            thresholds: [:]
        )
    }

    /// Drive the full pipeline: AuditEngine + aggregator, exactly the way
    /// AppState.runPostLoadAudit feeds UnifiedTasksView.
    private func aggregate(
        snapshot: FamilyGraphSnapshot,
        overrides: [AuditRuleOverride],
        now: Date = Date()
    ) -> [UnifiedTask] {
        let summary = AuditEngine.auditGrouped(
            snapshot,
            overrides: overrides,
            now: now
        )
        return UnifiedTaskAggregator.aggregate(
            snapshot: snapshot,
            auditSummary: summary,
            questions: [],
            lifeEvents: []
        )
    }

    // MARK: - Tests

    /// Snoozing a rule for one profile drops the matching audit-issue task
    /// from the aggregator's output.
    @Test func snoozedRuleNoLongerAppearsInTasksAggregator() {
        let p = makeProfile(id: "p1")
        let snap = snapshot([p])

        // Sanity — no overrides, the rule fires, so the audit task is present.
        let baseline = aggregate(snapshot: snap, overrides: [])
        let firedBefore = baseline.contains { task in
            if case .auditIssue(let r) = task,
               r.profileID == "p1", r.ruleID == "unsourcedBio" {
                return true
            }
            return false
        }
        #expect(firedBefore, "Baseline: missingBirthLocation should fire on p1")

        // Now snooze it for this person.
        let snooze = makeSnooze(
            ruleID: "unsourcedBio",
            scope: .profile(id: "p1")
        )
        let after = aggregate(snapshot: snap, overrides: [snooze])

        let firedAfter = after.contains { task in
            if case .auditIssue(let r) = task,
               r.profileID == "p1", r.ruleID == "unsourcedBio" {
                return true
            }
            return false
        }
        #expect(!firedAfter, "After snooze: missingBirthLocation must not surface for p1")
    }

    /// Global-scope snooze drops the rule across every profile.
    @Test func globalSnoozeRemovesAcrossAllProfiles() {
        let p1 = makeProfile(id: "p1", firstName: "Alice")
        let p2 = makeProfile(id: "p2", firstName: "Bob")
        let snap = snapshot([p1, p2])

        // Both profiles should fire baseline.
        let baseline = aggregate(snapshot: snap, overrides: [])
        let baselineHits = baseline.filter { task in
            if case .auditIssue(let r) = task, r.ruleID == "unsourcedBio" {
                return true
            }
            return false
        }
        #expect(baselineHits.count == 2, "Baseline: rule fires on both profiles")

        let snooze = makeSnooze(
            ruleID: "unsourcedBio",
            scope: .global
        )
        let after = aggregate(snapshot: snap, overrides: [snooze])
        let remaining = after.filter { task in
            if case .auditIssue(let r) = task, r.ruleID == "unsourcedBio" {
                return true
            }
            return false
        }
        #expect(remaining.isEmpty, "Global snooze should silence the rule on every profile")
    }

    /// An override whose `snoozedUntil` is in the past should let the rule
    /// fire again — the snooze has expired.
    @Test func expiredSnoozeReFiresInTasksAggregator() {
        let p = makeProfile(id: "p1")
        let snap = snapshot([p])

        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        let expired = AuditRuleOverride(
            id: UUID(),
            ruleID: "unsourcedBio",
            scope: .profile(id: "p1"),
            enabled: true,
            snoozedUntil: yesterday,
            thresholds: [:]
        )

        let after = aggregate(snapshot: snap, overrides: [expired], now: now)
        let fired = after.contains { task in
            if case .auditIssue(let r) = task,
               r.profileID == "p1", r.ruleID == "unsourcedBio" {
                return true
            }
            return false
        }
        #expect(fired, "An expired snooze must let the rule fire again")
    }

    /// Per-profile snooze on P1 leaves the same rule firing on P2 untouched.
    @Test func profileScopedSnoozeDoesNotAffectOtherProfiles() {
        let p1 = makeProfile(id: "p1", firstName: "Alice")
        let p2 = makeProfile(id: "p2", firstName: "Bob")
        let snap = snapshot([p1, p2])

        let snooze = makeSnooze(
            ruleID: "unsourcedBio",
            scope: .profile(id: "p1")
        )

        let after = aggregate(snapshot: snap, overrides: [snooze])

        let firedForP1 = after.contains { task in
            if case .auditIssue(let r) = task,
               r.profileID == "p1", r.ruleID == "unsourcedBio" {
                return true
            }
            return false
        }
        let firedForP2 = after.contains { task in
            if case .auditIssue(let r) = task,
               r.profileID == "p2", r.ruleID == "unsourcedBio" {
                return true
            }
            return false
        }
        #expect(!firedForP1, "P1 snooze should suppress the rule for P1")
        #expect(firedForP2, "P1 snooze must not silence the rule for P2")
    }
}
