import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `SiblingInferenceEngine.inferSiblings`.
///
/// Canonical scenario: Darryl Cauldwell is the subject. His birth record
/// shows surname=Cauldwell, MMN=Holmes, district=Belper, year=1976. A
/// hypothetical sister would have surname=Cauldwell, MMN=Holmes,
/// district=Belper, year≈1976±20. Other Cauldwell births (different MMN
/// or district) should be rejected.
struct SiblingInferenceEngineTests {

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
        return ScoredRecord(
            id: id,
            record: .birth(birth),
            verdict: .fact,
            gates: [],
            summary: ""
        )
    }

    private func profile(id: String, gender: Gender) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: nil, middleName: nil, lastName: nil, nickName: nil,
            mothersMaidenName: nil, gender: gender, attributes: nil,
            birthDate: nil, birthLocation: nil, birthLocationCode: nil,
            deathDate: nil, deathLocation: nil, deathLocationCode: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func emptySnapshot() -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [:], relationships: [])
    }

    // MARK: - Tests

    @Test func findsSiblingWithSameSurnameMMNAndDistrict() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let sister = birthRecord(
            id: "sister", surname: "Cauldwell", givenName: "Sarah",
            mmn: "Holmes", district: "Belper", year: 1978
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [subjectRecord, sister],
            knownFatherID: "father-id",
            knownMotherID: "mother-id",
            snapshot: emptySnapshot()
        )

        #expect(siblings.count == 1)
        #expect(siblings.first?.proposedGivenName == "Sarah")
        #expect(siblings.first?.fatherID == "father-id")
        #expect(siblings.first?.motherID == "mother-id")
    }

    @Test func excludesSubjectFromResults() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [subjectRecord],
            knownFatherID: "f", knownMotherID: "m",
            snapshot: emptySnapshot()
        )
        #expect(siblings.isEmpty, "subject's own record shouldn't appear as a sibling")
    }

    @Test func rejectsDifferentMMN() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let cousin = birthRecord(
            id: "cousin", surname: "Cauldwell", givenName: "Jane",
            mmn: "Smith", district: "Belper", year: 1977
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [cousin],
            knownFatherID: "f", knownMotherID: "m",
            snapshot: emptySnapshot()
        )
        #expect(siblings.isEmpty, "different MMN = different mother = not a sibling")
    }

    @Test func acceptsDifferentDistrict_sameCounty() {
        // Post-audit-fix behaviour: cross-district siblings with matching
        // MMN are real and accepted. Helen Clare Cauldwell (Derby 3A/177S,
        // MMN=Holmes) is Darryl Cauldwell's (Belper, MMN=Holmes) actual
        // sister — different district, same county, same parents. The
        // orchestrator's deficit-query already restricts the candidate
        // pool to the subject's home Chapman code, so trusting MMN is
        // sufficient at the per-record stage.
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let elsewhere = birthRecord(
            id: "else", surname: "Cauldwell", givenName: "Helen",
            mmn: "Holmes", district: "Derby", year: 1973
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [elsewhere],
            knownFatherID: "f", knownMotherID: "m",
            snapshot: emptySnapshot()
        )
        #expect(siblings.count == 1, "cross-district sibling with matching MMN should now be accepted")
    }

    @Test func rejectsBeyondMaxAgeGap() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let waterer = birthRecord(
            id: "old", surname: "Cauldwell", givenName: "Albert",
            mmn: "Holmes", district: "Belper", year: 1950  // 26 years older
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [waterer],
            knownFatherID: "f", knownMotherID: "m",
            snapshot: emptySnapshot()
        )
        #expect(siblings.isEmpty, "26-year gap exceeds the 20-year max; reject as implausible sibling")
    }

    @Test func acceptsTwentyYearGapAtBoundary() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let olderSister = birthRecord(
            id: "older", surname: "Cauldwell", givenName: "Mary",
            mmn: "Holmes", district: "Belper", year: 1956  // exactly 20 years
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [olderSister],
            knownFatherID: "f", knownMotherID: "m",
            snapshot: emptySnapshot()
        )
        #expect(siblings.count == 1, "20-year gap is at the inclusive boundary, should pass")
    }

    @Test func handlesMissingMMNGracefully() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: nil, district: "Belper", year: 1976
        )
        let candidate = birthRecord(
            id: "c", surname: "Cauldwell", givenName: "Sarah",
            mmn: "Holmes", district: "Belper", year: 1978
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [candidate],
            knownFatherID: "f", knownMotherID: "m",
            snapshot: emptySnapshot()
        )
        #expect(siblings.isEmpty, "no MMN on subject = no key to match siblings on")
    }

    @Test func sortsResultsByBirthYear() {
        let subjectRecord = birthRecord(
            id: "subj", surname: "Cauldwell", givenName: "Darryl",
            mmn: "Holmes", district: "Belper", year: 1976
        )
        let younger = birthRecord(
            id: "y", surname: "Cauldwell", givenName: "Tom",
            mmn: "Holmes", district: "Belper", year: 1982
        )
        let older = birthRecord(
            id: "o", surname: "Cauldwell", givenName: "Mary",
            mmn: "Holmes", district: "Belper", year: 1970
        )

        let siblings = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectRecord,
            candidateRecords: [younger, older],
            knownFatherID: "f", knownMotherID: "m",
            snapshot: emptySnapshot()
        )
        #expect(siblings.map(\.proposedGivenName) == ["Mary", "Tom"],
                "candidates should be sorted by birth year ascending")
    }
}
