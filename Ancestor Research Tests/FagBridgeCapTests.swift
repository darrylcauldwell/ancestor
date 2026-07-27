import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-17 — the FamilySearch → Find a Grave detail-bridge
/// must be capped at a small number of `fetchDetail` calls per iteration.
///
/// Before the fix, `enrichFagBridge` looped over every qualifying FS
/// burial persona (sourceID == "familysearch", a memorialID, nil
/// deathYear) and fired a full WKWebView detail load for each — no cap,
/// contrary to FreeCen's cap-1 pattern and the volunteer-budget rule.
/// These tests drive the bridge through the DEBUG test seam
/// `enrichFagBridgeForTesting` with a fixture that *would* trigger more
/// than the cap of bridge fetches, and assert the (N+1)th is skipped.
@MainActor
struct FagBridgeCapTests {

    // MARK: - Core cap assertion

    @Test func bridgeSkipsFetchesBeyondPerIterationCap() async {
        let fag = CountingFAGDetailSource()
        let pipeline = makePipeline(fag: fag)
        let cap = ResearchPipeline.maxFagBridgeFetchesPerIteration

        // Five qualifying FS burial personas — two more than the cap.
        let records = (0..<(cap + 2)).map { fsBurial(memorialID: 1000 + $0) }

        _ = await pipeline.enrichFagBridgeForTesting(records, existingIDs: [])

        let calls = fag.fetchCount
        #expect(calls == cap,
                "bridge should fire exactly \(cap) detail fetches for \(cap + 2) qualifying records; got \(calls)")
    }

    @Test func bridgeReturnsUnenrichedRecordsPastCap() async {
        let fag = CountingFAGDetailSource()
        let pipeline = makePipeline(fag: fag)
        let cap = ResearchPipeline.maxFagBridgeFetchesPerIteration

        let records = (0..<(cap + 2)).map { fsBurial(memorialID: 2000 + $0) }
        let out = await pipeline.enrichFagBridgeForTesting(records, existingIDs: [])

        // Every original FS persona is preserved (bridge appends
        // enriched records, never drops originals), plus one enriched
        // record per successful fetch (cap of them).
        let originals = out.filter { $0.sourceID == "familysearch" }
        let enriched = out.filter { $0.sourceID == "findagrave" }
        #expect(originals.count == cap + 2,
                "all FS personas kept regardless of cap; got \(originals.count)")
        #expect(enriched.count == cap,
                "only capped number of enriched FAG-detail records appended; got \(enriched.count)")
    }

    // MARK: - Cap interacts correctly with the existingIDs skip

    @Test func alreadyEnrichedMemorialsDoNotBurnBudget() async {
        let fag = CountingFAGDetailSource()
        let pipeline = makePipeline(fag: fag)
        let cap = ResearchPipeline.maxFagBridgeFetchesPerIteration

        // First record's memorial was already pulled in a prior
        // iteration; it must be skipped WITHOUT consuming budget, so the
        // next `cap` fresh memorials still all get fetched.
        let alreadyDone = fsBurial(memorialID: 3000)
        let fresh = (0..<cap).map { fsBurial(memorialID: 3100 + $0) }
        let records = [alreadyDone] + fresh

        _ = await pipeline.enrichFagBridgeForTesting(
            records,
            existingIDs: ["findagrave_3000"]
        )

        let calls = fag.fetchCount
        #expect(calls == cap,
                "existingIDs skip must not consume budget; expected \(cap) fetches for the fresh memorials, got \(calls)")
        let fetched = fag.fetchedIDs
        #expect(!fetched.contains("findagrave_3000"),
                "already-enriched memorial must never be fetched")
    }

    // MARK: - Non-qualifying records never count toward the cap

    @Test func onlyQualifyingRecordsConsumeBudget() async {
        let fag = CountingFAGDetailSource()
        let pipeline = makePipeline(fag: fag)
        let cap = ResearchPipeline.maxFagBridgeFetchesPerIteration

        // Interleave qualifying FS-burial personas with records that
        // must NOT trigger the bridge: a FS burial WITH a deathYear
        // (nothing to enrich), and a FAG-native burial (wrong source).
        var records: [SourceRecord] = []
        for i in 0..<(cap + 3) {
            records.append(fsBurial(memorialID: 4000 + i))          // qualifies
            records.append(fsBurial(memorialID: 5000 + i, deathYear: 1918)) // has year → skip
            records.append(fagNativeBurial(memorialID: 6000 + i))   // wrong source → skip
        }

        _ = await pipeline.enrichFagBridgeForTesting(records, existingIDs: [])

        let calls = fag.fetchCount
        #expect(calls == cap,
                "only nil-deathYear FS burials count toward the cap; got \(calls)")
    }

    // MARK: - Fixtures

    private func fsBurial(memorialID: Int, deathYear: Int? = nil) -> SourceRecord {
        .burial(BurialRecord(
            common: RecordCommon(
                id: "familysearch_persona_\(memorialID)",
                sourceID: "familysearch",
                name: "Robert Cauldwell",
                surname: "Cauldwell",
                givenName: "Robert",
                detailURL: nil,
                rawFields: [:]
            ),
            deathYear: deathYear,
            memorialID: memorialID,
            isVeteran: false
        ))
    }

    private func fagNativeBurial(memorialID: Int) -> SourceRecord {
        .burial(BurialRecord(
            common: RecordCommon(
                id: "findagrave_\(memorialID)",
                sourceID: "findagrave",
                name: "Robert Cauldwell",
                surname: "Cauldwell",
                givenName: "Robert",
                detailURL: nil,
                rawFields: [:]
            ),
            deathYear: nil,
            memorialID: memorialID,
            isVeteran: false
        ))
    }

    private func makePipeline(fag: CountingFAGDetailSource) -> ResearchPipeline {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(fag)
        let dispatcher = SearchDispatcher(registry: registry)
        return ResearchPipeline(
            dispatcher: dispatcher,
            snapshot: .empty,
            sourceInfoMap: [:]
        )
    }
}

