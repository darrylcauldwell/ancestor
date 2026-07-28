import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// CENSUS_PARENT_UNLOCK_SPEC Change 2 — the audit that surfaces a parentless
/// ancestor's already-found childhood census as a parent-unlock.
struct CensusParentUnlockAuditTests {

    /// A census evidence row for the subject, as research surfaces it.
    private func census(id: String = UUID().uuidString, year: Int, age: Int?,
                        birthYear: Int? = nil, birthCounty: String? = nil,
                        birthPlace: String? = nil, district: String? = nil,
                        verdict: RecordVerdict = .lead) -> EvidenceRecord {
        let common = RecordCommon(id: "freecen_census_\(id)", sourceID: "freecen", rawFields: [:])
        let rec = CensusRecord(common: common, censusYear: year, age: age, birthYear: birthYear,
                               birthPlace: birthPlace, birthCounty: birthCounty, district: district)
        return EvidenceRecord(
            id: EvidenceRecord.compositeID(profileID: "@G@", sourceRecordID: common.id),
            profileID: "@G@", sourceID: "freecen", sourceRecordID: common.id,
            recordType: .census, verdict: verdict, record: .census(rec),
            citationFull: "cite", citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: .unreviewed)
    }

    // George Keyworth's census leads: two Notts (Halam best-age, Carrington),
    // one Middlesex namesake, plus adult own-household censuses.
    private var georgeLeads: [EvidenceRecord] {
        [census(id: "halam", year: 1851, age: 13, birthYear: 1835, birthCounty: "Nottinghamshire"),
         census(id: "carr", year: 1851, age: 9, birthYear: 1842, birthCounty: "Nottinghamshire"),
         census(id: "hants", year: 1851, age: 12, birthYear: 1839, birthCounty: "Middlesex"),
         census(id: "own1881", year: 1881, age: 43, birthYear: 1838, birthCounty: "Nottinghamshire")]
    }

    @Test func firesForParentlessProfileWithChildhoodCensus() {
        let f = CensusParentUnlockAudit.finding(
            profileID: "@G@", profileName: "George Keyworth",
            birthYear: 1838, birthLocation: "Farnsfield, Nottinghamshire",
            hasParents: false, evidence: georgeLeads)
        #expect(f != nil)
        #expect(f?.severity == .warning)
        #expect(f?.category == .gap)
        #expect(f?.ruleID == "censusParentUnlock")
        #expect(f?.message.contains("1851") == true)
    }

    @Test func winningCensusIsTheCountyAndAgeMatch() {
        // The fix reads relatedProfileIDs.first to know which census to apply —
        // it must be the 1851 Halam (Notts, b.1835) row.
        let f = CensusParentUnlockAudit.finding(
            profileID: "@G@", profileName: "George Keyworth",
            birthYear: 1838, birthLocation: "Farnsfield, Nottinghamshire",
            hasParents: false, evidence: georgeLeads)
        #expect(f?.relatedProfileIDs?.first?.contains("halam") == true)
    }

    @Test func silentWhenParentsAlreadyKnown() {
        let f = CensusParentUnlockAudit.finding(
            profileID: "@G@", profileName: "George Keyworth",
            birthYear: 1838, birthLocation: "Farnsfield, Nottinghamshire",
            hasParents: true, evidence: georgeLeads)
        #expect(f == nil)
    }

    @Test func silentWhenOnlyAdultCensusesFound() {
        // A parentless person whose only census is their own adult household —
        // nothing to lift into parents.
        let f = CensusParentUnlockAudit.finding(
            profileID: "@G@", profileName: "George Keyworth",
            birthYear: 1838, birthLocation: "Nottinghamshire", hasParents: false,
            evidence: [census(id: "own1881", year: 1881, age: 43, birthCounty: "Nottinghamshire")])
        #expect(f == nil)
    }

    @Test func silentWithoutABirthYearAnchor() {
        // No birth year → no childhood window can be computed.
        let f = CensusParentUnlockAudit.finding(
            profileID: "@G@", profileName: "George Keyworth",
            birthYear: nil, birthLocation: "Nottinghamshire", hasParents: false,
            evidence: georgeLeads)
        #expect(f == nil)
    }

    @Test func silentWhenNoCensusEvidenceAtAll() {
        let f = CensusParentUnlockAudit.finding(
            profileID: "@G@", profileName: "George Keyworth",
            birthYear: 1838, birthLocation: "Nottinghamshire", hasParents: false, evidence: [])
        #expect(f == nil)
    }

    @Test func excludesRecordsTheScorerRuledImpossible() {
        // A same-county childhood-window census that would otherwise WIN, but the
        // scorer already killed it as .impossible → it must not be a candidate.
        let cands = CensusParentUnlockAudit.candidates(from: [
            census(id: "killed", year: 1851, age: 13, birthYear: 1835,
                   birthCounty: "Nottinghamshire", verdict: .impossible)])
        #expect(cands.isEmpty)

        // And the finding falls silent when the only in-window census is impossible.
        let f = CensusParentUnlockAudit.finding(
            profileID: "@G@", profileName: "George Keyworth",
            birthYear: 1838, birthLocation: "Nottinghamshire", hasParents: false,
            evidence: [census(id: "killed", year: 1851, age: 13, birthYear: 1835,
                              birthCounty: "Nottinghamshire", verdict: .impossible)])
        #expect(f == nil)
    }

    @Test func candidateMapperDerivesImpliedYearFromAgeWhenBirthYearAbsent() {
        // No explicit birthYear on the row → censusYear − age.
        let cands = CensusParentUnlockAudit.candidates(
            from: [census(id: "x", year: 1851, age: 13, birthYear: nil, birthCounty: "Nottinghamshire")])
        #expect(cands.count == 1)
        #expect(cands.first?.impliedBirthYear == 1838)
        #expect(cands.first?.place == "Nottinghamshire")
    }
}
