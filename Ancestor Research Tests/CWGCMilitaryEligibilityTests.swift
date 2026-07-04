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
        let registry = SourceRegistry()
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
}
