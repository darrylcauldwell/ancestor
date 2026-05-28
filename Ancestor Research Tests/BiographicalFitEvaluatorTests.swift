import Testing
import Foundation
@testable import Ancestor_Research

/// Slice C — biographical-fit reasoning. Pins the three rules from
/// `BiographicalFitEvaluator`:
///   • infant-death elimination
///   • age-at-death back-calculation
///   • children-age plausibility (14-65 father-age window)
///
/// George H Brooks is the canonical fixture — the same case I worked
/// through manually via Python earlier in the session. The fixture
/// faithfully reproduces the two competing birth candidates the engine
/// sees in his FreeBMD search: George Brooks b 1870 (an infant who died
/// 1871) vs George Brooks b 1883 (the actual subject, died 1937 age 53).
/// A correct evaluator rules out 1870 and confirms 1883.
@MainActor
struct BiographicalFitEvaluatorTests {

    // MARK: - George H Brooks fixture (the canonical case)

    @Test func georgeBrooks_1870InfantRuledOut_1883Confirmed() {
        let subjectID = "@SUBJ_GEORGE@"
        let lilianID = "@CHILD_LILIAN@"

        // Subject — George Herbert Brooks. Profile lives on the tree;
        // his birth window is wide (1869-1896, derived from his oldest
        // child's birth year per `ResearchSubject.fromProfile`).
        let subject = makeSubject(
            profileID: subjectID,
            surname: "Brooks",
            given: "George",
            birthFrom: 1869, birthTo: 1896
        )
        // Snapshot — subject + one known child Lilian b 1914. This is
        // the biographical anchor: any candidate birth must put the
        // subject in the 14-65 window when Lilian was born.
        let snapshot = makeSnapshot(
            subjectID: subjectID,
            children: [(id: lilianID, birthYear: 1914)]
        )

        // Two competing birth candidates that share the subject's
        // surname + region — exactly what FreeBMD returns for "Brooks
        // birth ~1870-1885 Belper/Basford".
        let infantBirth = makeBirthRecord(
            id: "bmd_1870_infant",
            given: "George", surname: "Brooks",
            year: 1870, place: "Basford"
        )
        let realBirth = makeBirthRecord(
            id: "bmd_1883_subject",
            given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )

        // Death records that disambiguate the two candidates:
        //   • The 1871 death of the infant rules him out (he was
        //     dead before Lilian was born).
        //   • The 1937 death age 53 back-calculates to ~1884, matching
        //     the 1883 candidate within the ±2 tolerance.
        let infantDeath = makeDeathRecord(
            id: "bmd_1871_infant_death",
            given: "George", surname: "Brooks",
            year: 1871, age: 1
        )
        let subjectDeath = makeDeathRecord(
            id: "bmd_1937_subject_death",
            given: "George", surname: "Brooks",
            year: 1937, age: 53
        )

        let results = BiographicalFitEvaluator.evaluate(
            candidates: [infantBirth, realBirth],
            subject: subject,
            deathRecords: [infantDeath, subjectDeath],
            snapshot: snapshot
        )

        #expect(results.count == 2)

        // Results are sorted plausibility-descending — the real birth
        // must be first.
        #expect(results[0].candidateBirthYear == 1883)
        #expect(results[0].plausibility >= 0.8)

        #expect(results[1].candidateBirthYear == 1870)
        #expect(results[1].plausibility == 0.0)
    }

    // MARK: - Rule 1: infant-death elimination

