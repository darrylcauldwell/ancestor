import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_AXES_SPEC.md Change 4 —
/// SearchStrictness type + RecordQuery field. No behaviour change.
struct SearchStrictnessTests {

    // MARK: - AC4.1 — three cases, Comparable, ordered strict < loose < variant

    @Test func ac4_1_threeCasesInWideningOrder() {
        #expect(SearchStrictness.allCases.count == 3)
        #expect(Set(SearchStrictness.allCases) == Set([.strict, .loose, .variant]))
        #expect(SearchStrictness.strict < .loose)
        #expect(SearchStrictness.loose < .variant)
        // Transitivity check — strict < variant implied by Comparable contract.
        #expect(SearchStrictness.strict < .variant)
    }

    // MARK: - AC4.2 — RecordQuery.strictness defaults to .strict

    @Test func ac4_2_recordQueryDefaultsToStrict() {
        let query = RecordQuery(
            surname: "Cauldwell",
            givenName: "Robert",
            recordType: .birth,
            yearFrom: 1880,
            yearTo: 1880,
            gender: .male,
            region: nil,
            sourceParams: .generic
        )
        #expect(query.strictness == .strict)
    }

    @Test func ac4_2_recordQueryAcceptsExplicitStrictness() {
        let query = RecordQuery(
            surname: "Cauldwell",
            givenName: "Robert",
            recordType: .birth,
            yearFrom: 1880,
            yearTo: 1880,
            gender: .male,
            region: nil,
            sourceParams: .generic,
            strictness: .loose
        )
        #expect(query.strictness == .loose)
    }

    // MARK: - AC4.3 — SearchDispatcher.dispatch accepts mode: parameter
    //
    // Compile-time evidence: the call below would not compile without the
    // `mode:` parameter. Runtime evidence: dispatch returns without throwing
    // — no behaviour change is required by AC4.4.

    @MainActor
    @Test func ac4_3_dispatcherAcceptsModeParameter() async {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        let dispatcher = SearchDispatcher(registry: registry)

        let subject = ResearchSubject(
            profileID: nil,
            surname: nil,                       // Surname-less skips most queries fast.
            givenName: nil,
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: nil, region: nil,
            mode: .verify,
            familyContext: nil,
            homeChapmanCode: "DBY"
        )

        // Smoke test for every mode — exercises the new parameter without
        // network I/O (no surname → no FreeBMD queries built).
        for mode in [ResearchMode.verify, .extend, .discover, .all] {
            _ = await dispatcher.dispatch(
                subject: subject,
                recordTypes: [.birth],
                scope: .county,
                mode: mode
            )
        }
    }
}
