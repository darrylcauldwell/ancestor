import Testing
import Foundation
@testable import Ancestor_Research

/// M16.10 — tests for the "group by profile" toggle. Drives the pure helper
/// `UnifiedTaskGrouping.groupedByProfile` so we don't need a SwiftUI host.
struct UnifiedTaskGroupingTests {

    // MARK: - Helpers

    private func auditTask(_ profileName: String, severity: Severity, message: String = "audit issue") -> UnifiedTask {
        let r = AuditResult(
            profileID: "id-\(profileName)",
            profileName: profileName,
            severity: severity,
            ruleID: "test.rule",
            message: message
        )
        return .auditIssue(r)
    }

    private func gapTask(_ profileName: String) -> UnifiedTask {
        let comp = ProfileCompleteness(score: 1, maximum: 4, missing: [.field(.firstName)], potentiallyLiving: false)
        return .gap(profileID: "id-\(profileName)", profileName: profileName, completeness: comp)
    }

    private func questionTask(_ profileName: String, priority: QuestionPriority) -> UnifiedTask {
        let q = OpenQuestion(
            id: UUID(),
            text: "\(profileName) question",
            profileIDs: [profileName],
            priority: priority,
            status: .open,
            triedSources: nil,
            promotedFrom: nil,
            createdAt: Date(),
            resolvedAt: nil,
            resolution: nil
        )
        return .openQuestion(q)
    }

    // MARK: - Bucketing across origin types

    @Test func tasksGroupByProfileBucketsAcrossOriginTypes() {
        // Mixed task types for the same person should land in one section.
        let tasks: [UnifiedTask] = [
            auditTask("Alice", severity: .warning),
            gapTask("Alice"),
            auditTask("Bob", severity: .error),
        ]

        let groups = UnifiedTaskGrouping.groupedByProfile(tasks)
        let names = groups.map(\.profileName)
        #expect(Set(names) == ["Alice", "Bob"])

        let alice = groups.first { $0.profileName == "Alice" }
        #expect(alice?.tasks.count == 2)

        let bob = groups.first { $0.profileName == "Bob" }
        #expect(bob?.tasks.count == 1)
    }

    // MARK: - Section ordering

    @Test func tasksGroupByProfileSortsSectionsBySeverity() {
        // Bob has an audit error (sortKey 0) so his section must come first
        // even though Alice precedes Bob alphabetically. Carol carries an
        // info-level audit (sortKey 9 — least severe) so she comes last.
        // We use audit tasks for everything because the openQuestion task's
        // profileName is "Question" (not the profile name) by design — the
        // grouping logic respects that explicitly.
        let tasks: [UnifiedTask] = [
            gapTask("Alice"),                     // sortKey 3 or 4
            auditTask("Bob", severity: .error),   // sortKey 0 — most severe
            auditTask("Carol", severity: .info),  // sortKey 9 — least severe
        ]

        let groups = UnifiedTaskGrouping.groupedByProfile(tasks)
        let names = groups.map(\.profileName)
        #expect(names == ["Bob", "Alice", "Carol"])
    }

    // MARK: - Total count preservation

    @Test func tasksGroupByProfilePreservesAllTasks() {
        let tasks: [UnifiedTask] = [
            auditTask("Alice", severity: .warning),
            gapTask("Alice"),
            auditTask("Bob", severity: .error),
            questionTask("Bob", priority: .high),
            questionTask("Carol", priority: .medium),
        ]

        let groups = UnifiedTaskGrouping.groupedByProfile(tasks)
        let totalGrouped = groups.reduce(0) { $0 + $1.tasks.count }
        #expect(totalGrouped == tasks.count)
    }

    // MARK: - Distinct names stay distinct

    @Test func tasksGroupByProfileDoesNotFuzzyMatch() {
        // "Alice Smith" and "Alice  Smith" (double space) are different
        // strings — they must not be merged.
        let aliceA: UnifiedTask = auditTask("Alice Smith", severity: .info)
        let aliceB: UnifiedTask = auditTask("Alice  Smith", severity: .info)

        let groups = UnifiedTaskGrouping.groupedByProfile([aliceA, aliceB])
        #expect(groups.count == 2)
    }

    // MARK: - Identity grouping (leads-rework tail a/b)

    private func auditFor(id: String, name: String, severity: Severity = .warning) -> UnifiedTask {
        .auditIssue(AuditResult(
            profileID: id, profileName: name, severity: severity,
            ruleID: "test.rule", message: "\(name)"))
    }

    /// The identity win: the SAME profile whose findings carry slightly
    /// different display-name strings still collapses into ONE section (old
    /// exact-profileName grouping would have split it).
    @Test func sameProfileGroupsAcrossDisplayNameVariation() {
        let tasks = [
            auditFor(id: "@P1@", name: "George Cauldwell"),
            auditFor(id: "@P1@", name: "George  Cauldwell"),   // stray double space
            auditFor(id: "@P1@", name: "George Cauldwell"),
        ]
        let groups = UnifiedTaskGrouping.groupedByProfile(tasks)
        #expect(groups.count == 1, "one person, one section — regardless of name-string wobble")
        #expect(groups.first?.tasks.count == 3)
        #expect(groups.first?.id == "@P1@")
    }

    /// Two DISTINCT people who share a display name stay in separate sections
    /// (and get distinct SwiftUI ids) — the correctness the identity key buys.
    @Test func distinctSameNamedProfilesDoNotMerge() {
        let tasks = [
            auditFor(id: "@P1@", name: "John Smith"),
            auditFor(id: "@P2@", name: "John Smith"),
        ]
        let groups = UnifiedTaskGrouping.groupedByProfile(tasks)
        #expect(groups.count == 2, "same name, different people → two sections")
        #expect(Set(groups.map(\.id)) == ["@P1@", "@P2@"])
    }
}
