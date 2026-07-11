import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// RESEARCH_PIPELINE_SPEC §5.15 Slice 2 — probe generation (§5.15.3
/// per-kind deficit ladder), grading (§5.15.4, Decision E5: supported
/// REQUIRES the linkage chain back to the subject — a marriage match
/// ALONE stays inconclusive), the T7 stall-gate carve-out (Decision E4:
/// one unconditional level-1 dispatch for user-origin rows), and
/// rejection-memory honouring (§5.15.6).
///
/// Follows the T12ParentPhase1Tests / T7SecondPassTests idiom: the
/// pipeline orchestrator needs a live dispatcher, so the ladder /
/// grading / carve-out predicates are pinned through the engine's and
/// pipeline's static surfaces.
@MainActor
struct ParentCandidatesSlice2Tests {

    // MARK: - Fixtures

    private func makeSubject(
        profileID: String? = "subj",
        surname: String? = "Wheeldon",
        givenName: String? = "George",
        birthYear: Int? = 1887,
        chapman: String = "DBY"
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: profileID, surname: surname, givenName: givenName,
            middleName: nil,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: chapman
        )
    }

    private func makeState(subject: ResearchSubject? = nil) -> ResearchState {
        ResearchState(subject: subject ?? makeSubject())
    }

    private func parentCandidatesKind(
        fatherGiven: String? = "Bob",
        fatherSurname: String? = nil,
        motherGiven: String? = "Sue",
        motherMaidenSurname: String? = "Land",
        window: ClosedRange<Int> = 1857...1888
    ) -> HypothesisKind {
        .parentCandidates(
            fatherGiven: fatherGiven,
            fatherSurname: fatherSurname,
            motherGiven: motherGiven,
            motherMaidenSurname: motherMaidenSurname,
            marriageWindow: window
        )
    }

    private func makeHypothesis(
        kind: HypothesisKind,
        subjectProfileID: String? = "subj",
        origin: ResearchHypothesis.Origin = .user,
        verdict: ResearchHypothesis.Verdict = .inconclusive,
        attempts: Int = 0
    ) -> ResearchHypothesis {
        ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: subjectProfileID),
            subjectProfileID: subjectProfileID,
            kind: kind,
            origin: origin,
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

    private func marriageRecord(
        id: String,
        surname: String, givenName: String,
        spouseSurname: String?,
        year: Int,
        quarter: String? = "Jun",
        district: String? = "Belper",
        volume: String? = "7B",
        page: String? = "1397"
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

    private func birthRecord(
        id: String,
        surname: String = "Wheeldon",
        givenName: String = "George",
        mmn: String?,
        district: String? = "Belper",
        year: Int = 1887,
        verdict: RecordVerdict = .lead
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

    private func censusRecord(
        id: String,
        censusYear: Int = 1891,
        household: [HouseholdMember]
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freecen", name: nil,
            surname: "Wheeldon", givenName: "George",
            detailURL: nil, rawFields: [:]
        )
        let census = CensusRecord(
            common: common,
            censusYear: censusYear,
            age: censusYear - 1887,
            birthYear: 1887,
            birthPlace: "Belper",
            birthCounty: "DBY",
            relationship: "Son",
            occupation: nil,
            address: nil, parish: nil, district: "Belper",
            household: household
        )
        return ScoredRecord(id: id, record: .census(census), verdict: .lead, gates: [], summary: "")
    }

    // MARK: - §5.15.3 probe shapes — level 1 (marriage-window probe)

    @Test func deficitLevel1_marriageProbe_hintedSurnamesWindowAndSpouseAxis() throws {
        let kind = parentCandidatesKind(
            fatherSurname: "Wheeldon", motherMaidenSurname: "Land",
            window: 1857...1888
        )
        let h = makeHypothesis(kind: kind)
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 1, state: makeState())
        let q = try #require(queries.first)
        #expect(queries.count == 1, "one fan-out template — district fan-out is the orchestrator's job (storm guards unchanged)")
        #expect(q.recordType == .marriage)
        #expect(q.surname == "Wheeldon")
        #expect(q.yearFrom == 1857)
        #expect(q.yearTo == 1888)
        #expect(q.givenName == nil, "given-name hint must NOT go on the wire — a literal fatherGiven=Bob filter would exclude the Robert registrations the nickname machinery matches client-side")
        guard case .freeBMD(let params) = q.sourceParams else {
            Issue.record("expected FreeBMD params")
            return
        }
        #expect(params.districtCode == "", "empty district → orchestrator fans out across scope")
        #expect(params.spouseSurname == "Land")
    }

    @Test func deficitLevel1_groomSurnameFallsBackToSubjectSurname() throws {
        // §5.15.1 payload semantics: effective groom surname =
        // fatherSurname ?? subject.lastName (paternal-naming convention).
        let kind = parentCandidatesKind(fatherSurname: nil, motherMaidenSurname: nil)
        let h = makeHypothesis(kind: kind)
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 1, state: makeState())
        let q = try #require(queries.first)
        #expect(q.surname == "Wheeldon")
        guard case .freeBMD(let params) = q.sourceParams else {
            Issue.record("expected FreeBMD params")
            return
        }
        #expect(params.spouseSurname == nil, "unknown maiden surname → groom-side-only probe; bride recovered at grading")
    }

    @Test func deficitLevel1_emptyWhenNoGroomSurnameDerivable() {
        let kind = parentCandidatesKind(fatherSurname: nil)
        let h = makeHypothesis(kind: kind)
        let state = makeState(subject: makeSubject(surname: nil))
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 1, state: state)
        #expect(queries.isEmpty, "no fatherSurname hint and no subject surname → no probe derivable")
    }

    // MARK: - §5.15.3 probe shapes — level 2 (MMN birth-index axis)

    @Test func deficitLevel2_mmnAxisFromHint() throws {
        let kind = parentCandidatesKind(motherMaidenSurname: "Land")
        let h = makeHypothesis(kind: kind)
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 2, state: makeState())
        let q = try #require(queries.first)
        #expect(q.recordType == .birth, "level 2 rides the §11.4 .birth focus shape — the SUBJECT's own birth-index search")
        #expect(q.surname == "Wheeldon")
        #expect(q.givenName == "George")
        #expect(q.yearFrom == 1887)
        #expect(q.yearTo == 1887)
        guard case .freeBMD(let params) = q.sourceParams else {
            Issue.record("expected FreeBMD params")
            return
        }
        #expect(params.motherSurname == "Land", "the MMN axis is the probe that turns 'the couple existed' into 'the couple are the subject's parents'")
        #expect(q.motherSurname == "Land")
    }

    @Test func deficitLevel2_mmnRecoveredFromLevelOneUniqueMatch() throws {
        // Maiden surname NOT hinted — level 1 found a unique groom-side
        // marriage whose post-1912-style spouse column carries "Land";
        // level 2 anchors the MMN axis on the recovered value.
        let kind = parentCandidatesKind(motherMaidenSurname: nil)
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [marriageRecord(
            id: "m-groom", surname: "Wheeldon", givenName: "Robert",
            spouseSurname: "Land", year: 1885
        )]
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 2, state: state)
        let q = try #require(queries.first)
        guard case .freeBMD(let params) = q.sourceParams else {
            Issue.record("expected FreeBMD params")
            return
        }
        #expect(params.motherSurname == "Land")
    }

    @Test func deficitLevel2_emptyWithoutAnyMMNAnchor() {
        // No hint and no level-1 match in state → the axis is
        // unanchorable; the level yields nothing.
        let kind = parentCandidatesKind(motherMaidenSurname: nil)
        let h = makeHypothesis(kind: kind)
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 2, state: makeState())
        #expect(queries.isEmpty)
    }

    // MARK: - §5.15.3 probe shapes — level 3 (census household)

    @Test func deficitLevel3_censusYearsWhereSubjectAged0to15() throws {
        // Subject born 1887 → aged 0–15 at the 1891 and 1901
        // enumerations; 1911 (aged 24) is out.
        let kind = parentCandidatesKind()
        let h = makeHypothesis(kind: kind)
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 3, state: makeState())
        #expect(queries.map(\.yearFrom) == [1891, 1901])
        let q = try #require(queries.first)
        #expect(q.recordType == .census)
        #expect(q.surname == "Wheeldon")
        guard case .freeCen(let params) = q.sourceParams else {
            Issue.record("expected FreeCen params")
            return
        }
        #expect(params.chapmanCode == "DBY")
        #expect(params.censusYear == 1891)
        let tolerance = ScoringRules.censusAgeTolerance
        #expect(params.birthYearRange == (1887 - tolerance)...(1887 + tolerance))
    }

    @Test func deficitLevel3_emptyWithoutSubjectBirthEstimate() {
        let kind = parentCandidatesKind()
        let h = makeHypothesis(kind: kind)
        let state = makeState(subject: makeSubject(birthYear: nil))
        #expect(HypothesisEngine.deficitQuery(for: h, atLevel: 3, state: state).isEmpty)
    }

    @Test func deficitLevel4_ladderExhausted() {
        // Level ≥ 4 → [] — exhausted; archive per §5.11 (AC 10: a row
        // reaches this with attempts == 3 after levels 1–3 dispatched).
        let kind = parentCandidatesKind()
        let h = makeHypothesis(kind: kind, attempts: 3)
        #expect(HypothesisEngine.deficitQuery(for: h, atLevel: h.attempts + 1, state: makeState()).isEmpty)
    }

    // MARK: - §5.15.4 grading — Decision E5 table

    @Test func grade_marriageOnly_staysInconclusive_noSelfConfirmation() {
        // THE E5 pin: a unique Bob × Sue marriage proves the COUPLE
        // existed — not that they are George's parents. Marriage match
        // alone must NOT reach .supported.
        let kind = parentCandidatesKind(fatherGiven: "Robert", motherGiven: "Sarah")
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [
            marriageRecord(id: "m-groom", surname: "Wheeldon", givenName: "Robert",
                           spouseSurname: "Land", year: 1885),
            marriageRecord(id: "m-bride", surname: "Land", givenName: "Sarah",
                           spouseSurname: "Wheeldon", year: 1885),
        ]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.verdict == .inconclusive)
        #expect(Set(result.supportingEvidence) == ["m-groom", "m-bride"])
        #expect(result.reasoning.contains("parental link unproven"))
        #expect(result.isModelAssisted == false)
    }

    @Test func grade_marriagePlusBirthMMNLinkage_isSupported() {
        // Marriage match + the subject's own birth record carrying
        // MMN = the matched bride's maiden surname = the full linkage
        // chain → .supported citing BOTH record sets.
        let kind = parentCandidatesKind(fatherGiven: "Robert", motherGiven: "Sarah")
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [
            marriageRecord(id: "m-groom", surname: "Wheeldon", givenName: "Robert",
                           spouseSurname: "Land", year: 1885),
            marriageRecord(id: "m-bride", surname: "Land", givenName: "Sarah",
                           spouseSurname: "Wheeldon", year: 1885),
            birthRecord(id: "b-subj", mmn: "Land"),
        ]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.verdict == .supported)
        #expect(result.supportingEvidence.contains("m-groom"))
        #expect(result.supportingEvidence.contains("m-bride"))
        #expect(result.supportingEvidence.contains("b-subj"))
    }

    @Test func grade_marriagePlusCensusHouseholdLinkage_isSupported() {
        // Alternative linkage leg: a census household with the subject
        // as child of the hinted couple (head ≈ fatherGiven, wife ≈
        // motherGiven, surname = subject's).
        let kind = parentCandidatesKind(fatherGiven: "Robert", motherGiven: "Sarah")
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [
            marriageRecord(id: "m-groom", surname: "Wheeldon", givenName: "Robert",
                           spouseSurname: "Land", year: 1885),
            censusRecord(id: "c-1891", household: [
                HouseholdMember(name: "Robert Wheeldon", relationship: "Head", age: 30),
                HouseholdMember(name: "Sarah Wheeldon", relationship: "Wife", age: 28),
                HouseholdMember(name: "George Wheeldon", relationship: "Son", age: 4),
            ]),
        ]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.verdict == .supported)
        #expect(result.supportingEvidence.contains("m-groom"))
        #expect(result.supportingEvidence.contains("c-1891"))
    }

    @Test func grade_mmnConflictOnResolvedBirth_isContradicted() {
        // Table row 3: the subject's identity-resolved birth record
        // carries an MMN conflicting with the non-nil hint → refuted;
        // reasoning names both values, evidence cites the record.
        let kind = parentCandidatesKind(motherMaidenSurname: "Land")
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        // Single .fact birth record resolves identity immediately.
        state.scoredRecords = [
            birthRecord(id: "b-resolved", mmn: "Jones", verdict: .fact)
        ]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.verdict == .contradicted)
        #expect(result.contradictingEvidence == ["b-resolved"])
        #expect(result.reasoning.contains("Land"))
        #expect(result.reasoning.contains("Jones"))
    }

    @Test func grade_confirmedParentGivenNameConflict_isContradicted() {
        // Table row 4: the tree already holds a confirmed
        // (field_sources-backed) father "Thomas"; hunch says "Bob" —
        // conflict beyond nickname equivalence cites the edge.
        let kind = parentCandidatesKind(fatherGiven: "Bob")
        let h = makeHypothesis(kind: kind)
        let snapshot = snapshotWithConfirmedFather(named: "Thomas")
        let result = HypothesisEngine.grade(h, state: makeState(), snapshot: snapshot)
        #expect(result.verdict == .contradicted)
        #expect(result.contradictingEvidence == ["edge:parent:father1"])
        #expect(result.reasoning.contains("Bob"))
        #expect(result.reasoning.contains("Thomas"))
    }

    @Test func grade_confirmedParentEquivalentViaNickname_isNotContradicted() {
        // "Bob" vs confirmed "Robert" agrees via nickname equivalence —
        // no conflict, grading proceeds to the marriage rules.
        let kind = parentCandidatesKind(fatherGiven: "Bob")
        let h = makeHypothesis(kind: kind)
        let snapshot = snapshotWithConfirmedFather(named: "Robert")
        let result = HypothesisEngine.grade(h, state: makeState(), snapshot: snapshot)
        #expect(result.verdict != .contradicted)
    }

    @Test func grade_unsourcedPlaceholderParent_doesNotContradict() {
        // "Confirmed" means field_sources-backed (§5.15.4). A bare
        // placeholder name with no FieldSource must not refute a hunch.
        let kind = parentCandidatesKind(fatherGiven: "Bob")
        let h = makeHypothesis(kind: kind)
        let snapshot = snapshotWithConfirmedFather(named: "Thomas", sourced: false)
        let result = HypothesisEngine.grade(h, state: makeState(), snapshot: snapshot)
        #expect(result.verdict != .contradicted)
    }

    @Test func grade_noMarriageFound_isInconclusive_neverContradicted() {
        // Table row 5 — asymmetric verdict space (§4.1): absence within
        // the searched window is NOT refutation (contrast
        // gradeParentMarriage, which contradicts on .none for its
        // engine-origin kind).
        let kind = parentCandidatesKind()
        let h = makeHypothesis(kind: kind)
        let result = HypothesisEngine.grade(h, state: makeState(), snapshot: .empty)
        #expect(result.verdict == .inconclusive)
        #expect(result.supportingEvidence.isEmpty)
        #expect(result.contradictingEvidence.isEmpty)
        #expect(result.reasoning.contains("1857–1888"))
    }

    @Test func grade_ambiguousMarriages_isInconclusive() {
        // Two distinct reference tuples for the hinted pair → not
        // unique → inconclusive, candidates listed for §5.11 review.
        let kind = parentCandidatesKind(fatherGiven: nil, motherGiven: nil)
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [
            marriageRecord(id: "m1", surname: "Wheeldon", givenName: "Robert",
                           spouseSurname: "Land", year: 1885,
                           volume: "7B", page: "1397"),
            marriageRecord(id: "m2", surname: "Wheeldon", givenName: "Albert",
                           spouseSurname: "Land", year: 1879,
                           volume: "9A", page: "22"),
        ]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.verdict == .inconclusive)
        #expect(Set(result.supportingEvidence) == ["m1", "m2"])
        #expect(result.reasoning.contains("2 candidate marriages"))
    }

    // MARK: - Nickname equivalence (AC 8 — "Bob" matches "Robert")

    @Test func grade_hintBobAdmitsRecoveredRobert() {
        // The canonical §5.15 hunch: fatherGiven "Bob" must match the
        // index's "Robert" via the nickname machinery — the groom entry
        // survives the hint filter and the couple is attested.
        let kind = parentCandidatesKind(fatherGiven: "Bob", motherGiven: nil)
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [marriageRecord(
            id: "m-groom", surname: "Wheeldon", givenName: "Robert",
            spouseSurname: "Land", year: 1885
        )]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.verdict == .inconclusive)
        #expect(result.supportingEvidence == ["m-groom"], "Bob ≈ Robert — entry admitted, couple attested")
        #expect(result.reasoning.contains("parental link unproven"))
    }

    @Test func grade_builtInNicknamePairHonoured() {
        // A pair the shipped ScoringRules.nicknameEquivalents table
        // carries (JACK ↔ JOHN) — the grader rides the same machinery.
        let kind = parentCandidatesKind(fatherGiven: "Jack", motherGiven: nil)
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [marriageRecord(
            id: "m-groom", surname: "Wheeldon", givenName: "John",
            spouseSurname: "Land", year: 1885
        )]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.supportingEvidence == ["m-groom"])
    }

    @Test func grade_givenNameBeyondNicknameEquivalence_excludesEntry() {
        // "Bob" vs "Charles" is not a nickname pair — the entry is
        // filtered out, the pair is unattested, verdict inconclusive
        // with NO supporting evidence (and never contradicted).
        let kind = parentCandidatesKind(fatherGiven: "Bob", motherGiven: nil)
        let h = makeHypothesis(kind: kind)
        var state = makeState()
        state.scoredRecords = [marriageRecord(
            id: "m-groom", surname: "Wheeldon", givenName: "Charles",
            spouseSurname: "Land", year: 1885
        )]
        let result = HypothesisEngine.grade(h, state: state, snapshot: .empty)
        #expect(result.verdict == .inconclusive)
        #expect(result.supportingEvidence.isEmpty)
    }

    @Test func givenNamesAgree_learnedEquivalenceApplies() {
        // The name_equivalences learned table (AC 8's second table)
        // flows through ScoringRules.nameSimilarity. Use a synthetic
        // pair so the assertion is independent of the built-in tables
        // and of other tests' learned state. (No containment, different
        // lengths, no nickname/supplement entry — only the learned pair
        // can make these agree. No negative pre-assertion: the learned
        // store is process-global and parallel test runners share it.)
        ScoringRules.addLearnedEquivalence("Xanth", "Quorby")
        #expect(HypothesisEngine.parentCandidatesGivenNamesAgree("Xanth", "Quorby"))
    }

    @Test func givenNamesAgree_firstTokenComparison() {
        // BMD index given names are often compound — "Robert James"
        // must still agree with hint "Bob".
        #expect(HypothesisEngine.parentCandidatesGivenNamesAgree("Bob", "Robert James"))
        #expect(HypothesisEngine.parentCandidatesGivenNamesAgree("Sue", "Susan"))
        #expect(!HypothesisEngine.parentCandidatesGivenNamesAgree("Bob", "Charles"))
    }

    // MARK: - T7 stall-gate carve-out (Decision E4)

    @Test func carveOut_firesForUserRowAtAttemptsZero() {
        let h = makeHypothesis(kind: parentCandidatesKind(), origin: .user, attempts: 0)
        #expect(ResearchPipeline.shouldDispatchUserSeededLevelOne(h, preGradeVerdict: .inconclusive))
    }

    @Test func carveOut_firesOnceOnly_attemptsBeyondZeroRideNormalGate() {
        // After the unconditional level-1 dispatch sets attempts = 1,
        // the carve-out never re-fires; levels 2–3 ride the standard T7
        // eligibility (inconclusive + ladder headroom).
        let h1 = makeHypothesis(kind: parentCandidatesKind(), origin: .user, attempts: 1)
        #expect(!ResearchPipeline.shouldDispatchUserSeededLevelOne(h1, preGradeVerdict: .inconclusive))
        // And the row IS T7-eligible at level 2 through the normal gate
        // (mms hinted → level-2 query derivable):
        #expect(h1.verdict == .inconclusive)
        let level2 = HypothesisEngine.deficitQuery(for: h1, atLevel: h1.attempts + 1, state: makeState())
        #expect(!level2.isEmpty, "level 2 has headroom — the NORMAL stall gate takes over from here")
    }

    @Test func carveOut_doesNotApplyToEngineRows() {
        // The gate exists to stop the engine burning queries on its own
        // speculations — only user directives get the carve-out.
        let h = makeHypothesis(kind: parentCandidatesKind(), origin: .engine, attempts: 0)
        #expect(!ResearchPipeline.shouldDispatchUserSeededLevelOne(h, preGradeVerdict: .inconclusive))
    }

    @Test func carveOut_skipsDispatchWhenPreGradeContradicts() {
        // §5.15.2 — a hunch already refuted against the tree/state is
        // graded without dispatch: the user learns immediately, not
        // after a wasted fan-out.
        let h = makeHypothesis(kind: parentCandidatesKind(), origin: .user, attempts: 0)
        #expect(!ResearchPipeline.shouldDispatchUserSeededLevelOne(h, preGradeVerdict: .contradicted))
    }

    // MARK: - Storm guards intact

    @Test func stormGuard_levelOneEmitsExactlyOneFanOutTemplate() {
        // §5.15.3: "All probes ride existing machinery; nothing here
        // invents a new dispatch path. Storm guards apply unchanged."
        // The ladder emits ONE districtCode:"" template per level-1
        // call; geographic fan-out is delegated to the same
        // dispatchMarriageQuery → freeBMDGeoAxes path as
        // .parentMarriage, whose empty-chapman degradation and scope
        // bounding stay in force.
        let h = makeHypothesis(kind: parentCandidatesKind())
        let queries = HypothesisEngine.deficitQuery(for: h, atLevel: 1, state: makeState())
        #expect(queries.count == 1)
    }

    @Test func stormGuard_parentMarriageLadderUnchanged() {
        // Regression pin: the .parentMarriage ladder this slice sits
        // beside keeps its exact pre-slice shape (level 1 = original
        // window, level 2 = ±10y widen, level 3 = exhausted).
        let kind = HypothesisKind.parentMarriage(
            motherSurname: "Land", fatherSurname: "Wheeldon",
            windowYears: 1857...1888
        )
        let h = makeHypothesis(kind: kind, origin: .engine, attempts: 1)
        let state = makeState()
        let level2 = HypothesisEngine.deficitQuery(for: h, atLevel: 2, state: state)
        #expect(level2.first?.yearFrom == 1847)
        #expect(level2.first?.yearTo == 1898)
        #expect(HypothesisEngine.deficitQuery(for: h, atLevel: 3, state: state).isEmpty)
    }

    // MARK: - §5.15.6 rejection memory

    @Test func rejectionMemory_lookupExcludesRejectedRows() throws {
        // user_rejected = 1 → no regeneration, no dispatch: the lookup
        // that feeds the user-hunch flow never returns the row.
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        let kind = parentCandidatesKind()
        let h = makeHypothesis(kind: kind, subjectProfileID: "p1", origin: .user)
        try db.upsertHypothesis(h)

        let lookup = try #require(ResearchPipeline.makeUserHypothesisLookup(database: db))
        #expect(lookup("p1").map(\.id) == [h.id])

        try db.rejectHypothesis(id: h.id)
        #expect(lookup("p1").isEmpty, "rejected hunch must never reach dispatch")
    }

    @Test func rejectionMemory_lookupFiltersToUserOrigin() throws {
        // Engine rows sharing the profile are not user hunches — the
        // flow must not treat them as such.
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        let engineRow = makeHypothesis(
            kind: .parentMarriage(motherSurname: "Land", fatherSurname: "Wheeldon", windowYears: 1857...1888),
            subjectProfileID: "p1", origin: .engine
        )
        let userRow = makeHypothesis(kind: parentCandidatesKind(), subjectProfileID: "p1", origin: .user)
        try db.upsertHypotheses([engineRow, userRow])

        let lookup = try #require(ResearchPipeline.makeUserHypothesisLookup(database: db))
        #expect(lookup("p1").map(\.id) == [userRow.id])
    }

    @Test func rejectionMemory_probeResultsFilteredThroughRecordRejections() {
        // record_rejections filters probe results before they reach
        // state/scoring — a hunch cannot resurrect the wrong Thomas the
        // user already discarded.
        let records = [
            marriageRecord(id: "m-keep", surname: "Wheeldon", givenName: "Robert",
                           spouseSurname: "Land", year: 1885),
            marriageRecord(id: "m-discarded", surname: "Wheeldon", givenName: "Thomas",
                           spouseSurname: "Land", year: 1880),
        ]
        let filtered = ResearchPipeline.excludingRejected(records, rejectedIDs: ["m-discarded"])
        #expect(filtered.map(\.id) == ["m-keep"])
        // Empty rejection set passes everything through untouched.
        #expect(ResearchPipeline.excludingRejected(records, rejectedIDs: []).count == 2)
    }

    // MARK: - Regeneration exemption (§5.15.1)

    @Test func generateSwitch_neverInventsParentCandidates() {
        // The engine's regeneration cycle never creates .user rows —
        // the generate arm is permanently empty, even with rich state.
        var state = makeState()
        state.scoredRecords = [birthRecord(id: "b1", mmn: "Land", verdict: .fact)]
        let generated = HypothesisEngine.generate(
            for: .parentCandidates, state: state, snapshot: .empty
        )
        #expect(generated.isEmpty)
    }

    // MARK: - Fixture helpers

    /// Snapshot with subject "subj" and a father edge to a profile whose
    /// given name is (optionally) field_sources-backed.
    private func snapshotWithConfirmedFather(
        named: String, sourced: Bool = true
    ) -> FamilyGraphSnapshot {
        let subject = Profile(
            id: "subj", externalIDs: [:],
            firstName: "George", lastName: "Wheeldon", gender: .male,
            birthDate: GenealogicalDate(parsing: "1887"),
            isDeleted: false, sources: [:], disputes: [:]
        )
        let fatherSources: [ProfileField: [FieldSource]] = sourced
            ? [.firstName: [FieldSource(origin: .freebmd, raw: named, addedAt: Date())]]
            : [:]
        let father = Profile(
            id: "father1", externalIDs: [:],
            firstName: named, lastName: "Wheeldon", gender: .male,
            isDeleted: false, sources: fatherSources, disputes: [:]
        )
        let edge = Relationship(
            id: UUID(), from: "father1", to: "subj",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        return FamilyGraphSnapshot(
            profiles: ["subj": subject, "father1": father],
            relationships: [edge]
        )
    }

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// research_hypotheses.subject_profile_id carries a FK to
    /// profiles(id) — hypothesis rows need their profile to exist.
    private func insertProfile(id: String, into db: ProjectDatabase) throws {
        let profile = Profile(
            id: id, externalIDs: [:],
            firstName: "George", lastName: "Wheeldon", gender: .male,
            birthDate: GenealogicalDate(parsing: "1887"),
            isDeleted: false, sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
    }
}
