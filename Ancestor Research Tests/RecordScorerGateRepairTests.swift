import Testing
import Foundation
@testable import Ancestor_Research

/// Stage-1 gate repairs from the 2026-07 sandwich audit.
///
/// - **DS-01** — a death/burial with NO recorded age and NO known death
///   year must not auto-promote to `.fact`. The only remaining signal is
///   that the birth-derived age-at-death lands in the plausible [15,100]
///   band, which essentially *any* adult death of a same-named person in
///   the district clears. Such a record must soft-fail the date gate (→
///   `.lead`) unless the subject's death year is independently known.
/// - **DS-17** — the geography gate must derive the home county from the
///   subject's Chapman code, not a hardcoded `.contains("derby")` literal
///   (No-Hardcoded-Regions invariant).
/// - **DS-18** — the name gate must accept *every* surname a twice-married
///   woman may have died under, not just the latest `marriedSurname`.
struct RecordScorerGateRepairTests {

    // MARK: - DS-01: no-age death needs a death anchor to reach .fact

    @Test func noAgeDeathWithoutKnownDeathYearSoftFailsDateGate() {
        // William Holmes, born ~1851, NO known death year. A "William
        // Holmes died 1910" record with no recorded age clears the [15,100]
        // band (age would be ~59) — but so would any adult namesake death.
        let subject = personSubject(
            surname: "Holmes", givenName: "William",
            birthFrom: 1850, birthTo: 1852,
            deathFrom: nil, deathTo: nil
        )
        let result = RecordScorer.classify(
            record: ageLessDeath(surname: "Holmes", givenName: "William", year: 1910),
            subject: subject, searchType: .death
        )
        let dateGate = result.gates.first { $0.gate == .date }
        #expect(dateGate?.outcome == .softFail,
                "No recorded age + no known death year must soft-fail the date gate — got \(String(describing: dateGate?.outcome))")
        #expect(result.verdict != .fact,
                "Such a record must not auto-promote to .fact — got \(result.verdict)")
    }

    @Test func noAgeDeathWithKnownDeathYearPassesDateGate() {
        // Same record, but now the subject's death year IS known (1909–1911).
        // The record year was constrained to that window, so the band overlap
        // is genuinely corroborating and the date gate passes to .fact.
        let subject = personSubject(
            surname: "Holmes", givenName: "William",
            birthFrom: 1850, birthTo: 1852,
            deathFrom: 1909, deathTo: 1911
        )
        let result = RecordScorer.classify(
            record: ageLessDeath(surname: "Holmes", givenName: "William", year: 1910),
            subject: subject, searchType: .death
        )
        let dateGate = result.gates.first { $0.gate == .date }
        #expect(dateGate?.outcome == .pass,
                "No recorded age but a known death year must pass the date gate — got \(String(describing: dateGate?.outcome))")
    }

    // MARK: - DS-17: geography gate reads home county from Chapman code

    @Test func homeCountyMatchDerivedFromChapmanCode() {
        // Nottinghamshire subject; a Nottinghamshire census record must pass
        // the geography gate. Before the fix only "derby" passed, so this
        // record soft-failed and cluttered Triage.
        let subject = personSubject(
            surname: "Smith", givenName: "John",
            birthFrom: 1843, birthTo: 1847, chapman: "NTT"
        )
        let result = RecordScorer.classify(
            record: censusInCounty(surname: "Smith", givenName: "John", county: "Nottinghamshire"),
            subject: subject, searchType: .census
        )
        #expect(geoOutcome(result) == .pass,
                "A Nottinghamshire record for a Nottinghamshire subject must pass geography — got \(String(describing: geoOutcome(result)))")
    }

    @Test func homeCountyShortFormMatchesViaReverseContainment() {
        // Census fields often carry the county town ("Nottingham") rather
        // than the full county ("Nottinghamshire"). Reverse containment
        // accepts it.
        let subject = personSubject(
            surname: "Smith", givenName: "John",
            birthFrom: 1843, birthTo: 1847, chapman: "NTT"
        )
        let result = RecordScorer.classify(
            record: censusInCounty(surname: "Smith", givenName: "John", county: "Nottingham"),
            subject: subject, searchType: .census
        )
        #expect(geoOutcome(result) == .pass)
    }

    @Test func defaultDerbyshireSubjectStillPasses() {
        // Regression pin: the Derbyshire case that the hardcode used to
        // handle must still pass, now via the Chapman-derived county name.
        let subject = personSubject(
            surname: "Smith", givenName: "John",
            birthFrom: 1843, birthTo: 1847, chapman: "DBY"
        )
        let result = RecordScorer.classify(
            record: censusInCounty(surname: "Smith", givenName: "John", county: "Derbyshire"),
            subject: subject, searchType: .census
        )
        #expect(geoOutcome(result) == .pass)
    }

    @Test func derbyshireRecordDoesNotAutoPassForNonDerbyshireSubject() {
        // The discriminator: a Derbyshire census record for a Nottinghamshire
        // subject must NOT get the home-county pass. Before the fix the
        // hardcoded `.contains("derby")` passed *every* subject's Derbyshire
        // record regardless of their home county.
        let subject = personSubject(
            surname: "Smith", givenName: "John",
            birthFrom: 1843, birthTo: 1847, chapman: "NTT"
        )
        let result = RecordScorer.classify(
            record: censusInCounty(surname: "Smith", givenName: "John", county: "Derbyshire"),
            subject: subject, searchType: .census
        )
        #expect(geoOutcome(result) != .pass,
                "A Derbyshire record must not auto-pass for a Nottinghamshire subject — got \(String(describing: geoOutcome(result)))")
    }

    // MARK: - DS-18: every married surname accepted, not just the latest

    @Test func deathUnderEarlierMarriedSurnameIsAccepted() {
        // Gillian Smith married twice — latest to Grant, earlier to Rose.
        // She died under the EARLIER name "Rose". The name gate must accept
        // it; before the fix only the single latest `marriedSurname` (Grant)
        // was accepted, so the "Rose" death scored .impossible.
        let subject = twiceMarriedWoman()
        let result = RecordScorer.classify(
            record: ageLessDeath(surname: "Rose", givenName: "Gillian", year: 1906, age: 62),
            subject: subject, searchType: .death
        )
        let nameGate = result.gates.first { $0.gate == .name }
        #expect(nameGate?.outcome == .pass,
                "Death under an earlier married surname must pass the name gate — got \(String(describing: nameGate?.outcome))")
        #expect(result.verdict != .impossible,
                "Death under an earlier married surname must not be .impossible — got \(result.verdict)")
    }

    @Test func deathUnderUnrelatedSurnameStillImpossible() {
        // Control: a surname she was never known by must still name-fail.
        let subject = twiceMarriedWoman()
        let result = RecordScorer.classify(
            record: ageLessDeath(surname: "Baker", givenName: "Gillian", year: 1906, age: 62),
            subject: subject, searchType: .death
        )
        #expect(result.verdict == .impossible,
                "Death under an unrelated surname must remain .impossible — got \(result.verdict)")
    }

    // MARK: - Fixtures

    private func personSubject(
        surname: String, givenName: String,
        birthFrom: Int, birthTo: Int,
        deathFrom: Int? = nil, deathTo: Int? = nil,
        chapman: String = ""
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: givenName,
            birthYearFrom: birthFrom,
            birthYearTo: birthTo,
            deathYearFrom: deathFrom,
            deathYearTo: deathTo,
            gender: .male,
            region: .englandAndWales,
            mode: .extend,
            familyContext: emptyContext(),
            homeChapmanCode: chapman
        )
    }

    private func twiceMarriedWoman() -> ResearchSubject {
        ResearchSubject(
            surname: "Smith",
            marriedSurname: "Grant",
            marriedSurnames: ["Grant", "Rose"],
            givenName: "Gillian",
            birthYearFrom: 1843,
            birthYearTo: 1845,
            deathYearFrom: 1905,
            deathYearTo: 1907,
            gender: .female,
            region: .englandAndWales,
            mode: .extend,
            familyContext: fatherContext("Smith")
        )
    }

    private func emptyContext() -> FamilyContext { fatherContext(nil) }

    private func fatherContext(_ surname: String?) -> FamilyContext {
        FamilyContext(
            spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
            spouseFatherSurname: nil, childNames: [],
            fatherName: nil, fatherSurname: surname, fatherGivenName: nil,
            motherName: nil, motherSurname: nil, motherGivenName: nil
        )
    }

    private func commonFields(_ id: String, surname: String, givenName: String) -> RecordCommon {
        RecordCommon(
            id: id, sourceID: "freebmd", name: nil,
            surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
    }

    /// A death record with no recorded age unless one is given.
    private func ageLessDeath(surname: String, givenName: String, year: Int, age: Int? = nil) -> SourceRecord {
        .death(DeathRecord(
            common: commonFields("rec-death-\(surname)-\(givenName)-\(year)", surname: surname, givenName: givenName),
            deathYear: year,
            deathDate: nil,
            deathPlace: nil,
            age: age,
            quarter: "Mar",
            district: "Belper",
            volume: "7b",
            page: "412",
            spouseSurname: nil
        ))
    }

    private func censusInCounty(surname: String, givenName: String, county: String) -> SourceRecord {
        .census(CensusRecord(
            common: commonFields("rec-census-\(surname)-\(givenName)-\(county)", surname: surname, givenName: givenName),
            censusYear: 1861,
            age: 16,
            birthYear: 1845,
            birthPlace: county,
            birthCounty: county,
            relationship: nil,
            occupation: nil,
            address: nil,
            parish: nil,
            district: nil,
            household: nil
        ))
    }

    private func geoOutcome(_ result: ScoredRecord) -> GateOutcome? {
        result.gates.first { $0.gate == .geography }?.outcome
    }
}