/// Fake FindAGrave source that counts `fetchDetail` calls and returns a
/// single enriched burial record per call. `sourceID == "findagrave"` so
/// `enrichFagBridge`'s registry lookup finds it.
///
/// Modelled as a `@MainActor` class rather than an `actor`: the project
/// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
/// `DetailFetchingSource` is a MainActor-isolated protocol; the pipeline
/// under test is itself `@MainActor`, so a MainActor mock is the natural
/// fit and the call counters are read from the same isolation domain.
@MainActor
final class CountingFAGDetailSource: DetailFetchingSource {
    nonisolated let sourceID = "findagrave"
    nonisolated let scopeHandling: ScopeHandling = .anchorPinned(reason: "test double")
    nonisolated let displayName = "Find a Grave (test)"
    nonisolated let recordTypes: Set<RecordType> = [.death]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .restricted, summary: "test stub")

    private(set) var fetchCount = 0
    private(set) var fetchedIDs: [String] = []

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        .results([])
    }

    func fetchDetail(recordID: String) async -> SourceQueryResult {
        fetchCount += 1
        fetchedIDs.append(recordID)
        // Return an enriched burial record so the bridge appends it.
        let numeric = recordID.replacingOccurrences(of: "findagrave_", with: "")
        let record = SourceRecord.burial(BurialRecord(
            common: RecordCommon(
                id: recordID,
                sourceID: "findagrave",
                name: "Robert Cauldwell",
                surname: "Cauldwell",
                givenName: "Robert",
                detailURL: nil,
                rawFields: [:]
            ),
            deathYear: 1917,
            memorialID: Int(numeric),
            inscription: "In loving memory",
            isVeteran: false
        ))
        return .results([record])
    }
}
