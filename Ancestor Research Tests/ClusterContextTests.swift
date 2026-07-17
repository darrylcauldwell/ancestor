import Testing
import Foundation
@testable import Ancestor_Research

/// POSSIBLE_PEOPLE_CONTEXT_SPEC — ties a cluster back to the tree people whose
/// research surfaced it, and the conservative namesake flag.
struct ClusterContextTests {

    private func makeLead(id: String, profileID: String, surname: String = "Ward",
                          given: String? = "George", birthYear: Int? = 1900) -> Lead {
        Lead(id: id, profileID: profileID,
             name: [given, surname].compactMap { $0 }.joined(separator: " "),
             surname: surname, givenName: given, birthYear: birthYear, deathYear: nil,
             relationship: nil, source: .scoredLead, status: .new,
             evidence: "", createdAt: Date(timeIntervalSince1970: 0))
    }

    private func cluster(_ leads: [Lead]) -> LeadDiscoveryEngine.EmergentCluster {
        let cs = LeadDiscoveryEngine.discover(leads: leads)
        precondition(cs.count == 1)
        return cs[0]
    }

    private func profile(_ id: String, name: String, birth: Int?, death: Int?) -> Profile {
        Profile(
            id: id, firstName: name, lastName: "Origin",
            birthDate: birth.map { GenealogicalDate(parsing: String($0)) },
            deathDate: death.map { GenealogicalDate(parsing: String($0)) },
            isDeleted: false, sources: [:], disputes: [:]
        )
    }

    @Test func originsResolveDistinctDatedProfiles() {
        let leads = [
            makeLead(id: "1", profileID: "ernest"),
            makeLead(id: "2", profileID: "ernest"),   // same origin, deduped
            makeLead(id: "3", profileID: "mabel"),     // second origin
            makeLead(id: "4", profileID: "ghost"),     // not in snapshot → skipped
        ]
        let profiles = [
            "ernest": profile("ernest", name: "Ernest", birth: 1887, death: 1950),
            "mabel": profile("mabel", name: "Mabel", birth: 1889, death: 1970),
        ]
        let origins = ClusterContext.origins(for: cluster(leads), in: profiles)
        #expect(origins.count == 2)
        #expect(origins.map(\.id) == ["ernest", "mabel"])
        #expect(origins[0].lifespanLabel == "(1887–1950)")
    }

    @Test func namesakeFlagFiresOnlyOnEgregiousGap() {
        let ernest = ClusterContext.Origin(id: "e", name: "Ernest", birthYear: 1810, deathYear: 1870)
        // Cluster born 1950 vs an 1810–1870 origin: 80 years past death+100? No —
        // 1950 vs window [1710, 1970] → still inside (great-grandchild). Silent.
        #expect(ClusterContext.namesakeFlag(clusterBirthYear: 1950, origins: [ernest]) == nil)
        // Cluster born 2010 vs the same origin → beyond 1970 → flagged.
        #expect(ClusterContext.namesakeFlag(clusterBirthYear: 2010, origins: [ernest]) != nil)
    }

    @Test func namesakeFlagSilentWithoutDates() {
        let undated = ClusterContext.Origin(id: "e", name: "Ernest", birthYear: nil, deathYear: nil)
        #expect(ClusterContext.namesakeFlag(clusterBirthYear: 1950, origins: [undated]) == nil)
        #expect(ClusterContext.namesakeFlag(clusterBirthYear: nil, origins: []) == nil)
    }

    @Test func namesakeFlagUsesClosestOrigin() {
        // Plausible against ANY one relative ⇒ not a namesake, even if far from
        // another. Ernest (1810–1870) is distant, but Alfred (1930–2000) makes a
        // 1990 cluster plausible.
        let ernest = ClusterContext.Origin(id: "e", name: "Ernest", birthYear: 1810, deathYear: 1870)
        let alfred = ClusterContext.Origin(id: "a", name: "Alfred", birthYear: 1930, deathYear: 2000)
        #expect(ClusterContext.namesakeFlag(clusterBirthYear: 1990, origins: [ernest, alfred]) == nil)
    }
}
