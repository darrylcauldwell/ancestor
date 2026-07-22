import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-16 (fetch half) + T1-23 (request-param half) —
/// CONNECTOR_AUDIT_2026-07.md §6.3.
///
/// Year-axis history: FAG year filtering was deliberately REMOVED after
/// a real bug — the old code mapped `query.yearFrom`/`yearTo` (the
/// bounds of ONE record-type search window; for `.burial` both bounds
/// are death-year ± 2) onto FAG's `birthyear`/`deathyear` person-fact
/// axes, so a subject who died ~2017 was queried as
/// birthyear=2015/deathyear=2019 — a four-year-old child, zero hits.
/// These tests pin the RESTORED design: subject-side windows ride in
/// `FindAGraveParams.birthYearRange`/`deathYearRange` with their own
/// tolerances, and the search window is never read for year params.
@MainActor
struct FindAGraveQueryShapeTests {

    private let fag = FindAGraveSource()

    private func dispatcher() -> SearchDispatcher {
        let registry = SourceRegistry()
        registry.register(fag)
        return SearchDispatcher(registry: registry)
    }

    private func subject(
        gender: Gender? = .male,
        birthFrom: Int? = nil, birthTo: Int? = nil,
        deathFrom: Int? = nil, deathTo: Int? = nil
    ) -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Ernest",
            birthYearFrom: birthFrom, birthYearTo: birthTo,
            deathYearFrom: deathFrom, deathYearTo: deathTo,
            gender: gender,
            region: .county("Derbyshire"),
            mode: .extend,
            homeChapmanCode: "DBY"
        )
    }

    private func burialQueries(for subject: ResearchSubject) -> [RecordQuery] {
        dispatcher().buildQueriesForTest(
            source: fag, subject: subject, recordType: .burial, scope: .county
        )
    }

    private func fagParams(_ query: RecordQuery) -> FindAGraveParams? {
        guard case .findAGrave(let p) = query.sourceParams else { return nil }
        return p
    }

    private func defaultParams(
        birthYearRange: ClosedRange<Int>? = nil,
        deathYearRange: ClosedRange<Int>? = nil,
        limit: Int = 20,
        includeMaidenName: Bool = false
    ) -> FindAGraveParams {
        FindAGraveParams(
            yearRangeWidth: 5, location: nil,
            birthYearRange: birthYearRange, deathYearRange: deathYearRange,
            limit: limit, includeMaidenName: includeMaidenName
        )
    }

    private func wireQuery(
        yearFrom: Int? = nil, yearTo: Int? = nil,
        params: FindAGraveParams
    ) -> [String: String] {
        let query = RecordQuery(
            surname: "Cauldwell", givenName: "Ernest",
            recordType: .burial,
            yearFrom: yearFrom, yearTo: yearTo,
            gender: .male, region: .englandAndWales,
            sourceParams: .findAGrave(params)
        )
        return FindAGraveSource.searchRequestParams(query: query, params: params)
    }

    // MARK: - THE regression: the 2015/2019 child-query bug stays dead

    @Test func searchWindowBoundsNeverBecomeYearParams() {
        // Subject died ~2017: the dispatcher's burial search window is
        // death ± 2 = 2015–2019. The pre-removal code sent
        // birthyear=2015 & deathyear=2019.
        let queries = burialQueries(for: subject(deathFrom: 2017, deathTo: 2017))
        #expect(queries.count == 1)
        guard let query = queries.first, let params = fagParams(query) else { return }
        // The search-window axis is unchanged (death ± 2)...
        #expect(query.yearFrom == 2015 && query.yearTo == 2019)
        // ...but the wire keys on the subject's actual DEATH year.
        let wire = FindAGraveSource.searchRequestParams(query: query, params: params)
        #expect(wire["deathyear"] == "2017",
                "burial search must key on the subject's death year, got \(wire["deathyear"] ?? "nil")")
        #expect(wire["deathyear"] != "2019",
                "the window's upper bound must never leak into deathyear")
        #expect(wire["birthyear"] == nil,
                "the window's lower bound must never leak into birthyear")
    }

    @Test func yearParamsAbsentWhenParamsCarryNoWindows() {
        // Even a query whose search window LOOKS like the old bug's
        // input emits no year params when FindAGraveParams carries no
        // subject-side windows (FocusedQuery / SourceExplorer paths
        // construct exactly this shape).
        let wire = wireQuery(yearFrom: 2015, yearTo: 2019, params: defaultParams())
        #expect(wire["birthyear"] == nil && wire["deathyear"] == nil)
        #expect(wire["birthyearfilter"] == nil && wire["deathyearfilter"] == nil)
    }

    // MARK: - T1-16 — dispatcher populates subject-side axes

    @Test func burialKeysOnDeathYearNeverTheFallbackGuess() {
        // Death unknown → the burial search window falls back to
        // birth+15..birth+95, an ~80-year guess that must NOT become a
        // death filter (FAG's widest tolerance is ±25).
        let queries = burialQueries(for: subject(birthFrom: 1887, birthTo: 1887))
        guard let params = queries.first.flatMap(fagParams) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(params.deathYearRange == nil,
                "no real death window → no death-year axis")
        #expect(params.birthYearRange == 1887...1887)
    }

    @Test func bothAxesPopulatedWhenBothKnown() {
        let queries = burialQueries(for: subject(
            birthFrom: 1887, birthTo: 1887, deathFrom: 2017, deathTo: 2017
        ))
        guard let query = queries.first, let params = fagParams(query) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(params.birthYearRange == 1887...1887)
        #expect(params.deathYearRange == 2017...2017)
        let wire = FindAGraveSource.searchRequestParams(query: query, params: params)
        #expect(wire["birthyear"] == "1887" && wire["birthyearfilter"] == "5")
        #expect(wire["deathyear"] == "2017" && wire["deathyearfilter"] == "5")
    }

    @Test func fuzzySubjectWindowsCarriedVerbatim() {
        // The dispatcher passes the subject's window; the CONNECTOR owns
        // midpoint/tolerance resolution (wire vocabulary lives there).
        let queries = burialQueries(for: subject(
            birthFrom: 1880, birthTo: 1890, deathFrom: 1914, deathTo: 1918
        ))
        guard let params = queries.first.flatMap(fagParams) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(params.birthYearRange == 1880...1890)
        #expect(params.deathYearRange == 1914...1918)
    }

    @Test func noWindowsMeansNoAxes() {
        let queries = burialQueries(for: subject())
        guard let query = queries.first, let params = fagParams(query) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(params.birthYearRange == nil && params.deathYearRange == nil)
        let wire = FindAGraveSource.searchRequestParams(query: query, params: params)
        #expect(wire["birthyear"] == nil && wire["deathyear"] == nil)
    }

    // MARK: - T1-16 — tolerance ladder (connector wire vocabulary)

    @Test func exactYearGetsFloorTolerance() {
        // Precise death 2017 with the default floor 5 → never narrower
        // than the requested floor.
        let axis = FindAGraveSource.yearAxis(range: 2017...2017, floor: 5)
        #expect(axis?.center == 2017)
        #expect(axis?.tolerance == 5)
    }

    @Test func windowMidpointIsCenter() {
        let axis = FindAGraveSource.yearAxis(range: 1914...1918, floor: 5)
        #expect(axis?.center == 1916)
        #expect(axis?.tolerance == 5, "half-span 2 is under the floor 5")
    }

    @Test func oddSpanRoundsHalfSpanUp() {
        // 1914–1917: integer midpoint 1915 sits 2 from the upper bound;
        // the half-span must be the larger distance, never the smaller.
        let axis = FindAGraveSource.yearAxis(range: 1914...1917, floor: 0)
        #expect(axis?.center == 1915)
        #expect(axis?.tolerance == 2)
    }

    @Test func toleranceRoundsUpTheLadder() {
        // Half-span 10 → exact rung 10; half-span 7 → next rung up (10);
        // half-span 12 → 25. The emitted filter always COVERS the window.
        #expect(FindAGraveSource.yearAxis(range: 1875...1895, floor: 5)?.tolerance == 10)
        #expect(FindAGraveSource.yearAxis(range: 1881...1895, floor: 5)?.tolerance == 10)
        #expect(FindAGraveSource.yearAxis(range: 1871...1895, floor: 5)?.tolerance == 25)
    }

    @Test func unrepresentableWindowGoesOutUnfiltered() {
        // Half-span > 25: any expressible filter would EXCLUDE plausible
        // years — false negatives by construction — so the axis drops.
        #expect(FindAGraveSource.yearAxis(range: 1900...1980, floor: 5) == nil)
        let wire = wireQuery(params: defaultParams(deathYearRange: 1900...1980))
        #expect(wire["deathyear"] == nil && wire["deathyearfilter"] == nil)
    }

    @Test func zeroFloorExactWindowOmitsFilterParam() {
        // Python parity (`if year_range:` — sources/findagrave.py:154):
        // tolerance 0 = exact match, the filter param is omitted while
        // the year param still goes out.
        let axis = FindAGraveSource.yearAxis(range: 2017...2017, floor: 0)
        #expect(axis?.center == 2017)
        #expect(axis?.tolerance == nil)
    }

    @Test func nilRangeYieldsNoAxis() {
        #expect(FindAGraveSource.yearAxis(range: nil, floor: 5) == nil)
    }

    // MARK: - T1-16 — limit plumbing

    @Test func defaultLimitKeepsHistoricalTwenty() {
        let queries = burialQueries(for: subject(deathFrom: 2017, deathTo: 2017))
        guard let query = queries.first, let params = fagParams(query) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(params.limit == 20)
        let wire = FindAGraveSource.searchRequestParams(query: query, params: params)
        #expect(wire["limit"] == "20")
        #expect(wire["skip"] == "0", "no skip pagination — batching stays out")
    }

    @Test func raisedLimitReachesTheWire() {
        // The truncated-first-page raise: the dispatcher CAN request a
        // bigger page via the param; nothing loops automatically.
        let wire = wireQuery(params: defaultParams(limit: 100))
        #expect(wire["limit"] == "100")
    }

    @Test func limitClampedToFAGAcceptedBand() {
        #expect(wireQuery(params: defaultParams(limit: 500))["limit"] == "100")
        #expect(wireQuery(params: defaultParams(limit: 0))["limit"] == "1")
    }

    // MARK: - T1-23 — includeMaidenName emission

    @Test func femaleSubjectEmitsIncludeMaidenName() {
        let queries = burialQueries(for: subject(gender: .female))
        guard let query = queries.first, let params = fagParams(query) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(params.includeMaidenName)
        let wire = FindAGraveSource.searchRequestParams(query: query, params: params)
        #expect(wire["includeMaidenName"] == "true")
    }

    @Test func maleSubjectOmitsIncludeMaidenName() {
        let queries = burialQueries(for: subject(gender: .male))
        guard let query = queries.first, let params = fagParams(query) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(!params.includeMaidenName)
        let wire = FindAGraveSource.searchRequestParams(query: query, params: params)
        #expect(wire["includeMaidenName"] == nil,
                "checkbox-presence semantics — the param is absent when unticked")
    }

    @Test func unknownGenderOmitsIncludeMaidenName() {
        // Mirrors surnamesToProbe's maiden-axis gate: gender == .female
        // is the trigger; unknown gender does not fire it.
        let queries = burialQueries(for: subject(gender: nil))
        guard let params = queries.first.flatMap(fagParams) else {
            Issue.record("expected one FAG query with findAGrave params")
            return
        }
        #expect(!params.includeMaidenName)
    }

    // MARK: - T1-18 — includeNickName emission

    @Test func includeNickNameRidesWithFirstname() {
        // The scorer knows Jack=John (ScoringRules.nicknameEquivalents)
        // but without the flag the query can never RETRIEVE the Jack
        // memorial — match logic downstream, no retrieval upstream.
        let wire = wireQuery(params: defaultParams())
        #expect(wire["firstname"] == "Ernest")
        #expect(wire["includeNickName"] == "true")
    }

    @Test func noFirstnameOmitsIncludeNickName() {
        // Checkbox-presence semantics, and the flag is only meaningful
        // alongside a firstname — a surname-only probe must not emit it.
        let query = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .burial,
            yearFrom: nil, yearTo: nil,
            gender: .male, region: .englandAndWales,
            sourceParams: .findAGrave(defaultParams())
        )
        let wire = FindAGraveSource.searchRequestParams(query: query, params: defaultParams())
        #expect(wire["firstname"] == nil)
        #expect(wire["includeNickName"] == nil)
    }

    // MARK: - T1-C3: URL encoding of sub-delimiters

    @Test func searchURLEncodesSubDelimitersInValues() {
        // A location value carrying &, = and + must round-trip intact — the
        // old .urlQueryAllowed join left these literal and corrupted the query.
        let raw = "Smith & Sons=Cemetery, East+West"
        guard let url = FindAGraveSource.buildSearchURL(["location": raw, "lastname": "O'Brien"]) else {
            Issue.record("buildSearchURL returned nil"); return
        }
        // Parse the query back out and confirm the value is exactly what went in.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "location" }?.value == raw,
                "location value must round-trip; got \(String(describing: items.first { $0.name == "location" }?.value))")
        #expect(items.first { $0.name == "lastname" }?.value == "O'Brien")
        // The raw ampersand must be percent-encoded, not a literal separator.
        #expect(url.absoluteString.contains("%26"), "'&' must be encoded as %26")
        #expect(url.absoluteString.contains("%2B"), "'+' must be encoded as %2B")
    }
}
