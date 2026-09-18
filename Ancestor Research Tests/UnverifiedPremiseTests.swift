import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// EV7 (2026-08-26), the user-facing half. The premise machinery itself
/// (`ResearchSubject.unverifiedKinPremises`, `SearchDispatcher.
/// unverifiedPremise`, the `NegativeSearchAggregator` split) shipped earlier
/// and is pinned by `KinResidenceScopeTests`. What was missing is that
/// NOTHING TOLD THE USER: `assumptionCaveat` had no production caller, the
/// settle pass rebuilt every source card from `searchOutcomes` without ever
/// reading `unverifiedPremise`, and the `.pipelineStage` message survived only
/// in a 30-entry in-memory ring that a FreeBMD district fan-out evicts before
/// the run ends.
///
/// So a run whose every query rested on a GEDCOM-only maiden name settled
/// reading "searched 6 queries — no results" and left nothing behind. These
/// pin the two repairs: the card tells the truth, and the truth outlives the
/// run without ever counting as a searched surface.
@MainActor
struct PremiseSurfacingTests {

    private func makeStatus(id: String) -> ResearchViewModel.SourceStatus {
        ResearchViewModel.SourceStatus(
            id: id, displayName: id.uppercased(),
            state: .pending, resultCount: 0, reason: nil)
    }

    private func entry(
        _ sourceID: String, _ recordType: RecordType,
        queryKey: String = "k",
        outcome: SearchOutcome = SearchOutcome(resultCount: 0),
        premise: String? = nil
    ) -> SearchOutcomeEntry {
        SearchOutcomeEntry(
            sourceID: sourceID, recordType: recordType, strictness: .strict,
            queryKey: queryKey, outcome: outcome, unverifiedPremise: premise)
    }

    private func result(_ outcomes: [SearchOutcomeEntry]) -> ResearchResult {
        ResearchResult(
            confirmedFacts: [], leads: [], allScoredRecords: [], clusters: [],
            discrepancies: [], householdMembers: [], searchHistory: [],
            searchOutcomes: outcomes)
    }

    // MARK: - The settle pass

    @Test func premiseBearingEmptySettlesAsACaveatNotAsNoResults() {
        let vm = ResearchViewModel()
        vm.sourceStatuses = [makeStatus(id: "freebmd")]

        vm.updateSourceStatuses(from: result([
            entry("freebmd", .marriage,
                  premise: "the spouse surname \"Wheatman\" (gedcom import, no citation)"),
        ]))

        #expect(vm.sourceStatuses[0].reason
                == "searched, but the query assumed the spouse surname \"Wheatman\" (gedcom import, no citation), which is unverified")
    }

    /// Guards against the caveat swallowing the normal path.
    @Test func aCleanEmptyStillReportsNoResults() {
        let vm = ResearchViewModel()
        vm.sourceStatuses = [makeStatus(id: "freebmd")]

        vm.updateSourceStatuses(from: result([entry("freebmd", .marriage)]))

        #expect(vm.sourceStatuses[0].reason == "searched 1 query — no results")
    }

    /// Branch ordering is load-bearing: a broken connector has a truer
    /// explanation than the premise, and a caveat must never mask it.
    @Test func aFailedQueryStillWinsOverTheCaveat() {
        let vm = ResearchViewModel()
        vm.sourceStatuses = [makeStatus(id: "freebmd")]

        vm.updateSourceStatuses(from: result([
            entry("freebmd", .marriage, queryKey: "k1",
                  outcome: SearchOutcome(resultCount: 0,
                                         availability: .error(reason: "HTTP 500"))),
            entry("freebmd", .marriage, queryKey: "k2",
                  premise: "the spouse surname \"Wheatman\" (gedcom import, no citation)"),
        ]))

        #expect(vm.sourceStatuses[0].state == .error)
        #expect(vm.sourceStatuses[0].reason?.contains("queries failed") == true)
    }

    /// Same ordering rule for a deliberate non-search: a scope skip is a
    /// truer explanation than a caveat about a query that was never sent.
    @Test func aScopeSkipStillWinsOverTheCaveat() {
        let vm = ResearchViewModel()
        vm.sourceStatuses = [makeStatus(id: "freebmd")]

        vm.updateSourceStatuses(from: result([
            entry("freebmd", .marriage, queryKey: "k1",
                  outcome: SearchOutcome(
                      resultCount: 0,
                      availability: .skipped(reason: "FreeBMD has no parish endpoint")),
                  premise: "the spouse surname \"Wheatman\" (gedcom import, no citation)"),
        ]))

        #expect(vm.sourceStatuses[0].reason == "skipped — FreeBMD has no parish endpoint")
    }

    /// A source that actually returned something is never re-explained.
    @Test func aSourceWithResultsIsUntouchedByTheCaveat() {
        let vm = ResearchViewModel()
        var status = makeStatus(id: "freebmd")
        status.reason = "3 results"
        vm.sourceStatuses = [status]

        let scored = ScoredRecord(
            id: "r1",
            record: .birth(BirthRecord(
                common: RecordCommon(id: "r1", sourceID: "freebmd", rawFields: [:]),
                birthYear: 1858)),
            verdict: .lead, gates: [], summary: "")
        let withHit = ResearchResult(
            confirmedFacts: [], leads: [scored], allScoredRecords: [scored],
            clusters: [], discrepancies: [], householdMembers: [], searchHistory: [],
            searchOutcomes: [entry("freebmd", .birth,
                                   premise: "the mother's maiden name \"Wheatman\" (gedcom import, no citation)")])
        vm.updateSourceStatuses(from: withHit)

        #expect(vm.sourceStatuses[0].reason == "3 results")
        #expect(vm.sourceStatuses[0].resultCount == 1)
    }
}

