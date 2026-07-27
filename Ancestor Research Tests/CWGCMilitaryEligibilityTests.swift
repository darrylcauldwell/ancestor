import Testing
import Foundation
@testable import Ancestor_Research

/// Regression tests for CWGC's proactive military-eligibility gate
/// (`SearchDispatcher.swift:426-442`). Pins the existing behaviour
/// against silent refactor drift — Python's
/// `_check_military_eligibility` runs the same gate at strategy
/// time; Swift bakes it into the dispatcher's per-source query
/// builder, so any change here would silently affect every male
/// subject's CWGC coverage.
///
/// Mirrors the WW1 (1880-1900) and WW2 (1900-1927) ranges from
/// `agent/rules.py:149-152`.
@MainActor
struct CWGCMilitaryEligibilityTests {

    private let cwgc = CWGCSource()

    private func dispatcher() -> SearchDispatcher {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(cwgc)
        return SearchDispatcher(registry: registry)
    }

    private func subject(
        gender: Gender?,
        birthYear: Int?,
        surname: String = "Cauldwell",
        given: String = "Ernest"
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: given,
            birthYearFrom: birthYear,
            birthYearTo: birthYear,
            gender: gender,
            region: .county("Derbyshire"),
            mode: .extend,
            homeChapmanCode: "DBY"
        )
    }

    // MARK: - Subject-level eligibility gate

    @Test func maleSubjectInWW1WindowDispatchesCWGC() {
        // Born 1887 → eligible for WW1 (1880-1900 range)
        let queries = dispatcher().buildQueriesForTest(
            source: cwgc,
            subject: subject(gender: .male, birthYear: 1887),
            recordType: .death,
            scope: .county
        )
        #expect(!queries.isEmpty,
                "Military-age male should produce CWGC queries")
    }

    @Test func maleSubjectInWW2WindowDispatchesCWGC() {
        // Born 1920 → eligible for WW2 (1900-1927 range)
        let queries = dispatcher().buildQueriesForTest(
            source: cwgc,
            subject: subject(gender: .male, birthYear: 1920),
            recordType: .death,
            scope: .county
        )
        #expect(!queries.isEmpty)
    }

    @Test func maleSubjectBornBeforeWW1WindowSkipsCWGC() {
        // Born 1850 → outside WW1 range (≥1880)
        let queries = dispatcher().buildQueriesForTest(
            source: cwgc,
            subject: subject(gender: .male, birthYear: 1850),
            recordType: .death,
            scope: .county
        )
        #expect(queries.isEmpty,
                "Pre-1880 birth should not trigger CWGC dispatch")
    }

    @Test func maleSubjectBornAfterWW2WindowSkipsCWGC() {
        // Born 1950 → outside WW2 range (≤1927)
        let queries = dispatcher().buildQueriesForTest(
            source: cwgc,
            subject: subject(gender: .male, birthYear: 1950),
            recordType: .death,
            scope: .county
        )
        #expect(queries.isEmpty)
    }

    @Test func femaleSubjectSkipsCWGC() {
        // Female of military age — still skipped (Python rule + Swift
        // both gate on male). WAAC / women's services aren't covered.
        let queries = dispatcher().buildQueriesForTest(
            source: cwgc,
            subject: subject(gender: .female, birthYear: 1900),
            recordType: .death,
            scope: .county
        )
        #expect(queries.isEmpty)
    }

    @Test func subjectWithoutBirthYearSkipsCWGC() {
        // No birth year → can't evaluate eligibility → skip safely.
        let queries = dispatcher().buildQueriesForTest(
            source: cwgc,
            subject: subject(gender: .male, birthYear: nil),
            recordType: .death,
            scope: .county
        )
        #expect(queries.isEmpty)
    }

    @Test func unknownGenderMaleSubjectStillDispatches() {
        // gender == nil should fall through to the dispatch path —
        // we don't have a positive female signal to skip on. Without
        // this, a male profile imported without explicit gender would
        // silently miss CWGC. Pins the current `gender == .male ||
        // gender == nil` predicate.
        let queries = dispatcher().buildQueriesForTest(
            source: cwgc,
            subject: subject(gender: nil, birthYear: 1890),
            recordType: .death,
            scope: .county
        )
        #expect(!queries.isEmpty)
    }

    // MARK: - T1-08 — interval-overlap eligibility (CWGCSource helper)
    //
    // These pin the NEW pure predicate `CWGCSource.isMilitaryEligible`,
    // which the dispatcher's `buildQueries` gate should call in place of
    // the point test on `birthYearFrom` (that rewire is a coordinator
    // follow-up in SearchDispatcher, not touched here). The
    // `buildQueriesForTest` cases above still pin the CURRENT dispatcher
    // behaviour, which is why a straddling window / war-death-no-birth
    // subject reads as `.isEmpty` there but eligible here — the gap is
    // exactly what T1-08 documents.

    @Test func pointBirthYearInsideRangeIsEligible() {
        // Parity with the old point behaviour for the easy case.
        #expect(CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: 1887, birthYearTo: 1887,
            deathYearFrom: nil, deathYearTo: nil))
    }

    @Test func straddlingBirthWindowIsEligible() {
        // 'ABT 1879' widened to 1876–1882. birthYearFrom=1876 is OUTSIDE
        // WW1 eligibility (1880–1900) — the old point test skipped CWGC —
        // but 1880–1882 lies inside, so the interval test admits it.
        #expect(CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: 1876, birthYearTo: 1882,
            deathYearFrom: nil, deathYearTo: nil))
    }

    @Test func warYearsDeathWithNoBirthYearIsEligible() {
        // No birth year at all, but a known 1916 death — the single
        // strongest CWGC trigger. The old `if let birthYear` skipped it.
        #expect(CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: 1916, deathYearTo: 1916))
    }

    @Test func ww2DeathWindowWithNoBirthYearIsEligible() {
        #expect(CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: 1941, deathYearTo: 1943))
    }

    @Test func peacetimeDeathWithNoBirthYearIsNotEligible() {
        // A death squarely between the wars (and no birth year) is not a
        // CWGC trigger — the death-window branch must not admit everyone.
        #expect(!CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: 1930, deathYearTo: 1932))
    }

    @Test func birthWindowWhollyBeforeEligibilityIsNotEligible() {
        // 1848–1852 never touches WW1's 1880 floor.
        #expect(!CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: 1848, birthYearTo: 1852,
            deathYearFrom: nil, deathYearTo: nil))
    }

    @Test func birthWindowWhollyAfterEligibilityIsNotEligible() {
        // Born 1948–1952 — past WW2's 1927 ceiling.
        #expect(!CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: 1948, birthYearTo: 1952,
            deathYearFrom: nil, deathYearTo: nil))
    }

    @Test func femaleIsExcludedEvenWithWarYearsDeath() {
        // The male-only scope is unchanged (spec-pinned; §7 widening is
        // out of T1-08's scope). A positive female signal excludes even a
        // war-years death.
        #expect(!CWGCSource.isMilitaryEligible(
            gender: .female, birthYearFrom: 1895, birthYearTo: 1895,
            deathYearFrom: 1916, deathYearTo: 1916))
    }

    @Test func nilGenderFallsThroughToEligible() {
        // A profile imported without explicit gender must not silently
        // miss CWGC — nil gender is permitted, matching the dispatcher's
        // `gender == .male || gender == nil` predicate.
        #expect(CWGCSource.isMilitaryEligible(
            gender: nil, birthYearFrom: 1890, birthYearTo: 1890,
            deathYearFrom: nil, deathYearTo: nil))
    }

    @Test func noBirthAndNoDeathIsNotEligible() {
        #expect(!CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil))
    }

    @Test func boundaryBirthYearsAreInclusive() {
        // The eligibility ranges are closed — the endpoints count.
        #expect(CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: nil, deathYearTo: nil), "WW1 floor 1880 inclusive")
        #expect(CWGCSource.isMilitaryEligible(
            gender: .male, birthYearFrom: 1927, birthYearTo: 1927,
            deathYearFrom: nil, deathYearTo: nil), "WW2 ceiling 1927 inclusive")
    }
}
