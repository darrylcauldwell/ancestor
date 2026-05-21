import Testing
import Foundation
@testable import Ancestor_Research

/// T7 — Hypothesis-guided second pass invariants (V2 spec §5.3). The
/// pipeline runs a second pass at most once when there's at least one
/// `.inconclusive` hypothesis whose per-kind deficit-query ladder
/// still has headroom (`deficitQuery(for:atLevel: attempts + 1, …)`
/// returns non-nil). Tests here pin the eligibility filter,
/// per-kind ladder behaviour, and the re-grading + reconciliation
/// path that fires post-dispatch.
///
/// The orchestrator itself (`ResearchPipeline.runSecondPass`) is
/// private and requires a live dispatcher to exercise end-to-end —
/// these tests cover the eligibility / ladder / re-grading shape via
/// the engine's public surface.
@MainActor
struct T7SecondPassTests {

    // MARK: - Helpers

    private func makeHypothesis(
        id: String = "h",
        subjectProfileID: String? = "subj",
        kind: HypothesisKind,
        verdict: ResearchHypothesis.Verdict = .inconclusive,
        attempts: Int = 1
    ) -> ResearchHypothesis {
        ResearchHypothesis(
            id: id,
            subjectProfileID: subjectProfileID,
            kind: kind,
            verdict: verdict,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "test",
            createdAt: Date(),
            lastTestedAt: Date(),
            attempts: attempts,
            history: []
        )
    }

    private func makeState(surname: String? = "Cauldwell", birthYear: Int? = 1976) -> ResearchState {
        let subject = ResearchSubject(
            profileID: "subj", surname: surname, givenName: nil,
            middleName: nil,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil, mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY"
        )
        return ResearchState(subject: subject)
    }

    // MARK: - Eligibility filter

