import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 4 test coverage for the `.subjectSpouseMarriage` pre-iteration
/// strategy (RESEARCH_PIPELINE_SPEC §5.14). Pure-function tests over the
/// engine extension; orchestrator-side integration (pipeline.research)
/// is covered indirectly because the reconciliation logic was extracted
/// into a static `HypothesisEngine.reconcileSubjectSpouseWriteback` that
/// these tests exercise directly.
///
/// Test plan mirrors slice 4 in §5.14.11:
///   • Trigger predicate (all branches of §5.14.1)
///   • Per-distinct-MMN generator + same-MMN dedup (Q3+Q4)
///   • Grader outcomes (.unique / .ambiguous / .none → §5.14.4 verdicts)
///   • Gender precedence ladder (Q1 — all four rules)
///   • MMN provenance fallback (Q2 — profile field → child evidence map)
///   • Cross-hypothesis reconciliation (Q4 four cases)
///   • Recovery extraction + gender-routed pick
///   • Expansiveness ladder (§5.14.9)
///   • Identity-key stability (rejection persistence)
@MainActor
struct SubjectSpouseMarriageTests {

    // MARK: - Helpers

    private func makeSubject(
        profileID: String,
        surname: String = "Brooks",
        givenName: String? = nil,
        gender: Gender? = nil,
        birthYear: Int? = nil
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: profileID, surname: surname, givenName: givenName,
            middleName: nil,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: nil, deathYearTo: nil,
            gender: gender, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    private func makeChildProfile(
        id: String,
        surname: String,
        givenName: String,
        gender: Gender = .male,
        mmn: String?,
        birthYear: Int?
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: givenName, middleName: nil, lastName: surname,
            marriedSurname: nil, nickName: nil, mothersMaidenName: mmn,
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, birthLocationCode: nil,
            deathDate: nil, deathLocation: nil, deathLocationCode: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func makeAdultProfile(
        id: String,
        surname: String,
        givenName: String,
        gender: Gender = .male
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: givenName, middleName: nil, lastName: surname,
            marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
            gender: gender, attributes: nil,
            birthDate: nil, birthLocation: nil, birthLocationCode: nil,
            deathDate: nil, deathLocation: nil, deathLocationCode: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentRel(_ from: String, _ to: String, role: ParentRole) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: role, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func marriageRecord(
        id: String,
        surname: String,
        givenName: String,
        spouseSurname: String,
        year: Int,
        quarter: String? = "3",
        district: String? = "Belper",
        volume: String = "7B",
        page: String = "1234",
        sourceURL: String? = nil
    ) -> ScoredRecord {
        let url = sourceURL ?? "https://freebmd.org.uk/m/\(id)"
        let common = RecordCommon(
            id: id, sourceID: "freebmd", name: nil,
            surname: surname, givenName: givenName,
            detailURL: url, rawFields: [:]
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

    /// Build a snapshot whose subject has one or more linked children.
    /// `extraProfiles`/`extraRels` let tests inject linked spouses for
    /// the topology rule, etc.
    private func snapshotWith(
        subjectID: String,
        children: [Profile],
        extraProfiles: [Profile] = [],
        extraRels: [Relationship] = []
    ) -> FamilyGraphSnapshot {
        let subjectProfile = makeAdultProfile(
            id: subjectID, surname: "Brooks", givenName: ""
        )
        var profiles: [String: Profile] = [subjectID: subjectProfile]
        var rels: [Relationship] = []
        for child in children {
            profiles[child.id] = child
            rels.append(parentRel(subjectID, child.id, role: .father))
        }
        for p in extraProfiles { profiles[p.id] = p }
        rels.append(contentsOf: extraRels)
        return FamilyGraphSnapshot(profiles: profiles, relationships: rels)
    }

    // MARK: - Trigger predicate (§5.14.1)

    @Test func generator_emptyWhenSubjectHasNoProfileID() {
        let subject = ResearchSubject(
            profileID: nil, surname: "Brooks", givenName: nil,
            middleName: nil,
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .extend, familyContext: nil, homeChapmanCode: "DBY"
        )
        let state = ResearchState(subject: subject)
        let result = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: .empty, childMMNs: [:]
        )
        #expect(result.isEmpty, "no profileID = no anchor = no hypothesis")
    }

    @Test func generator_emptyWhenSubjectHasNoSurname() {
        let subject = makeSubject(profileID: "s", surname: "")
        let state = ResearchState(subject: subject)
        #expect(HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: .empty, childMMNs: [:]
        ).isEmpty, "empty surname = no marriage anchor")
    }

    @Test func generator_emptyWhenSubjectHasGivenName() {
        // Strategy is given-name recovery; bail when subject already has one.
        let subject = makeSubject(profileID: "s", givenName: "John")
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: "Smith", birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)
        #expect(HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        ).isEmpty, "rich subject = strategy out of scope")
    }

    @Test func generator_emptyWhenNoLinkedChildren() {
        let subject = makeSubject(profileID: "s")
        let snapshot = snapshotWith(subjectID: "s", children: [])
        let state = ResearchState(subject: subject)
        #expect(HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        ).isEmpty)
    }

    @Test func generator_emptyWhenChildrenHaveNoMMNAnchor() {
        let subject = makeSubject(profileID: "s")
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: nil, birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)
        #expect(HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        ).isEmpty, "no MMN on any child = no anchor")
    }

