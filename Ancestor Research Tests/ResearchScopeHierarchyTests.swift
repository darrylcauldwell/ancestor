import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_AXES_SPEC.md Change 3 — ResearchScope hierarchy.
@MainActor
struct ResearchScopeHierarchyTests {

    // MARK: - AC3.1 — enum has 5 cases in widening order

    @Test func ac3_1_sixCasesInWideningOrder() {
        let all: [ResearchScope] = [.parish, .district, .county, .adjacent, .national, .international]
        #expect(ResearchScope.allCases.count == 6)
        #expect(Set(ResearchScope.allCases) == Set(all))
        // Comparable order: parish < district < county < adjacent < national < international
        #expect(ResearchScope.parish < .district)
        #expect(ResearchScope.district < .county)
        #expect(ResearchScope.county < .adjacent)
        #expect(ResearchScope.adjacent < .national)
        #expect(ResearchScope.national < .international)
    }

    // MARK: - AC3.2 — dispatcher fan-out + AC3.3 — parish-unsupported sources

    @Test func ac3_2_countyScopeIsOneCountyLevelQuery() async {
        // FT-01 (2026-07-11): .county scope emits ONE county-level query
        // carrying the captured live-form countyid value — the per-district
        // fan-out this test originally pinned survives only behind the
        // gate-off fallback (covered in FreeBMDQueryShapeTests).
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let queries = buildFreeBMDQueries(dispatcher: dispatcher, subject: subject, scope: .county)
        #expect(queries.count == 1)
        if case .freeBMD(let p) = queries.first?.sourceParams {
            #expect(p.countyCode == RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"))
        } else {
            Issue.record("expected .freeBMD params")
        }
    }

    @Test func ac3_2_adjacentFreeCenUsesBirthCountyAxisNotResidenceFanOut() async {
        // FT-11 (2026-07-11): .adjacent no longer fans out across home +
        // neighbour RESIDENCE codes (the 7× shape this test originally
        // pinned). One query per census year scopes by BIRTH county
        // (`birth_chapman_codes[]`) with no residence filter — broader
        // reach (migrants included) at 1/7th the request cost.
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let queries = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .adjacent)
        let countyQueries = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .county)
        #expect(queries.count == countyQueries.count,
                "adjacent should emit ONE birth-county query per census year, not a residence fan-out")
        for query in queries {
            guard case .freeCen(let p) = query.sourceParams else {
                Issue.record("expected .freeCen params")
                continue
            }
            #expect(p.birthChapmanCode == "DBY", "adjacent scope must carry the birth-county axis")
            #expect(p.chapmanCode == nil, "adjacent scope must not carry a residence filter")
        }
        // .county keeps the residence axis (FT-11: \"keeping residence
        // codes for .county\").
        for query in countyQueries {
            guard case .freeCen(let p) = query.sourceParams else { continue }
            #expect(p.chapmanCode == "DBY")
            #expect(p.birthChapmanCode == nil)
        }
    }

    @Test func ac3_2_nationalFreeCenUsesBirthCountyAxisWhenHomeKnown() async {
        // FT-11: .national with a derivable home chapman = ONE
        // birth-county query per census year (was ~90 residence codes).
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "DBY")

        let national = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .national)
        let county = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .county)
        #expect(national.count == county.count,
                "national with known birth county should be one query per census year")
        for query in national {
            guard case .freeCen(let p) = query.sourceParams else { continue }
            #expect(p.birthChapmanCode == "DBY")
            #expect(p.chapmanCode == nil)
        }
    }

    @Test func ac3_2_nationalFreeCenFallsBackToResidenceFanOutWithoutHomeChapman() async {
        // FT-11 fallback: no derivable home county (empty chapman = no
        // anchor, per the chapman-derivation chain) → the pre-FT-11
        // national residence fan-out (~90 codes × years) is preserved,
        // because a birth-county axis cannot be built from nothing.
        let dispatcher = makeDispatcher()
        let subject = makeSubject(homeChapmanCode: "")

        let national = buildFreeCenQueries(dispatcher: dispatcher, subject: subject, scope: .national)
        #expect(national.count > 50, "fallback should fan out across GB residence codes")
        for query in national.prefix(5) {
            guard case .freeCen(let p) = query.sourceParams else { continue }
            #expect(p.birthChapmanCode == nil)
            #expect(p.chapmanCode?.isEmpty == false)
        }
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
        let registry = SourceRegistry(defaults: .ephemeralSuite())
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
        if case .freeCen(let p) = sourceParams { key += "|fcen:\(p.chapmanCode):\(p.censusYear):\(p.birthChapmanCode)" }
        if case .freeREG(let p) = sourceParams { key += "|freg:\(p.chapmanCode)" }
        return key
    }
}
