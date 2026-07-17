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
        ageAtDeath: Int? = nil,
        place: String? = nil,
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
            ageAtDeath: ageAtDeath, place: place,
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

    // MARK: - Phase 0 fix: age-at-death implied birth year + place discriminator

    @Test func effectiveBirthYearDerivesFromAgeAtDeath() {
        // No own birth year, but a death record with an age → implied birth.
        let lead = makeLead(id: "1", surname: "Ward", given: "George",
                            deathYear: 1960, ageAtDeath: 74)
        #expect(lead.effectiveBirthYear == 1886)
        // Own birth year always wins over the implied one.
        let known = makeLead(id: "2", surname: "Ward", given: "George",
                             birthYear: 1888, deathYear: 1960, ageAtDeath: 74)
        #expect(known.effectiveBirthYear == 1888)
        // A nonsense age is ignored.
        let junk = makeLead(id: "3", surname: "Ward", given: "George",
                            deathYear: 1960, ageAtDeath: 999)
        #expect(junk.effectiveBirthYear == nil)
    }

    @Test func ageAtDeathSplitsNamesakesIntoDifferentDecades() {
        // Two "George Ward" death leads, neither with an own birth year, but
        // ages implying births ~40 years apart. They must NOT merge — the
        // Phase 0 over-merge (all no-birth-year George Wards → one cluster).
        let leads = [
            makeLead(id: "1", surname: "Ward", given: "George",
                     deathYear: 1960, ageAtDeath: 74),   // b~1886
            makeLead(id: "2", surname: "Ward", given: "George",
                     deathYear: 1975, ageAtDeath: 30),   // b~1945
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 2)
    }

    @Test func yearlessSameNameDifferentPlaceStaySeparate() {
        // No birth signal at all on either side. Different cemeteries ⇒
        // different people ⇒ must not merge on name alone (George Ward = 273).
        let leads = [
            makeLead(id: "1", surname: "Ward", given: "George", place: "Wollaton Cemetery"),
            makeLead(id: "2", surname: "Ward", given: "George", place: "St Michael and All Angels Church"),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 2)
    }

    @Test func yearlessSameNameSamePlaceMerge() {
        // No birth signal, but an agreeing locality ⇒ plausibly one person.
        let leads = [
            makeLead(id: "1", surname: "Ward", given: "George", place: "Wollaton Cemetery"),
            makeLead(id: "2", surname: "Ward", given: "George", place: "Wollaton", source: .discovery),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 1)
        #expect(clusters[0].coherence.isSurfaceable)
    }

    @Test func yearlessSameNameNoPlaceStaySeparate() {
        // No birth signal AND no place ⇒ can't be resolved ⇒ stay split.
        let leads = [
            makeLead(id: "1", surname: "Ward", given: "George"),
            makeLead(id: "2", surname: "Ward", given: "George", source: .discovery),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 2)
    }

    @Test func differentDeathYearsAreDifferentPeople() {
        // Two "John Thompson" burial leads, no birth signal, SAME place, but
        // deaths three years apart — a person dies once, so they must split.
        let leads = [
            makeLead(id: "1", surname: "Thompson", given: "John",
                     deathYear: 1917, place: "Burnley Cemetery"),
            makeLead(id: "2", surname: "Thompson", given: "John",
                     deathYear: 1920, place: "Burnley Cemetery"),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 2)
        // A one-year jitter (death vs burial vs probate) still counts as one.
        #expect(LeadDiscoveryEngine.leadsCompatible(
            makeLead(id: "3", surname: "Thompson", given: "John", deathYear: 1917, place: "Burnley"),
            makeLead(id: "4", surname: "Thompson", given: "John", deathYear: 1918, place: "Burnley")
        ))
    }

    @Test func representativeLeadPrefersBirthSignalThenFullestName() {
        // Cluster of one person spelled three ways. The representative (used by
        // Phase 2's "Research as one person") should be the fullest name that
        // also carries a birth signal.
        let leads = [
            makeLead(id: "1", surname: "Ward", given: "G", birthYear: 1886),
            makeLead(id: "2", surname: "Ward", given: "George Edwin", birthYear: 1886),
            makeLead(id: "3", surname: "Ward", given: "George", birthYear: 1887),
        ]
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        #expect(clusters.count == 1)
        #expect(clusters[0].representativeLead.id == "2")
    }

    @Test func placesCompatibleIgnoresGenericWords() {
        // Both are "a cemetery" — the shared word is generic, not a locality.
        #expect(!LeadDiscoveryEngine.placesCompatible("BURNLEY CEMETERY", "HAREHILLS CEMETERY"))
        #expect(LeadDiscoveryEngine.placesCompatible("WOLLATON CEMETERY", "WOLLATON"))
    }
}
