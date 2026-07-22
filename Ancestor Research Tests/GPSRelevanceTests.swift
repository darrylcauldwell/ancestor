import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// DS-22 — GPS Criterion 1 ("reasonably exhaustive search") was a flat
/// min(3, total) count, blind to which sources actually matter for the
/// subject. It now requires the subject-relevant sources to have been
/// searched. Anchored to Robert Cauldwell (b.~1885, d.1918) — researched
/// three times with CWGC, the one source for a war death, never run, yet
/// the flat count reported him "exhaustively searched".
struct GPSRelevanceTests {

    private let allSources: Set<String> = ["freebmd", "freecen", "freereg", "cwgc", "findagrave", "probate", "wirksworth"]

    // MARK: - relevantSourceIDs

    @Test func ww1EligibleMaleRequiresCWGC() {
        // Robert Cauldwell: b.1885 (WW1 service age), male.
        let relevant = GPSScorer.relevantSourceIDs(
            birthYear: 1885, deathYear: 1918, gender: .male, available: allSources)
        #expect(relevant.contains("cwgc"))
        #expect(relevant.contains("freecen"), "1885 is census era")
    }

    @Test func deathInsideWarWindowRequiresCWGCEvenWithoutBirthYear() {
        let relevant = GPSScorer.relevantSourceIDs(
            birthYear: nil, deathYear: 1917, gender: .male, available: allSources)
        #expect(relevant.contains("cwgc"))
    }

    @Test func femaleSubjectDoesNotRequireCWGC() {
        let relevant = GPSScorer.relevantSourceIDs(
            birthYear: 1885, deathYear: 1918, gender: .female, available: allSources)
        #expect(!relevant.contains("cwgc"))
        #expect(relevant.contains("freecen"))
    }

    @Test func preRegistrationBirthRequiresParish() {
        let relevant = GPSScorer.relevantSourceIDs(
            birthYear: 1820, deathYear: nil, gender: .male, available: allSources)
        #expect(relevant.contains("freereg"), "pre-1837 birth → parish registers")
        #expect(relevant.contains("freecen"))
    }

    @Test func modernSubjectHasNoRelevanceDemands() {
        let relevant = GPSScorer.relevantSourceIDs(
            birthYear: 1950, deathYear: nil, gender: .male, available: allSources)
        #expect(relevant.isEmpty, "born 1950 — no census/war/parish signal")
    }

    @Test func unavailableRelevantSourceIsNotDemanded() {
        // If CWGC isn't registered for this run, don't demand it.
        let relevant = GPSScorer.relevantSourceIDs(
            birthYear: 1885, deathYear: 1918, gender: .male,
            available: ["freebmd", "freecen", "freereg"])
        #expect(!relevant.contains("cwgc"))
    }

    // MARK: - Criterion 1 integration

    @Test func missingRelevantSourceFailsExhaustiveSearch() {
        // Robert: 3 sources searched (count met) but CWGC missing → NOT met.
        let gps = GPSScorer.score(
            result: researched(),
            sourceInfoMap: [:],
            searchedSourceIDs: ["freebmd", "freecen", "freereg"],
            totalSourceCount: 7,
            relevantSourceIDs: ["cwgc"])
        let c1 = gps.criteria.first { $0.criterion == .exhaustiveSearch }
        #expect(c1?.met == false)
        #expect(c1?.reason.contains("cwgc") == true)
    }

    @Test func coveringRelevantSourcePassesExhaustiveSearch() {
        let gps = GPSScorer.score(
            result: researched(),
            sourceInfoMap: [:],
            searchedSourceIDs: ["freebmd", "freecen", "freereg", "cwgc"],
            totalSourceCount: 7,
            relevantSourceIDs: ["cwgc"])
        let c1 = gps.criteria.first { $0.criterion == .exhaustiveSearch }
        #expect(c1?.met == true)
    }

    @Test func noRelevanceDemandsFallsBackToCount() {
        // No relevant sources specified → behaves like the old flat count.
        let gps = GPSScorer.score(
            result: researched(),
            sourceInfoMap: [:],
            searchedSourceIDs: ["freebmd", "freecen", "freereg"],
            totalSourceCount: 7,
            relevantSourceIDs: [])
        let c1 = gps.criteria.first { $0.criterion == .exhaustiveSearch }
        #expect(c1?.met == true, "3 of 7 with no relevance demand still meets the count floor")
    }

    // MARK: - Fixtures

    private func researched() -> ResearchResult {
        ResearchResult(
            confirmedFacts: [], leads: [], allScoredRecords: [],
            clusters: [], discrepancies: [], householdMembers: [],
            searchHistory: [SearchAttempt(
                sourceID: "freebmd", recordType: .death,
                searchKey: "k", resultCount: 0, timestamp: Date())])
    }
}
