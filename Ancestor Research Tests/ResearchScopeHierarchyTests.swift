import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_AXES_SPEC.md Change 3 — ResearchScope hierarchy.
@MainActor
struct ResearchScopeHierarchyTests {

    // MARK: - AC3.1 — enum has 5 cases in widening order

    @Test func ac3_1_fiveCasesInWideningOrder() {
        let all: [ResearchScope] = [.parish, .district, .county, .adjacent, .national]
        #expect(ResearchScope.allCases.count == 5)
        #expect(Set(ResearchScope.allCases) == Set(all))
        // Comparable order: parish < district < county < adjacent < national
        #expect(ResearchScope.parish < .district)
        #expect(ResearchScope.district < .county)
        #expect(ResearchScope.county < .adjacent)
        #expect(ResearchScope.adjacent < .national)
    }

    // MARK: - AC3.2 — dispatcher fan-out + AC3.3 — parish-unsupported sources

    @Test func ac3_2_countyFanOutMatchesDerbyshireDistricts() async {
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let queries = buildFreeBMDQueries(dispatcher: dispatcher, subject: subject, scope: .county)
        let expectedCount = RegionConfig.districts(forChapmanCode: "DBY").count
        #expect(queries.count == expectedCount)
        #expect(expectedCount > 0)
    }

    @Test func ac3_2_adjacentFanOutForFreeCenIncludesNeighbours() async {
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let queries = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .adjacent)
        // FreeCen at .adjacent should fan out across home + adjacent chapman codes,
        // multiplied by the applicable census years. With DBY having 6 adjacent
        // counties, expect at least 7× the .county count.
        let countyQueries = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .county)
        #expect(queries.count >= countyQueries.count * 7,
                "adjacent fan-out should multiply county count by 1 (home) + neighbours")
    }

    @Test func ac3_3_parishScopeReturnsZeroQueriesForFreeBMD() async {
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let queries = buildFreeBMDQueries(dispatcher: dispatcher, subject: subject, scope: .parish)
        // FreeBMD has no parish endpoint — must return zero queries, not widen.
        #expect(queries.isEmpty)
    }

    // MARK: - AC3.4 — nil-birthLocationCode subjects fall through to county
    //
    // The dispatcher uses subject.homeChapmanCode as the lookup; subject's
    // location-code carrying is in prior spec's Change 2, not yet shipped.
    // For now any subject is effectively "no parish data", so .parish and
    // .district paths must produce the same query set as .county for
    // parish/district-supporting sources.

    @Test func ac3_4_districtFreeBMDFallsThroughToCounty() async {
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let district = buildFreeBMDQueries(dispatcher: dispatcher, subject: subject, scope: .district)
        let county = buildFreeBMDQueries(dispatcher: dispatcher, subject: subject, scope: .county)
        // Transitional widening: until birthLocationCode ships, .district
        // behaves identically to .county for FreeBMD.
        #expect(Set(district.map(\.queryKey)) == Set(county.map(\.queryKey)))
    }

    @Test func ac3_4_parishFreeCenWidensToCounty() async {
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let parish = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .parish)
        let county = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .county)
        // FreeCen at .parish without parish data widens to its single home
        // chapman code — same as .county.
        #expect(Set(parish.map(\.queryKey)) == Set(county.map(\.queryKey)))
    }

    // MARK: - Helpers

    @MainActor
    private func makeDispatcher() -> SearchDispatcher {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        return SearchDispatcher(registry: registry)
    }

    private func makeSubject(homeChapmanCode: String) -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell",
            givenName: "Robert",
            birthYearFrom: 1880,
            birthYearTo: 1880,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: nil,
            mode: .extend,
            familyContext: nil,
            homeChapmanCode: homeChapmanCode
        )
    }

    @MainActor
    private func buildFreeBMDQueries(
        dispatcher: SearchDispatcher,
        subject: ResearchSubject,
        scope: ResearchScope
    ) -> [RecordQuery] {
        guard let source = dispatcher.registry.allSources().first(where: { $0.sourceID == "freebmd" }) else {
            return []
        }
        return dispatcher.buildQueriesForTest(source: source, subject: subject, recordType: .birth, scope: scope)
    }

    @MainActor
    private func buildFreeCenQueries(
        dispatcher: SearchDispatcher,
        subject: ResearchSubject,
        scope: ResearchScope
    ) -> [RecordQuery] {
        guard let source = dispatcher.registry.allSources().first(where: { $0.sourceID == "freecen" }) else {
            return []
        }
        return dispatcher.buildQueriesForTest(source: source, subject: subject, recordType: .census, scope: scope)
    }
}

// Stable per-query key for set comparison in the AC3.4 tests.
private extension RecordQuery {
    var queryKey: String {
        var key = "\(recordType)|\(surname ?? "_")|\(givenName ?? "_")|\(yearFrom ?? -1)-\(yearTo ?? -1)"
        if case .freeBMD(let p) = sourceParams { key += "|fbmd:\(p.districtCode)" }
        if case .freeCen(let p) = sourceParams { key += "|fcen:\(p.chapmanCode):\(p.censusYear)" }
        if case .freeREG(let p) = sourceParams { key += "|freg:\(p.chapmanCode)" }
        return key
    }
}
