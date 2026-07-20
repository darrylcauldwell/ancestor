import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Census-roster birth-year enrichment: fill an EMPTY birth year on a relative
/// already linked to the subject, from that relative's age in the subject's
/// census household. Synthetic fixtures modelled on the real 1891 Cauldwell
/// household (Ernest, age 4, a Son of John + Elizabeth) — no real data.
struct CensusAgeEnrichmentTests {

    private func profile(_ id: String, first: String?, last: String?, birth: String? = nil) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) }, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func member(_ name: String, _ rel: String, age: Int? = nil,
                        birthYear: Int? = nil) -> HouseholdMember {
        HouseholdMember(name: name, relationship: rel, age: age, birthYear: birthYear)
    }

    /// The core case: John (Head, 30) and Elizabeth (Wife, 30) are linked
    /// parents with no birth year → both get a calculated ~1861.
    @Test func fillsEmptyBirthYearForLinkedParents() {
        let john = profile("john", first: "John", last: "Cauldwell")       // 1/6, no year
        let liz = profile("liz", first: "Elizabeth", last: "Cauldwell")    // 1/6, no year
        let household = [
            member("John CAULDWELL", "Head", age: 30),
            member("Elizabeth CAULDWELL", "Wife", age: 30),
            member("Ernest CAULDWELL", "Son", age: 4),
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [john, liz], sourceID: "src-census")

        #expect(proposals.count == 2)
        #expect(proposals.allSatisfy { $0.estimatedBirthYear == 1861 })
        #expect(Set(proposals.map(\.targetProfileID)) == ["john", "liz"])
        #expect(proposals.first?.sourceID == "src-census")
    }

    /// Never overwrite: a relative who already has a birth year is skipped.
    @Test func skipsRelativeThatAlreadyHasBirthYear() {
        let john = profile("john", first: "John", last: "Cauldwell", birth: "1860")
        let household = [member("John CAULDWELL", "Head", age: 30)]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [john], sourceID: nil)
        #expect(proposals.isEmpty)
    }

    /// A household member who is NOT a linked relative produces nothing here
    /// (that member is the DiscoveryExtractor "unlinked" path's job).
    @Test func ignoresUnlinkedHouseholdMembers() {
        let john = profile("john", first: "John", last: "Cauldwell")
        let household = [
            member("John CAULDWELL", "Head", age: 30),
            member("Martha BARKER", "Ma-Law", age: 66),   // not in linkedRelatives
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [john], sourceID: nil)
        #expect(proposals.count == 1)
        #expect(proposals.first?.targetProfileID == "john")
    }

    /// Ambiguity guard: two same-named gap relatives, one roster row → skip
    /// rather than guess which one it is.
    @Test func skipsWhenTwoRelativesShareTheName() {
        let johnSr = profile("john-sr", first: "John", last: "Cauldwell")
        let johnJr = profile("john-jr", first: "John", last: "Cauldwell")
        let household = [member("John CAULDWELL", "Head", age: 30)]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [johnSr, johnJr], sourceID: nil)
        #expect(proposals.isEmpty)
    }

    /// Ambiguity guard, member side: one relative, two roster rows that both
    /// match it ("John" head and "John Henry" son) → skip.
    @Test func skipsWhenTwoRosterRowsMatchOneRelative() {
        let john = profile("john", first: "John", last: "Cauldwell")
        let household = [
            member("John CAULDWELL", "Head", age: 30),
            member("John Henry CAULDWELL", "Son", age: 10),
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [john], sourceID: nil)
        #expect(proposals.isEmpty)
    }

    /// A stated birth year on the roster is preferred over age arithmetic.
    @Test func prefersStatedBirthYear() {
        let liz = profile("liz", first: "Elizabeth", last: "Cauldwell")
        let household = [member("Elizabeth CAULDWELL", "Wife", age: 30, birthYear: 1862)]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [liz], sourceID: nil)
        #expect(proposals.first?.estimatedBirthYear == 1862)
    }

    /// A non-family roster role (servant) never seeds a linked relative's year,
    /// even on a name collision.
    @Test func ignoresNonFamilyRoles() {
        let john = profile("john", first: "John", last: "Cauldwell")
        let household = [member("John SMITH", "Servant", age: 30)]  // name won't match anyway
        let household2 = [member("John CAULDWELL", "Boarder", age: 30)] // exact name, but boarder
        #expect(CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [john], sourceID: nil).isEmpty)
        #expect(CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household2, censusYear: 1891,
            linkedRelatives: [john], sourceID: nil).isEmpty)
    }

    /// Nonsense ages don't seed wild years.
    @Test func guardsAgainstNonsenseAges() {
        let john = profile("john", first: "John", last: "Cauldwell")
        let household = [member("John CAULDWELL", "Head", age: 0)]
        #expect(CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [john], sourceID: nil).isEmpty)
    }

    /// The subject themselves is never a target even if present in the list.
    @Test func neverTargetsTheSubject() {
        let ernest = profile("ernest", first: "Ernest", last: "Cauldwell")
        let household = [member("Ernest CAULDWELL", "Son", age: 4)]
        #expect(CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [ernest], sourceID: nil).isEmpty)
    }

    /// Role-aware tiebreak: two "John"s (father Head-30, son Son-10). Told the
    /// target is the subject's PARENT, the engine picks the Head row (1861),
    /// recovering a father the plain name guard would have skipped.
    @Test func roleAwareTiebreakRecoversParent() {
        let johnSr = profile("john-sr", first: "John", last: "Cauldwell")
        let household = [
            member("John CAULDWELL", "Head", age: 30),
            member("John Henry CAULDWELL", "Son", age: 10),
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [johnSr], sourceID: nil,
            relations: ["john-sr": .parent])
        #expect(proposals.count == 1)
        #expect(proposals.first?.estimatedBirthYear == 1861)
    }

    /// The same ambiguity, but the target is the subject's CHILD → the Son row
    /// (1881) wins instead.
    @Test func roleAwareTiebreakPicksChildRow() {
        let johnJr = profile("john-jr", first: "John", last: "Cauldwell")
        let household = [
            member("John CAULDWELL", "Head", age: 30),
            member("John Henry CAULDWELL", "Son", age: 10),
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "subject", household: household, censusYear: 1891,
            linkedRelatives: [johnJr], sourceID: nil,
            relations: ["john-jr": .child])
        #expect(proposals.first?.estimatedBirthYear == 1881)
    }

    /// Without a relation hint the two-John ambiguity is still skipped — the
    /// role tiebreak narrows, it never loosens the guard.
    @Test func noRelationHintStillSkipsAmbiguity() {
        let johnSr = profile("john-sr", first: "John", last: "Cauldwell")
        let household = [
            member("John CAULDWELL", "Head", age: 30),
            member("John Henry CAULDWELL", "Son", age: 10),
        ]
        #expect(CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [johnSr], sourceID: nil).isEmpty)
    }

    /// Given-name-only thin stub (no surname) still matches on the given name.
    @Test func matchesGivenNameOnlyStub() {
        let liz = profile("liz", first: "Elizabeth", last: nil)   // 1/6 stub, no surname
        let household = [member("Elizabeth CAULDWELL", "Wife", age: 30)]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "ernest", household: household, censusYear: 1891,
            linkedRelatives: [liz], sourceID: nil)
        #expect(proposals.first?.estimatedBirthYear == 1861)
    }
}
