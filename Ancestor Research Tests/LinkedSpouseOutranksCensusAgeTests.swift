import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// An existing tree edge outranks a transcribed census age.
///
/// Owner dogfood 2026-08-22. Jacob Holmes's 1817 baptism proved the 1861 census
/// understated his age by five years, so his birth year was corrected 1823 →
/// 1817. His WIFE's card then offered **"Add 1 family member: Jacob HOLMES —
/// head"** — the husband she was already married to. Six years apart against a
/// `yearTolerance` of 3, so the name+age match failed and he read as a stranger.
///
/// Making the tree more accurate made the app offer a duplicate. These pin the
/// fix and, just as importantly, pin the safety rule it must not break.
@MainActor
struct LinkedSpouseOutranksCensusAgeTests {

    private func member(_ name: String, _ relationship: String, age: Int,
                        sex: String) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age,
                        birthPlace: "Stanton Lees", sex: sex)
    }

    private func profile(_ id: String, _ first: String, _ last: String,
                         year: Int, gender: Gender) -> Profile {
        Profile(id: id, firstName: first, lastName: last, gender: gender,
                birthDate: GenealogicalDate.parsePreview(String(year)).parsed,
                isDeleted: false, sources: [:], disputes: [:])
    }

    /// Jacob as the tree now holds him — b. 1817, from his baptism.
    private var jacob: Profile { profile("jacob", "Jacob", "Holmes", year: 1817, gender: .male) }
    /// Jacob's row in the 1861 census — age 38, so an implied 1823.
    private var jacobRow: HouseholdMember { member("Jacob HOLMES", "Head", age: 38, sex: "M") }

    // MARK: - The specimen

    @Test func aLinkedSpouseMatchesDespiteASixYearAgeGap() throws {
        let match = CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: jacobRow, relation: .spouse,
            treeRelatives: [(jacob, .spouse)])
        #expect(match?.id == "jacob",
                "her husband must be recognised — the marriage edge outranks a census age")
    }

    /// Precondition: the ordinary name+year match really does fail here, so the
    /// test above is exercising the new rung and not something else.
    @Test func theOrdinaryYearMatchGenuinelyFails() {
        #expect(!CensusRelationshipReconciler.matches(
            member: jacobRow, profile: jacob, censusYear: 1861),
            "1823 vs 1817 is outside yearTolerance — this is why the bug existed")
    }

    /// A parent is a singleton role too — nobody has two fathers.
    @Test func aLinkedParentAlsoMatchesDespiteTheGap() {
        let father = profile("john", "John", "Holmes", year: 1790, gender: .male)
        let row = member("John HOLMES", "Father", age: 65, sex: "M")   // implies 1796
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: row, relation: .parent, treeRelatives: [(father, .parent)])?.id == "john")
    }

    /// Both parents linked: sex picks the right one rather than going ambiguous.
    @Test func sexDisambiguatesATwoParentRole() {
        let father = profile("john", "John", "Holmes", year: 1790, gender: .male)
        let mother = profile("sophia", "Sophia", "Holmes", year: 1792, gender: .female)
        let row = member("Sophia HOLMES", "Mother", age: 70, sex: "F")
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: row, relation: .parent,
            treeRelatives: [(father, .parent), (mother, .parent)])?.id == "sophia")
    }

    // MARK: - The safety rule this must NOT break

    /// Children and siblings are EXCLUDED. The rule this rung sits beside — "a
    /// name-agreeing relative whose year is wrong is a genuinely distinct
    /// person" — is true for children: families reused a dead child's name, and
    /// two Georges eleven years apart are two people.
    @Test func childrenAreExcludedBecauseFamiliesReusedNames() {
        let georgeOnTree = profile("g1", "George", "Holmes", year: 1889, gender: .male)
        let georgeOnRoster = member("George HOLMES", "Son", age: 4, sex: "M")   // implies 1857
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: georgeOnRoster, relation: .child,
            treeRelatives: [(georgeOnTree, .child)]) == nil,
            "a child with a wrong year must stay distinct — the dead-child-name pattern is real")
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: georgeOnRoster, relation: .sibling,
            treeRelatives: [(georgeOnTree, .sibling)]) == nil)
    }

    /// A DIFFERENT name in the same role is not the same person, whatever the
    /// role's cardinality.
    @Test func aDifferentNameNeverMatches() {
        let other = profile("x", "Thomas", "Holmes", year: 1817, gender: .male)
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: jacobRow, relation: .spouse, treeRelatives: [(other, .spouse)]) == nil)
    }

    /// Sex contradiction blocks it even with a matching name and role.
    @Test func sexContradictionBlocksTheMatch() {
        let wrongSex = profile("j", "Jacob", "Holmes", year: 1817, gender: .female)
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: jacobRow, relation: .spouse, treeRelatives: [(wrongSex, .spouse)]) == nil)
    }

    /// Two equally-qualifying linked relatives is ambiguous — refuse rather
    /// than guess. (Successive wives of the same forename; rare, but the rung
    /// must not pick one at random.)
    @Test func twoQualifyingCandidatesRefuseToMatch() {
        let first = profile("a", "Jacob", "Holmes", year: 1817, gender: .male)
        let second = profile("b", "Jacob", "Holmes", year: 1830, gender: .male)
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: jacobRow, relation: .spouse,
            treeRelatives: [(first, .spouse), (second, .spouse)]) == nil)
    }

    /// An UNLINKED profile is not reachable through this rung — it only ever
    /// considers relatives the tree already joins to the subject.
    @Test func onlyLinkedRelativesQualify() {
        #expect(CensusRelationshipReconciler.linkedSingletonRoleMatch(
            member: jacobRow, relation: .spouse, treeRelatives: []) == nil)
    }
}
