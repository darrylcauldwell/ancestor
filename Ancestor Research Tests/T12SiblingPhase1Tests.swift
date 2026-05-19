import Testing
import Foundation
@testable import Ancestor_Research

/// T12-sibling Phase 2 invariants (V2 spec §5.2). The `.siblingExists`
/// framework path is now the sole source of truth: `HypothesisEngine`
/// generates the hypothesis, the orchestrator dispatches the level-1
/// deficit query, `gradeSiblingExists` grades it, and the projection
/// helper rebuilds the legacy `SiblingProposal` list from the supported
/// hypothesis. The Phase 1 file name is preserved so the cross-phase
/// invariant (supportingEvidence ↔ proposal candidateRecordIDs) keeps
/// the same regression-test home through the four-phase migration.
@MainActor
struct T12SiblingPhase1Tests {

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
            id: id,
            sourceID: "freebmd",
            name: nil,
            surname: surname,
            givenName: givenName,
            detailURL: nil,
            rawFields: [:]
        )
        let birth = BirthRecord(
            common: common,
            birthYear: year,
            birthDate: nil,
            birthPlace: nil,
            quarter: nil,
            district: district,
            volume: nil,
            page: nil,
            mothersMaidenName: mmn
        )
        return ScoredRecord(id: id, record: .birth(birth), verdict: verdict, gates: [], summary: "")
    }

    private func makeProfile(id: String, gender: Gender) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: nil, lastName: nil, gender: gender,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    private func makeSubject(profileID: String) -> ResearchSubject {
        ResearchSubject(
            profileID: profileID, surname: "Cauldwell", givenName: nil,
            middleName: nil,
            birthYearFrom: 1976, birthYearTo: 1976,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    /// Snapshot with subject + father + mother and the two parent edges.
    /// Mirrors the precondition the engine checks (`parentsOf(subject)`
    /// must return both genders).
    private func snapshotWithParents(subjectID: String, fatherID: String, motherID: String) -> FamilyGraphSnapshot {
        let subject = makeProfile(id: subjectID, gender: .male)
        let father = makeProfile(id: fatherID, gender: .male)
        let mother = makeProfile(id: motherID, gender: .female)
        let fatherRel = Relationship(
            id: UUID(), from: fatherID, to: subjectID,
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let motherRel = Relationship(
            id: UUID(), from: motherID, to: subjectID,
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        return FamilyGraphSnapshot(
            profiles: [subjectID: subject, fatherID: father, motherID: mother],
            relationships: [fatherRel, motherRel]
        )
    }

    // MARK: - generateSiblingExists

    @Test func generate_emitsHypothesisWhenPreconditionsMet() {
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord]
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")

        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        #expect(drafts.count == 1)
        let h = drafts[0]
        #expect(h.verdict == .inconclusive)
        #expect(h.attempts == 0)
        #expect(h.supportingEvidence.isEmpty)
        if case .siblingExists(let district, let mmn, let window) = h.kind {
            #expect(district == "Belper")
            #expect(mmn == "Holmes")
            #expect(window == 1956...1996)
        } else {
            Issue.record("hypothesis kind should be .siblingExists")
        }
    }

    @Test func generate_returnsEmptyWhenParentsNotLinked() {
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord]
        // Empty snapshot — no parents linked.
        let snapshot = FamilyGraphSnapshot(profiles: [:], relationships: [])

        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        #expect(drafts.isEmpty)
    }

    @Test func generate_stableIdAcrossRuns() {
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord]
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")

        let first = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let second = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        #expect(first.count == 1 && second.count == 1)
        // Stable ID = re-runs upsert rather than duplicate (Decision 1).
        #expect(first[0].id == second[0].id)
    }

    // MARK: - gradeSiblingExists

    @Test func grade_supportedWhenCandidateMatches() throws {
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let sisterRecord = birthRecord(
            id: "sister-birth", surname: "Cauldwell", givenName: "Sarah",
            mmn: "Holmes", district: "Belper", year: 1978,
            verdict: .lead   // candidate from sibling dispatch, not a fact
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord, sisterRecord]
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")

        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeSiblingExists(draft, state: state, snapshot: snapshot)
        #expect(result.verdict == .supported)
        #expect(result.supportingEvidence == ["sister-birth"])
        #expect(result.contradictingEvidence.isEmpty)
    }

    @Test func grade_contradictedWhenNoCandidateMatches() throws {
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord]   // no sibling candidates
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")

        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeSiblingExists(draft, state: state, snapshot: snapshot)
        #expect(result.verdict == .contradicted)
        #expect(result.supportingEvidence.isEmpty)
        #expect(result.reasoning.contains("0 matching candidates"))
    }

    // MARK: - Cross-phase regression invariant

    @Test func projection_candidateIDsMatchSupportingEvidence() throws {
        // The bisectable-commit invariant: after the engine runs end-to-end,
        // projection of the supported hypothesis must produce SiblingProposals
        // whose candidateRecordIDs exactly equal the hypothesis's
        // supportingEvidence. Phase 1 asserted this across two parallel paths;
        // Phase 2 asserts it across the single source-of-truth path.
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let sister1 = birthRecord(
            id: "sister-1", surname: "Cauldwell", givenName: "Sarah",
            mmn: "Holmes", district: "Belper", year: 1978,
            verdict: .lead
        )
        let sister2 = birthRecord(
            id: "sister-2", surname: "Cauldwell", givenName: "Mary",
            mmn: "Holmes", district: "Belper", year: 1970,
            verdict: .lead
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord, sister1, sister2]
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")

        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeSiblingExists(draft, state: state, snapshot: snapshot)
        let graded = ResearchHypothesis(
            id: draft.id, subjectProfileID: draft.subjectProfileID, kind: draft.kind,
            verdict: result.verdict, isModelAssisted: result.isModelAssisted,
            supportingEvidence: result.supportingEvidence,
            contradictingEvidence: result.contradictingEvidence,
            reasoning: result.reasoning,
            createdAt: draft.createdAt, lastTestedAt: Date(),
            attempts: 1, history: []
        )
        #expect(graded.isDeterministicallySupported)

        let proposals = ResearchPipeline.projectSiblingExistsToProposals(
            hypothesis: graded,
            scoredRecords: state.scoredRecords,
            snapshot: snapshot
        )
        #expect(Set(proposals.map(\.candidateRecordID)) == Set(graded.supportingEvidence))
        // Father / mother edges thread through from snapshot.
        #expect(proposals.allSatisfy { $0.fatherID == "father-id" })
        #expect(proposals.allSatisfy { $0.motherID == "mother-id" })
    }

    // MARK: - Phase 3 / 4 — UI reads from result.hypotheses

    @Test func uiPath_projectsFromHypotheses_producesExpectedProposals() throws {
        // Phase 3 swapped the UI to derive its sibling list by filtering
        // `result.hypotheses` for `.siblingExists` /
        // `isDeterministicallySupported` and projecting through the
        // pipeline helper. Phase 4 deleted the legacy
        // `result.proposedSiblings` mirror; this test pins the UI path
        // as the only surface, asserting it produces the expected
        // candidate set (id stability, father / mother edges threaded
        // through from snapshot, ordering preserved from
        // `supportingEvidence`).
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let sister1 = birthRecord(
            id: "sister-1", surname: "Cauldwell", givenName: "Sarah",
            mmn: "Holmes", district: "Belper", year: 1978,
            verdict: .lead
        )
        let sister2 = birthRecord(
            id: "sister-2", surname: "Cauldwell", givenName: "Mary",
            mmn: "Holmes", district: "Belper", year: 1970,
            verdict: .lead
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord, sister1, sister2]
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")

        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let draft = try #require(drafts.first)
        let gradeResult = HypothesisEngine.gradeSiblingExists(draft, state: state, snapshot: snapshot)
        let graded = ResearchHypothesis(
            id: draft.id, subjectProfileID: draft.subjectProfileID, kind: draft.kind,
            verdict: gradeResult.verdict, isModelAssisted: gradeResult.isModelAssisted,
            supportingEvidence: gradeResult.supportingEvidence,
            contradictingEvidence: gradeResult.contradictingEvidence,
            reasoning: gradeResult.reasoning,
            createdAt: draft.createdAt, lastTestedAt: Date(),
            attempts: 1, history: []
        )

        // Phase 4: no `proposedSiblings` field; the engine's hypothesis
        // list IS the surface.
        let result = ResearchResult(
            confirmedFacts: [subjectRecord],
            leads: [sister1, sister2],
            allScoredRecords: state.scoredRecords,
            clusters: [],
            discrepancies: [],
            householdMembers: [],
            searchHistory: [],
            hypotheses: [graded]
        )

        // Run the UI path directly on `result` — mirrors
        // `ResearchViewModel.visibleSiblings(snapshot:)` without the
        // rejection-store side trip (that's tested separately).
        let uiProposals = result.hypotheses
            .filter { h in
                guard case .siblingExists = h.kind else { return false }
                return h.isDeterministicallySupported
            }
            .flatMap { h in
                ResearchPipeline.projectSiblingExistsToProposals(
                    hypothesis: h,
                    scoredRecords: result.allScoredRecords,
                    snapshot: snapshot
                )
            }
        // Both sisters surface, ordered to match the hypothesis's
        // supportingEvidence (which `SiblingInferenceEngine` ordered by
        // birth year ascending → sister2 1970 before sister1 1978).
        #expect(uiProposals.map(\.candidateRecordID) == graded.supportingEvidence)
        #expect(uiProposals.allSatisfy { $0.fatherID == "father-id" })
        #expect(uiProposals.allSatisfy { $0.motherID == "mother-id" })
        // Proposal ids are stable across the candidateRecordID — Phase 1's
        // accept-flow invariant survives the migration.
        #expect(uiProposals.map(\.id) == uiProposals.map { "siblingOf:father-id:\($0.candidateRecordID)" })
    }

    @Test func uiPath_skipsContradictedAndInconclusiveHypotheses() throws {
        // Only `.supported` + `!isModelAssisted` hypotheses contribute
        // to the UI list — contradicted ones surface in §5.11's archive
        // view, not the proposed-siblings section. This pins the filter.
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord]   // no candidates
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")

        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let draft = try #require(drafts.first)
        let gradeResult = HypothesisEngine.gradeSiblingExists(draft, state: state, snapshot: snapshot)
        #expect(gradeResult.verdict == .contradicted, "test setup requires contradicted grading")
        let contradicted = ResearchHypothesis(
            id: draft.id, subjectProfileID: draft.subjectProfileID, kind: draft.kind,
            verdict: gradeResult.verdict, isModelAssisted: gradeResult.isModelAssisted,
            supportingEvidence: gradeResult.supportingEvidence,
            contradictingEvidence: gradeResult.contradictingEvidence,
            reasoning: gradeResult.reasoning,
            createdAt: draft.createdAt, lastTestedAt: Date(),
            attempts: 1, history: []
        )
        let uiProposals = [contradicted]
            .filter { h in
                guard case .siblingExists = h.kind else { return false }
                return h.isDeterministicallySupported
            }
            .flatMap { h in
                ResearchPipeline.projectSiblingExistsToProposals(
                    hypothesis: h,
                    scoredRecords: state.scoredRecords,
                    snapshot: snapshot
                )
            }
        #expect(uiProposals.isEmpty)
    }

    // MARK: - deficitQuerySiblingExists (Phase 1 — unchanged in Phase 2)

    @Test func deficitQuery_level1_returnsFreeBMDQuery() throws {
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord]
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")
        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let h = try #require(drafts.first)

        let query = HypothesisEngine.deficitQuerySiblingExists(
            for: h, atLevel: 1, state: state
        )
        let unwrapped = try #require(query)
        #expect(unwrapped.surname == "Cauldwell")
        #expect(unwrapped.givenName == nil)
        #expect(unwrapped.recordType == .birth)
        #expect(unwrapped.yearFrom == 1956)
        #expect(unwrapped.yearTo == 1996)
    }

    @Test func deficitQuery_level2_returnsNil_inPhase2() throws {
        let subjectID = "subj-profile"
        let subjectRecord = birthRecord(
            id: "subj-birth", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        var state = ResearchState(subject: makeSubject(profileID: subjectID))
        state.scoredRecords = [subjectRecord]
        let snapshot = snapshotWithParents(subjectID: subjectID, fatherID: "father-id", motherID: "mother-id")
        let drafts = HypothesisEngine.generateSiblingExists(state: state, snapshot: snapshot)
        let h = try #require(drafts.first)

        let query = HypothesisEngine.deficitQuerySiblingExists(
            for: h, atLevel: 2, state: state
        )
        #expect(query == nil, "Phase 2 ladder ceiling is level 1; ≥2 is exhausted")
    }

    @Test func deficitQuery_returnsNil_whenSubjectSurnameMissing() {
        // Hand-construct a hypothesis directly — the generator would refuse
        // to emit one without a resolvable subject, so we can't get there
        // through the normal flow. Surname-on-state is the deficit-query
        // side's separate gate (the legacy `findSiblings` path checked it
        // independently of the resolver).
        let kind = HypothesisKind.siblingExists(
            district: "Belper", mmn: "Holmes", yearWindow: 1956...1996
        )
        let now = Date()
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "subj-profile"),
            subjectProfileID: "subj-profile", kind: kind,
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "", createdAt: now, lastTestedAt: now,
            attempts: 0, history: []
        )
        let subject = ResearchSubject(
            profileID: "subj-profile", surname: nil, givenName: nil,
            middleName: nil,
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
        let state = ResearchState(subject: subject)
        let query = HypothesisEngine.deficitQuerySiblingExists(
            for: h, atLevel: 1, state: state
        )
        #expect(query == nil, "no surname on subject = no query to dispatch")
    }
}
