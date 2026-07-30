import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// FREEREG_INTEGRATION_SPEC §5 — the 1911 fertility-gap audit rule.
/// A married woman's 1911 statement (children born alive / living /
/// deceased, years married) vs the tree. Deliberately under-firing:
/// unknown-birth-year children count toward the tally; inconsistent
/// statements fire nothing; ambiguous marriages fire nothing.
struct FertilityGapRuleTests {

    // MARK: - Fixtures

    private func person(_ id: String, _ first: String, _ last: String, birthYear: Int?) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last, gender: nil,
            attributes: PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: .normal),
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String, subtype: RelationshipSubtype = .biological) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: subtype, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(_ a: String, _ b: String, marriageYear: Int? = nil) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown,
                     marriageDate: marriageYear.map { GenealogicalDate(parsing: String($0)) },
                     marriageLocation: nil, divorceDate: nil)
    }

    private func censusEvent(_ ownerID: String, year: Int = 1911, household: [HouseholdMember]) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: ownerID, type: .census,
            date: GenealogicalDate(parsing: String(year)),
            details: .census(CensusDetails(household: household)))
    }

    /// Harry (Head, b.1877) + Sarah (Wife, b.1879) — Sarah's fertility
    /// statement rides her roster row.
    private func household(born: Int?, living: Int?, died: Int?, yearsMarried: String? = nil) -> [HouseholdMember] {
        [
            HouseholdMember(name: "Harry Marshall", relationship: "Head", age: 34, sex: "M", isTarget: true),
            HouseholdMember(name: "Sarah Marshall", relationship: "Wife", age: 32, sex: "F",
                            yearsMarried: yearsMarried,
                            childrenBornAlive: born, childrenLiving: living, childrenDeceased: died),
        ]
    }

    /// Sarah + Harry + `childCount` dated children of theirs, with the 1911
    /// household on HARRY's profile (the roster usually lives on the
    /// searched person's event — the rule must find her row there).
    private func snapshot(
        household: [HouseholdMember],
        childYears: [Int?],
        marriageYear: Int? = nil,
        childSubtypes: [RelationshipSubtype]? = nil
    ) -> (FamilyGraphSnapshot, Profile) {
        let sarah = person("sarah", "Sarah", "Marshall", birthYear: 1879)
        let harry = person("harry", "Harry", "Marshall", birthYear: 1877)
        var profiles: [String: Profile] = ["sarah": sarah, "harry": harry]
        var relationships: [Relationship] = [spouseEdge("harry", "sarah", marriageYear: marriageYear)]
        for (i, year) in childYears.enumerated() {
            let id = "child\(i)"
            profiles[id] = person(id, "Child\(i)", "Marshall", birthYear: year)
            let subtype = childSubtypes?[i] ?? .biological
            relationships.append(parentEdge("sarah", id, subtype: subtype))
            relationships.append(parentEdge("harry", id, subtype: subtype))
        }
        let snapshot = FamilyGraphSnapshot(
            profiles: profiles,
            relationships: relationships,
            lifeEvents: ["harry": [censusEvent("harry", household: household)]])
        return (snapshot, sarah)
    }

    private let rule = FertilityGapRule()

    // MARK: - Shortfall detection

    @Test func firesOnShortfallViaHusbandsEvent() {
        let (snap, sarah) = snapshot(
            household: household(born: 5, living: 4, died: 1),
            childYears: [1900, 1903, 1906])
        let results = rule.evaluate(profile: sarah, snapshot: snap)
        #expect(results.count == 1)
        let message = results.first?.message ?? ""
        #expect(message.contains("5 children born alive"))
        #expect(message.contains("2 unaccounted"))
        #expect(message.contains("1 who died young"), "the deceased count is the research hook")
        #expect(results.first?.severity == .info)
        #expect(results.first?.category == .gap)
    }

    @Test func completeTreeIsSilent() {
        let (snap, sarah) = snapshot(
            household: household(born: 3, living: 3, died: 0),
            childYears: [1900, 1903, 1906])
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty)
    }

    @Test func unknownYearChildCountsTowardTheTally() {
        // 4 stated; 3 dated + 1 unknown-year child = tally 4 → under-fire.
        let (snap, sarah) = snapshot(
            household: household(born: 4, living: 4, died: 0),
            childYears: [1900, 1903, 1906, nil])
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty,
                "an unknown-birth-year child must count as accounted-for")
    }

    @Test func post1911ChildDoesNotCount() {
        // 3 stated; 2 pre-1911 children + 1 born 1913 → tally 2 → fires.
        let (snap, sarah) = snapshot(
            household: household(born: 3, living: 3, died: 0),
            childYears: [1900, 1903, 1913])
        let results = rule.evaluate(profile: sarah, snapshot: snap)
        #expect(results.first?.message.contains("1 unaccounted") == true)
    }

    @Test func stepChildrenDoNotMaskAShortfall() {
        // 2 stated born alive; tree: 1 biological + 1 step → tally 1 → fires.
        let (snap, sarah) = snapshot(
            household: household(born: 2, living: 2, died: 0),
            childYears: [1900, 1904],
            childSubtypes: [.biological, .step])
        let results = rule.evaluate(profile: sarah, snapshot: snap)
        #expect(results.first?.message.contains("1 unaccounted") == true,
                "a step-child is not a child she bore")
    }

    // MARK: - Consistency + corroboration guards

    @Test func inconsistentStatementIsSilent() {
        // 5 born but 4 living + 2 died = 6 — transcription doubt → nothing.
        let (snap, sarah) = snapshot(
            household: household(born: 5, living: 4, died: 2),
            childYears: [1900])
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty)
    }

    @Test func scotlandShapeWithoutDeceasedStillFires() {
        // Scotland/Ireland 1911 omit the deceased column: born ≥ living OK.
        let (snap, sarah) = snapshot(
            household: household(born: 5, living: 4, died: nil),
            childYears: [1900, 1903, 1906])
        let results = rule.evaluate(profile: sarah, snapshot: snap)
        #expect(results.first?.message.contains("2 unaccounted") == true)
        #expect(results.first?.message.contains("died young") == false,
                "no deceased figure → no died-young clause")
    }

    @Test func noFertilityDataIsSilent() {
        let (snap, sarah) = snapshot(
            household: household(born: nil, living: nil, died: nil),
            childYears: [])
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty)
    }

    @Test func wrongWomanRowIsRejectedByYearCorroboration() {
        // Roster "Sarah Marshall" aged 52 (b.~1859) vs profile b.1879 —
        // a namesake, not her → no statement, no finding.
        var members = household(born: 6, living: 5, died: 1)
        members[1] = HouseholdMember(
            name: "Sarah Marshall", relationship: "Wife", age: 52, sex: "F",
            childrenBornAlive: 6, childrenLiving: 5, childrenDeceased: 1)
        let (snap, sarah) = snapshot(household: members, childYears: [])
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty)
    }

    // MARK: - yearsMarried cross-check

    @Test func impliedMarriageYearMismatchFires() {
        // 18 years married → implied ~1893; tree records 1898 (Δ5 > 2).
        let (snap, sarah) = snapshot(
            household: household(born: 1, living: 1, died: 0, yearsMarried: "18"),
            childYears: [1900],
            marriageYear: 1898)
        let results = rule.evaluate(profile: sarah, snapshot: snap)
        #expect(results.count == 1, "tree is complete → only the marriage finding")
        #expect(results.first?.message.contains("implies marriage ~1893") == true)
        #expect(results.first?.message.contains("1898") == true)
    }

    @Test func impliedMarriageYearWithinToleranceIsSilent() {
        let (snap, sarah) = snapshot(
            household: household(born: 1, living: 1, died: 0, yearsMarried: "13"),
            childYears: [1900],
            marriageYear: 1899)   // implied 1898, Δ1 ≤ 2
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty)
    }

    @Test func undatedMarriageIsSilentOnTheCrossCheck() {
        let (snap, sarah) = snapshot(
            household: household(born: 1, living: 1, died: 0, yearsMarried: "18"),
            childYears: [1900],
            marriageYear: nil)
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty,
                "no recorded marriage date → nothing to contradict")
    }

    @Test func nonNumericYearsMarriedIsSilentOnTheCrossCheck() {
        let (snap, sarah) = snapshot(
            household: household(born: 1, living: 1, died: 0, yearsMarried: "abt 18"),
            childYears: [1900],
            marriageYear: 1880)
        #expect(rule.evaluate(profile: sarah, snapshot: snap).isEmpty)
    }

    // MARK: - Registration

    @Test func ruleIsRegistered() {
        #expect(AuditRules.builtIn.contains { $0.id == "fertilityGap" })
    }
}
