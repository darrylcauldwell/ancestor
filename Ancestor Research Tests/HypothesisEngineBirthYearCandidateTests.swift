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
}
