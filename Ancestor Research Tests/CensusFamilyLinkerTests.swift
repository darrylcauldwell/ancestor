import Testing
import Foundation
import AncestorKit

/// CensusFamilyLinker: mine a census household roster into proposed family
/// links, relative to the subject, excluding the dwelling's non-family
/// co-residents. A census is a record of a dwelling, not a family, so the
/// linker must never offer a boarder/lodger/servant as a relative, and must
/// resolve roles relative to the subject's own household role — not the Head's.
struct CensusFamilyLinkerTests {

    private func member(_ name: String, _ relationship: String,
                        age: Int? = nil, isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age, isTarget: isTarget)
    }

    private func relation(_ links: [CensusFamilyLinker.Link], _ name: String) -> CensusRelation? {
        links.first { $0.member.name == name }?.relation
    }

    // MARK: - The real William-in-1891 case (subject is a child)

    @Test func childSubjectGetsParentsAndSiblings() {
        // William, age 9, Son of John (Head) + Elizabeth (Wife); brothers
        // John Henry, Robert, Ernest. Plus a boarder who must NOT be linked.
        let roster = [
            member("John CAULDWELL", "Head", age: 30),
            member("Elizabeth CAULDWELL", "Wife", age: 30),
            member("John Henry CAULDWELL", "Son", age: 10),
            member("William CAULDWELL", "Son", age: 9, isTarget: true),
            member("Robert CAULDWELL", "Son", age: 6),
            member("Ernest CAULDWELL", "Son", age: 4),
            member("Thomas BROWN", "Boarder", age: 25),
        ]
        let links = CensusFamilyLinker.familyLinks(household: roster)

        #expect(relation(links, "John CAULDWELL") == .parent)
        #expect(relation(links, "Elizabeth CAULDWELL") == .parent)
        #expect(relation(links, "John Henry CAULDWELL") == .sibling)
        #expect(relation(links, "Robert CAULDWELL") == .sibling)
        #expect(relation(links, "Ernest CAULDWELL") == .sibling)
        #expect(relation(links, "Thomas BROWN") == nil, "a boarder is never a relative")
        #expect(links.first { $0.member.isTarget == true } == nil, "the subject's own row is excluded")
        #expect(links.count == 5)
    }

    // MARK: - Subject is the Head

    @Test func headSubjectGetsSpouseAndChildren() {
        let roster = [
            member("William HOLMES", "Head", age: 40, isTarget: true),
            member("Mary Ellen HOLMES", "Wife", age: 38),
            member("Reginald HOLMES", "Son", age: 5),
            member("Ada SMITH", "Servant", age: 19),
        ]
        let links = CensusFamilyLinker.familyLinks(household: roster)
        #expect(relation(links, "Mary Ellen HOLMES") == .spouse)
        #expect(relation(links, "Reginald HOLMES") == .child)
        #expect(relation(links, "Ada SMITH") == nil, "a servant is never a relative")
        #expect(links.count == 2)
    }

    // MARK: - Safety: non-family and ambiguous kin excluded

    @Test func allNonFamilyRolesExcluded() {
        let roster = [
            member("Head Person", "Head", isTarget: true),
            member("A", "Boarder"), member("B", "Lodger"), member("C", "Visitor"),
            member("D", "Servant"), member("E", "Nurse"), member("F", "Apprentice"),
        ]
        #expect(CensusFamilyLinker.familyLinks(household: roster).isEmpty)
    }

    @Test func ambiguousKinNotAutoClassified() {
        // Subject is the Head; none of these should auto-link.
        let roster = [
            member("Head Person", "Head", isTarget: true),
            member("G", "Grandson"),            // grand- → skip
            member("H", "Son-in-law"),          // in-law → skip
            member("I", "Stepdaughter"),        // step- → skip
            member("J", "Mother-in-law"),       // in-law → skip
            member("K", "Wife's sister"),       // possessive → skip
        ]
        #expect(CensusFamilyLinker.familyLinks(household: roster).isEmpty)
    }

    // MARK: - A spouse subject skips the Head's blood kin (they're in-laws)

    @Test func spouseSubjectSkipsHeadsKin() {
        let roster = [
            member("William HOLMES", "Head", age: 40),
            member("Mary Ellen HOLMES", "Wife", age: 38, isTarget: true),
            member("Reginald HOLMES", "Son", age: 5),
            member("Old HOLMES", "Mother", age: 68),   // Head's mother = subject's mother-in-law
        ]
        let links = CensusFamilyLinker.familyLinks(household: roster)
        #expect(relation(links, "William HOLMES") == .spouse)
        #expect(relation(links, "Reginald HOLMES") == .child)
        #expect(relation(links, "Old HOLMES") == nil, "the head's mother is the subject's in-law, not her parent")
        #expect(links.count == 2)
    }

    // MARK: - Anchoring guards

    @Test func noTargetRowReturnsEmpty() {
        let roster = [
            member("John CAULDWELL", "Head"),
            member("Elizabeth CAULDWELL", "Wife"),
        ]
        #expect(CensusFamilyLinker.familyLinks(household: roster).isEmpty,
                "without a marked subject row there's no anchor for relative roles")
    }

    @Test func twoTargetRowsReturnEmpty() {
        let roster = [
            member("A", "Head", isTarget: true),
            member("B", "Wife", isTarget: true),
        ]
        #expect(CensusFamilyLinker.familyLinks(household: roster).isEmpty)
    }

    @Test func namelessFamilyRowSkipped() {
        let roster = [
            member("John CAULDWELL", "Head", isTarget: true),
            member("   ", "Son"),               // no name → can't create a profile
            member("Real Child", "Daughter"),
        ]
        let links = CensusFamilyLinker.familyLinks(household: roster)
        #expect(links.count == 1)
        #expect(relation(links, "Real Child") == .child)
    }
}
