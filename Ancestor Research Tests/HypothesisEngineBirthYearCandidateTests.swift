import Testing
import Foundation
@testable import Ancestor_Research

/// `.birthYearCandidate` slice 1 — generator invariants.
///
/// Generator emits one hypothesis per distinct precise (span-0) year
/// attested in `Profile.sources[.birthDate]`, but only when ≥ 2 distinct
/// years compete. See `project_multi_hypothesis_birth_year_plan` memory.
@MainActor
struct HypothesisEngineBirthYearCandidateTests {

    // MARK: - Helpers

    private func birthDateSource(_ raw: String) -> FieldSource {
        FieldSource(origin: .freebmd, raw: raw, addedAt: Date())
    }

    private func makeProfile(
        id: String,
        birthDateSources: [FieldSource]
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: nil, lastName: nil, gender: nil,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [.birthDate: birthDateSources],
            disputes: [:]
        )
    }

    private func makeSubject(profileID: String?) -> ResearchSubject {
        ResearchSubject(
            profileID: profileID, surname: "Brooks", givenName: "George",
            middleName: nil,
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    private func snapshot(with profile: Profile) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
    }

    /// Snapshot where `profile` has one child with the given birth year —
    /// gives `BiographicalFitEvaluator` an earliest-child anchor for rule 3.
    private func snapshotWithChild(
        parent: Profile, childID: String, childBirthYear: Int
    ) -> FamilyGraphSnapshot {
        let child = Profile(
            id: childID, externalIDs: [:],
            firstName: nil, lastName: nil, gender: nil,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: String(childBirthYear)),
            birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
        let rel = Relationship(
            id: UUID(),
            from: parent.id, to: childID,
            type: .parent, role: nil, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        return FamilyGraphSnapshot(
            profiles: [parent.id: parent, childID: child],
            relationships: [rel]
        )
    }

    private func birthYearCandidateHypothesis(
        profileID: String, year: Int
    ) -> ResearchHypothesis {
        let kind = HypothesisKind.birthYearCandidate(profileID: profileID, year: year)
        let now = Date()
        return ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: profileID),
            subjectProfileID: profileID,
            kind: kind,
            verdict: .inconclusive,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "Pending grading.",
            createdAt: now,
            lastTestedAt: now,
            attempts: 0,
            history: []
        )
    }

    // MARK: - Empty / single-candidate cases

    @Test func emitsNothingWhenNoSources() {
        let profile = makeProfile(id: "p1", birthDateSources: [])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.isEmpty)
    }

    @Test func emitsNothingWhenOnlyOnePreciseCandidate() {
        // One precise year is the subject-self-narrowing slice-B path's
        // job (it writes a pending fact). The multi-hypothesis kind only
        // fires when ≥ 2 distinct precise candidates compete.
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("Jun 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.isEmpty)
    }

    @Test func emitsNothingWhenAllSourcesAreWideRange() {
        // Wide-range entries can't compete — they support or contradict,
        // never disambiguate against each other.
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("BET 1869 AND 1896"),
            birthDateSource("ABT 1880"),
            birthDateSource("BEF 1900")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.isEmpty)
    }

    @Test func emitsNothingWhenSubjectProfileIDMissing() {
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: nil))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.isEmpty)
    }

    @Test func emitsNothingWhenProfileMissingFromSnapshot() {
        // Subject says p1 but snapshot only has p2 — no profile to read.
        let otherProfile = makeProfile(id: "p2", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: otherProfile)
        )
        #expect(drafts.isEmpty)
    }

    // MARK: - Multi-candidate cases

    @Test func emitsTwoHypothesesForGeorgeBrooksCanonicalCase() {
        // The motivating case from project_multi_hypothesis_birth_year_plan:
        // Jun 1870 vs Dec 1883, with a wide range alongside that should be
        // ignored. Per known_george_brooks_test_state.md.
        let profile = makeProfile(id: "george", birthDateSources: [
            birthDateSource("BET 1869 AND 1896"),
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "george"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.count == 2)
        let years = drafts.compactMap { h -> Int? in
            if case .birthYearCandidate(_, let year) = h.kind { return year }
            return nil
        }
        // Sorted ascending for deterministic ordering.
        #expect(years == [1870, 1883])
        // Subject ID propagated to payload + parent fields.
        for h in drafts {
            #expect(h.subjectProfileID == "george")
            #expect(h.verdict == .inconclusive)
            #expect(h.attempts == 0)
            #expect(h.supportingEvidence.isEmpty)
            #expect(h.isModelAssisted == false)
            if case .birthYearCandidate(let pid, _) = h.kind {
                #expect(pid == "george")
            }
        }
    }

    @Test func dedupesDuplicatePreciseYears() {
        // Two scoring passes that recorded `Jun 1870` twice should yield
        // ONE candidate for 1870 (not two). Concretely from the canonical
        // state, the freebmd-side dedup of repeated rows shouldn't fan out
        // to duplicate hypotheses.
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.count == 2)
        let years = Set(drafts.compactMap { h -> Int? in
            if case .birthYearCandidate(_, let year) = h.kind { return year }
            return nil
        })
        #expect(years == [1870, 1883])
    }

    @Test func ignoresWideRangeMixedWithMultiplePreciseValues() {
        // Wide range alongside two precise candidates: emit only the two
        // precise hypotheses. The wide range neither competes nor inflates
        // the count.
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("BET 1869 AND 1896"),
            birthDateSource("ABT 1880"),
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.count == 2)
    }

    @Test func emitsThreeWhenThreeDistinctPreciseYears() {
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Mar 1875"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.count == 3)
        let years = drafts.compactMap { h -> Int? in
            if case .birthYearCandidate(_, let year) = h.kind { return year }
            return nil
        }
        #expect(years == [1870, 1875, 1883])
    }

    // MARK: - Stability invariants

    @Test func stableIdAcrossRuns() {
        let profile = makeProfile(id: "george", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "george"))
        let first = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        let second = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(first.count == 2 && second.count == 2)
        #expect(first[0].id == second[0].id)
        #expect(first[1].id == second[1].id)
        // ID format is `birthYearCandidate:<profileID>:<year>` so the two
        // distinct years produce two distinct stable IDs.
        #expect(Set(first.map(\.id)).count == 2)
    }

    @Test func emitsForYearOnlyAndExactQualifiersAlike() {
        // GenealogicalDate parses "1883" as .yearOnly with earliest==latest;
        // "1 Jan 1883" parses as .exact with earliest==latest. Both should
        // be treated as the same precise candidate.
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("1870"),
            birthDateSource("1 Jan 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let drafts = HypothesisEngine.generateBirthYearCandidate(
            state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.count == 2)
    }

    // MARK: - Discriminator + central-switch wiring

    @Test func discriminatorRoundTrip() {
        let kind = HypothesisKind.birthYearCandidate(profileID: "p1", year: 1883)
        #expect(kind.discriminator == "birthYearCandidate")
        #expect(kind.identityKey(subjectProfileID: "p1") == "birthYearCandidate:p1:1883")
    }

    @Test func centralGenerateSwitchRoutesToExtension() {
        // Sanity check: HypothesisEngine.generate(for:) on the
        // .birthYearCandidate discriminator dispatches to the same
        // extension method we call directly elsewhere in this file.
        let profile = makeProfile(id: "p1", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "p1"))
        let viaCentral = HypothesisEngine.generate(
            for: .birthYearCandidate, state: state, snapshot: snapshot(with: profile)
        )
        #expect(viaCentral.count == 2)
    }

    // MARK: - Grader (slice 2)
    //
    // The grader scores each candidate year via BiographicalFitEvaluator
    // and compares plausibilities against `birthYearCandidateDecisiveMargin`
    // (0.4). The evaluator's rule 3 (parent-age 14–65 at first child's
    // birth) is the only rule that fires deterministically without
    // death-shape records in state. That gives clean test scenarios.

    @Test func grade_supportedWhenDecisiveWinner() {
        // Subject has a child born 1900. Candidates:
        //   1870 → age 30 at child birth → rule 3 plausible (1.0)
        //   1895 → age  5 at child birth → rule 3 implausible (0.0)
        // Gap 1.0 ≥ 0.4 → 1870 is .supported.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Jun 1895")
        ])
        var state = ResearchState(subject: makeSubject(profileID: "subj"))
        state.scoredRecords = []
        let snap = snapshotWithChild(parent: profile, childID: "kid", childBirthYear: 1900)

        let h = birthYearCandidateHypothesis(profileID: "subj", year: 1870)
        let result = HypothesisEngine.gradeBirthYearCandidate(h, state: state, snapshot: snap)
        #expect(result.verdict == .supported)
        #expect(result.isModelAssisted == false)
        #expect(result.reasoning.contains("1870"))
        // Confirms it referenced the competing year for explainability.
        #expect(result.reasoning.contains("1895"))
    }

    @Test func grade_contradictedForLosingCandidate() {
        // Same setup, but grade the implausible candidate.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Jun 1895")
        ])
        var state = ResearchState(subject: makeSubject(profileID: "subj"))
        state.scoredRecords = []
        let snap = snapshotWithChild(parent: profile, childID: "kid", childBirthYear: 1900)

        let h = birthYearCandidateHypothesis(profileID: "subj", year: 1895)
        let result = HypothesisEngine.gradeBirthYearCandidate(h, state: state, snapshot: snap)
        #expect(result.verdict == .contradicted)
        #expect(result.isModelAssisted == false)
    }

    @Test func grade_inconclusiveForGeorgeBrooksCanonicalCase() {
        // Per known_george_brooks_test_state.md: child Hilda b. 1912.
        //   1870 → age 42 at first child → rule 3 plausible (1.0)
        //   1883 → age 29 at first child → rule 3 plausible (1.0)
        // Both score 1.0; gap 0.0 < 0.4 → both .inconclusive.
        // This is the case slice 4's deficit queries will resolve by
        // bringing in census + marriage corroborating records.
        let profile = makeProfile(id: "george", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        var state = ResearchState(subject: makeSubject(profileID: "george"))
        state.scoredRecords = []
        let snap = snapshotWithChild(parent: profile, childID: "hilda", childBirthYear: 1912)

        let h1870 = birthYearCandidateHypothesis(profileID: "george", year: 1870)
        let h1883 = birthYearCandidateHypothesis(profileID: "george", year: 1883)
        let r1870 = HypothesisEngine.gradeBirthYearCandidate(h1870, state: state, snapshot: snap)
        let r1883 = HypothesisEngine.gradeBirthYearCandidate(h1883, state: state, snapshot: snap)
        #expect(r1870.verdict == .inconclusive)
        #expect(r1883.verdict == .inconclusive)
        // The reasoning should reference slice 4's role for future work.
        #expect(r1870.reasoning.contains("slice-4") || r1870.reasoning.contains("slice 4"))
    }

    @Test func grade_inconclusiveWhenNoChildrenAnchor() {
        // Without children on the tree, rule 3 has nothing to anchor on.
        // Both candidates retain plausibility 1.0 → inconclusive.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Jun 1895")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "subj"))
        let snap = snapshot(with: profile)

        let h = birthYearCandidateHypothesis(profileID: "subj", year: 1870)
        let result = HypothesisEngine.gradeBirthYearCandidate(h, state: state, snapshot: snap)
        #expect(result.verdict == .inconclusive)
    }

    @Test func grade_inconclusiveWhenPreconditionsEvaporated() {
        // Sources edited mid-run: now only one precise candidate left.
        // Grader returns .inconclusive with a self-describing reason.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "subj"))
        let snap = snapshot(with: profile)

        let h = birthYearCandidateHypothesis(profileID: "subj", year: 1870)
        let result = HypothesisEngine.gradeBirthYearCandidate(h, state: state, snapshot: snap)
        #expect(result.verdict == .inconclusive)
        #expect(result.reasoning.contains("Preconditions"))
    }

    @Test func grade_contradictedWhenHypothesisYearNoLongerAttested() {
        // Sources changed: hypothesis says 1895 but Profile.sources only
        // shows 1870 + 1883 now. The hypothesis is referring to a year
        // that no longer competes — .contradicted.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Dec 1883")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "subj"))
        let snap = snapshot(with: profile)

        let h = birthYearCandidateHypothesis(profileID: "subj", year: 1895)
        let result = HypothesisEngine.gradeBirthYearCandidate(h, state: state, snapshot: snap)
        #expect(result.verdict == .contradicted)
        #expect(result.reasoning.contains("no longer attested"))
    }

    @Test func grade_inconclusiveStubWhenWrongKind() {
        // Defensive: if a non-.birthYearCandidate hypothesis is somehow
        // routed here, grader returns inconclusiveStub.
        let now = Date()
        let unrelatedKind = HypothesisKind.parentInferred(gender: .male, surname: "Brooks")
        let h = ResearchHypothesis(
            id: unrelatedKind.identityKey(subjectProfileID: "subj"),
            subjectProfileID: "subj",
            kind: unrelatedKind,
            verdict: .inconclusive,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "",
            createdAt: now, lastTestedAt: now,
            attempts: 0, history: []
        )
        let state = ResearchState(subject: makeSubject(profileID: "subj"))
        let result = HypothesisEngine.gradeBirthYearCandidate(
            h, state: state, snapshot: FamilyGraphSnapshot(profiles: [:], relationships: [])
        )
        #expect(result.verdict == .inconclusive)
    }

    @Test func grade_centralSwitchRoutesToExtension() {
        // HypothesisEngine.grade(_:state:snapshot:) routes .birthYearCandidate
        // to our extension method — sanity check on the central switch.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Jun 1895")
        ])
        var state = ResearchState(subject: makeSubject(profileID: "subj"))
        state.scoredRecords = []
        let snap = snapshotWithChild(parent: profile, childID: "kid", childBirthYear: 1900)
        let h = birthYearCandidateHypothesis(profileID: "subj", year: 1870)
        let viaCentral = HypothesisEngine.grade(h, state: state, snapshot: snap)
        #expect(viaCentral.verdict == .supported)
    }

    // MARK: - Pipeline-flow shape (slice 3)
    //
    // `ResearchPipeline.runBirthYearCandidateFlow` is private — these
    // tests exercise the same generate → grade chain through the
    // central HypothesisEngine surfaces that the flow itself calls.
    // The flow is otherwise just `drafts.map { finalizeHypothesis }`
    // which is a one-line transformation; the meaningful invariants
    // live in the generate + grade behaviour, plus the discriminator
    // routing the central switch does.

    @Test func slice3_flow_emitsAndGradesEndToEndForCompetingCandidates() {
        // Real-shape end-to-end: generate via central switch, grade
        // every draft via central switch. Mirrors what
        // ResearchPipeline.runBirthYearCandidateFlow does internally.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870"),
            birthDateSource("Jun 1895")
        ])
        var state = ResearchState(subject: makeSubject(profileID: "subj"))
        state.scoredRecords = []
        let snap = snapshotWithChild(parent: profile, childID: "kid", childBirthYear: 1900)

        let drafts = HypothesisEngine.generate(
            for: .birthYearCandidate, state: state, snapshot: snap
        )
        #expect(drafts.count == 2)

        let graded = drafts.map { draft in
            (draft, HypothesisEngine.grade(draft, state: state, snapshot: snap))
        }
        // One supported (1870 — plausible parent age 30 at child birth)
        // and one contradicted (1895 — implausible parent age 5).
        let supportedYears = graded.compactMap { (draft, result) -> Int? in
            guard result.verdict == .supported else { return nil }
            if case .birthYearCandidate(_, let y) = draft.kind { return y }
            return nil
        }
        let contradictedYears = graded.compactMap { (draft, result) -> Int? in
            guard result.verdict == .contradicted else { return nil }
            if case .birthYearCandidate(_, let y) = draft.kind { return y }
            return nil
        }
        #expect(supportedYears == [1870])
        #expect(contradictedYears == [1895])
    }

    @Test func slice3_flow_emitsNothingWhenNoCompetingCandidates() {
        // The pipeline calls this flow unconditionally per run; it must
        // be a quiet no-op when the subject only has one (or zero)
        // precise candidates. Generator's guard handles it.
        let profile = makeProfile(id: "subj", birthDateSources: [
            birthDateSource("Jun 1870")
        ])
        let state = ResearchState(subject: makeSubject(profileID: "subj"))
        let drafts = HypothesisEngine.generate(
            for: .birthYearCandidate, state: state, snapshot: snapshot(with: profile)
        )
        #expect(drafts.isEmpty)
    }

    @Test func slice3_birthYearCandidateInDiscriminatorAllCases() {
        // Discriminator must include `.birthYearCandidate` so any
        // generator that iterates over `HypothesisKindDiscriminator.allCases`
        // picks up the new kind. Protects against accidental removal.
        #expect(HypothesisKindDiscriminator.allCases.contains(.birthYearCandidate))
    }
}
