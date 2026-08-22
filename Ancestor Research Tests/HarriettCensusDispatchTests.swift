import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Diagnostic: does the dispatcher build a FreeCen query that could FIND
/// Harriet Holmes's 1891 census?
///
/// Owner dogfood 2026-08-22. Her 1891 Bakewell household is demonstrably in
/// FreeCen — the app fetched that very household through her husband Samuel and
/// stored her roster row (`Harriett HOLMES, Wife, 34, born Longcliffe Wharf`).
/// Yet researching HER has never once produced a census record beyond a Derby
/// namesake, across many runs. Before blaming caching or the strictness ladder,
/// establish whether the query fan-out even emits an 1891 probe for her.
@MainActor
struct HarriettCensusDispatchTests {

    /// Harriet as the tree actually holds her: born 1857 at Longcliffe Wharf in
    /// Derbyshire, no death date (which is what makes her census window run to
    /// birth + 80), married into Bakewell.
    private func harriett(homeChapmanCode: String = "DBY") -> ResearchSubject {
        ResearchSubject(
            profileID: "EE5EC3D5-A7BA-4C1D-A5B6-1453C48ECB45",
            surname: "Holmes", givenName: "Harriet",
            birthYearFrom: 1857, birthYearTo: 1857,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .female, region: nil,
            mode: .adaptive, familyContext: nil,
            homeChapmanCode: homeChapmanCode
        )
    }

    private func dispatcher() -> SearchDispatcher {
        SearchDispatcher(registry: SourceRegistry(defaults: .ephemeralSuite()))
    }

    /// Her census year range is birth (1857) → birth + 80 (1937) because she has
    /// no recorded death, so every census from 1861 on is in scope.
    @Test func censusYearRangeSpansHerWholeLife() {
        let range = harriett().yearRange(for: .census)
        #expect(range.from == 1857)
        #expect((range.to ?? 0) >= 1891, "no death date → birth + 80; got \(String(describing: range.to))")
    }

    /// THE ONE THAT MATTERS: an 1891 FreeCen probe must be emitted for her.
    /// If this fails, no amount of ladder or fan-out work can ever find her
    /// census — the query was never built.
    @Test func freeCenEmitsAn1891CensusQueryForHer() {
        let queries = dispatcher().buildQueriesForTest(
            source: FreeCenSource(), subject: harriett(),
            recordType: .census, scope: .county
        )
        let years: Set<Int> = Set(queries.compactMap { q in
            guard case .freeCen(let p) = q.sourceParams else { return nil }
            return p.censusYear
        })
        #expect(!queries.isEmpty, "FreeCen emitted NO census queries at all for her")
        #expect(years.contains(1891),
                "no 1891 probe — her own census can never be found. Years emitted: \(years.sorted())")
    }

    /// 1861 is emitted too — that is where the Derby namesake came from, so it
    /// proves the fan-out is alive and the 1891 question above is meaningful.
    @Test func freeCenAlsoEmitsThe1861QueryThatFoundTheNamesake() {
        let queries = dispatcher().buildQueriesForTest(
            source: FreeCenSource(), subject: harriett(),
            recordType: .census, scope: .county
        )
        let years: Set<Int> = Set(queries.compactMap { q in
            guard case .freeCen(let p) = q.sourceParams else { return nil }
            return p.censusYear
        })
        #expect(years.contains(1861))
    }

    /// The anchor guard: with no derivable home county, a `.scoped` source at
    /// county scope builds nothing at all. Her birthplace is "Longcliffe Wharf,
    /// Derbyshire" — a hamlet the gazetteer does not know — so if the chapman
    /// code fails to resolve, this is how she goes silently unsearched.
    @Test func noHomeChapmanCodeMeansNoQueriesAtAll() {
        let queries = dispatcher().buildQueriesForTest(
            source: FreeCenSource(), subject: harriett(homeChapmanCode: ""),
            recordType: .census, scope: .county
        )
        #expect(queries.isEmpty,
                "documents the failure mode: no county anchor → FreeCen searches nothing")
        let reason = SearchDispatcher.scopeSkipReason(
            source: FreeCenSource(), subject: harriett(homeChapmanCode: ""), scope: .county)
        #expect(reason != nil, "and it should be a VISIBLE skip, not silence")
    }

    /// Her given name must reach the wire as HARRIETT too at the variant tier —
    /// the census spells it with two t's (fixed in 5c6091c, asserted here in her
    /// own shape rather than in the abstract).
    @Test func variantTierProbesTheCensusSpellingOfHerName() {
        let queries = dispatcher().buildQueriesForTest(
            source: FreeCenSource(), subject: harriett(),
            recordType: .census, scope: .county, strictness: .variant
        )
        let givens = Set(queries.compactMap { $0.givenName?.uppercased() })
        #expect(givens.contains("HARRIETT"),
                "variant tier must probe the census spelling; got \(givens.sorted())")
    }
}
