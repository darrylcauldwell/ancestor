import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// District affinity — a positive-only ranking signal in BiographicalFitEvaluator.
/// A candidate birth record whose registration district is one the subject's
/// immediate family is known to live in earns an extra corroborating match, so
/// it wins the corroboration tie-break among otherwise-equal same-name
/// namesakes. Anchored to the real "Eve Land" case: a Belper birth outranks a
/// distant-district namesake. It must NEVER penalise records outside the family
/// district (real lives span districts) nor rescue an implausible candidate.
@MainActor
struct DistrictAffinityTests {

    // MARK: - Location → district mining

    @Test func minesDistrictFromFreeformLocation() {
        let d = BiographicalFitEvaluator.districtsInLocation("Belper, Derbyshire, England")
        #expect(d.contains("belper"))
    }

    @Test func unrecognisedLocationYieldsNoDistrict() {
        #expect(BiographicalFitEvaluator.districtsInLocation("Atlantis, Nowhere").isEmpty)
        #expect(BiographicalFitEvaluator.districtsInLocation(nil).isEmpty)
    }

    // MARK: - Record → district

    @Test func birthRecordExposesItsDistrict() {
        #expect(BiographicalFitEvaluator.district(of: birthRecord(id: "b", year: 1894, district: "Belper").record) == "belper")
    }

    @Test func burialRecordHasNoAnchoringDistrict() {
        // Burial place doesn't reliably anchor to where a person lived.
        let common = RecordCommon(id: "bur1", sourceID: "findagrave",
                                  name: "Eve Land", surname: "Land", givenName: "Eve",
                                  detailURL: nil, rawFields: [:])
        let burial = SourceRecord.burial(BurialRecord(
            common: common, deathYear: 1964,
            burialLocation: "Cathays Cemetery, Cardiff, Wales",
            cemetery: "Cathays", isVeteran: false))
        #expect(BiographicalFitEvaluator.district(of: burial) == nil)
    }

    // MARK: - Corroboration bump

    @Test func familyDistrictCandidateWinsCorroborationTieBreak() {
        // Two same-name birth candidates, same year, no other anchors. One is
        // in Belper (a family district via the subject's sibling Ida), one in a
        // distant district. The Belper candidate must carry more corroboration.
        let belper = birthRecord(id: "belper", year: 1894, district: "Belper")
        let distant = birthRecord(id: "distant", year: 1894, district: "Cardiff")

        let results = BiographicalFitEvaluator.evaluate(
            candidates: [distant, belper],
            subject: eveSubject(),
            deathRecords: [],
            snapshot: eveSnapshot())

        let belperResult = results.first { $0.candidate.record.id == "belper" }
        let distantResult = results.first { $0.candidate.record.id == "distant" }
        #expect(belperResult != nil && distantResult != nil)
        #expect(belperResult!.corroboratingMatches > distantResult!.corroboratingMatches,
                "the Belper (family-district) candidate must gain a corroboration bump")
    }

    @Test func noPenaltyForCandidateOutsideFamilyDistrict() {
        // A lone candidate outside the family district keeps full plausibility —
        // affinity is a positive signal, never a demotion. Real lives span
        // districts (born Belper, died Ilkeston), so no penalty may apply.
        let distant = birthRecord(id: "distant", year: 1894, district: "Cardiff")
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [distant],
            subject: eveSubject(),
            deathRecords: [],
            snapshot: eveSnapshot())
        #expect(results.first?.plausibility == 1.0)
    }

    // MARK: - Fixtures

    private func birthRecord(id: String, year: Int, district: String) -> ScoredRecord {
        let common = RecordCommon(id: id, sourceID: "freebmd",
                                  name: "Eve Land", surname: "Land", givenName: "Eve",
                                  detailURL: nil, rawFields: [:])
        let r = BirthRecord(common: common, birthYear: year, birthDate: nil,
                            birthPlace: district, quarter: nil, district: district,
                            volume: nil, page: nil, mothersMaidenName: nil)
        return ScoredRecord(id: id, record: .birth(r), verdict: .lead, gates: [], summary: "")
    }

    /// Subject = dateless "Eve Land"; her sibling Ida was born in Belper,
    /// establishing Belper as a family district. No own DOB or children, so the
    /// only biographical anchor in play is district affinity.
    private func eveSubject() -> ResearchSubject {
        var s = ResearchSubject(profileID: "eve", surname: "Land", givenName: "Eve", mode: .discover)
        s.homeChapmanCode = "DBY"
        return s
    }

    private func eveSnapshot() -> FamilyGraphSnapshot {
        let mother = profile(id: "mother", given: "Mary", birthLocation: nil)
        let ida = profile(id: "ida", given: "Ida", birthLocation: "Belper, Derbyshire, England")
        let eve = profile(id: "eve", given: "Eve", birthLocation: nil)
        var profiles: [String: Profile] = [mother.id: mother, ida.id: ida, eve.id: eve]
        var rels: [Relationship] = []
        for kid in [eve, ida] {
            rels.append(Relationship(
                id: UUID(), from: mother.id, to: kid.id, type: .parent,
                role: .mother, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        }
        return FamilyGraphSnapshot(profiles: profiles, relationships: rels)
    }

    private func profile(id: String, given: String, birthLocation: String?) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: given, middleName: nil, lastName: "Land",
                marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
                gender: .female, attributes: nil,
                birthDate: nil, birthLocation: birthLocation, birthLocationCode: nil,
                deathDate: nil, deathLocation: nil, deathLocationCode: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }
}
