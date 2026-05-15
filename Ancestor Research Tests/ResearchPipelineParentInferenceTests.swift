import Testing
import Foundation
@testable import Ancestor_Research

/// Change 3 — Parent Inference from confirmed birth records.
/// Verifies ParentInferenceEngine against acceptance criteria AC3.1-AC3.6.
struct ResearchPipelineParentInferenceTests {

    // MARK: - Helpers

    private let transcriptionSources: [String: SourceInfo] = [
        "freebmd": SourceInfo(
            sourceID: "freebmd",
            lineage: .independentTranscription(of: "GRO-indexes"),
            trustTier: .transcription,
            directness: .directTranscription
        ),
        "findagrave": SourceInfo(
            sourceID: "findagrave",
            lineage: .communityEdited,
            trustTier: .community,
            directness: .derivative
        ),
    ]

    private func birthFact(
        id: String = UUID().uuidString,
        sourceID: String = "freebmd",
        surname: String = "Cauldwell",
        givenName: String = "Darryl",
        birthYear: Int? = 1976,
        mothersMaidenName: String? = "Holmes"
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: sourceID, name: nil,
            surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
        let birth = BirthRecord(
            common: common, birthYear: birthYear, birthDate: nil,
            birthPlace: nil, quarter: nil, district: nil,
            volume: nil, page: nil, mothersMaidenName: mothersMaidenName
        )
        return ScoredRecord(
            id: id, record: .birth(birth),
            verdict: .fact, gates: [], summary: ""
        )
    }

