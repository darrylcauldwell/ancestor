import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the per-record-type date tolerance contract introduced when we
/// noticed the previous single `birthYearTolerance = 2` constant was both
/// too loose for civil birth registrations (a real Q4-born baby registered
/// Q1 next year is ±1, not ±2) and far too tight for 19th-century census
/// records (where age misreporting routinely produces ±3–5 year drift).
///
/// Per-type values live in `ScoringRules.tolerance(for:)`. These tests
/// pin the bands the scorer's date gate now applies, with both pass and
/// fail cases on each tier so loosening or tightening shows up loudly.
struct RecordScorerDateToleranceTests {

    // MARK: - Helpers

    private func subject(birthYear: Int = 1900, deathYear: Int? = nil) -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Test",
            birthYearFrom: birthYear,
            birthYearTo: birthYear,
            deathYearFrom: deathYear,
            deathYearTo: deathYear,
            gender: .male,
            region: .englandAndWales,
            mode: .extend
        )
    }

    private func birthRecord(year: Int) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: "b-\(year)", sourceID: "freebmd",
                name: nil, surname: "Cauldwell", givenName: "Test",
                detailURL: nil, rawFields: [:]
            ),
            birthYear: year, birthDate: nil, birthPlace: nil,
            quarter: nil, district: "Belper", volume: nil, page: nil,
            mothersMaidenName: nil
        ))
    }

    private func censusRecord(censusYear: Int, birthYear: Int) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: "c-\(censusYear)-\(birthYear)", sourceID: "freecen",
                name: nil, surname: "Cauldwell", givenName: "Test",
                detailURL: nil, rawFields: [:]
            ),
            censusYear: censusYear,
            age: censusYear - birthYear,
            birthYear: birthYear,
            birthPlace: "Derbyshire",
            birthCounty: "Derbyshire",
            relationship: nil, occupation: nil,
            address: nil, parish: "Belper", district: "Belper",
            household: nil
        ))
    }

    private func probateRecord(deathYear: Int) -> SourceRecord {
        .probate(ProbateRecord(
            common: RecordCommon(
                id: "p-\(deathYear)", sourceID: "probate",
                name: nil, surname: "Cauldwell", givenName: "Test",
                detailURL: nil, rawFields: [:]
            ),
            deathDate: "\(deathYear)-01-01", deathYear: deathYear,
            probateDate: "\(deathYear)-06-01", birthDate: nil,
            ageAtDeath: nil, address: "Derbyshire",
            grantType: "PROBATE", registry: "Manchester",
            probateNumber: nil, regimentNumber: nil
        ))
    }

    // MARK: - Per-type lookup invariants

    @Test func toleranceLookupReturnsExpectedTiers() {
        // Tight tier (civil registrations)
        #expect(ScoringRules.tolerance(for: .birth) == 1)
        #expect(ScoringRules.tolerance(for: .death) == 1)
        #expect(ScoringRules.tolerance(for: .military) == 1)
        #expect(ScoringRules.tolerance(for: .marriage) == 1)

        // Medium tier (events that lag their underlying date)
        #expect(ScoringRules.tolerance(for: .probate) == 2)
        #expect(ScoringRules.tolerance(for: .burial) == 2)

        // Loose tier (notorious for misreporting / lag)
        #expect(ScoringRules.tolerance(for: .census) == 5)
        #expect(ScoringRules.tolerance(for: .baptism) == 5)
        #expect(ScoringRules.tolerance(for: .christening) == 5)

        // Generic parish
        #expect(ScoringRules.tolerance(for: .parish) == 3)

        // Pedigree: declared in tree, must match exactly
        #expect(ScoringRules.tolerance(for: .pedigree) == 0)
    }

    // MARK: - Birth: tight ±1

    @Test func birthRecordOneYearOffPasses_atTightBoundary() {
        let result = RecordScorer.classify(
            record: birthRecord(year: 1901),
            subject: subject(birthYear: 1900),
            searchType: .birth
        )
        let date = result.gates.first(where: { $0.gate == .date })
        #expect(date?.outcome == .pass,
                "±1 must pass — covers the Q4-birth/Q1-following-year registration boundary slip")
    }

    @Test func birthRecordTwoYearsOffFails_outsideTightTolerance() {
        let result = RecordScorer.classify(
            record: birthRecord(year: 1902),
            subject: subject(birthYear: 1900),
            searchType: .birth
        )
        let date = result.gates.first(where: { $0.gate == .date })
        #expect(date?.outcome != .pass,
                "±2 must not pass for .birth — previous loose ±2 was admitting genuinely-different people")
    }

    // MARK: - Census: loose ±5

    @Test func censusFiveYearsOffPasses_atLooseBoundary() {
        let result = RecordScorer.classify(
            record: censusRecord(censusYear: 1911, birthYear: 1905),
            subject: subject(birthYear: 1900),
            searchType: .census
        )
        let date = result.gates.first(where: { $0.gate == .date })
        #expect(date?.outcome == .pass,
                "±5 must pass — 19th/early-20th-c. census age misreporting routinely produces this drift")
    }

    @Test func censusSixYearsOffFails_outsideLooseTolerance() {
        let result = RecordScorer.classify(
            record: censusRecord(censusYear: 1911, birthYear: 1906),
            subject: subject(birthYear: 1900),
            searchType: .census
        )
        let date = result.gates.first(where: { $0.gate == .date })
        #expect(date?.outcome != .pass,
                "±6 should not pass — beyond the realistic age-misreporting band")
    }

    // MARK: - Probate: medium ±2 against known death year

    @Test func probateTwoYearsOffKnownDeathPasses() {
        let result = RecordScorer.classify(
            record: probateRecord(deathYear: 1962),
            subject: subject(birthYear: 1900, deathYear: 1960),
            searchType: .probate
        )
        let date = result.gates.first(where: { $0.gate == .date })
        #expect(date?.outcome == .pass,
                "±2 should pass for .probate — grants can lag death by months and slip a year boundary")
    }

    @Test func probateThreeYearsOffKnownDeathFails() {
        let result = RecordScorer.classify(
            record: probateRecord(deathYear: 1963),
            subject: subject(birthYear: 1900, deathYear: 1960),
            searchType: .probate
        )
        let date = result.gates.first(where: { $0.gate == .date })
        #expect(date?.outcome != .pass,
                "±3 outside .probate tolerance — likely a different person of the same name")
    }
}
