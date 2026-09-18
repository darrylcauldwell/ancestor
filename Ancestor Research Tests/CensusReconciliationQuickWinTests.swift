import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV33 follow-up (review C5) — the quick-win registry must mirror EVERY
/// one-click the Health list's census-reconciliation panel renders, not only
/// the `.missing` "Add <relation>" button. The `.info` gap row fires for a
/// household with ZERO missing relatives — an unlinked-in-tree relative or a
/// parent-in-law lead is enough — and for those the panel renders "Link
/// <name>" / "Add <spouse>'s mother/father", both deterministic local
/// mutations. Before this fix such a row wore no ⚡ badge, sorted behind
/// judgement rows in its band, and was excluded from the ⚡ Quick-wins queue.
/// `.nearMatch`-only households stay OUT of the registry: "Same person" /
/// "Add separately" is a judgement about an unestablished identity (EV18).
@MainActor
struct CensusReconciliationQuickWinTests {

    // MARK: - Fixtures (pattern of CensusRelationshipReconcilerTests)

    private func person(_ id: String, _ first: String, _ last: String, birthYear: Int?) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last, gender: nil,
            attributes: PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: .normal),
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func member(_ name: String, _ relationship: String, age: Int?, isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age, isTarget: isTarget)
    }

    private func censusEvent(_ subjectID: String, year: Int, household: [HouseholdMember]) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: subjectID, type: .census,
            date: GenealogicalDate(parsing: String(year)),
            details: .census(CensusDetails(household: household)))
    }

    /// The `.info` gap row as the Health list would carry it for `profileID`.
    private func gapRow(_ profileID: String, name: String, severity: Severity = .info) -> AuditResult {
        AuditResult(profileID: profileID, profileName: name, severity: severity,
                    category: .gap, ruleID: "censusRelationship", message: "m")
    }

    private func isOneClick(_ r: AuditResult, _ snap: FamilyGraphSnapshot) -> Bool {
        HealthTriage.isOneClickFinding(r, snapshot: snap, hasDatabase: true)
    }

    // MARK: - The two under-counted one-clicks

    /// A household whose only actionable roster row is a relative already IN
    /// the tree but not linked — the panel renders one-click "Link <name>".
    @Test func unlinkedRelativeOnlyHouseholdIsAQuickWin() {
        let john = person("john", "John", "Wheeldon", birthYear: 1824)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let snap = FamilyGraphSnapshot(
            profiles: ["john": john, "mary": mary],
            relationships: [],       // Mary exists but is NOT linked to John
            lifeEvents: ["john": [censusEvent("john", year: 1861, household: [
                member("John Wheeldon", "Head", age: 37, isTarget: true),
                member("Mary Wheeldon", "Daughter", age: 5),
            ])]])

        // Premise: this household yields NO .missing finding, only an
        // unlinked-in-tree relative — the case the old predicate ignored.
        #expect(CensusRelationshipReconciler.findings(for: john, in: snap)
            .allSatisfy { $0.kind != .missing })
        #expect(!CensusRelationshipReconciler.unlinkedRelatives(for: john, in: snap).isEmpty)

        // The rule still surfaces the .info gap row for it…
        let rows = CensusRelationshipRule().evaluate(profile: john, snapshot: snap)
        #expect(rows.contains { $0.severity == .info && $0.category == .gap })

        // …and that row is a quick win: the panel renders "Link Mary Wheeldon".
        #expect(CensusRelationshipRule.hasOneClickReconciliation(for: john, in: snap))
        #expect(isOneClick(gapRow("john", name: "John Wheeldon"), snap))
    }

    /// A household whose only actionable roster row is the head's
    /// mother-in-law — the panel renders one-click "Add <spouse>'s mother".
    @Test func inLawLeadOnlyHouseholdIsAQuickWin() {
        let john = person("john", "John", "Wheeldon", birthYear: 1824)
        let ruth = person("ruth", "Ruth", "Hewkin", birthYear: 1826)
        let snap = FamilyGraphSnapshot(
            profiles: ["john": john, "ruth": ruth],
            relationships: [spouseEdge("john", "ruth")],
            lifeEvents: ["john": [censusEvent("john", year: 1861, household: [
                member("John Wheeldon", "Head", age: 37, isTarget: true),
                member("Sarah Hewkin", "Mother-in-law", age: 60),
            ])]])

        // Premise: no .missing finding and no unlinked relative — the in-law
        // lead alone carries the row (and its one-click).
        #expect(CensusRelationshipReconciler.findings(for: john, in: snap)
            .allSatisfy { $0.kind != .missing })
        #expect(CensusRelationshipReconciler.unlinkedRelatives(for: john, in: snap).isEmpty)
        #expect(!CensusRelationshipReconciler.inLawLeads(for: john, in: snap).isEmpty)

        let rows = CensusRelationshipRule().evaluate(profile: john, snapshot: snap)
        #expect(rows.contains { $0.severity == .info && $0.category == .gap })

        #expect(CensusRelationshipRule.hasOneClickReconciliation(for: john, in: snap))
        #expect(isOneClick(gapRow("john", name: "John Wheeldon"), snap))
    }

    // MARK: - What must NOT be counted

    /// A household whose only open row is a near-match stays OUT of the
    /// registry: its "Same person" / "Add separately" pair is deliberately
    /// non-prominent judgement (EV18), never a ⚡ clearance click.
    @Test func nearMatchOnlyHouseholdIsNotAQuickWin() {
        // EV18's live specimen: William Gladwin's 1871 schedule lists a son
        // "John H Gladwin" (b. ~1861) against the tree's "Thomas H Gladwin"
        // (b. 1861) — structural agreement, forename disagreement.
        let william = person("william", "William", "Gladwin", birthYear: 1831)
        let thomas = person("thomas", "Thomas H", "Gladwin", birthYear: 1861)
        let snap = FamilyGraphSnapshot(
            profiles: ["william": william, "thomas": thomas],
            relationships: [parentEdge("william", "thomas")],
            lifeEvents: ["william": [censusEvent("william", year: 1871, household: [
                member("William Gladwin", "Head", age: 40, isTarget: true),
                member("John H Gladwin", "Son", age: 10),
            ])]])

        // Premise: the near-match is the household's ONLY open row, and it
        // still surfaces the .info gap row (EV18)…
        #expect(!CensusRelationshipReconciler.nearMatchProposals(for: william, in: snap).isEmpty)
        #expect(CensusRelationshipReconciler.findings(for: william, in: snap)
            .allSatisfy { $0.kind != .missing })
        #expect(CensusRelationshipReconciler.unlinkedRelatives(for: william, in: snap).isEmpty)
        #expect(CensusRelationshipReconciler.inLawLeads(for: william, in: snap).isEmpty)
        let rows = CensusRelationshipRule().evaluate(profile: william, snapshot: snap)
        #expect(rows.contains { $0.severity == .info && $0.category == .gap })

        // …but that row is judgement, not a quick win.
        #expect(!CensusRelationshipRule.hasOneClickReconciliation(for: william, in: snap))
        #expect(!isOneClick(gapRow("william", name: "William Gladwin"), snap))
    }

    // MARK: - Existing behaviour retained

    /// A genuinely missing relative was a quick win before this fix and must
    /// remain one.
    @Test func missingRelativeHouseholdRemainsAQuickWin() {
        let john = person("john", "John", "Wheeldon", birthYear: 1824)
        let snap = FamilyGraphSnapshot(
            profiles: ["john": john],
            relationships: [],
            lifeEvents: ["john": [censusEvent("john", year: 1861, household: [
                member("John Wheeldon", "Head", age: 37, isTarget: true),
                member("Jane Wheeldon", "Daughter", age: 5),      // nowhere in the tree
            ])]])

        #expect(CensusRelationshipReconciler.findings(for: john, in: snap)
            .contains { $0.kind == .missing })
        #expect(CensusRelationshipRule.hasOneClickReconciliation(for: john, in: snap))
        #expect(isOneClick(gapRow("john", name: "John Wheeldon"), snap))

        // The registry's severity guard is unchanged: only the .info gap row
        // carries the panel — a .warning contradiction row never wears the ⚡.
        #expect(!isOneClick(gapRow("john", name: "John Wheeldon", severity: .warning), snap))
    }
}
