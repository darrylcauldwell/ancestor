import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// The 2026-08-23 FreeBMD efficiency audit, pinned. FreeBMD throttled early
/// because the app was structurally louder toward it than toward the sources
/// that never complain (FreeCEN/FreeREG): a double retry stack sent up to six
/// wire POSTs per throttled query, there was no pre-emptive budget at all,
/// mode=all re-fetched rows the loose (soundex) pass already returned, and
/// the daily-budget counter charged per-run cache hits the host never saw.
@MainActor
struct FreeBMDEfficiencyTests {

    private func source(_ id: String) -> (any RecordSource)? {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        bootstrapSources(registry: registry)
        return registry.allSources().first { $0.sourceID == id }
    }

    private func query(surname: String = "Thompson", given: String? = "John") -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: given, recordType: .death,
            yearFrom: 1816, yearTo: 1906, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: nil, countyCode: "DBY", wildcardSurname: false,
                motherSurname: nil, spouseSurname: nil)))
    }

    // MARK: - Fix 1: first 429 is final

    @Test func throttledIsNotRetryableAtTheTransportLayer() {
        // A 429 is the server asking us to stop; retrying it at this layer
        // multiplied with the connector's own throttle handling into six
        // wire POSTs per throttled query. Genuine transients keep retrying.
        #expect(!HTTPError.throttled.isRetryable)
        #expect(HTTPError.status(code: 503, body: nil).isRetryable)
    }

    // MARK: - Fix 2: a self-imposed ceiling, like the sources that never trip

    @Test func freeBMDCarriesASelfImposedDailyBudget() throws {
        let bmd = try #require(source("freebmd"))
        #expect(bmd.budgetPolicy.dailyLimit == 200,
                "unlimited meant the only brake was the live 429 — park before the host complains, as FreeCEN/FreeREG do at 300")
    }

    // MARK: - Fix 3a: mode=all trims the tier the loose pass subsumes

    @Test func allModeTrimsStrictFromTheFreeBMDLadder() throws {
        let bmd = try #require(source("freebmd"))
        let full: [SearchStrictness] = [.strict, .loose, .variant]
        #expect(SearchDispatcher.effectiveLadder(full, source: bmd, mode: .all)
                == [.loose, .variant],
                "loose is the same wire query with soundex ON — a strict superset of strict's rows")
    }

    @Test func adaptiveModeKeepsTheFullLadder() throws {
        // Strict earns its keep in adaptive modes via early-stop economy.
        let bmd = try #require(source("freebmd"))
        let full: [SearchStrictness] = [.strict, .loose, .variant]
        #expect(SearchDispatcher.effectiveLadder(full, source: bmd, mode: .adaptive) == full)
    }

    @Test func otherSourcesKeepTheirLadderInAllMode() throws {
        let cen = try #require(source("freecen"))
        let full: [SearchStrictness] = [.strict, .loose, .variant]
        #expect(SearchDispatcher.effectiveLadder(full, source: cen, mode: .all) == full)
    }

    @Test func aStrictOnlyLadderIsNeverTrimmedToNothing() throws {
        let bmd = try #require(source("freebmd"))
        #expect(SearchDispatcher.effectiveLadder([.strict], source: bmd, mode: .all)
                == [.strict])
    }

    // MARK: - Fix 3a: the variant tier's original combination

    @Test func variantTierDropsTheOriginalComboOnlyWhenAsked() throws {
        let bmd = try #require(source("freebmd"))
        func combos(drop: Bool) -> Set<String> {
            Set(SearchDispatcher.applyStrictness(
                [query()], strictness: .variant, source: bmd,
                dropOriginalVariantCombination: drop
            ).map { "\(($0.surname ?? "").uppercased())|\(($0.givenName ?? "").uppercased())" })
        }
        let kept = combos(drop: false)
        let dropped = combos(drop: true)
        #expect(kept.contains("THOMPSON|JOHN"),
                "adaptive modes keep the original combo — it is a free cache hit there")
        #expect(!dropped.contains("THOMPSON|JOHN"),
                "with strict trimmed from the .all ladder, the original combo would be a live re-fetch of rows loose already returned")
        #expect(dropped.subtracting(["THOMPSON|JOHN"]) == kept.subtracting(["THOMPSON|JOHN"]),
                "only the original combination goes — every genuine variant survives")
        #expect(!dropped.isEmpty, "Thompson has curated variants; the fan must survive the drop")
    }

    // MARK: - Fix 3b: budget charges mirror what the host actually sees

    @Test func onWireFetchFiresOnMissAndNeverOnCacheHit() async {
        let stub = EmptyCountingSource(sourceID: "stub")
        let cache = QueryCache()
        let counter = WireCounter()
        let q = query()
        _ = await QueryCache.wrappedSearchWithOutcome(
            source: stub, query: q, cache: cache,
            onWireFetch: { await counter.bump() })
        #expect(await counter.count == 1)
        _ = await QueryCache.wrappedSearchWithOutcome(
            source: stub, query: q, cache: cache,
            onWireFetch: { await counter.bump() })
        #expect(await counter.count == 1,
                "a per-run cache hit makes no request the volunteer host could see — it must not charge the daily budget")
        #expect(await stub.searchCount == 1)
    }
}

private actor WireCounter {
    var count = 0
    func bump() { count += 1 }
}

private actor EmptyCountingSource: RecordSource {
    nonisolated let sourceID: String
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Empty Counting Source"
    nonisolated let recordTypes: Set<RecordType> = [.death]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")
    nonisolated let budgetPolicy = SourceBudgetPolicy.unlimited

    private(set) var searchCount = 0

    init(sourceID: String) { self.sourceID = sourceID }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        searchCount += 1
        return .results([])
    }
}