    @Test func rule1_candidateWithMatchingInfantDeath_isRuledOut() {
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1869, birthTo: 1896
        )
        let snapshot = makeSnapshot(
            subjectID: "@SUBJ@",
            children: [(id: "@CHILD@", birthYear: 1914)]
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1870, place: "Basford"
        )
        let infantDeath = makeDeathRecord(
            id: "d1", given: "George", surname: "Brooks",
            year: 1871, age: 1
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [infantDeath],
            snapshot: snapshot
        )
        #expect(results[0].plausibility == 0.0)
        #expect(results[0].reasoning.contains("ruled out"))
    }

    // MARK: - Rule 2: age-at-death back-calculation

    @Test func rule2_ageAtDeathMatch_keepsPlausibility() {
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let snapshot = makeSnapshot(subjectID: "@SUBJ@", children: [])
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        let death = makeDeathRecord(
            id: "d1", given: "George", surname: "Brooks",
            year: 1937, age: 53
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [death],
            snapshot: snapshot
        )
        #expect(results[0].plausibility >= 0.8)
        #expect(results[0].reasoning.contains("age-at-death match"))
    }

    @Test func rule2_ageAtDeathMismatch_lowersPlausibility() {
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let snapshot = makeSnapshot(subjectID: "@SUBJ@", children: [])
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        // Death age 57 in 1937 implies birth ~1880, not 1883 — 3-year
        // gap is outside the ±2 match tolerance but inside the 5-year
        // relevance window, so it counts as a contradicting same-person
        // signal rather than being skipped as "different person".
        let death = makeDeathRecord(
            id: "d1", given: "George", surname: "Brooks",
            year: 1937, age: 57
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [death],
            snapshot: snapshot
        )
        #expect(results[0].plausibility < 0.5)
        #expect(results[0].reasoning.contains("mismatch"))
    }

    // MARK: - Rule 3: children-age plausibility

    @Test func rule3_fatherTooYoungAtFirstChild_isRuledOut() {
        // Candidate born 1905 + first child 1914 = father aged 9. Floor
        // is 14; this candidate is biologically impossible.
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1900, birthTo: 1910
        )
        let snapshot = makeSnapshot(
            subjectID: "@SUBJ@",
            children: [(id: "@CHILD@", birthYear: 1914)]
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1905, place: "Belper"
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [],
            snapshot: snapshot
        )
        #expect(results[0].plausibility == 0.0)
        #expect(results[0].reasoning.contains("ruled out"))
    }

    @Test func rule3_fatherTooOldAtFirstChild_isRuledOut() {
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1840, birthTo: 1850
        )
        let snapshot = makeSnapshot(
            subjectID: "@SUBJ@",
            children: [(id: "@CHILD@", birthYear: 1914)]
        )
        // 1914 - 1840 = 74, exceeds 65-year ceiling.
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1840, place: "Belper"
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [],
            snapshot: snapshot
        )
        #expect(results[0].plausibility == 0.0)
    }

    // MARK: - No-anchor case

    @Test func noChildrenAndNoDeath_plausibilityUnchanged() {
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1860, birthTo: 1900
        )
        let snapshot = makeSnapshot(subjectID: "@SUBJ@", children: [])
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [],
            snapshot: snapshot
        )
        // With no biographical anchors, plausibility starts at 1.0 and
        // no rule fires. The note explains why.
        #expect(results[0].plausibility == 1.0)
        #expect(results[0].reasoning.contains("no biographical anchors"))
    }

    // MARK: - Identity guard — different surname/given doesn't cross-reference

    @Test func identityGuard_differentSurname_deathDoesNotEliminate() {
        // A death record for "Henry Brooks" must not eliminate a birth
        // for "George Brooks" — different person, regardless of year.
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1869, birthTo: 1896
        )
        let snapshot = makeSnapshot(
            subjectID: "@SUBJ@",
            children: [(id: "@CHILD@", birthYear: 1914)]
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1870, place: "Basford"
        )
        let unrelatedDeath = makeDeathRecord(
            id: "d1", given: "Henry", surname: "Brooks",
            year: 1871, age: 1
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [unrelatedDeath],
            snapshot: snapshot
        )
        // Children-age rule still fires (1914 - 1870 = 44, within
        // 14-65), so result is plausible. Crucially, the unrelated
        // Henry death didn't rule it out.
        #expect(results[0].plausibility > 0)
        #expect(results[0].reasoning.contains("parent-age plausible"))
    }

    // MARK: - Helpers

    private func makeSubject(
        profileID: String, surname: String, given: String,
        birthFrom: Int, birthTo: Int
    ) -> ResearchSubject {
        var s = ResearchSubject(
            profileID: profileID, surname: surname, givenName: given,
            mode: .discover
        )
        s.birthYearFrom = birthFrom
        s.birthYearTo = birthTo
        return s
    }

    private func makeSnapshot(
        subjectID: String,
        children: [(id: String, birthYear: Int)]
    ) -> FamilyGraphSnapshot {
        let subjectProfile = makeProfile(id: subjectID, firstName: "George", lastName: "Brooks")
        var profiles: [String: Profile] = [subjectID: subjectProfile]
        var relationships: [Relationship] = []
        for child in children {
            var c = makeProfile(id: child.id, firstName: "Child", lastName: "Brooks")
            c.birthDate = GenealogicalDate(parsing: "\(child.birthYear)")
            profiles[child.id] = c
            relationships.append(Relationship(
                id: UUID(), from: subjectID, to: child.id,
                type: .parent, role: .father, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            ))
        }
        return FamilyGraphSnapshot(profiles: profiles, relationships: relationships)
    }

    private func makeProfile(id: String, firstName: String?, lastName: String?) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, middleName: nil, lastName: lastName,
            marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil, birthLocationCode: nil,
            deathDate: nil, deathLocation: nil, deathLocationCode: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func makeBirthRecord(
        id: String, given: String, surname: String,
        year: Int, place: String?
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd",
            name: "\(given) \(surname)", surname: surname, givenName: given,
            detailURL: nil, rawFields: [:]
        )
        let r = BirthRecord(
            common: common, birthYear: year, birthDate: nil,
            birthPlace: place, quarter: nil, district: place,
            volume: nil, page: nil, mothersMaidenName: nil
        )
        return ScoredRecord(
            id: id, record: .birth(r),
            verdict: .lead, gates: [], summary: ""
        )
    }

    private func makeDeathRecord(
        id: String, given: String, surname: String,
        year: Int, age: Int,
        district: String? = nil
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd",
            name: "\(given) \(surname)", surname: surname, givenName: given,
            detailURL: nil, rawFields: [:]
        )
        let r = DeathRecord(
            common: common, deathYear: year, deathDate: nil,
            deathPlace: nil, age: age, quarter: nil, district: district,
            volume: nil, page: nil, spouseSurname: nil
        )
        return ScoredRecord(
            id: id, record: .death(r),
            verdict: .lead, gates: [], summary: ""
        )
    }

    private func makeCensusRecord(
        id: String, given: String, surname: String,
        censusYear: Int, age: Int,
        district: String? = nil,
        birthCounty: String? = nil
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freecen",
            name: "\(given) \(surname)", surname: surname, givenName: given,
            detailURL: nil, rawFields: [:]
        )
        let r = CensusRecord(
            common: common, censusYear: censusYear,
            age: age, birthYear: nil,
            birthPlace: nil, birthCounty: birthCounty,
            relationship: nil, occupation: nil,
            address: nil, parish: nil, district: district,
            household: nil
        )
        return ScoredRecord(
            id: id, record: .census(r),
            verdict: .lead, gates: [], summary: ""
        )
    }

    // MARK: - Stage 3: chapman-code anchor (slice 4 robustness, 2026-05-28)
    //
    // The pre-stage-3 sameIdentity matched every same-named record
    // nationwide as "could be the subject" — which scrambled the
    // George Brooks 1870-vs-1883 disambiguation by counting cross-county
    // namesake deaths as both corroboration AND penalty inputs.
    // Stage 3 anchors the check on the subject's home chapman code:
    // when the record carries a derivable location, it must match the
    // subject's chapman or the record is excluded entirely.

    @Test func locationFilter_crossCountyDeath_doesNotPenalisePlausibility() {
        // DBY subject; "George Brooks" died in a district that maps to
        // a different chapman code. Implied birth from age would be a
        // ×0.4 mismatch under old logic. Stage 3 excludes the record →
        // plausibility stays 1.0.
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"   // DBY
        )
        // "Marylebone" is a London district (LND in the catalogue) —
        // a same-named different person.
        let crossCountyDeath = makeDeathRecord(
            id: "d-cross", given: "George", surname: "Brooks",
            year: 1906, age: 20, district: "Marylebone"
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [crossCountyDeath],
            snapshot: makeSnapshot(subjectID: "@SUBJ@", children: [])
        )
        #expect(results.count == 1)
        #expect(results[0].plausibility == 1.0)   // no penalty applied
        #expect(results[0].corroboratingMatches == 0)
    }

    @Test func locationFilter_sameCountyDeath_stillCorroborates() {
        // Two DBY death records of "George Brooks" matching candidate
        // 1883 — both pass sameIdentity (record chapman == DBY subject
        // chapman) → both count as corroborating matches.
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        // Both Belper (DBY) and Bakewell (DBY) — same chapman as subject.
        let dByDeath1 = makeDeathRecord(
            id: "d-dby-1", given: "George", surname: "Brooks",
            year: 1949, age: 66, district: "Belper"
        )
        let dByDeath2 = makeDeathRecord(
            id: "d-dby-2", given: "George", surname: "Brooks",
            year: 1957, age: 73, district: "Bakewell"
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [dByDeath1, dByDeath2],
            snapshot: makeSnapshot(subjectID: "@SUBJ@", children: [])
        )
        #expect(results.count == 1)
        #expect(results[0].plausibility == 1.0)
        #expect(results[0].corroboratingMatches == 2)
    }

    @Test func locationFilter_recordMissingDistrict_passesPermissively() {
        // A FreeBMD death record with no district field falls through
        // stage 3's permissive branch — the record is included as if
        // stage 3 didn't run. Maintains backward-compat for sources
        // that don't reliably carry district.
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        let noDistrictDeath = makeDeathRecord(
            id: "d-nd", given: "George", surname: "Brooks",
            year: 1949, age: 66, district: nil   // no location data
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [noDistrictDeath],
            snapshot: makeSnapshot(subjectID: "@SUBJ@", children: [])
        )
        #expect(results[0].corroboratingMatches == 1)
    }

    @Test func locationFilter_crossCountyCensus_doesNotCorroborate() {
        // Census record with district mapping to a different chapman
        // code than subject → excluded from Rule 4.
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        let crossCountyCensus = makeCensusRecord(
            id: "c-cross", given: "George", surname: "Brooks",
            censusYear: 1891, age: 8,
            district: "Marylebone"   // LND
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [],
            snapshot: makeSnapshot(subjectID: "@SUBJ@", children: []),
            censusRecords: [crossCountyCensus]
        )
        #expect(results[0].corroboratingMatches == 0)   // cross-county dropped
    }

    @Test func locationFilter_sameCountyCensus_corroborates() {
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        let dByCensus = makeCensusRecord(
            id: "c-dby", given: "George", surname: "Brooks",
            censusYear: 1891, age: 8,
            district: "Belper"
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [],
            snapshot: makeSnapshot(subjectID: "@SUBJ@", children: []),
            censusRecords: [dByCensus]
        )
        #expect(results[0].corroboratingMatches == 1)
    }

    @Test func locationFilter_censusBirthCountyAsChapman_used() {
        // FreeCen sometimes carries `birthCounty` as a 3-letter chapman
        // code directly. The helper should recognise that without going
        // through the district catalogue.
        let subject = makeSubject(
            profileID: "@SUBJ@", surname: "Brooks", given: "George",
            birthFrom: 1880, birthTo: 1890
        )
        let candidate = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        // No district set; birthCounty is the chapman code "DBY".
        let bcCensus = makeCensusRecord(
            id: "c-bc", given: "George", surname: "Brooks",
            censusYear: 1891, age: 8,
            district: nil, birthCounty: "DBY"
        )
        let results = BiographicalFitEvaluator.evaluate(
            candidates: [candidate],
            subject: subject,
            deathRecords: [],
            snapshot: makeSnapshot(subjectID: "@SUBJ@", children: []),
            censusRecords: [bcCensus]
        )
        #expect(results[0].corroboratingMatches == 1)
    }

    // MARK: - chapmanCode(of:) helper

    @Test func chapmanCodeOf_birthRecord_viaDistrictCatalogue() {
        let r = makeBirthRecord(
            id: "b1", given: "George", surname: "Brooks",
            year: 1883, place: "Belper"
        )
        #expect(BiographicalFitEvaluator.chapmanCode(of: r.record) == "DBY")
    }

    @Test func chapmanCodeOf_deathRecord_viaDistrictCatalogue() {
        let r = makeDeathRecord(
            id: "d1", given: "George", surname: "Brooks",
            year: 1949, age: 66, district: "Belper"
        )
        #expect(BiographicalFitEvaluator.chapmanCode(of: r.record) == "DBY")
    }

    @Test func chapmanCodeOf_censusRecord_prefersBirthCountyWhen3LetterCode() {
        // birthCounty "DBY" takes precedence over district "Marylebone".
        // (Edge case: a Marylebone enumeration district recorded
        // birthCounty = DBY for a Derbyshire-born resident in London.
        // Stage 3 anchors on birth county since that's about the
        // subject's home, not the current enumeration.)
        let r = makeCensusRecord(
            id: "c1", given: "George", surname: "Brooks",
            censusYear: 1891, age: 8,
            district: "Marylebone", birthCounty: "DBY"
        )
        #expect(BiographicalFitEvaluator.chapmanCode(of: r.record) == "DBY")
    }

    @Test func chapmanCodeOf_recordsWithoutLocation_returnNil() {
        let r = makeDeathRecord(
            id: "d-nd", given: "George", surname: "Brooks",
            year: 1949, age: 66, district: nil
        )
        #expect(BiographicalFitEvaluator.chapmanCode(of: r.record) == nil)
    }
}
