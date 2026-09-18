import Testing
import AncestorKit
@testable import Ancestor_Research

/// Health recategorisation #HR1 — the three-way category split is
/// load-bearing: `.research` findings are computed but NOT rendered in the
/// Health tab or the profile Health strip, so a miscategorised rule either
/// buries Health in research prompts again or silently hides a real defect.
/// This walks the whole registry so a NEW rule must declare its category
/// here deliberately.
struct AuditCategoryAssignmentTests {

    /// Person under-researched — research prompts, never shown in Health.
    private static let research: Set<String> = [
        "incompleteName", "completenessScore", "missingParents",
        "missingBirthDate", "missingDeathDate", "missingBirthLocation",
        "missingBio", "missingDeathLocation", "ancestorExtension",
        "fertilityGap",
    ]

    /// Evidence present but incompletely applied — stays in Health.
    /// (censusRelationship emits a per-finding `.gap` but its struct-level
    /// category is `.issue` so it still runs for placeholder profiles.)
    private static let gap: Set<String> = [
        "datelessReadsAsLiving", "unlinkedSpouseForFemaleSubject",
        // 2026-08-26: a census cited as the source of a field with no census
        // event behind it is evidence already in the project and only half
        // applied — the `.gap` definition, so it belongs in Health.
        // (`siblingIdentityCollision`, added the same day, is deliberately NOT
        // here: "these two may be one person" is a structural defect, `.issue`.)
        "citedCensusWithoutEvent",
    ]

    @Test func everyBuiltInRuleHasItsRuledCategory() {
        for rule in AuditRules.builtIn {
            let expected: AuditCategory =
                Self.research.contains(rule.id) ? .research
                : Self.gap.contains(rule.id) ? .gap
                : .issue
            #expect(rule.category == expected,
                    "\(rule.id): expected \(expected), got \(rule.category) — new/changed rules must be classified in AuditCategoryAssignmentTests")
        }
    }

    @Test func theResearchAndGapSetsNameRealRules() {
        let ids = Set(AuditRules.builtIn.map(\.id))
        for id in Self.research.union(Self.gap) {
            #expect(ids.contains(id), "\(id) is not a registered rule")
        }
    }

    /// The engine's placeholder de-noise skip must treat `.research` exactly
    /// as it treated `.gap` — a nameless placeholder is inherently
    /// incomplete, and "research me" framing there is misleading.
    @Test func placeholderProfilesGetNoGapOrResearchFindings() {
        let placeholder = Profile(
            id: "@GHOST@", externalIDs: [:],
            firstName: nil, lastName: "Gould", gender: nil,
            attributes: PersonAttributes(nameStatus: .placeholder, lifeStatus: .normal, privacy: .normal),
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
        let snapshot = FamilyGraphSnapshot(
            profiles: [placeholder.id: placeholder], relationships: [])
        let summary = AuditEngine.auditGrouped(snapshot)
        let all = summary.errors + summary.warnings + summary.info
        let nonIssue = all.filter {
            $0.profileID == placeholder.id && $0.category != .issue
        }
        #expect(nonIssue.isEmpty,
                "placeholders must produce no gap/research findings: \(nonIssue.map(\.ruleID))")
    }
}
