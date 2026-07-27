import Testing
import Foundation
import AncestorKit

/// The census-relationship reconciliation engine (`CensusRelationshipReconciler`)
/// and its audit rule (`CensusRelationshipRule`). A census records
/// relationship-to-Head; the engine turns a household into the members'
/// relations to the subject (via `CensusFamilyLinker`) and diffs them against
/// the subject's tree relatives → `.missing` / `.contradiction`. The
/// contradiction case is the real one that bit us: the 1861 census showed
/// Samuel and Mary Wheeldon as siblings while the tree recorded Samuel as
/// Mary's father (2026-07-27).
struct CensusRelationshipReconcilerTests {

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

    /// A census life-event on `subjectID` carrying `household`.
    private func censusEvent(_ subjectID: String, year: Int, household: [HouseholdMember]) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: subjectID, type: .census,
            date: GenealogicalDate(parsing: String(year)),
            details: .census(CensusDetails(household: household)))
    }

    /// The Wheeldon 1861 household as it sits on Samuel's census: John (Head) +
    /// Ruth (Wife) as his parents, Samuel (Son, the subject) and Mary (Dau) as
    /// children → census makes John/Ruth Samuel's parents and Mary his sibling.
    private func wheeldonHousehold() -> [HouseholdMember] {
        [member("John Wheeldon", "Head", age: 37),
         member("Ruth Wheeldon", "Wife", age: 37),
         member("Samuel Wheeldon", "Son", age: 8, isTarget: true),
         member("Mary Wheeldon", "Daughter", age: 5)]
    }

    // MARK: - Tests

    /// The tree records Samuel as Mary's FATHER while the census makes them
    /// siblings → one `.contradiction` (census sibling vs tree child).
    @Test func detectsParentChildVsCensusSiblingContradiction() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary],
            relationships: [parentEdge("samuel", "mary")],       // tree: Samuel is Mary's father
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let findings = CensusRelationshipReconciler.findings(for: samuel, in: snapshot)
        let contradictions = findings.filter { $0.kind == .contradiction }
        #expect(contradictions.count == 1)
        let c = try! #require(contradictions.first)
        #expect(c.member.name == "Mary Wheeldon")
        #expect(c.censusRelation == .sibling)     // census: Mary is Samuel's sibling
        #expect(c.treeRelation == .child)         // tree: Mary is Samuel's child
        #expect(c.treeRelativeID == "mary")
    }

    /// When the tree already has Samuel and Mary as siblings (shared parent),
    /// the census agrees → NO contradiction.
    @Test func consistentSiblingProducesNoContradiction() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let dad = person("dad", "John", "Wheeldon", birthYear: 1824)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary, "dad": dad],
            relationships: [parentEdge("dad", "samuel"), parentEdge("dad", "mary")],  // siblings
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let contradictions = CensusRelationshipReconciler.findings(for: samuel, in: snapshot)
            .filter { $0.kind == .contradiction }
        #expect(contradictions.isEmpty)
    }

    /// A census relative absent from the tree is reported as `.missing`
    /// (John/Ruth here are not in the tree).
    @Test func reportsCensusRelativesMissingFromTree() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary],
            relationships: [parentEdge("samuel", "mary")],
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let missing = CensusRelationshipReconciler.findings(for: samuel, in: snapshot)
            .filter { $0.kind == .missing }
        // John (Head) and Ruth (Wife) → the subject's parents, neither in the tree.
        #expect(missing.contains { $0.member.name == "John Wheeldon" && $0.censusRelation == .parent })
        #expect(missing.contains { $0.member.name == "Ruth Wheeldon" && $0.censusRelation == .parent })
    }

    /// Non-family co-residents (servant, lodger) and out-of-scope kin
    /// (grandchild) are excluded by `CensusFamilyLinker` → never a finding.
    @Test func excludesNonFamilyAndOutOfScopeRoles() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        var household = wheeldonHousehold()
        household.append(member("Jane Smith", "Servant", age: 20))
        household.append(member("Tom Brown", "Lodger", age: 40))
        household.append(member("Baby Wheeldon", "Grandson", age: 1))
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel],
            relationships: [],
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: household)]])

        let names = Set(CensusRelationshipReconciler.findings(for: samuel, in: snapshot).map { $0.member.name })
        #expect(!names.contains("Jane Smith"))
        #expect(!names.contains("Tom Brown"))
        #expect(!names.contains("Baby Wheeldon"))
    }

    /// The audit rule surfaces the contradiction as a single `.warning`.
    @Test func ruleSurfacesContradictionAsWarning() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary],
            relationships: [parentEdge("samuel", "mary")],
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let results = CensusRelationshipRule().evaluate(profile: samuel, snapshot: snapshot)
        // A contradiction warning (Mary) plus a missing-summary info (John + Ruth).
        let warning = try! #require(results.first { $0.severity == .warning })
        #expect(warning.ruleID == "censusRelationship")
        #expect(warning.relatedProfileIDs == ["mary"])
        #expect(warning.message.contains("sibling") && warning.message.contains("child"))
        #expect(results.contains { $0.severity == .info && $0.category == .gap && $0.message.contains("not in the tree") })
    }

    /// A household attached to a subject but whose `isTarget` row is SOMEONE
    /// ELSE (a shared household / stale target) must produce NO findings — else
    /// the relations are computed in the wrong reference frame. Here the census
    /// sits on John (the Head, b.1861) but flags his son Ernest as the target;
    /// without the anchor guard this yielded phantom contradictions (Elizabeth
    /// read as John's parent, the sons as his siblings). Live repro 2026-07-27.
    @Test func misAnchoredHouseholdProducesNoFindings() {
        let john = person("john", "John", "Cauldwell", birthYear: 1861)       // the Head
        let eliza = person("eliza", "Elizabeth", "Cauldwell", birthYear: 1861)
        let ernest = person("ernest", "Ernest", "Cauldwell", birthYear: 1887)
        let household = [
            member("John Cauldwell", "Head", age: 30),                        // John's own row — NOT flagged
            member("Elizabeth Cauldwell", "Wife", age: 30),
            member("Ernest Cauldwell", "Son", age: 4, isTarget: true)]        // wrong anchor: a son
        let snapshot = FamilyGraphSnapshot(
            profiles: ["john": john, "eliza": eliza, "ernest": ernest],
            relationships: [spouseEdge("john", "eliza"), parentEdge("john", "ernest")], // correct Head family
            lifeEvents: ["john": [censusEvent("john", year: 1891, household: household)]])

        // isTarget row ("Ernest", age 4 → 1887) does not match John (1861) → skip.
        #expect(CensusRelationshipReconciler.findings(for: john, in: snapshot).isEmpty)
    }

    /// A census sibling and a tree child that merely SHARE A NAME (different
    /// people, decades apart) must NOT be matched — so no phantom contradiction.
    /// Ernest's census sibling George (b.1889) vs Ernest's son George (b.1915).
    /// Live repro 2026-07-27 (name-only matching paired the two Georges).
    @Test func namesakeWithDivergentYearIsNotAContradiction() {
        let ernest = person("ernest", "Ernest", "Cauldwell", birthYear: 1886)
        let georgeSon = person("georgeSon", "George", "Cauldwell", birthYear: 1915)  // Ernest's real son
        let household = [
            member("John Cauldwell", "Head", age: 30),
            member("Ernest Cauldwell", "Son", age: 5, isTarget: true),        // b.1886
            member("George Cauldwell", "Son", age: 2)]                        // census sibling, b.1889
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ernest": ernest, "georgeSon": georgeSon],
            relationships: [parentEdge("ernest", "georgeSon")],               // Ernest is George(1915)'s father
            lifeEvents: ["ernest": [censusEvent("ernest", year: 1891, household: household)]])

        let findings = CensusRelationshipReconciler.findings(for: ernest, in: snapshot)
        // The b.1889 census-sibling George must NOT match the b.1915 son George.
        #expect(findings.allSatisfy { $0.kind != .contradiction })
        // It should instead be reported as a missing sibling.
        #expect(findings.contains { $0.kind == .missing && $0.member.name == "George Cauldwell" && $0.censusRelation == .sibling })
    }
}
