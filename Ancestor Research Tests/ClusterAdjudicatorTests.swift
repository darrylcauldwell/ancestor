import Testing
import Foundation
@testable import Ancestor_Research

/// Phase 4 — deterministic halves of the cluster adjudicator: narration
/// formatting, prompt construction (with the lead cap), and verdict parsing.
/// The live model call is not unit-tested (no model in CI-like runs; a loaded
/// model would make it slow/nondeterministic) — its guard pattern mirrors the
/// proven ResearchInterpreter consumers.
struct ClusterAdjudicatorTests {

    private func makeLead(
        id: String,
        surname: String = "Thompson",
        given: String? = "John",
        birthYear: Int? = nil,
        deathYear: Int? = nil,
        ageAtDeath: Int? = nil,
        place: String? = nil,
        evidence: String = ""
    ) -> Lead {
        Lead(
            id: id, profileID: "origin",
            name: [given, surname].compactMap { $0 }.joined(separator: " "),
            surname: surname, givenName: given,
            birthYear: birthYear, deathYear: deathYear,
            ageAtDeath: ageAtDeath, place: place,
            relationship: nil, source: .scoredLead, status: .new,
            evidence: evidence, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func cluster(from leads: [Lead]) -> LeadDiscoveryEngine.EmergentCluster {
        let clusters = LeadDiscoveryEngine.discover(leads: leads)
        precondition(clusters.count == 1, "fixture leads must form one cluster")
        return clusters[0]
    }

    // MARK: - Narration

    @Test func summaryFormatsSpanKindsAndPlaces() {
        let c = cluster(from: [
            makeLead(id: "1", surname: "Ward", given: "George", birthYear: 1886,
                     place: "Bakewell", evidence: "census 1891"),
            makeLead(id: "2", surname: "Ward", given: "George", birthYear: 1886,
                     deathYear: 1960, place: "Wollaton Cemetery", evidence: "burial"),
        ])
        let s = ClusterAdjudicator.summary(c)
        #expect(s.contains("b~1886"))
        #expect(s.contains("d~1960"))
        #expect(s.contains("census"))
        #expect(s.contains("death"))
        #expect(s.contains("Bakewell"))
        #expect(s.contains("Wollaton"))
    }

    @Test func summaryTruncatesLongPlaceLists() {
        let places = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]
        let leads = places.enumerated().map { i, p in
            makeLead(id: "\(i)", place: "\(p) Common", evidence: "burial")
        }
        let s = ClusterAdjudicator.summary(cluster(from: leads))
        #expect(s.contains("+2 more"))
    }

    // MARK: - Prompt

    @Test func promptListsLeadsAndCapsAtTwelve() {
        let leads = (0..<20).map { i in
            makeLead(id: "\(i)", deathYear: 1917, place: "Burnley Cemetery",
                     evidence: "burial record")
        }
        let p = ClusterAdjudicator.prompt(for: cluster(from: leads))
        #expect(p.contains("These 20 genealogical records"))
        #expect(p.contains("12. "))
        #expect(!p.contains("13. "))
        #expect(p.contains("and 8 more"))
        #expect(p.contains(#""verdict""#))
    }

    // MARK: - Verdict parsing

    @Test func parseVerdictAcceptsWellFormedJSON() {
        let v = ClusterAdjudicator.parseVerdict(
            fromRaw: #"{"verdict": "multiple", "reason": "Three different regiments and services."}"#)
        #expect(v?.assessment == .likelyMultiplePeople)
        #expect(v?.reasoning.contains("regiments") == true)
    }

    @Test func parseVerdictAcceptsCodeFencedReply() {
        let raw = """
        Here is my judgement:
        ```json
        {"verdict": "one", "reason": "Consistent place and era."}
        ```
        """
        let v = ClusterAdjudicator.parseVerdict(fromRaw: raw)
        #expect(v?.assessment == .plausiblyOnePerson)
    }

    @Test func parseVerdictRejectsGarbage() {
        #expect(ClusterAdjudicator.parseVerdict(fromRaw: "I think they are the same person.") == nil)
        #expect(ClusterAdjudicator.parseVerdict(fromRaw: #"{"verdict": "maybe", "reason": "x"}"#) == nil)
        #expect(ClusterAdjudicator.parseVerdict(fromRaw: #"{"verdict": "one", "reason": "  "}"#) == nil)
    }
}