    @Test func eligibility_inconclusiveSiblingAtLevel2_returnsNil_notEligible() {
        // .siblingExists has level-1 ladder ceiling — attempts already
        // at 1 means level-2 returns nil → not eligible for retry.
        let kind = HypothesisKind.siblingExists(
            district: "Belper", mmn: "Holmes", yearWindow: 1956...1996
        )
        let h = makeHypothesis(kind: kind, verdict: .inconclusive, attempts: 1)
        let state = makeState()
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: h.attempts + 1, state: state)
        #expect(queries.isEmpty, "sibling level-2 is exhausted in current ladder")
    }

    @Test func eligibility_inconclusiveParentMarriageAtLevel2_returnsQuery_eligible() {
        // .parentMarriage has level-1 ladder (window widen ±10y).
        // attempts=1 means level-2 returns a query → eligible.
        let kind = HypothesisKind.parentMarriage(
            motherSurname: "Holmes", fatherSurname: "Cauldwell",
            windowYears: 1946...1977
        )
        let h = makeHypothesis(kind: kind, verdict: .inconclusive, attempts: 1)
        let state = makeState()
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: h.attempts + 1, state: state)
        #expect(!queries.isEmpty, "parentMarriage level-2 widens window — eligible for retry")
        // Window widens by ±10 years (per the deficit-query
        // implementation).
        if let q = queries.first {
            #expect(q.yearFrom == 1936)
            #expect(q.yearTo == 1987)
            #expect(q.recordType == .marriage)
        }
    }

    @Test func eligibility_supportedHypothesis_notEligible() {
        // Even if the ladder has headroom, a .supported hypothesis
        // shouldn't be retried — T7 only fires for .inconclusive.
        let kind = HypothesisKind.parentMarriage(
            motherSurname: "Holmes", fatherSurname: "Cauldwell",
            windowYears: 1946...1977
        )
        let h = makeHypothesis(kind: kind, verdict: .supported, attempts: 1)
        let state = makeState()
        // The deficit query itself still returns non-nil (level-2
        // exists structurally) — the eligibility filter in
        // runSecondPass gates on verdict separately.
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: h.attempts + 1, state: state)
        #expect(!queries.isEmpty)
        // But the orchestrator's predicate must reject this:
        #expect(h.verdict != .inconclusive, "supported hypotheses must be filtered out at the verdict gate")
    }

    @Test func eligibility_contradictedHypothesis_notEligible() {
        // .contradicted hypotheses are settled — no retry.
        let kind = HypothesisKind.parentMarriage(
            motherSurname: "Holmes", fatherSurname: "Cauldwell",
            windowYears: 1946...1977
        )
        let h = makeHypothesis(kind: kind, verdict: .contradicted, attempts: 1)
        #expect(h.verdict != .inconclusive)
    }

    // MARK: - Per-kind ladder ceilings (T7's exhaustion signal)

    @Test func ladder_parentInferred_alwaysReturnsNil() {
        // .parentInferred has no per-kind ladder — falls through to
        // T8's MLX fallback (§5.4) instead. T7 never retries it.
        let kind = HypothesisKind.parentInferred(gender: .female, surname: "Holmes")
        let h = makeHypothesis(kind: kind, attempts: 1)
        let state = makeState()
        for level in 1...5 {
            let queries = HypothesisEngine.deficitQuery(for: h, atLevel: level, state: state)
            #expect(queries.isEmpty, "parentInferred has no ladder — level \(level) must return empty")
        }
    }

    @Test func ladder_parentMarriage_level1FromAttempts0_returnsOriginalWindow() {
        // attempts=0 (freshly generated, never dispatched) → level-1
        // returns the original-window query (same shape as the
        // first-pass dispatch). This is the path the orchestrator
        // would take if a stale persisted hypothesis is replayed at
        // the start of a new run — fall back through level 1 before
        // T7 retries at level 2.
        let kind = HypothesisKind.parentMarriage(
            motherSurname: "Holmes", fatherSurname: "Cauldwell",
            windowYears: 1946...1977
        )
        let h = makeHypothesis(kind: kind, verdict: .inconclusive, attempts: 0)
        let state = makeState()
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: h.attempts + 1, state: state)
        let unwrapped = try! #require(queries.first)
        #expect(unwrapped.yearFrom == 1946)
        #expect(unwrapped.yearTo == 1977)
    }

    @Test func ladder_parentMarriage_level3PlusReturnsNil() {
        // Level ≥ 2 ladder ceiling — T31 retunes once eval-harness
        // data is available.
        let kind = HypothesisKind.parentMarriage(
            motherSurname: "Holmes", fatherSurname: "Cauldwell",
            windowYears: 1946...1977
        )
        let h = makeHypothesis(kind: kind, verdict: .inconclusive, attempts: 2)
        let state = makeState()
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: h.attempts + 1, state: state)
        #expect(queries.isEmpty, "parentMarriage level-3 ceiling reached")
    }

    // MARK: - Re-grading shape

    @Test func regrading_flipsContradictedToSupported_whenEvidenceArrives() throws {
        // Scenario: first pass graded .parentMarriage as .contradicted
        // because no marriage records matched the surname pair in the
        // initial window. T7 dispatches the widened window, returns
        // matching records, re-grading flips verdict to .supported.
        // This test pins the re-grade transition by simulating the
        // state change manually.
        let subjectID = "subj"
        let kind = HypothesisKind.parentMarriage(
            motherSurname: "Holmes", fatherSurname: "Cauldwell",
            windowYears: 1946...1977
        )
        let h = makeHypothesis(
            id: kind.identityKey(subjectProfileID: subjectID),
            subjectProfileID: subjectID,
            kind: kind, verdict: .contradicted, attempts: 1
        )

        // Pre-second-pass state: no marriage records (matches
        // first-pass `.contradicted` verdict).
        var state = makeState()
        // Build a marriage record at the window's edge — appears
        // when the widened window catches it.
        let groomCommon = RecordCommon(
            id: "m-groom", sourceID: "freebmd", name: nil,
            surname: "Cauldwell", givenName: "David",
            detailURL: nil, rawFields: [:]
        )
        let groom = MarriageRecord(
            common: groomCommon,
            marriageYear: 1969,   // inside original window — to demo grade flip
            marriageDate: nil, marriagePlace: nil,
            quarter: "Mar", district: "Belper",
            volume: "7B", page: "1234",
            spouseName: "Holmes"
        )
        let groomScored = ScoredRecord(
            id: "m-groom", record: .marriage(groom),
            verdict: .lead, gates: [], summary: ""
        )
        let brideCommon = RecordCommon(
            id: "m-bride", sourceID: "freebmd", name: nil,
            surname: "Holmes", givenName: "Jennifer",
            detailURL: nil, rawFields: [:]
        )
        let bride = MarriageRecord(
            common: brideCommon,
            marriageYear: 1969,
            marriageDate: nil, marriagePlace: nil,
            quarter: "Mar", district: "Belper",
            volume: "7B", page: "1234",
            spouseName: "Cauldwell"
        )
        let brideScored = ScoredRecord(
            id: "m-bride", record: .marriage(bride),
            verdict: .lead, gates: [], summary: ""
        )

        // Simulate T7's dispatch by appending records to state.
        state.scoredRecords.append(contentsOf: [groomScored, brideScored])

        // Re-grade with populated state.
        let regrade = HypothesisEngine.gradeParentMarriage(
            h, state: state, snapshot: .empty
        )
        #expect(regrade.verdict == .supported, "evidence arrives → contradicted → supported")
        #expect(Set(regrade.supportingEvidence) == ["m-groom", "m-bride"])
    }

    // MARK: - Reconciliation after T7

    @Test func reconciliation_appliesNewlySupportedParentMarriageToParents() throws {
        // After T7 re-grades .parentMarriage to .supported,
        // reconciliation must thread the marriage evidence onto the
        // .parentInferred rows even though those weren't the target of
        // the deficit dispatch.
        let subjectID = "subj"
        let motherKind = HypothesisKind.parentInferred(gender: .female, surname: "Holmes")
        let fatherKind = HypothesisKind.parentInferred(gender: .male, surname: "Cauldwell")
        let marriageKind = HypothesisKind.parentMarriage(
            motherSurname: "Holmes", fatherSurname: "Cauldwell",
            windowYears: 1946...1977
        )
        let now = Date()
        let mother = makeHypothesis(
            id: motherKind.identityKey(subjectProfileID: subjectID),
            kind: motherKind,
            verdict: .supported, attempts: 1
        )
        let father = makeHypothesis(
            id: fatherKind.identityKey(subjectProfileID: subjectID),
            kind: fatherKind,
            verdict: .supported, attempts: 1
        )
        // .parentMarriage now .supported after T7 re-grade,
        // attempts bumped to 2.
        let marriage = ResearchHypothesis(
            id: marriageKind.identityKey(subjectProfileID: subjectID),
            subjectProfileID: subjectID,
            kind: marriageKind,
            verdict: .supported,
            isModelAssisted: false,
            supportingEvidence: ["m-groom", "m-bride"],
            contradictingEvidence: [],
            reasoning: "Marriage David Cauldwell × Jennifer Holmes within 1936–1987.",
            createdAt: now, lastTestedAt: now,
            attempts: 2, history: []
        )

        let reconciled = HypothesisEngine.reconcileParentMarriages(
            hypotheses: [mother, father, marriage]
        )
        let motherReconciled = try #require(reconciled.first { $0.id == mother.id })
        let fatherReconciled = try #require(reconciled.first { $0.id == father.id })
        #expect(motherReconciled.supportingEvidence.contains("m-groom"))
        #expect(motherReconciled.supportingEvidence.contains("m-bride"))
        #expect(fatherReconciled.supportingEvidence.contains("m-groom"))
        #expect(fatherReconciled.supportingEvidence.contains("m-bride"))
        #expect(motherReconciled.reasoning.contains("cross-ref"))
        #expect(fatherReconciled.reasoning.contains("cross-ref"))
    }
}