    // MARK: - Generator (Q3 same-MMN collapse + Q4 distinct-MMN split)

    @Test func generator_emitsOneHypothesisWhenSingleChildHasMMN() throws {
        let subject = makeSubject(profileID: "s")
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: "Smith", birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)

        let hypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        #expect(hypotheses.count == 1)
        let h = try #require(hypotheses.first)
        guard case .subjectSpouseMarriage(let sub, let spouse, let window) = h.kind else {
            Issue.record("expected .subjectSpouseMarriage kind")
            return
        }
        #expect(sub == "Brooks")
        #expect(spouse == "Smith")
        #expect(window == (1885 - 30)...(1885 + 1))
        #expect(h.verdict == .inconclusive)
        #expect(h.attempts == 0)
        #expect(h.supportingEvidence == ["c1"])
    }

    @Test func generator_collapsesSameMMNAcrossMultipleChildren() throws {
        let subject = makeSubject(profileID: "s")
        let c1 = makeChildProfile(id: "c1", surname: "Brooks", givenName: "Tom", mmn: "Smith", birthYear: 1885)
        let c2 = makeChildProfile(id: "c2", surname: "Brooks", givenName: "Sarah", mmn: "Smith", birthYear: 1887)
        let c3 = makeChildProfile(id: "c3", surname: "Brooks", givenName: "Annie", mmn: "smith", birthYear: 1890)  // case-drift
        let snapshot = snapshotWith(subjectID: "s", children: [c1, c2, c3])
        let state = ResearchState(subject: subject)

        let hypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        #expect(hypotheses.count == 1, "same MMN (case-insensitive) = one canonical hypothesis (Q3)")
        let h = try #require(hypotheses.first)
        #expect(Set(h.supportingEvidence) == ["c1", "c2", "c3"])
        if case .subjectSpouseMarriage(_, _, let window) = h.kind {
            // Window anchored on EARLIEST child birth.
            #expect(window.lowerBound == 1885 - 30)
            #expect(window.upperBound == 1885 + 1)
        } else {
            Issue.record("expected .subjectSpouseMarriage kind")
        }
    }

    @Test func generator_splitsDistinctMMNsAcrossChildren() throws {
        // Q4 — children disagree on MMN → one hypothesis per distinct MMN.
        let subject = makeSubject(profileID: "s")
        let c1 = makeChildProfile(id: "c1", surname: "Brooks", givenName: "Tom", mmn: "Smith", birthYear: 1885)
        let c2 = makeChildProfile(id: "c2", surname: "Brooks", givenName: "Sarah", mmn: "Jones", birthYear: 1888)
        let snapshot = snapshotWith(subjectID: "s", children: [c1, c2])
        let state = ResearchState(subject: subject)

        let hypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        #expect(hypotheses.count == 2, "distinct MMNs = separate hypotheses (Q4)")
        let spouses = hypotheses.compactMap { h -> String? in
            if case .subjectSpouseMarriage(_, let spouse, _) = h.kind { return spouse }
            return nil
        }
        #expect(Set(spouses) == ["Smith", "Jones"])
    }

    // MARK: - MMN provenance fallback (Q2)

    @Test func generator_fallsBackToChildMMNsMapWhenProfileFieldEmpty() throws {
        let subject = makeSubject(profileID: "s")
        // Child profile has NO mothersMaidenName field — Q2 Option B
        // says the orchestrator can pre-load it from the child's
        // persisted research records.
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: nil, birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)

        // First confirm the fallback is needed.
        #expect(HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        ).isEmpty, "no profile MMN, no fallback = no hypothesis")

        // Now with the fallback map populated.
        let hypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: ["c1": "Smith"]
        )
        #expect(hypotheses.count == 1)
        guard case .subjectSpouseMarriage(_, let spouse, _) = hypotheses.first?.kind else {
            Issue.record("expected hypothesis")
            return
        }
        #expect(spouse == "Smith")
    }

    @Test func generator_prefersProfileFieldOverFallbackMap() {
        let subject = makeSubject(profileID: "s")
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: "Smith", birthYear: 1885   // profile-side
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)

        // Fallback map disagrees — should be ignored when profile field is non-empty.
        let hypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: ["c1": "Jones"]
        )
        #expect(hypotheses.count == 1)
        if case .subjectSpouseMarriage(_, let spouse, _) = hypotheses.first?.kind {
            #expect(spouse == "Smith", "profile field wins, fallback ignored")
        }
    }

    // MARK: - Gender precedence ladder (Q1)

    @Test func genderLadder_rule1ExplicitGenderUsedAsGiven() {
        let subject = makeSubject(profileID: "s", gender: .male)
        let snapshot = snapshotWith(subjectID: "s", children: [])
        let state = ResearchState(subject: subject)
        let res = HypothesisEngine.resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        if case .explicit(let g) = res {
            #expect(g == .male)
        } else {
            Issue.record("expected .explicit, got \(res)")
        }
    }

    @Test func genderLadder_rule2SurnamePatternIdentifiesMaleSubject() {
        // subject.surname == child.surname AND != child.MMN → male
        let subject = makeSubject(profileID: "s", surname: "Brooks")
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: "Smith", birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)
        let res = HypothesisEngine.resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        if case .surnamePattern(let g) = res {
            #expect(g == .male)
        } else {
            Issue.record("expected .surnamePattern(.male), got \(res)")
        }
    }

    @Test func genderLadder_rule2SurnamePatternIdentifiesFemaleSubject() {
        // subject.surname == child.MMN AND != child.surname → female
        let subject = makeSubject(profileID: "s", surname: "Smith")
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: "Smith", birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)
        let res = HypothesisEngine.resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        if case .surnamePattern(let g) = res {
            #expect(g == .female)
        } else {
            Issue.record("expected .surnamePattern(.female), got \(res)")
        }
    }

    @Test func genderLadder_rule3TopologyInfersFemaleWhenFatherSlotFilled() {
        // Subject is the mother (father slot is held by a different profile).
        let subject = makeSubject(profileID: "s", surname: "Brooks", gender: nil)
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: nil, birthYear: 1885   // neither surname rule matches
        )
        let father = makeAdultProfile(id: "f", surname: "Brooks", givenName: "John", gender: .male)
        // Two parent edges: subject → child AND father → child.
        // Use the snapshotWith helper but inject an additional father edge.
        let extraFatherRel = parentRel("f", "c1", role: .father)
        let snapshot = snapshotWith(
            subjectID: "s", children: [child],
            extraProfiles: [father], extraRels: [extraFatherRel]
        )
        let state = ResearchState(subject: subject)
        let res = HypothesisEngine.resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        // Rule 2 fires first when child.MMN is non-empty (matches subject
        // if subject == "Brooks" and MMN is "Brooks", or otherwise) —
        // here child has no MMN so rule 2 falls through cleanly, then
        // rule 3 sees the linked father and infers female.
        if case .topology(let g) = res {
            #expect(g == .female)
        } else {
            Issue.record("expected .topology(.female), got \(res)")
        }
    }

    @Test func genderLadder_rule4RefuseWhenNothingDecides() {
        let subject = makeSubject(profileID: "s", surname: "Brooks", gender: nil)
        let snapshot = snapshotWith(subjectID: "s", children: [])
        let state = ResearchState(subject: subject)
        let res = HypothesisEngine.resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        if case .unresolved = res {
            // pass
        } else {
            Issue.record("expected .unresolved, got \(res)")
        }
    }

    @Test func genderLadder_crossChildSurnameDisagreementFallsThrough() {
        // Child A → male signal; Child B → female signal. The
        // surname-pattern rule sees two distinct signals and falls
        // through. No topology either → refuse.
        let subject = makeSubject(profileID: "s", surname: "Brooks", gender: nil)
        let childA = makeChildProfile(
            id: "cA", surname: "Brooks", givenName: "Tom",
            mmn: "Smith", birthYear: 1885   // → male signal
        )
        let childB = makeChildProfile(
            id: "cB", surname: "Other", givenName: "Step",
            mmn: "Brooks", birthYear: 1890   // → female signal
        )
        let snapshot = snapshotWith(subjectID: "s", children: [childA, childB])
        let state = ResearchState(subject: subject)
        let res = HypothesisEngine.resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        if case .unresolved = res {
            // pass
        } else {
            Issue.record("expected .unresolved (disagreement), got \(res)")
        }
    }

    // MARK: - Grader (§5.14.4)

    private func subjectAndStateWithChild(
        mmn: String = "Smith", childYear: Int = 1885
    ) -> (ResearchSubject, FamilyGraphSnapshot, ResearchState) {
        let subject = makeSubject(profileID: "s", gender: .male)
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: mmn, birthYear: childYear
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)
        return (subject, snapshot, state)
    }

    @Test func grader_supportedOnUniqueMatch() throws {
        let (_, snapshot, _state) = subjectAndStateWithChild(); var state = _state
        // Both sides of the BMD index at the same reference tuple.
        let groomSide = marriageRecord(
            id: "m-groom", surname: "Brooks", givenName: "John",
            spouseSurname: "Smith", year: 1882
        )
        let brideSide = marriageRecord(
            id: "m-bride", surname: "Smith", givenName: "Mary",
            spouseSurname: "Brooks", year: 1882
        )
        state.scoredRecords = [groomSide, brideSide]
        let drafts = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeSubjectSpouseMarriage(
            draft, state: state, snapshot: snapshot
        )
        #expect(result.verdict == .supported)
        #expect(Set(result.supportingEvidence) == ["m-groom", "m-bride"])
        #expect(result.reasoning.contains("John"))
        #expect(result.reasoning.contains("Mary"))
    }

    @Test func grader_contradictedWhenNoMatch() throws {
        let (_, snapshot, state) = subjectAndStateWithChild()
        let drafts = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeSubjectSpouseMarriage(
            draft, state: state, snapshot: snapshot
        )
        #expect(result.verdict == .contradicted)
        #expect(result.supportingEvidence.isEmpty)
    }

    @Test func grader_inconclusiveWhenAmbiguous() throws {
        let (_, snapshot, _state) = subjectAndStateWithChild(); var state = _state
        // Two distinct reference tuples → ambiguous.
        let groom1 = marriageRecord(
            id: "m1g", surname: "Brooks", givenName: "John",
            spouseSurname: "Smith", year: 1882, volume: "7B", page: "1234"
        )
        let bride1 = marriageRecord(
            id: "m1b", surname: "Smith", givenName: "Mary",
            spouseSurname: "Brooks", year: 1882, volume: "7B", page: "1234"
        )
        let groom2 = marriageRecord(
            id: "m2g", surname: "Brooks", givenName: "Robert",
            spouseSurname: "Smith", year: 1883, volume: "9A", page: "0099"
        )
        let bride2 = marriageRecord(
            id: "m2b", surname: "Smith", givenName: "Alice",
            spouseSurname: "Brooks", year: 1883, volume: "9A", page: "0099"
        )
        state.scoredRecords = [groom1, bride1, groom2, bride2]
        let drafts = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        let draft = try #require(drafts.first)
        let result = HypothesisEngine.gradeSubjectSpouseMarriage(
            draft, state: state, snapshot: snapshot
        )
        #expect(result.verdict == .inconclusive)
        #expect(result.supportingEvidence.count >= 2)
    }

    // MARK: - Recovery extraction + gender-routed pick

    @Test func recovery_extractsBothGivenNamesFromTwoSidedMatch() throws {
        let (_, snapshot, _state) = subjectAndStateWithChild(); var state = _state
        let groomSide = marriageRecord(
            id: "m-groom", surname: "Brooks", givenName: "John",
            spouseSurname: "Smith", year: 1882, district: "Belper"
        )
        let brideSide = marriageRecord(
            id: "m-bride", surname: "Smith", givenName: "Mary",
            spouseSurname: "Brooks", year: 1882, district: "Belper"
        )
        state.scoredRecords = [groomSide, brideSide]
        let drafts = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        var draft = try #require(drafts.first)
        // Flip to .supported with the two record IDs as supporting evidence.
        draft = ResearchHypothesis(
            id: draft.id, subjectProfileID: draft.subjectProfileID,
            kind: draft.kind, verdict: .supported, isModelAssisted: false,
            supportingEvidence: ["m-groom", "m-bride"], contradictingEvidence: [],
            reasoning: "", createdAt: draft.createdAt, lastTestedAt: Date(),
            attempts: 1, history: []
        )
        let recovery = try #require(HypothesisEngine.extractSubjectSpouseRecovery(
            from: draft, scoredRecords: state.scoredRecords
        ))
        #expect(recovery.groomGiven == "John")
        #expect(recovery.brideGiven == "Mary")
        #expect(recovery.matchedYear == 1882)
        #expect(recovery.matchedDistrict == "Belper")
    }

    @Test func recovery_nilWhenHypothesisNotSupported() {
        let (_, _, _state) = subjectAndStateWithChild()
        var state = _state
        state.scoredRecords = []
        let kind = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Smith",
            childYearWindow: 1855...1886
        )
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "s"),
            subjectProfileID: "s", kind: kind,
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "", createdAt: Date(), lastTestedAt: Date(),
            attempts: 0, history: []
        )
        #expect(HypothesisEngine.extractSubjectSpouseRecovery(
            from: h, scoredRecords: state.scoredRecords
        ) == nil)
    }

    @Test func pick_routesGivenNameByGender() {
        let recovery = HypothesisEngine.SubjectSpouseRecovery(
            groomGiven: "John", brideGiven: "Mary",
            marriageRecordIDs: ["m1", "m2"],
            primarySourceURL: nil, primarySourceID: nil, primarySourceTitle: nil,
            matchedYear: 1882, matchedQuarter: "3", matchedDistrict: "Belper"
        )
        #expect(HypothesisEngine.pickSubjectGivenName(from: recovery, resolvedGender: .male) == "John")
        #expect(HypothesisEngine.pickSubjectGivenName(from: recovery, resolvedGender: .female) == "Mary")
        #expect(HypothesisEngine.pickSubjectGivenName(from: recovery, resolvedGender: .unknown) == nil)
    }

    // MARK: - Cross-hypothesis reconciliation (Q4 four cases)

    private func supportedHypothesis(
        groomSurname: String, brideSurname: String,
        groomGiven: String? = "John", brideGiven: String? = "Mary",
        recordIDs: [String] = ["m-groom", "m-bride"]
    ) -> (ResearchHypothesis, [ScoredRecord]) {
        let kind = HypothesisKind.subjectSpouseMarriage(
            groomSurname: groomSurname,
            brideSurname: brideSurname,
            childYearWindow: 1855...1886
        )
        var records: [ScoredRecord] = []
        if let g = groomGiven {
            records.append(marriageRecord(
                id: recordIDs[0], surname: groomSurname, givenName: g,
                spouseSurname: brideSurname, year: 1882
            ))
        }
        if let b = brideGiven, recordIDs.count > 1 {
            records.append(marriageRecord(
                id: recordIDs[1], surname: brideSurname, givenName: b,
                spouseSurname: groomSurname, year: 1882
            ))
        }
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "s"),
            subjectProfileID: "s", kind: kind,
            verdict: .supported, isModelAssisted: false,
            supportingEvidence: recordIDs, contradictingEvidence: [],
            reasoning: "test", createdAt: Date(), lastTestedAt: Date(),
            attempts: 1, history: []
        )
        return (h, records)
    }

    @Test func reconcile_zeroSupportedReturnsNoWriteback() {
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [], scoredRecords: [], resolvedGender: .male
        )
        if case .noWriteback = decision {
            // pass
        } else {
            Issue.record("expected .noWriteback, got \(decision)")
        }
    }

    @Test func reconcile_oneSupportedWritesBackForMale() throws {
        let (h, records) = supportedHypothesis(
            groomSurname: "Brooks", brideSurname: "Smith"
        )
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [h], scoredRecords: records, resolvedGender: .male
        )
        guard case .applyName(let name, let sub, let spouse, let cited, _, _) = decision else {
            Issue.record("expected .applyName, got \(decision)")
            return
        }
        #expect(name == "John")
        #expect(sub == "Brooks")
        #expect(spouse == "Smith")
        #expect(Set(cited) == ["m-groom", "m-bride"])
    }

    @Test func reconcile_oneSupportedWritesBackForFemale() {
        let (h, records) = supportedHypothesis(
            groomSurname: "Brooks", brideSurname: "Smith"
        )
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [h], scoredRecords: records, resolvedGender: .female
        )
        if case .applyName(let name, _, _, _, _, _) = decision {
            #expect(name == "Mary", "female → bride given")
        } else {
            Issue.record("expected .applyName, got \(decision)")
        }
    }

    @Test func reconcile_multiAgreeingWritesBackOnce() throws {
        // Q4 remarriage with same recovered name across two marriages.
        let (h1, r1) = supportedHypothesis(
            groomSurname: "Brooks", brideSurname: "Smith",
            groomGiven: "John", brideGiven: "Mary",
            recordIDs: ["m1g", "m1b"]
        )
        let (h2, r2) = supportedHypothesis(
            groomSurname: "Brooks", brideSurname: "Jones",
            groomGiven: "John", brideGiven: "Eliza",
            recordIDs: ["m2g", "m2b"]
        )
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [h1, h2], scoredRecords: r1 + r2, resolvedGender: .male
        )
        guard case .applyName(let name, _, _, let cited, _, _) = decision else {
            Issue.record("expected .applyName, got \(decision)")
            return
        }
        #expect(name == "John")
        #expect(Set(cited) == ["m1g", "m1b", "m2g", "m2b"])
    }

    @Test func reconcile_multiDisagreeingReturnsNoWriteback() {
        let (h1, r1) = supportedHypothesis(
            groomSurname: "Brooks", brideSurname: "Smith",
            groomGiven: "John",
            recordIDs: ["m1g", "m1b"]
        )
        let (h2, r2) = supportedHypothesis(
            groomSurname: "Brooks", brideSurname: "Jones",
            groomGiven: "Robert",
            recordIDs: ["m2g", "m2b"]
        )
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [h1, h2], scoredRecords: r1 + r2, resolvedGender: .male
        )
        if case .noWriteback(let reason) = decision {
            #expect(reason.lowercased().contains("disagree") || reason.contains("John") || reason.contains("Robert"))
        } else {
            Issue.record("expected .noWriteback for disagreement, got \(decision)")
        }
    }

    @Test func reconcile_unresolvedGenderReturnsNoWriteback() {
        let (h, records) = supportedHypothesis(
            groomSurname: "Brooks", brideSurname: "Smith"
        )
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [h], scoredRecords: records, resolvedGender: nil
        )
        if case .noWriteback(let reason) = decision {
            #expect(reason.lowercased().contains("gender"))
        } else {
            Issue.record("expected .noWriteback (unresolved gender), got \(decision)")
        }
    }

    // MARK: - Expansiveness ladder (§5.14.9)

    @Test func deficitLadder_level1MatchesHypothesisWindow() {
        let kind = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Smith",
            childYearWindow: 1855...1886
        )
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "s"),
            subjectProfileID: "s", kind: kind,
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "", createdAt: Date(), lastTestedAt: Date(),
            attempts: 0, history: []
        )
        let queries = HypothesisEngine.deficitQuerySubjectSpouseMarriage(
            for: h, atLevel: 1, state: ResearchState(subject: makeSubject(profileID: "s"))
        )
        #expect(queries.count == 1)
        #expect(queries.first?.yearFrom == 1855)
        #expect(queries.first?.yearTo == 1886)
        #expect(queries.first?.surname == "Brooks")
    }

    @Test func deficitLadder_level2WidensByTen() {
        let kind = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Smith",
            childYearWindow: 1855...1886
        )
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "s"),
            subjectProfileID: "s", kind: kind,
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "", createdAt: Date(), lastTestedAt: Date(),
            attempts: 1, history: []
        )
        let queries = HypothesisEngine.deficitQuerySubjectSpouseMarriage(
            for: h, atLevel: 2, state: ResearchState(subject: makeSubject(profileID: "s"))
        )
        #expect(queries.first?.yearFrom == 1845)
        #expect(queries.first?.yearTo == 1896)
    }

    @Test func deficitLadder_level3IsExhausted() {
        let kind = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Smith",
            childYearWindow: 1855...1886
        )
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "s"),
            subjectProfileID: "s", kind: kind,
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "", createdAt: Date(), lastTestedAt: Date(),
            attempts: 2, history: []
        )
        let queries = HypothesisEngine.deficitQuerySubjectSpouseMarriage(
            for: h, atLevel: 3, state: ResearchState(subject: makeSubject(profileID: "s"))
        )
        #expect(queries.isEmpty, "ladder ceiling — exhausted")
    }

    // MARK: - Identity-key stability (rejection persistence prerequisite)

    @Test func identityKey_stableAcrossSamePayload() {
        let k1 = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Smith",
            childYearWindow: 1855...1886
        )
        let k2 = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "brooks", brideSurname: "smith",  // case-drift
            childYearWindow: 1855...1886
        )
        #expect(
            k1.identityKey(subjectProfileID: "s") == k2.identityKey(subjectProfileID: "s"),
            "identity key uppercases surnames so case drift doesn't fragment"
        )
    }

    @Test func identityKey_distinctForDistinctMMNs() {
        let k1 = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Smith",
            childYearWindow: 1855...1886
        )
        let k2 = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Jones",
            childYearWindow: 1855...1886
        )
        #expect(k1.identityKey(subjectProfileID: "s") != k2.identityKey(subjectProfileID: "s"))
    }

    // MARK: - Slice 5 — Land scenario (female maiden-stored mother) +
    //         (groom, bride) payload semantics

    /// The bug surfaced by the user 2026-05-27: a mother placeholder
    /// stored under her MAIDEN surname (because parent-inference creates
    /// female parents with surname=MMN) produced a `(Land, Land)` pair
    /// before slice 5. The (groom, bride) refactor anchors the pair on
    /// `(child.lastName, child.MMN)` regardless of which parent is the
    /// subject — so Land subject correctly yields `(Brooks, Land)`.
    @Test func generator_landScenarioFemaleMaidenStored() throws {
        // Mother stored under maiden — surname == Lilian's MMN.
        let subject = makeSubject(profileID: "s", surname: "Land")
        // Lilian Brooks, b.1914, MMN=Land.
        let child = makeChildProfile(
            id: "lilian", surname: "Brooks", givenName: "Lilian",
            mmn: "Land", birthYear: 1914
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)

        let hypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        )
        #expect(hypotheses.count == 1, "Land subject with linked child Brooks/Land = one hypothesis")
        let h = try #require(hypotheses.first)
        guard case .subjectSpouseMarriage(let groom, let bride, let window) = h.kind else {
            Issue.record("expected .subjectSpouseMarriage")
            return
        }
        #expect(groom == "Brooks", "(groom, bride) = (child.lastName, child.MMN) — not (subject.surname, child.MMN)")
        #expect(bride == "Land")
        #expect(window == (1914 - 30)...(1914 + 1))
    }

    @Test func generator_landAndBrooksProduceSameMarriagePair() {
        // Both placeholder parents (Land mother + Brooks father) anchored
        // on the same child Lilian should produce hypotheses pointing at
        // the SAME marriage — (Brooks, Land). The identity-key includes
        // subjectProfileID so the rows are distinct, but the kind payload
        // is identical.
        let child = makeChildProfile(
            id: "lilian", surname: "Brooks", givenName: "Lilian",
            mmn: "Land", birthYear: 1914
        )

        // Land subject.
        let landSubject = makeSubject(profileID: "land", surname: "Land")
        var landSnapshot = snapshotWith(subjectID: "land", children: [child])
        // snapshotWith hard-codes the subject's surname to "Brooks"; for
        // Land we need to override the subject profile too.
        var profiles = landSnapshot.profiles
        profiles["land"] = makeAdultProfile(id: "land", surname: "Land", givenName: "")
        landSnapshot = FamilyGraphSnapshot(profiles: profiles, relationships: landSnapshot.relationships)
        let landState = ResearchState(subject: landSubject)
        let landHypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: landState, snapshot: landSnapshot, childMMNs: [:]
        )

        // Brooks subject.
        let brooksSubject = makeSubject(profileID: "brooks", surname: "Brooks")
        let brooksSnapshot = snapshotWith(subjectID: "brooks", children: [child])
        let brooksState = ResearchState(subject: brooksSubject)
        let brooksHypotheses = HypothesisEngine.generateSubjectSpouseMarriage(
            state: brooksState, snapshot: brooksSnapshot, childMMNs: [:]
        )

        guard case .subjectSpouseMarriage(let landGroom, let landBride, _) = landHypotheses.first?.kind,
              case .subjectSpouseMarriage(let brooksGroom, let brooksBride, _) = brooksHypotheses.first?.kind
        else {
            Issue.record("expected one hypothesis each")
            return
        }
        #expect(landGroom == "Brooks" && landBride == "Land")
        #expect(brooksGroom == "Brooks" && brooksBride == "Land")
        #expect(landGroom == brooksGroom && landBride == brooksBride,
                "same marriage anchor regardless of subject")
    }

    @Test func reconcile_femaleMaidenStoredPicksBrideGiven() {
        // Land subject (female), .supported hypothesis with two BMD
        // records: Brooks-indexed (groom John) + Land-indexed (bride Mary).
        // pickSubjectGivenName(.female) → brideGiven = "Mary".
        let kind = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Land",
            childYearWindow: 1884...1915
        )
        let groomRec = marriageRecord(
            id: "m-g", surname: "Brooks", givenName: "John",
            spouseSurname: "Land", year: 1900
        )
        let brideRec = marriageRecord(
            id: "m-b", surname: "Land", givenName: "Mary",
            spouseSurname: "Brooks", year: 1900
        )
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "land"),
            subjectProfileID: "land", kind: kind,
            verdict: .supported, isModelAssisted: false,
            supportingEvidence: ["m-g", "m-b"], contradictingEvidence: [],
            reasoning: "test", createdAt: Date(), lastTestedAt: Date(),
            attempts: 1, history: []
        )
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [h], scoredRecords: [groomRec, brideRec],
            resolvedGender: .female
        )
        guard case .applyName(let name, _, _, _, _, _) = decision else {
            Issue.record("expected .applyName, got \(decision)")
            return
        }
        #expect(name == "Mary", "female subject → bride-side given (Land-indexed record)")
    }

    @Test func reconcile_maleSubjectPicksGroomGivenUnderNewPayload() {
        // Sanity check: the rename doesn't break the male path.
        let kind = HypothesisKind.subjectSpouseMarriage(
            groomSurname: "Brooks", brideSurname: "Land",
            childYearWindow: 1884...1915
        )
        let groomRec = marriageRecord(
            id: "m-g", surname: "Brooks", givenName: "John",
            spouseSurname: "Land", year: 1900
        )
        let brideRec = marriageRecord(
            id: "m-b", surname: "Land", givenName: "Mary",
            spouseSurname: "Brooks", year: 1900
        )
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "brooks"),
            subjectProfileID: "brooks", kind: kind,
            verdict: .supported, isModelAssisted: false,
            supportingEvidence: ["m-g", "m-b"], contradictingEvidence: [],
            reasoning: "test", createdAt: Date(), lastTestedAt: Date(),
            attempts: 1, history: []
        )
        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: [h], scoredRecords: [groomRec, brideRec],
            resolvedGender: .male
        )
        guard case .applyName(let name, _, _, _, _, _) = decision else {
            Issue.record("expected .applyName")
            return
        }
        #expect(name == "John")
    }

    @Test func generator_skipsChildWithoutSurname() {
        // (groom, bride) requires BOTH child.lastName AND MMN. Child
        // with missing surname → skip the anchor, not crash.
        let subject = makeSubject(profileID: "s")
        let child = makeChildProfile(
            id: "c1", surname: "", givenName: "?",
            mmn: "Smith", birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)
        #expect(HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        ).isEmpty, "child without surname = no (groom, bride) pair = no hypothesis")
    }

    @Test func generator_skipsPairThatDoesntInvolveSubject() {
        // Defensive guard: if for whatever reason the derived (groom,
        // bride) pair doesn't contain subject.surname (e.g. a re-parented
        // child anchor), skip that pair rather than emitting a hypothesis
        // about someone else's marriage.
        let subject = makeSubject(profileID: "s", surname: "Zeta")
        let child = makeChildProfile(
            id: "c1", surname: "Brooks", givenName: "Tom",
            mmn: "Smith", birthYear: 1885
        )
        let snapshot = snapshotWith(subjectID: "s", children: [child])
        let state = ResearchState(subject: subject)
        #expect(HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: [:]
        ).isEmpty, "Zeta isn't in the Brooks×Smith marriage — no hypothesis")
    }
}
