import Testing
import Foundation
@testable import Ancestor_Research

/// T12-sibling Phase 1 invariants (V2 spec §5.2): the legacy
/// `proposedSiblings` field and the new `.siblingExists` hypothesis must
/// agree about which records are sibling candidates.
///
/// Phase 1 doesn't yet move the inference into the engine — it ships a
/// pipeline-side mapping (`buildSiblingExistsHypothesis`) that takes the
/// legacy `findSiblings` output and shapes it into the hypothesis form.
/// Both surfaces are populated from the same `SiblingSearchOutcome`, so
/// equality here is the "didn't accidentally drop data in translation"
/// check. Phase 2 deletes the legacy path and the hypothesis becomes
/// the only source of truth.
@MainActor
struct T12SiblingPhase1Tests {

    // MARK: - Helpers

    private func date(_ year: Int) -> GenealogicalDate {
        GenealogicalDate(
            original: "\(year)",
            earliest: year,
            latest: year,
            isApproximate: false,
            qualifier: .yearOnly
        )
    }

    private func birthRecord(
        id: String,
        surname: String,
        givenName: String,
        mmn: String?,
        district: String?,
        year: Int
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
        return ScoredRecord(id: id, record: .birth(birth), verdict: .fact, gates: [], summary: "")
    }

    // MARK: - buildSiblingExistsHypothesis

    @Test func buildHypothesis_supportedWhenProposalsExist() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let sister = birthRecord(
            id: "sister", surname: "Cauldwell", givenName: "Sarah",
            mmn: "Holmes", district: "Belper", year: 1978
        )
        let proposals = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [subjectRecord, sister],
            knownFatherID: "father-id",
            knownMotherID: "mother-id",
            snapshot: FamilyGraphSnapshot(profiles: [:], relationships: [])
        )
        #expect(proposals.count == 1)

        let h = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj-profile",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: proposals
        )

        #expect(h.verdict == .supported)
        #expect(h.supportingEvidence == ["sister"])
        #expect(h.contradictingEvidence.isEmpty)
        #expect(h.isModelAssisted == false)
        #expect(h.isDeterministicallySupported == true)
        if case .siblingExists(let district, let mmn, let window) = h.kind {
            #expect(district == "Belper")
            #expect(mmn == "Holmes")
            #expect(window == 1956...1996)
        } else {
            Issue.record("hypothesis kind should be .siblingExists")
        }
    }

    @Test func buildHypothesis_contradictedWhenNoProposals() {
        let h = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj-profile",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: []
        )
        #expect(h.verdict == .contradicted)
        #expect(h.supportingEvidence.isEmpty)
        #expect(h.isDeterministicallySupported == false)
        #expect(h.reasoning.contains("0 matching candidates"))
    }

    @Test func buildHypothesis_stableIdAcrossRuns() {
        let proposals1: [SiblingProposal] = []
        let proposals2: [SiblingProposal] = []   // identical second run
        let h1 = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: proposals1
        )
        let h2 = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: proposals2
        )
        // Stable ID = re-runs upsert rather than duplicate (Decision 1).
        #expect(h1.id == h2.id)
    }

    @Test func buildHypothesis_supportingEvidenceMatches_proposalsCandidateIDs() {
        // The Phase 1 invariant: hypothesis.supportingEvidence must be
        // 1:1 with the candidateRecordIDs of the legacy proposals (just
        // in a different shape). Phase 2 lets the hypothesis become the
        // source of truth; this test guards against silent drift before
        // that swap.
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let sister1 = birthRecord(
            id: "sister-1", surname: "Cauldwell", givenName: "Sarah",
            mmn: "Holmes", district: "Belper", year: 1978
        )
        let sister2 = birthRecord(
            id: "sister-2", surname: "Cauldwell", givenName: "Mary",
            mmn: "Holmes", district: "Belper", year: 1970
        )
        let proposals = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [subjectRecord, sister1, sister2],
            knownFatherID: "father-id",
            knownMotherID: "mother-id",
            snapshot: FamilyGraphSnapshot(profiles: [:], relationships: [])
        )
        let h = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj-profile",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: proposals
        )
        #expect(Set(h.supportingEvidence) == Set(proposals.map(\.candidateRecordID)))
    }

    // MARK: - deficitQuerySiblingExists

    @Test func deficitQuery_level1_returnsFreeBMDQuery() throws {
        let h = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj-profile",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: []
        )
        var subject = ResearchSubject(
            profileID: "subj-profile", surname: "Cauldwell", givenName: nil,
            middleName: nil,
            birthYearFrom: 1976, birthYearTo: 1976,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
        _ = subject
        let state = ResearchState(subject: subject)

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

    @Test func deficitQuery_level2_returnsNil_inPhase1() {
        let h = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj-profile",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: []
        )
        let subject = ResearchSubject(
            profileID: "subj-profile", surname: "Cauldwell", givenName: nil,
            middleName: nil,
            birthYearFrom: 1976, birthYearTo: 1976,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
        let state = ResearchState(subject: subject)
        let query = HypothesisEngine.deficitQuerySiblingExists(
            for: h, atLevel: 2, state: state
        )
        #expect(query == nil, "Phase 1 ladder ceiling is level 1; ≥2 is exhausted")
    }

    @Test func deficitQuery_returnsNil_whenSubjectSurnameMissing() {
        let h = ResearchPipeline.buildSiblingExistsHypothesis(
            subjectProfileID: "subj-profile",
            district: "Belper",
            mmn: "Holmes",
            yearWindow: 1956...1996,
            proposals: []
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