/// The durable half. An `'assumed'` row records that we asked the wrong
/// question — so it must be visible to the Dossier's "partial answer" bucket
/// while being invisible to BOTH the suppression reader (or it would go on
/// blocking the re-search, which is the Gladwin failure) and the
/// searched-surface reader (or it would launder into GPS criterion 1 as
/// "we searched that source", a worse lie than the one being fixed).
nonisolated struct AssumedNegativePersistenceTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    @Test func anAssumedRowNeverSuppressesAFutureSearch() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "marriage",
                                  params: "k", resultKind: "assumed", hitCount: 0)
        #expect(try db.loadNegativeSearchKeys(profileID: "p1").isEmpty)
    }

    @Test func anAssumedRowIsNotASearchedSurface() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "marriage",
                                  params: "k", resultKind: "assumed", hitCount: 0)
        #expect(try db.loadNegativeSearches(profileID: "p1").isEmpty)
    }

    @Test func aCleanZeroRowStillLoadsBothWays() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "marriage",
                                  params: "k", resultKind: "zero", hitCount: 0)
        #expect(try db.loadNegativeSearchKeys(profileID: "p1").count == 1)
        #expect(try db.loadNegativeSearches(profileID: "p1").count == 1)
    }

    /// A legacy pre-v42 row carries NULL and the writer only ever produced
    /// clean zeros for it — the filter must keep reading it as one.
    @Test func aLegacyNullKindRowStillLoadsBothWays() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "marriage",
                                  params: "k")
        #expect(try db.loadNegativeSearchKeys(profileID: "p1").count == 1)
        #expect(try db.loadNegativeSearches(profileID: "p1").count == 1)
    }

    /// The Dossier must still SEE the row — hidden from exhaustiveness is not
    /// the same as hidden from the reader. D3 routes it to "partial answer
    /// (assumed) — not evidence of absence" via `isCleanNegative == false`.
    @Test func theDossierStillSeesTheAssumedRowAsAPartialAnswer() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "marriage",
                                  params: "k", resultKind: "assumed", hitCount: 0)
        let rows = try db.negativeSearches(profileID: "p1")
        #expect(rows.count == 1)
        #expect(rows.first?.isCleanNegative == false)
        #expect(rows.first?.resultKind == "assumed")
    }

    /// Re-running with the premise now cited must upgrade the row in place,
    /// not leave a stale 'assumed' shadowing a real negative.
    @Test func aLaterCleanZeroUpgradesTheAssumedRow() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "marriage",
                                  params: "k", resultKind: "assumed", hitCount: 0)
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "marriage",
                                  params: "k", resultKind: "zero", hitCount: 0)
        #expect(try db.loadNegativeSearchKeys(profileID: "p1").count == 1)
        #expect(try db.loadNegativeSearches(profileID: "p1").count == 1)
    }
}