    private func subject(
        profileID: String? = "subj-1",
        surname: String? = "Cauldwell",
        givenName: String? = "Darryl",
        birthYear: Int? = 1976
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: profileID,
            surname: surname,
            givenName: givenName,
            birthYearFrom: birthYear,
            birthYearTo: birthYear,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: nil,
            mode: .extend,
            familyContext: nil
        )
    }

    private func profile(
        id: String,
        firstName: String? = nil,
        lastName: String?,
        gender: Gender
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName,
            gender: gender, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil,
            isDeleted: false, sources: [:], disputes: [:]
        )
    }

    // MARK: - AC3.1 — Mother and father both proposed from a confirmed birth record

    @Test func proposesMotherAndFatherFromBirthRecordWithMaidenName() {
        let fact = birthFact()
        let proposals = ParentInferenceEngine.infer(
            from: [fact],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )

        #expect(proposals.count == 2)

        let mother = proposals.first { $0.gender == .female }
        let father = proposals.first { $0.gender == .male }

        #expect(mother != nil)
        #expect(mother?.proposedSurname == "Holmes")
        #expect(mother?.proposedGivenName == nil)

        #expect(father != nil)
        #expect(father?.proposedSurname == "Cauldwell")
        #expect(father?.proposedGivenName == nil)

        // Birth window: subject birth 1976 → parents born 1931..1958
        #expect(mother?.birthYearLow == 1931)
        #expect(mother?.birthYearHigh == 1958)
        #expect(father?.birthYearLow == 1931)
        #expect(father?.birthYearHigh == 1958)

        // Both proposals carry the originating fact
        #expect(mother?.evidence.count == 1)
        #expect(father?.evidence.count == 1)
        #expect(mother?.evidence.first?.id == fact.id)
    }

    // MARK: - AC3.2 — Existing parents do NOT suppress the proposal at engine level
    //
    // Earlier the engine silently dropped proposals matching existingParents,
    // which made re-research show no Proposed Relatives section at all once the
    // user had accepted them. The engine now always emits both proposals; UI
    // surfaces "Already linked" status by joining against the live snapshot.

    @Test func emitsBothParentProposalsEvenWhenMotherAlreadyExists() {
        let existingMother = profile(id: "mum-1", lastName: "Holmes", gender: .female)
        let proposals = ParentInferenceEngine.infer(
            from: [birthFact()],
            subject: subject(),
            existingParents: [existingMother],
            sourceInfoMap: transcriptionSources
        )
        // Both still proposed — UI handles already-linked display
        #expect(proposals.count == 2)
        #expect(proposals.contains { $0.gender == .female && $0.proposedSurname == "Holmes" })
        #expect(proposals.contains { $0.gender == .male && $0.proposedSurname == "Cauldwell" })
    }

    @Test func emitsBothParentProposalsEvenWhenFatherAlreadyExists() {
        let existingFather = profile(id: "dad-1", lastName: "Cauldwell", gender: .male)
        let proposals = ParentInferenceEngine.infer(
            from: [birthFact()],
            subject: subject(),
            existingParents: [existingFather],
            sourceInfoMap: transcriptionSources
        )
        #expect(proposals.count == 2)
    }

    // MARK: - AC3.3 — Pre-1911 records (no mothersMaidenName) yield no proposals

    @Test func preMaidenNameBirthRecordYieldsNoProposals() {
        let fact = birthFact(mothersMaidenName: nil)
        let proposals = ParentInferenceEngine.infer(
            from: [fact],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        #expect(proposals.isEmpty)
    }

    @Test func emptyMaidenNameStringYieldsNoProposals() {
        let fact = birthFact(mothersMaidenName: "   ")
        let proposals = ParentInferenceEngine.infer(
            from: [fact],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        #expect(proposals.isEmpty)
    }

    // MARK: - Trust tier gate

    @Test func communityTierRecordYieldsNoProposals() {
        // Same maiden name but recorded by a community-tier source — skipped by trust gate
        let fact = birthFact(sourceID: "findagrave")
        let proposals = ParentInferenceEngine.infer(
            from: [fact],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        #expect(proposals.isEmpty)
    }

    // MARK: - Subject must have profileID

    @Test func noProposalsWithoutSubjectProfileID() {
        let proposals = ParentInferenceEngine.infer(
            from: [birthFact()],
            subject: subject(profileID: nil),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        #expect(proposals.isEmpty)
    }

    // MARK: - Stability across iterations

    @Test func stableIDsPreventDuplicateProposalsAcrossIterations() {
        let fact = birthFact()
        let firstPass = ParentInferenceEngine.infer(
            from: [fact],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        // Second pass: pass first pass as existing — should not double up
        let secondPass = ParentInferenceEngine.infer(
            from: [fact],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources,
            existing: firstPass
        )
        #expect(secondPass.count == firstPass.count)
        #expect(Set(secondPass.map(\.id)) == Set(firstPass.map(\.id)))
    }

    @Test func stableIDsContainSubjectAndRoleAndSurname() {
        let proposals = ParentInferenceEngine.infer(
            from: [birthFact()],
            subject: subject(profileID: "subj-1"),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        let mother = proposals.first { $0.gender == .female }
        let father = proposals.first { $0.gender == .male }

        #expect(mother?.id == "parentOf:subj-1:female:HOLMES")
        #expect(father?.id == "parentOf:subj-1:male:CAULDWELL")
    }

    // MARK: - Multiple birth facts dedup against each other

    @Test func multipleBirthFactsProduceOneProposalPerParent() {
        let fact1 = birthFact(id: "b1")
        let fact2 = birthFact(id: "b2")
        let proposals = ParentInferenceEngine.infer(
            from: [fact1, fact2],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        // Still just one mother + one father, dedup by stable id
        #expect(proposals.count == 2)
    }

    // MARK: - Subject birth year from record overrides subject estimate

    @Test func usesBirthRecordYearWhenSubjectHasNone() {
        let fact = birthFact(birthYear: 1950)
        let proposals = ParentInferenceEngine.infer(
            from: [fact],
            subject: subject(birthYear: nil),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        let mother = proposals.first { $0.gender == .female }
        #expect(mother?.birthYearLow == 1905)   // 1950 - 45
        #expect(mother?.birthYearHigh == 1932)  // 1950 - 18
    }

    // MARK: - Confidence reflects source trust tier

    @Test func transcriptionTierGivesModerateConfidence() {
        let proposals = ParentInferenceEngine.infer(
            from: [birthFact()],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )
        #expect(proposals.first?.confidence == .moderate)
    }

    // MARK: - Lead-verdict records also propose parents (broadened gate)

    @Test func leadVerdictRecordStillProposesParents() {
        let common = RecordCommon(
            id: "lead-b1", sourceID: "freebmd", name: nil,
            surname: "Cauldwell", givenName: "Darryl",
            detailURL: nil, rawFields: [:]
        )
        let birth = BirthRecord(
            common: common, birthYear: 1976, birthDate: nil,
            birthPlace: nil, quarter: nil, district: "Belper",
            volume: nil, page: nil, mothersMaidenName: "Holmes"
        )
        let scoredLead = ScoredRecord(
            id: "lead-b1", record: .birth(birth),
            verdict: .lead, gates: [], summary: ""
        )

        let proposals = ParentInferenceEngine.infer(
            from: [scoredLead],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )

        // Both parents proposed even though the source record was a lead
        #expect(proposals.count == 2)
        // Confidence drops a tier — moderate-tier source as lead → weak
        let mother = proposals.first { $0.gender == .female }
        #expect(mother?.confidence == .weak)
    }

    @Test func impossibleRecordsDoNotProposeParents() {
        let common = RecordCommon(
            id: "imp-b1", sourceID: "freebmd", name: nil,
            surname: "Cauldwell", givenName: "Darryl",
            detailURL: nil, rawFields: [:]
        )
        let birth = BirthRecord(
            common: common, birthYear: 1700, birthDate: nil,
            birthPlace: nil, quarter: nil, district: nil,
            volume: nil, page: nil, mothersMaidenName: "Holmes"
        )
        let scoredImpossible = ScoredRecord(
            id: "imp-b1", record: .birth(birth),
            verdict: .impossible, gates: [], summary: ""
        )

        let proposals = ParentInferenceEngine.infer(
            from: [scoredImpossible],
            subject: subject(),
            existingParents: [],
            sourceInfoMap: transcriptionSources
        )

        // Impossible verdicts are gated out — name/date hard-fail means this
        // isn't the right person and the maiden name belongs to someone else
        #expect(proposals.isEmpty)
    }
}
