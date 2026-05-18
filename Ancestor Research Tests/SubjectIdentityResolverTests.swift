import Testing
import Foundation
@testable import Ancestor_Research

/// Verifies `SubjectIdentityResolver` correctly pins (or refuses to pin) the
/// subject's identity to a single candidate birth record using the top
/// geographic hypothesis.
///
/// The canonical case is the Jennifer Holmes failure mode: 5 candidate
/// "Jennifer Holmes 1947-49" births returned by FreeBMD, no birth district
/// on the subject's profile, no middle name. The geographic hypothesis from
/// the family graph (own marriage in Belper, son born in Wirksworth/Belper)
/// must filter the candidates down to the one Belper birth.
struct SubjectIdentityResolverTests {

    // MARK: - Helpers

    private func birth(
        id: String,
        district: String?,
        year: Int = 1948,
        mothersMaidenName: String? = nil,
        sourceID: String = "freebmd"
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id,
            sourceID: sourceID,
            name: nil,
            surname: "Holmes",
            givenName: "Jennifer",
            detailURL: nil,
            rawFields: [:]
        )
        let record = BirthRecord(
            common: common,
            birthYear: year,
            birthDate: nil,
            birthPlace: nil,
            quarter: nil,
            district: district,
            volume: nil,
            page: nil,
            mothersMaidenName: mothersMaidenName
        )
        return ScoredRecord(
            id: id,
            record: .birth(record),
            verdict: .fact,
            gates: [],
            summary: ""
        )
    }

    private func hyp(
        district: String,
        weight: Double,
        signals: [String] = ["test"]
    ) -> GeographicHypothesis {
        GeographicHypothesis(
            districtName: district,
            districtCode: "TEST-\(district)",
            chapmanCode: "DBY",
            weight: weight,
            signals: signals
        )
    }

    // MARK: - Tests

    @Test func jenniferFiveCandidatesResolvedByBelperHypothesis() {
        // The real-world failure case from May 2026: five candidate Jennifer
        // Holmes 1947-49 births, only one in Belper. Without the resolver,
        // auto-promote picked the wrong (Ashbourne) record and promoted Colin
        // Holmes as a fake maternal grandfather. With the resolver, the Belper
        // hypothesis filters cleanly to one.
        let candidates = [
            birth(id: "ashbourne-1948", district: "Ashbourne", year: 1948),
            birth(id: "derby-1947", district: "Derby", year: 1947),
            birth(id: "belper-1948", district: "Belper", year: 1948),
            birth(id: "unknown-1948", district: nil, year: 1948),
            birth(id: "chesterfield-1948", district: "Chesterfield", year: 1948),
        ]
        let hypotheses = [hyp(district: "Belper", weight: 0.87)]

        let outcome = SubjectIdentityResolver.resolve(
            candidateBirthFacts: candidates,
            hypotheses: hypotheses
        )

        guard case .resolved(let recordID, let district) = outcome else {
            Issue.record("expected .resolved, got \(outcome)")
            return
        }
        #expect(recordID == "belper-1948")
        #expect(district == "Belper")
    }

    @Test func noCandidatesIsUnresolved() {
        let outcome = SubjectIdentityResolver.resolve(
            candidateBirthFacts: [],
            hypotheses: [hyp(district: "Belper", weight: 0.9)]
        )
        guard case .unresolved = outcome else {
            Issue.record("expected .unresolved, got \(outcome)")
            return
        }
    }

    @Test func singleCandidateResolvesWithoutHypothesis() {
        // With no ambiguity to resolve, a lone candidate is the answer
        // regardless of whether we have a hypothesis.
        let only = birth(id: "only", district: "Belper")
        let outcome = SubjectIdentityResolver.resolve(
            candidateBirthFacts: [only],
            hypotheses: []
        )
        guard case .resolved(let id, _) = outcome else {
            Issue.record("expected .resolved, got \(outcome)")
            return
        }
        #expect(id == "only")
    }

    @Test func multipleCandidatesNoHypothesisIsAmbiguous() {
        // Five candidates, no geographic signal — the resolver must NOT guess.
        let candidates = (1...5).map { birth(id: "c\($0)", district: "D\($0)") }
        let outcome = SubjectIdentityResolver.resolve(
            candidateBirthFacts: candidates,
            hypotheses: []
        )
        guard case .ambiguous = outcome else {
            Issue.record("expected .ambiguous, got \(outcome)")
            return
        }
    }

    @Test func weakHypothesisDoesNotFilter() {
        // Hypothesis below the minimum weight threshold must be ignored.
        let candidates = [
            birth(id: "a", district: "Ashbourne"),
            birth(id: "b", district: "Belper"),
        ]
        let outcome = SubjectIdentityResolver.resolve(
            candidateBirthFacts: candidates,
            hypotheses: [hyp(district: "Belper", weight: 0.10)]
        )
        guard case .ambiguous = outcome else {
            Issue.record("expected .ambiguous from weak hypothesis, got \(outcome)")
            return
        }
    }

    @Test func hypothesisMatchingZeroCandidatesIsAmbiguous() {
        // Hypothesis points at a district that doesn't appear in any
        // candidate — keep all candidates ambiguous rather than silently
        // discard them.
        let candidates = [
            birth(id: "a", district: "Ashbourne"),
            birth(id: "b", district: "Derby"),
        ]
        let outcome = SubjectIdentityResolver.resolve(
            candidateBirthFacts: candidates,
            hypotheses: [hyp(district: "Belper", weight: 0.9)]
        )
        guard case .ambiguous(let ids, _) = outcome else {
            Issue.record("expected .ambiguous, got \(outcome)")
            return
        }
        #expect(Set(ids) == Set(["a", "b"]))
    }

    @Test func hypothesisMatchingMultipleCandidatesNarrowsButStaysAmbiguous() {
        // Two Belper candidates and one Ashbourne — the hypothesis narrows
        // to the two Belper ones but can't pick between them.
        let candidates = [
            birth(id: "belper-a", district: "Belper"),
            birth(id: "belper-b", district: "Belper"),
            birth(id: "ashbourne", district: "Ashbourne"),
        ]
        let outcome = SubjectIdentityResolver.resolve(
            candidateBirthFacts: candidates,
            hypotheses: [hyp(district: "Belper", weight: 0.9)]
        )
        guard case .ambiguous(let ids, _) = outcome else {
            Issue.record("expected .ambiguous, got \(outcome)")
            return
        }
        #expect(Set(ids) == Set(["belper-a", "belper-b"]))
    }
}
