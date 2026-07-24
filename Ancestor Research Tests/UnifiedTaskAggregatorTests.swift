import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the Unified Tasks aggregator. Pure-function tests — no view, no DB.
/// Since audit issues and completeness gaps moved to the Health tab, the
/// aggregator is the research worklist: open questions + tentative facts only.
/// The first two tests pin that split (no audit / no gap tasks).
struct UnifiedTaskAggregatorTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "p1",
        firstName: String? = "Jane",
        lastName: String? = "Doe",
        birthDate: String? = "1880",
        deathDate: String? = "1950",
        birthLocation: String? = "Wirksworth",
        deathLocation: String? = "Derby",
        bio: String? = "Sample bio.",
        sources: [ProfileField: [FieldSource]] = [:]
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
            sources: sources,
            disputes: [:]
        )
    }

    private func snapshot(_ profiles: [Profile], _ rels: [Relationship] = []) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: rels)
    }

    private func parentRel(_ from: String, _ to: String) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    /// Build a complete profile with a parent edge so completeness == max
    /// (no gap should be emitted).
    private func completeProfileWithParent() -> ([Profile], [Relationship]) {
        let parent = makeProfile(id: "parent")
        let child = makeProfile(id: "child")
        return ([parent, child], [parentRel("parent", "child")])
    }

    // MARK: - Audit + gaps moved to Health

    @Test func aggregateNoLongerProducesAuditTasks() {
        // Audit issues live on the Health tab now; the Tasks aggregator must not
        // re-add them, even when handed an audit summary.
        let (profiles, rels) = completeProfileWithParent()
        let r1 = AuditResult(
            profileID: "p1", profileName: "Subject A",
            severity: .error, ruleID: "rule.x", message: "Subject A — boom"
        )
        let summary = AuditSummary(errors: [r1], warnings: [], info: [], total: 1, profilesChecked: 2)

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot(profiles, rels),
            auditSummary: summary,
            questions: [],
            lifeEvents: []
        )
        #expect(tasks.allSatisfy { $0.category != .audit })
    }

    @Test func aggregateNoLongerProducesGapTasks() {
        // Completeness gaps are represented on Health via the gap-class audit
        // rules; the Tasks aggregator no longer emits per-profile .gap tasks.
        let p1 = makeProfile(id: "a", birthLocation: nil, deathLocation: nil, bio: nil)
        let p2 = makeProfile(id: "b", birthLocation: nil, deathLocation: nil, bio: nil)

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot([p1, p2]),
            auditSummary: nil,
            questions: [],
            lifeEvents: []
        )
        #expect(tasks.allSatisfy { $0.category != .gap })
    }

    // MARK: - Questions

    @Test func aggregateOnlyEmitsOpenQuestions() {
        let (profiles, rels) = completeProfileWithParent()
        let openQ = OpenQuestion(
            id: UUID(), text: "Open one", profileIDs: [],
            priority: .medium, status: .open,
            triedSources: nil, promotedFrom: nil,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        let resolvedQ = OpenQuestion(
            id: UUID(), text: "Resolved one", profileIDs: [],
            priority: .medium, status: .resolved,
            triedSources: nil, promotedFrom: nil,
            createdAt: Date(), resolvedAt: Date(), resolution: "done"
        )
        let blockedQ = OpenQuestion(
            id: UUID(), text: "Blocked one", profileIDs: [],
            priority: .medium, status: .blocked,
            triedSources: nil, promotedFrom: nil,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot(profiles, rels),
            auditSummary: nil,
            questions: [openQ, resolvedQ, blockedQ],
            lifeEvents: []
        )

        let questionTasks = tasks.filter { $0.category == .question }
        #expect(questionTasks.count == 1)
        if case .openQuestion(let q) = questionTasks.first {
            #expect(q.text == "Open one")
        } else {
            Issue.record("Expected openQuestion task")
        }
    }

    // MARK: - Tentative field tasks

    @Test func aggregateProducesTentativeFieldTasksForTentativeSources() {
        let tentativeSource = FieldSource(
            origin: .manualMemory, raw: "Maria",
            addedAt: Date(),
            citation: nil, quality: nil, confidence: .tentative
        )
        let standardSource = FieldSource(
            origin: .manualMemory, raw: "Maria",
            addedAt: Date(),
            citation: nil, quality: nil, confidence: .standard
        )

        let p = makeProfile(id: "x", sources: [
            .firstName: [tentativeSource, standardSource]
        ])

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot([p]),
            auditSummary: nil,
            questions: [],
            lifeEvents: []
        )

        let tentativeTasks = tasks.filter {
            if case .tentativeField = $0 { return true }
            return false
        }
        #expect(tentativeTasks.count == 1)
    }

    // MARK: - Tentative life events

    @Test func aggregateProducesTentativeLifeEventTasks() {
        let (profiles, rels) = completeProfileWithParent()
        let tentativeEvent = LifeEvent(
            id: UUID(), profileID: "child", type: .occupation,
            date: nil, endDate: nil,
            location: "Derby", description: "Framework knitter",
            sources: [], confidence: .tentative,
            createdByTransactionID: nil
        )
        let standardEvent = LifeEvent(
            id: UUID(), profileID: "child", type: .residence,
            date: nil, endDate: nil,
            location: "Wirksworth", description: nil,
            sources: [], confidence: .standard,
            createdByTransactionID: nil
        )

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot(profiles, rels),
            auditSummary: nil,
            questions: [],
            lifeEvents: [tentativeEvent, standardEvent]
        )

        let eventTasks = tasks.filter {
            if case .tentativeLifeEvent = $0 { return true }
            return false
        }
        #expect(eventTasks.count == 1)
    }

    // MARK: - Leads are NOT tasks (owner decision 2026-07-17)

    @Test func aggregatorHasNoLeadStream() {
        // Leads live only in Triage (Findings + Possible People). The
        // aggregator takes no leads input and TaskCategory has no lead case —
        // this pins the taxonomy so a regression re-adding lead rows to Tasks
        // fails here first.
        #expect(!TaskCategory.allCases.map(\.rawValue).contains("lead"))
        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot([]),
            auditSummary: nil,
            questions: [],
            lifeEvents: []
        )
        #expect(tasks.isEmpty)
    }

    @Test func gapTaskTargetProfileIDPointsAtOwningProfile() {
        let p = makeProfile(id: "pa", birthLocation: nil, deathLocation: nil, bio: nil)
        let comp = ProfileCompleteness(
            score: 4, maximum: 7,
            missing: [.field(.birthLocation), .field(.deathLocation), .field(.bio)],
            potentiallyLiving: false
        )
        let task = UnifiedTask.gap(profileID: "pa", profileName: "Jane Doe", completeness: comp)
        #expect(task.targetProfileID == "pa")
    }

    @Test func openQuestionWithoutProfilesYieldsNilTarget() {
        // A free-floating workbench question (no profileIDs) has no
        // navigation target — the row stays non-clickable rather than
        // jumping to an arbitrary profile.
        let q = OpenQuestion(
            id: UUID(), text: "General question", profileIDs: [],
            priority: .medium, status: .open,
            triedSources: nil, promotedFrom: nil,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        #expect(UnifiedTask.openQuestion(q).targetProfileID == nil)
    }

    @Test func openQuestionAttachedToProfilesTargetsFirstID() {
        let q = OpenQuestion(
            id: UUID(), text: "About Ernest", profileIDs: ["ernest", "kathleen"],
            priority: .high, status: .open,
            triedSources: nil, promotedFrom: nil,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        #expect(UnifiedTask.openQuestion(q).targetProfileID == "ernest")
    }

}
