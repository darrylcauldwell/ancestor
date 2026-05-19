import Testing
import Foundation
@testable import Ancestor_Research

/// T12-parent Phase 1 invariants (V2 spec §5.2 / §5.2.1): the legacy
/// `ParentInferenceEngine.infer` + `enrichParentsWithMarriage` paths
/// and the new `.parentInferred` + `.parentMarriage` framework path
/// produce projection-equal surfaces — same parent surnames per
/// gender, same marriage-record evidence cross-referenced onto the
/// parent hypotheses.
///
/// Phase 2 will flip the source of truth; this test file pins the
/// equivalence so the swap doesn't silently drop data.
@MainActor
struct T12ParentPhase1Tests {

    // MARK: - Helpers

    private func birthRecord(
        id: String,
        surname: String,
        givenName: String,
        mmn: String?,
        district: String?,
        year: Int,
        verdict: RecordVerdict = .fact
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd", name: nil,
            surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
        let birth = BirthRecord(
            common: common,
            birthYear: year, birthDate: nil, birthPlace: nil,
            quarter: nil, district: district,
            volume: nil, page: nil,
            mothersMaidenName: mmn
        )
        return ScoredRecord(id: id, record: .birth(birth), verdict: verdict, gates: [], summary: "")
    }

    private func marriageRecord(
        id: String,
        surname: String, givenName: String,
        spouseSurname: String,
        year: Int,
        quarter: String? = "Mar",
        district: String? = "Belper",
        volume: String? = "7B",
        page: String? = "1234"
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd", name: nil,
            surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
        let marriage = MarriageRecord(
            common: common,
            marriageYear: year, marriageDate: nil, marriagePlace: nil,
            quarter: quarter, district: district,
            volume: volume, page: page,
            spouseName: spouseSurname
        )
        return ScoredRecord(id: id, record: .marriage(marriage), verdict: .lead, gates: [], summary: "")
    }

