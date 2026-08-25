import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// EV14 (owner dogfood 2026-08-25) — the member-side uniqueness check re-ran
/// `nameMatches` WITHOUT the role gate the target-side match had already
/// applied five lines earlier. A grandfather (Thomas, relation `.parent`) and
/// his grandson (Thomas, relation `.child`) therefore counted as rivals for
/// each other's roster row, `relativesForMember.count` reached 2, and the
/// guard bailed — neither generation got a proposal, from a household that
/// names them both unambiguously.
struct CensusAgeEnrichmentRoleUniquenessTests {

    private func profile(_ id: String, first: String, last: String) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func member(_ name: String, _ role: String, age: Int) -> HouseholdMember {
        HouseholdMember(name: name, relationship: role, age: age, birthYear: nil)
    }

    /// Grandfather on the Head row, grandson on the Son row, both called
    /// Thomas Land, both dateless. Each is a unique match once the role gate
    /// is honoured on BOTH sides.
    @Test func sameNamedRelativesInIncompatibleRolesEachMatchUniquely() {
        let senior = profile("thomas-sr", first: "Thomas", last: "Land")
        let junior = profile("thomas-jr", first: "Thomas", last: "Land")
        let household = [
            member("Thomas LAND", "Head", age: 60),
            member("Thomas LAND", "Son", age: 30),
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "subject", household: household, censusYear: 1861,
            linkedRelatives: [senior, junior], sourceID: "src-census",
            relations: ["thomas-sr": .parent, "thomas-jr": .child])

        #expect(proposals.count == 2,
                "a household that names both generations produced \(proposals.count) proposal(s)")
        let byTarget = Dictionary(uniqueKeysWithValues: proposals.map { ($0.targetProfileID, $0) })
        #expect(byTarget["thomas-sr"]?.estimatedBirthYear == 1801)
        #expect(byTarget["thomas-jr"]?.estimatedBirthYear == 1831)
        #expect(byTarget["thomas-sr"]?.relationshipLabel == "Head")
        #expect(byTarget["thomas-jr"]?.relationshipLabel == "Son")
    }

    /// With NO known relation the engine can't discriminate, and two same-named
    /// candidates must still be skipped — "when in doubt, split" is unchanged.
    @Test func withoutKnownRelationsSameNamedCandidatesAreStillSkipped() {
        let senior = profile("thomas-sr", first: "Thomas", last: "Land")
        let junior = profile("thomas-jr", first: "Thomas", last: "Land")
        let household = [
            member("Thomas LAND", "Head", age: 60),
            member("Thomas LAND", "Son", age: 30),
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "subject", household: household, censusYear: 1861,
            linkedRelatives: [senior, junior], sourceID: nil)
        #expect(proposals.isEmpty)
    }

    /// Two same-named relatives in the SAME generation stay ambiguous even
    /// with relations known — the role gate can't separate them, so neither
    /// gets a proposal.
    @Test func sameNamedRelativesInTheSameRoleStayAmbiguous() {
        let one = profile("thomas-a", first: "Thomas", last: "Land")
        let two = profile("thomas-b", first: "Thomas", last: "Land")
        let household = [member("Thomas LAND", "Son", age: 12)]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "subject", household: household, censusYear: 1861,
            linkedRelatives: [one, two], sourceID: nil,
            relations: ["thomas-a": .child, "thomas-b": .child])
        #expect(proposals.isEmpty)
    }

    /// One roster row, two same-named targets in incompatible generations: the
    /// row belongs to exactly one of them.
    @Test func oneRosterRowResolvesToTheGenerationItsRoleNames() {
        let senior = profile("thomas-sr", first: "Thomas", last: "Land")
        let junior = profile("thomas-jr", first: "Thomas", last: "Land")
        let household = [member("Thomas LAND", "Head", age: 60)]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "subject", household: household, censusYear: 1861,
            linkedRelatives: [senior, junior], sourceID: nil,
            relations: ["thomas-sr": .parent, "thomas-jr": .child])

        #expect(proposals.count == 1)
        #expect(proposals.first?.targetProfileID == "thomas-sr")
        #expect(proposals.first?.estimatedBirthYear == 1801)
    }
}
