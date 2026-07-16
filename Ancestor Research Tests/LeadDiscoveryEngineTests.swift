import Testing
import Foundation
@testable import Ancestor_Research

/// Phase 0/1 lead-discovery blocking engine — deterministic entity resolution
/// over the orphan lead pool (LEAD_DISCOVERY_SPEC).
struct LeadDiscoveryEngineTests {

    private func makeLead(
        id: String,
        surname: String?,
        given: String?,
        birthYear: Int? = nil,
        deathYear: Int? = nil,
        source: LeadSource = .scoredLead,
        evidence: String = "",
        profileID: String = "origin",
        status: LeadStatus = .new
    ) -> Lead {
        Lead(
            id: id, profileID: profileID,
            name: [given, surname].compactMap { $0 }.joined(separator: " "),
            surname: surname, givenName: given,
            birthYear: birthYear, deathYear: deathYear,
            relationship: nil, source: source, status: status,
            evidence: evidence, createdAt: Date(timeIntervalSince1970: 0),
            investigatedAt: nil, resolvedAt: nil, resolution: nil
        )
    }

    @Test func coherentLeadsFormOneSurfaceableCluster() {
        let leads = [
            makeLead(id: "1", surname: "Cauldwell", given: "Ernest", birthYear: 1887,
                     source: .scoredLead, evidence: "census 1891"),
            makeLead(id: "2", surname: "Cauldwell", given: "Ernest", birthYear: 1887,
                     source: .scoredLead, evidence: "marriage 1915 spouse Ward"),
            makeLead(id: "3", surname: "CAULDWELL", given: "Ernest", birthYear: 1888,
                     source: .discovery, evidence: "birth 1888"),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 1)
        #expect(clusters[0].leads.count == 3)
        #expect(clusters[0].coherence.isSurfaceable)
        #expect(clusters[0].coherence.distinctEventKinds >= 2)  // census + marriage + birth
        #expect(clusters[0].surname == "CAULDWELL")
    }

    @Test func differentGivenNamesStaySeparate() {
        // Same surname + decade, but Ernest vs Mabel are different people.
        let leads = [
            makeLead(id: "1", surname: "Cauldwell", given: "Ernest", birthYear: 1887),
            makeLead(id: "2", surname: "Cauldwell", given: "Mabel", birthYear: 1888),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 2)
    }

    @Test func leadsCompatible_birthAfterDeath_false() {
        let dead = makeLead(id: "1", surname: "Land", given: "Thomas", deathYear: 1850)
        let bornLater = makeLead(id: "2", surname: "Land", given: "Thomas", birthYear: 1880)
        #expect(!LeadDiscoveryEngine.leadsCompatible(dead, bornLater))
    }

    @Test func leadWithNoNameIsDropped() {
        let leads = [
            makeLead(id: "1", surname: nil, given: nil),  // no anchor
            makeLead(id: "2", surname: "Ward", given: "Mary", birthYear: 1900),
            makeLead(id: "3", surname: "Ward", given: "Mary", birthYear: 1900, source: .discovery),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        let placed = clusters.reduce(0) { $0 + $1.leads.count }
        #expect(placed == 2)  // the nameless lead is dropped
    }

    @Test func dismissedAndPromotedLeadsAreExcluded() {
        let leads = [
            makeLead(id: "1", surname: "Ward", given: "Mary", birthYear: 1900),
            makeLead(id: "2", surname: "Ward", given: "Mary", birthYear: 1900, status: .dismissed),
            makeLead(id: "3", surname: "Ward", given: "Mary", birthYear: 1900, status: .promoted),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        // Only the one .new lead survives; a singleton, not surfaceable.
        let placed = clusters.reduce(0) { $0 + $1.leads.count }
        #expect(placed == 1)
    }

    @Test func reportCountsSurfaceableClusters() {
        let leads = [
            makeLead(id: "1", surname: "Ward", given: "Mary", birthYear: 1900),
            makeLead(id: "2", surname: "Ward", given: "Mary", birthYear: 1900, source: .discovery),
            makeLead(id: "3", surname: "Solo", given: "Han", birthYear: 1850),  // singleton
        ]
        let r = LeadDiscoveryEngine.report(leads: leads)
        #expect(r.totalLeads == 3)
        #expect(r.surfaceableClusters == 1)
        #expect(r.largestClusterSize == 2)
        #expect(r.leadsInSurfaceableClusters == 2)
    }
}