    private func makeSubject(profileID: String, surname: String = "Cauldwell", birthYear: Int = 1976) -> ResearchSubject {
        ResearchSubject(
            profileID: profileID, surname: surname, givenName: nil,
            middleName: nil,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    // MARK: - .parentInferred generator

    @Test func generateParentInferred_emitsOnePerGenderPerMMN() {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth]
        let snapshot = FamilyGraphSnapshot.empty

        let hypotheses = HypothesisEngine.generateParentInferred(state: state, snapshot: snapshot)
        #expect(hypotheses.count == 2)
        let kinds = hypotheses.map(\.kind)
        // Mother (Holmes) and father (Cauldwell) — order isn't pinned.
        let hasMother = kinds.contains { kind in
            if case .parentInferred(.female, let s) = kind, s == "Holmes" { return true }
            return false
        }
        let hasFather = kinds.contains { kind in
            if case .parentInferred(.male, let s) = kind, s == "Cauldwell" { return true }
            return false
        }
        #expect(hasMother)
        #expect(hasFather)
        // Drafts start inconclusive, attempts: 0.
        #expect(hypotheses.allSatisfy { $0.verdict == .inconclusive })
        #expect(hypotheses.allSatisfy { $0.attempts == 0 })
    }

    @Test func generateParentInferred_dedupsAcrossMultipleBirthRecords() {
        // Two birth records carrying the same MMN should produce one
        // .parentInferred(.female, "Holmes") hypothesis, not two.
        let subjectID = "subj"
        let b1 = birthRecord(id: "b1", surname: "Cauldwell", givenName: "Darryl",
                              mmn: "Holmes", district: "Belper", year: 1976)
        let b2 = birthRecord(id: "b2", surname: "Cauldwell", givenName: "Darryl",
                              mmn: "Holmes", district: "Belper", year: 1976,
                              verdict: .lead)
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [b1, b2]

        let hypotheses = HypothesisEngine.generateParentInferred(
            state: state, snapshot: .empty
        )
        // Two unique kinds (mother + father), not four.
        #expect(hypotheses.count == 2)
    }

    @Test func generateParentInferred_emptyWhenNoSubject() {
        var state = ResearchState(subject: ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: nil,
            middleName: nil,
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil, mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY"
        ))
        state.scoredRecords = [birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )]
        let hypotheses = HypothesisEngine.generateParentInferred(
            state: state, snapshot: .empty
        )
        #expect(hypotheses.isEmpty, "no subject profileID = no anchor = no proposals")
    }

    // MARK: - .parentInferred grader

    @Test func gradeParentInferred_supportedWhenMMNMatches() throws {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth]

        let drafts = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)
        let mother = try #require(drafts.first(where: {
            if case .parentInferred(.female, _) = $0.kind { return true }
            return false
        }))
        let result = HypothesisEngine.gradeParentInferred(
            mother, state: state, snapshot: .empty
        )
        #expect(result.verdict == .supported)
        #expect(result.supportingEvidence == ["b1"])
    }

    @Test func gradeParentInferred_inconclusiveWhenNoBirthAttests() throws {
        // Stored hypothesis from a prior run, but state's birth record
        // no longer carries the MMN (e.g. user cleansed it).
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: nil, district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth]
        let kind = HypothesisKind.parentInferred(gender: .female, surname: "Holmes")
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: subjectID),
            subjectProfileID: subjectID, kind: kind,
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "", createdAt: Date(), lastTestedAt: Date(),
            attempts: 0, history: []
        )
        let result = HypothesisEngine.gradeParentInferred(h, state: state, snapshot: .empty)
        #expect(result.verdict == .inconclusive)
        #expect(result.supportingEvidence.isEmpty)
    }

    // MARK: - .parentMarriage generator

    @Test func generateParentMarriage_emitsOnePerMMN() throws {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth]

        let hypotheses = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        #expect(hypotheses.count == 1)
        let h = try #require(hypotheses.first)
        if case .parentMarriage(let mother, let father, let window) = h.kind {
            #expect(mother == "Holmes")
            #expect(father == "Cauldwell")
            #expect(window == (1976 - 30)...(1976 + 1))
        } else {
            Issue.record("expected .parentMarriage kind")
        }
    }

    @Test func generateParentMarriage_emptyWithoutSubjectBirthYear() {
        let subject = ResearchSubject(
            profileID: "subj", surname: "Cauldwell", givenName: nil,
            middleName: nil,
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil, mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY"
        )
        var state = ResearchState(subject: subject)
        state.scoredRecords = [birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )]
        let hypotheses = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        #expect(hypotheses.isEmpty, "no birth year on subject = no window = no .parentMarriage")
    }

    // MARK: - .parentMarriage grader

    @Test func gradeParentMarriage_supportedWhenUniqueMarriageFound() throws {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        // Both sides of the BMD index — groom and bride at the same
        // reference tuple. MarriageEnrichmentEngine reunites them.
        let groomSide = marriageRecord(
            id: "m1-groom", surname: "Cauldwell", givenName: "David",
            spouseSurname: "Holmes", year: 1969
        )
        let brideSide = marriageRecord(
            id: "m1-bride", surname: "Holmes", givenName: "Jennifer",
            spouseSurname: "Cauldwell", year: 1969
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth, groomSide, brideSide]

        let drafts = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeParentMarriage(draft, state: state, snapshot: .empty)
        #expect(result.verdict == .supported)
        #expect(Set(result.supportingEvidence) == ["m1-groom", "m1-bride"])
        #expect(result.reasoning.contains("David"))
        #expect(result.reasoning.contains("Jennifer"))
    }

    @Test func gradeParentMarriage_contradictedWhenNoMarriage() throws {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        // No marriage records in state.
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth]

        let drafts = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeParentMarriage(draft, state: state, snapshot: .empty)
        #expect(result.verdict == .contradicted)
        #expect(result.supportingEvidence.isEmpty)
    }

    // MARK: - Reconciliation cross-references marriage → parent

    @Test func reconcile_crossReferencesMarriageOntoBothParents() throws {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let groomSide = marriageRecord(
            id: "m1-groom", surname: "Cauldwell", givenName: "David",
            spouseSurname: "Holmes", year: 1969
        )
        let brideSide = marriageRecord(
            id: "m1-bride", surname: "Holmes", givenName: "Jennifer",
            spouseSurname: "Cauldwell", year: 1969
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth, groomSide, brideSide]

        // Generate parent + marriage hypotheses, grade them, then reconcile.
        let parentDrafts = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)
        let marriageDrafts = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        let graded: [ResearchHypothesis] = (parentDrafts + marriageDrafts).map { draft in
            let r = HypothesisEngine.grade(draft, state: state, snapshot: .empty)
            return ResearchHypothesis(
                id: draft.id, subjectProfileID: draft.subjectProfileID,
                kind: draft.kind,
                verdict: r.verdict, isModelAssisted: r.isModelAssisted,
                supportingEvidence: r.supportingEvidence,
                contradictingEvidence: r.contradictingEvidence,
                reasoning: r.reasoning,
                createdAt: draft.createdAt, lastTestedAt: Date(),
                attempts: 1, history: []
            )
        }
        let reconciled = HypothesisEngine.reconcileParentMarriages(hypotheses: graded)

        // Mother (.parentInferred(.female, Holmes)) and father
        // (.parentInferred(.male, Cauldwell)) both now carry the
        // marriage record IDs in supportingEvidence.
        let mother = try #require(reconciled.first {
            if case .parentInferred(.female, "Holmes") = $0.kind { return true }
            return false
        })
        let father = try #require(reconciled.first {
            if case .parentInferred(.male, "Cauldwell") = $0.kind { return true }
            return false
        })
        #expect(mother.supportingEvidence.contains("b1"))
        #expect(mother.supportingEvidence.contains("m1-groom") || mother.supportingEvidence.contains("m1-bride"))
        #expect(father.supportingEvidence.contains("b1"))
        #expect(father.supportingEvidence.contains("m1-groom") || father.supportingEvidence.contains("m1-bride"))
        // Reasoning gains the cross-ref marker.
        #expect(mother.reasoning.contains("cross-ref"))
        #expect(father.reasoning.contains("cross-ref"))
    }

    @Test func reconcile_isIdempotent() throws {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let groomSide = marriageRecord(
            id: "m1-groom", surname: "Cauldwell", givenName: "David",
            spouseSurname: "Holmes", year: 1969
        )
        let brideSide = marriageRecord(
            id: "m1-bride", surname: "Holmes", givenName: "Jennifer",
            spouseSurname: "Cauldwell", year: 1969
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth, groomSide, brideSide]

        let parentDrafts = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)
        let marriageDrafts = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        let graded: [ResearchHypothesis] = (parentDrafts + marriageDrafts).map { draft in
            let r = HypothesisEngine.grade(draft, state: state, snapshot: .empty)
            return ResearchHypothesis(
                id: draft.id, subjectProfileID: draft.subjectProfileID,
                kind: draft.kind,
                verdict: r.verdict, isModelAssisted: r.isModelAssisted,
                supportingEvidence: r.supportingEvidence,
                contradictingEvidence: r.contradictingEvidence,
                reasoning: r.reasoning,
                createdAt: draft.createdAt, lastTestedAt: Date(),
                attempts: 1, history: []
            )
        }
        let once = HypothesisEngine.reconcileParentMarriages(hypotheses: graded)
        let twice = HypothesisEngine.reconcileParentMarriages(hypotheses: once)
        // Same supportingEvidence sets after a second pass — no duplication.
        for (a, b) in zip(once, twice) {
            #expect(a.supportingEvidence == b.supportingEvidence)
            #expect(a.reasoning == b.reasoning)
        }
    }

    // MARK: - Identity-key stability

    @Test func parentInferred_identityKey_stableAcrossRuns() {
        let kind1 = HypothesisKind.parentInferred(gender: .female, surname: "Holmes")
        let kind2 = HypothesisKind.parentInferred(gender: .female, surname: "Holmes")
        #expect(kind1.identityKey(subjectProfileID: "subj") == kind2.identityKey(subjectProfileID: "subj"))
    }

    @Test func parentInferred_identityKey_caseNormalised() {
        let kind1 = HypothesisKind.parentInferred(gender: .female, surname: "holmes")
        let kind2 = HypothesisKind.parentInferred(gender: .female, surname: "HOLMES")
        #expect(kind1.identityKey(subjectProfileID: "subj") == kind2.identityKey(subjectProfileID: "subj"))
    }

    @Test func parentInferred_identityKey_distinctByGender() {
        let mother = HypothesisKind.parentInferred(gender: .female, surname: "Holmes")
        let father = HypothesisKind.parentInferred(gender: .male, surname: "Holmes")
        #expect(mother.identityKey(subjectProfileID: "subj") != father.identityKey(subjectProfileID: "subj"))
    }

    // MARK: - Phase 1 invariant: legacy + framework agree

    @Test func phase1_legacyProposalsAndHypotheses_carryIdenticalSurnames() {
        // V2 spec §5.2 Phase 1 cross-phase regression: per-profile
        // output exhibits projection-equality on the legacy field's
        // shape. Same MMN + subject-surname pair → legacy emits two
        // ProposedRelatives (mother + father), framework emits two
        // .parentInferred hypotheses with the same surnames.
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )

        // Legacy path (subset of ResearchPipeline.research's iteration loop).
        let legacy = ParentInferenceEngine.infer(
            from: [birth],
            subject: makeSubject(profileID: subjectID),
            existingParents: [],
            sourceInfoMap: ["freebmd": SourceInfo(
                sourceID: "freebmd",
                lineage: .independentTranscription(of: "GRO"),
                trustTier: .transcription,
                directness: .directTranscription
            )]
        )

        // Framework path.
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth]
        let framework = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)

        // Surname × gender sets must match between the two surfaces.
        struct PG: Hashable { let gender: Gender?; let surname: String }
        let legacySet: Set<PG> = Set(legacy.map { PG(gender: $0.gender, surname: ($0.proposedSurname ?? "").uppercased()) })
        let frameworkSet: Set<PG> = Set(framework.compactMap { h -> PG? in
            guard case .parentInferred(let g, let s) = h.kind else { return nil }
            return PG(gender: g, surname: s.uppercased())
        })
        #expect(legacySet == frameworkSet)
    }

    // MARK: - Phase 2 — projection from hypothesis to ProposedRelative

    @Test func projection_supportedParentInferred_producesProposal() throws {
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth]

        let parentDrafts = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)
        let mother = try #require(parentDrafts.first {
            if case .parentInferred(.female, _) = $0.kind { return true }
            return false
        })
        let result = HypothesisEngine.gradeParentInferred(mother, state: state, snapshot: .empty)
        let graded = ResearchHypothesis(
            id: mother.id, subjectProfileID: mother.subjectProfileID,
            kind: mother.kind,
            verdict: result.verdict, isModelAssisted: result.isModelAssisted,
            supportingEvidence: result.supportingEvidence,
            contradictingEvidence: result.contradictingEvidence,
            reasoning: result.reasoning,
            createdAt: mother.createdAt, lastTestedAt: Date(),
            attempts: 1, history: []
        )
        let proposal = try #require(ResearchPipeline.projectParentInferredToProposal(
            hypothesis: graded,
            allHypotheses: [graded],
            scoredRecords: state.scoredRecords,
            subject: makeSubject(profileID: subjectID)
        ))
        #expect(proposal.proposedSurname == "Holmes")
        #expect(proposal.gender == .female)
        #expect(proposal.proposedGivenName == nil, "no marriage evidence → no given name")
        // parent age band: subject 1976 → 1931...1958
        #expect(proposal.birthYearLow == 1931)
        #expect(proposal.birthYearHigh == 1958)
        if case .parentOf(let id) = proposal.relationship {
            #expect(id == subjectID)
        } else {
            Issue.record("relationship should be .parentOf(subjectID)")
        }
        #expect(proposal.evidence.map(\.id) == ["b1"])
        #expect(proposal.ambiguousMarriages.isEmpty)
    }

    @Test func projection_extractsGivenNameFromCrossReferencedMarriage() throws {
        // Reconciliation appends marriage record IDs to .parentInferred
        // supportingEvidence; projection pulls the given name from the
        // matching marriage record.
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let groomSide = marriageRecord(
            id: "m1-groom", surname: "Cauldwell", givenName: "David",
            spouseSurname: "Holmes", year: 1969
        )
        let brideSide = marriageRecord(
            id: "m1-bride", surname: "Holmes", givenName: "Jennifer",
            spouseSurname: "Cauldwell", year: 1969
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth, groomSide, brideSide]

        let parentDrafts = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)
        let marriageDrafts = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        let graded: [ResearchHypothesis] = (parentDrafts + marriageDrafts).map { draft in
            let r = HypothesisEngine.grade(draft, state: state, snapshot: .empty)
            return ResearchHypothesis(
                id: draft.id, subjectProfileID: draft.subjectProfileID,
                kind: draft.kind,
                verdict: r.verdict, isModelAssisted: r.isModelAssisted,
                supportingEvidence: r.supportingEvidence,
                contradictingEvidence: r.contradictingEvidence,
                reasoning: r.reasoning,
                createdAt: draft.createdAt, lastTestedAt: Date(),
                attempts: 1, history: []
            )
        }
        let reconciled = HypothesisEngine.reconcileParentMarriages(hypotheses: graded)
        let subject = makeSubject(profileID: subjectID)
        let proposals = reconciled.compactMap { h in
            ResearchPipeline.projectParentInferredToProposal(
                hypothesis: h,
                allHypotheses: reconciled,
                scoredRecords: state.scoredRecords,
                subject: subject
            )
        }
        #expect(proposals.count == 2)
        let mother = try #require(proposals.first { $0.gender == .female })
        let father = try #require(proposals.first { $0.gender == .male })
        #expect(mother.proposedGivenName == "Jennifer")
        #expect(father.proposedGivenName == "David")
    }

    @Test func projection_threadsAmbiguousMarriagesFromInconclusive() throws {
        // Two marriages match the surname pair → .parentMarriage grades
        // as .inconclusive (ambiguous), and supportingEvidence lists
        // both candidates. Projection threads those onto the parent
        // proposals' ambiguousMarriages.
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        // Two marriages with the same surname pair but different reference tuples
        let m1Groom = marriageRecord(
            id: "m1-groom", surname: "Cauldwell", givenName: "David",
            spouseSurname: "Holmes", year: 1969,
            volume: "7B", page: "1234"
        )
        let m1Bride = marriageRecord(
            id: "m1-bride", surname: "Holmes", givenName: "Jennifer",
            spouseSurname: "Cauldwell", year: 1969,
            volume: "7B", page: "1234"
        )
        let m2Groom = marriageRecord(
            id: "m2-groom", surname: "Cauldwell", givenName: "Albert",
            spouseSurname: "Holmes", year: 1962,
            volume: "9A", page: "5678"
        )
        let m2Bride = marriageRecord(
            id: "m2-bride", surname: "Holmes", givenName: "Mary",
            spouseSurname: "Cauldwell", year: 1962,
            volume: "9A", page: "5678"
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth, m1Groom, m1Bride, m2Groom, m2Bride]

        let parentDrafts = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)
        let marriageDrafts = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        let graded: [ResearchHypothesis] = (parentDrafts + marriageDrafts).map { draft in
            let r = HypothesisEngine.grade(draft, state: state, snapshot: .empty)
            return ResearchHypothesis(
                id: draft.id, subjectProfileID: draft.subjectProfileID,
                kind: draft.kind,
                verdict: r.verdict, isModelAssisted: r.isModelAssisted,
                supportingEvidence: r.supportingEvidence,
                contradictingEvidence: r.contradictingEvidence,
                reasoning: r.reasoning,
                createdAt: draft.createdAt, lastTestedAt: Date(),
                attempts: 1, history: []
            )
        }
        // The .parentMarriage should be .inconclusive with 2 candidate
        // marriages (the matcher dedupes by BMD reference tuple, so two
        // distinct marriages → two candidates, not four sides).
        let marriage = try #require(graded.first {
            if case .parentMarriage = $0.kind { return true }
            return false
        })
        #expect(marriage.verdict == .inconclusive)
        #expect(marriage.supportingEvidence.count == 2)

        let reconciled = HypothesisEngine.reconcileParentMarriages(hypotheses: graded)
        let subject = makeSubject(profileID: subjectID)
        let mother = try #require(reconciled.compactMap { h in
            ResearchPipeline.projectParentInferredToProposal(
                hypothesis: h, allHypotheses: reconciled,
                scoredRecords: state.scoredRecords, subject: subject
            )
        }.first { $0.gender == .female })
        // Two distinct marriages threaded through to the proposal.
        #expect(mother.ambiguousMarriages.count == 2)
        #expect(mother.proposedGivenName == nil, "ambiguous → no given name committed")
    }

    // MARK: - Phase 3 — UI reads from result.hypotheses

    @Test func phase3_uiPath_projectsFromHypotheses_matchesPipelinePopulatedField() throws {
        // The UI now derives its parent list by filtering
        // `result.hypotheses` for `.parentInferred` /
        // `isDeterministicallySupported` and projecting through the
        // pipeline helper. This must produce the same list as the
        // pipeline's own `result.proposedRelatives` projection — both
        // call sites feed the same helper. If they diverge, the
        // source-of-truth swap dropped data in translation.
        let subjectID = "subj"
        let birth = birthRecord(
            id: "b1", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let groomSide = marriageRecord(
            id: "m1-groom", surname: "Cauldwell", givenName: "David",
            spouseSurname: "Holmes", year: 1969
        )
        let brideSide = marriageRecord(
            id: "m1-bride", surname: "Holmes", givenName: "Jennifer",
            spouseSurname: "Cauldwell", year: 1969
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [birth, groomSide, brideSide]

        let parentDrafts = HypothesisEngine.generateParentInferred(state: state, snapshot: .empty)
        let marriageDrafts = HypothesisEngine.generateParentMarriage(state: state, snapshot: .empty)
        let graded: [ResearchHypothesis] = (parentDrafts + marriageDrafts).map { draft in
            let r = HypothesisEngine.grade(draft, state: state, snapshot: .empty)
            return ResearchHypothesis(
                id: draft.id, subjectProfileID: draft.subjectProfileID,
                kind: draft.kind,
                verdict: r.verdict, isModelAssisted: r.isModelAssisted,
                supportingEvidence: r.supportingEvidence,
                contradictingEvidence: r.contradictingEvidence,
                reasoning: r.reasoning,
                createdAt: draft.createdAt, lastTestedAt: Date(),
                attempts: 1, history: []
            )
        }
        let reconciled = HypothesisEngine.reconcileParentMarriages(hypotheses: graded)
        let subject = makeSubject(profileID: subjectID)

        // Pipeline path: projection done at result-construction time.
        let pipelineProposals = reconciled.compactMap { h in
            ResearchPipeline.projectParentInferredToProposal(
                hypothesis: h,
                allHypotheses: reconciled,
                scoredRecords: state.scoredRecords,
                subject: subject
            )
        }

        // Assemble ResearchResult (no proposedRelatives field — Phase 4
        // deleted it). The UI-side filter+project chain mirrors
        // `ResearchViewModel.visibleProposedRelatives`.
        let result = ResearchResult(
            confirmedFacts: [birth],
            leads: [groomSide, brideSide],
            allScoredRecords: state.scoredRecords,
            clusters: [],
            discrepancies: [],
            householdMembers: [],
            searchHistory: [],
            hypotheses: reconciled
        )
        let uiProposals = result.hypotheses
            .filter { h in
                guard case .parentInferred = h.kind else { return false }
                return h.isDeterministicallySupported
            }
            .compactMap { h in
                ResearchPipeline.projectParentInferredToProposal(
                    hypothesis: h,
                    allHypotheses: result.hypotheses,
                    scoredRecords: result.allScoredRecords,
                    subject: subject
                )
            }
        // The UI projection must agree with the projection the pipeline
        // would have produced (`pipelineProposals` above) at result-
        // construction time. Phase 4 removed the field; the equivalence
        // is now asserted directly between the two projection call
        // sites with the same inputs.
        #expect(Set(uiProposals.map(\.id)) == Set(pipelineProposals.map(\.id)))
        #expect(Set(uiProposals.compactMap(\.proposedGivenName)) ==
                Set(pipelineProposals.compactMap(\.proposedGivenName)))
    }
}
