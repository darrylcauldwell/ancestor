import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the M12 Unified Tasks aggregator. Pure-function tests — no view,
/// no DB. Covers the four input streams (audit, gaps, questions, tentative
/// facts) and the priority sort order.
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

    // MARK: - Audit issues

    @Test func aggregateProducesAuditIssuesFromSummary() {
        let (profiles, rels) = completeProfileWithParent()
        let r1 = AuditResult(
            profileID: "p1", profileName: "Subject A",
            severity: .error, ruleID: "rule.x", message: "Subject A — boom"
        )
        let r2 = AuditResult(
            profileID: "p1", profileName: "Subject B",
            severity: .warning, ruleID: "rule.y", message: "Subject B — watch"
        )
        let summary = AuditSummary(errors: [r1], warnings: [r2], info: [], total: 2, profilesChecked: 2)

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot(profiles, rels),
            auditSummary: summary,
            questions: [],
            lifeEvents: []
        )

        let auditTasks = tasks.filter { $0.category == .audit }
        #expect(auditTasks.count == 2)
    }

    // MARK: - Gaps

    @Test func aggregateProducesGapsForIncompleteProfiles() {
        // Two incomplete profiles (no parents, no birthLocation, etc.) and
        // no audit / questions / events. Should emit two gap tasks.
        let p1 = makeProfile(id: "a", birthLocation: nil, deathLocation: nil, bio: nil)
        let p2 = makeProfile(id: "b", birthLocation: nil, deathLocation: nil, bio: nil)

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot([p1, p2]),
            auditSummary: nil,
            questions: [],
            lifeEvents: []
        )

        let gapTasks = tasks.filter { $0.category == .gap }
        #expect(gapTasks.count == 2)
    }

    @Test func aggregateSkipsCompleteProfiles() {
        // A profile that's fully complete + has a parent edge produces no gap.
        let (profiles, rels) = completeProfileWithParent()
        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot(profiles, rels),
            auditSummary: nil,
            questions: [],
            lifeEvents: []
        )
        // The parent has no parent edge of its own — that's still a gap.
        // The child has a parent edge and is otherwise complete → no gap.
        let gaps = tasks.filter { $0.category == .gap }
        #expect(gaps.contains { task in
            if case .gap(let pid, _, _) = task { return pid == "parent" }
            return false
        })
        #expect(!gaps.contains { task in
            if case .gap(let pid, _, _) = task { return pid == "child" }
            return false
        })
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

    // MARK: - Sort order

    @Test func aggregateSortsErrorsBeforeWarningsBeforeInfo() {
        let (profiles, rels) = completeProfileWithParent()
        let err = AuditResult(
            profileID: "p", profileName: "Errored",
            severity: .error, ruleID: "r1", message: "boom"
        )
        let warn = AuditResult(
            profileID: "p", profileName: "Warned",
            severity: .warning, ruleID: "r2", message: "watch"
        )
        let info = AuditResult(
            profileID: "p", profileName: "Inflated",
            severity: .info, ruleID: "r3", message: "fyi"
        )
        let summary = AuditSummary(
            errors: [err], warnings: [warn], info: [info],
            total: 3, profilesChecked: 2
        )

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot(profiles, rels),
            auditSummary: summary,
            questions: [],
            lifeEvents: []
        )

        // Find the indexes of the three audit tasks.
        let errIdx = tasks.firstIndex {
            if case .auditIssue(let r) = $0 { return r.severity == .error }
            return false
        }
        let warnIdx = tasks.firstIndex {
            if case .auditIssue(let r) = $0 { return r.severity == .warning }
            return false
        }
        let infoIdx = tasks.firstIndex {
            if case .auditIssue(let r) = $0 { return r.severity == .info }
            return false
        }
        #expect(errIdx != nil && warnIdx != nil && infoIdx != nil)
        #expect(errIdx! < warnIdx!)
        #expect(warnIdx! < infoIdx!)
    }

    // MARK: - Leads

    private func makeLead(
        id: String = "lead1",
        profileID: String = "p1",
        name: String = "Henry Cauldwell",
        status: LeadStatus = .new,
        source: LeadSource = .scoredLead,
        relationship: String? = "father",
        birthYear: Int? = 1860
    ) -> Lead {
        Lead(
            id: id, profileID: profileID,
            name: name,
            surname: name.split(separator: " ").last.map(String.init),
            givenName: name.split(separator: " ").first.map(String.init),
            birthYear: birthYear, deathYear: nil,
            relationship: relationship, source: source,
            status: status, evidence: "scored 0.8",
            createdAt: Date(), investigatedAt: nil,
            resolvedAt: nil, resolution: nil
        )
    }

    @Test func aggregateEmitsActiveLeads() {
        // .new, .investigating, .investigated all surface — they're things
        // the user can either act on (research / decide) or see in flight.
        let leads = [
            makeLead(id: "l-new", name: "New Lead", status: .new),
            makeLead(id: "l-flight", name: "Flight Lead", status: .investigating),
            makeLead(id: "l-done", name: "Done Lead", status: .investigated)
        ]

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot([]),
            auditSummary: nil,
            questions: [],
            lifeEvents: [],
            leads: leads
        )

        let leadTasks = tasks.filter { $0.category == .lead }
        #expect(leadTasks.count == 3)
    }

    @Test func aggregateSkipsTerminalLeads() {
        // Promoted and dismissed leads are resolved — never surface as tasks.
        let leads = [
            makeLead(id: "l-promoted", name: "Old Promoted", status: .promoted),
            makeLead(id: "l-dismissed", name: "Old Dismissed", status: .dismissed),
            makeLead(id: "l-new", name: "Current", status: .new)
        ]

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot([]),
            auditSummary: nil,
            questions: [],
            lifeEvents: [],
            leads: leads
        )

        let leadTasks = tasks.filter { $0.category == .lead }
        #expect(leadTasks.count == 1)
        if case .lead(let lead) = leadTasks.first {
            #expect(lead.id == "l-new")
        } else {
            Issue.record("Expected the single .new lead to survive the filter")
        }
    }

    @Test func aggregateRanksInvestigatedLeadsAboveNewLeads() {
        // .investigated needs the user's promote/dismiss decision — more
        // actionable than a .new lead which only needs research kicked off.
        let leads = [
            makeLead(id: "l-new", name: "Aaa New", status: .new),
            makeLead(id: "l-done", name: "Zzz Done", status: .investigated)
        ]

        let tasks = UnifiedTaskAggregator.aggregate(
            snapshot: snapshot([]),
            auditSummary: nil,
            questions: [],
            lifeEvents: [],
            leads: leads
        )

        let leadIdxs = tasks.enumerated().compactMap { idx, t -> (Int, String)? in
            if case .lead(let lead) = t { return (idx, lead.id) }
            return nil
        }
        let newIdx = leadIdxs.first(where: { $0.1 == "l-new" })?.0
        let doneIdx = leadIdxs.first(where: { $0.1 == "l-done" })?.0
        #expect(newIdx != nil && doneIdx != nil)
        #expect(doneIdx! < newIdx!,
                "investigated lead should sort above .new despite alphabetical disadvantage")
    }
}
