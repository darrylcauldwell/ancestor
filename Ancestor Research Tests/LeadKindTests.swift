import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the A/B lead classifier that lets the Possible People panel
/// separate namesake noise (identity candidates) from tree-growing discovery
/// leads (relatives to add).
struct LeadKindTests {

    private func lead(relationship: String?, source: LeadSource = .scoredLead,
                      name: String = "Test Person", birthYear: Int? = nil) -> Lead {
        Lead(
            id: "lead_\(UUID().uuidString)",
            profileID: "@P1@",
            name: name,
            surname: name.split(separator: " ").last.map(String.init),
            givenName: name.split(separator: " ").first.map(String.init),
            birthYear: birthYear,
            deathYear: nil,
            relationship: relationship,
            source: source,
            status: .new,
            evidence: "",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Category A: identity candidates (the namesake noise)

    @Test func scoredRecordWithNoRelationshipIsIdentityCandidate() {
        // The dominant path: scored-record leads reach the pool with relationship nil.
        #expect(LeadKind.classify(lead(relationship: nil)) == .identityCandidate)
    }

    @Test func unknownAndNonKinRelationshipsAreIdentityCandidates() {
        for r in ["unknown", "", "  ", "head", "boarder", "servant", "visitor", "nephew"] {
            #expect(LeadKind.classify(lead(relationship: r)) == .identityCandidate,
                    "\(r) should not be a kin role")
        }
    }

    // MARK: - Category B: relatives to add (the signal)

    @Test func inferredParentsAreRelativeParents() {
        // createFromParentInferredHypothesis stores "father"/"mother".
        #expect(LeadKind.classify(lead(relationship: "father")) == .relative(.parent))
        #expect(LeadKind.classify(lead(relationship: "mother")) == .relative(.parent))
    }

    @Test func censusRelationshipsMapToRoles() {
        // createFromHouseholdMember carries the census relationship verbatim.
        #expect(LeadKind.classify(lead(relationship: "son")) == .relative(.child))
        #expect(LeadKind.classify(lead(relationship: "daughter")) == .relative(.child))
        #expect(LeadKind.classify(lead(relationship: "wife")) == .relative(.spouse))
        #expect(LeadKind.classify(lead(relationship: "husband")) == .relative(.spouse))
        #expect(LeadKind.classify(lead(relationship: "brother")) == .relative(.sibling))
        #expect(LeadKind.classify(lead(relationship: "sister")) == .relative(.sibling))
    }

    @Test func relationshipMatchingIsCaseAndWhitespaceInsensitive() {
        #expect(LeadKind.classify(lead(relationship: " Father ")) == .relative(.parent))
        #expect(LeadKind.classify(lead(relationship: "SPOUSE")) == .relative(.spouse))
    }

    // MARK: - Cluster-level classification

    @Test func clusterOfNamesakesIsIdentityCandidate() {
        let namesakes = [lead(relationship: nil), lead(relationship: nil), lead(relationship: nil)]
        #expect(LeadKind.classify(namesakes) == .identityCandidate)
    }

    @Test func clusterOfInferredParentsIsRelativeParent() {
        let parents = [lead(relationship: "father"), lead(relationship: "father")]
        #expect(LeadKind.classify(parents) == .relative(.parent))
    }

    @Test func mixedClusterTakesTheMajorityRole() {
        let leads = [lead(relationship: "son"), lead(relationship: "son"), lead(relationship: "father")]
        #expect(LeadKind.classify(leads) == .relative(.child))
    }

    @Test func emptyClusterIsIdentityCandidate() {
        #expect(LeadKind.classify([Lead]()) == .identityCandidate)
    }

    // MARK: - RelativeRole presentation

    @Test func rolesSortClosestKinFirst() {
        let sorted = LeadKind.RelativeRole.allCases.sorted { $0.sortOrder < $1.sortOrder }
        #expect(sorted == [.parent, .spouse, .child, .sibling])
    }
}
