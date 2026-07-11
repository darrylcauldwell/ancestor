import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-26: the Probate Calendar's digital index really
/// starts ~1996 (plus WWI/WWII soldier wills), not the 1858 the connector
/// used to declare. A death window entirely outside real coverage is
/// GUARANTEED empty, so it must degrade to `.outsideCoverage` — never a
/// clean negative, never cached, never fed to the strategist as an
/// already-searched avenue. Mirrors FreeCen's off-census-year guard
/// (FT-14). The guard fires BEFORE any wire request, so an
/// out-of-coverage query never touches the (recording) HTTP client.
struct ProbateCoverageGuardTests {

    // MARK: - Predicate (pure, no async)

    @Test func digitalEraDeathIsCovered() {
        #expect(ProbateSource.coversDeathWindow(from: 2000, to: 2010, gender: .male))
        #expect(ProbateSource.coversDeathWindow(from: 1996, to: 1996, gender: .female))
    }

    @Test func windowStraddlingTheDigitalFloorIsCovered() {
        // Any part of the window at/after the floor keeps the source in play.
        #expect(ProbateSource.coversDeathWindow(from: 1990, to: 2001, gender: .male))
    }

    @Test func victorianDeathIsOutsideCoverage() {
        #expect(!ProbateSource.coversDeathWindow(from: 1880, to: 1905, gender: .male))
        #expect(!ProbateSource.coversDeathWindow(from: 1900, to: 1900, gender: nil))
    }

    @Test func interWarGapIsOutsideCoverage() {
        // 1925–1935 sits between the two soldier-wills windows and before
        // the digital floor — genuinely uncovered.
        #expect(!ProbateSource.coversDeathWindow(from: 1925, to: 1935, gender: .male))
    }

    @Test func maleSoldierInWWIWindowIsCovered() {
        #expect(ProbateSource.coversDeathWindow(from: 1917, to: 1917, gender: .male))
        #expect(ProbateSource.coversDeathWindow(from: 1940, to: 1944, gender: .male))
    }

    @Test func unknownSexSoldierWindowIsAdmittedNotExcluded() {
        // A missing sex fact must not exclude a possible soldier will.
        #expect(ProbateSource.coversDeathWindow(from: 1916, to: 1916, gender: nil))
        #expect(ProbateSource.coversDeathWindow(from: 1916, to: 1916, gender: .other))
    }

    @Test func femaleInSoldierWindowIsNotASoldierWill() {
        // A woman cannot have a soldier will; a WWI-era female death with no
        // digital-era overlap is outside coverage.
        #expect(!ProbateSource.coversDeathWindow(from: 1917, to: 1917, gender: .female))
    }

    @Test func unboundedWindowIsCovered() {
        // No year window at all → don't refuse; nil bounds are open.
        #expect(ProbateSource.coversDeathWindow(from: nil, to: nil, gender: nil))
        // Open upper edge reaches the present, so it overlaps the digital era.
        #expect(ProbateSource.coversDeathWindow(from: 1880, to: nil, gender: .male))
    }

    // MARK: - End-to-end: out-of-coverage is .outsideCoverage, NOT a negative

    @MainActor
    @Test func outOfCoverageQueryReturnsOutsideCoverageAndNeverHitsWire() async {
        // A poisoned client that would return a clean-empty body if reached —
        // proving the guard fires before any request, so the empty can never
        // masquerade as a genuine negative.
        let http = RecordingHTTPClient(body: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery(from: 1880, to: 1905, gender: .male))

        guard case .outsideCoverage(let reason) = envelope.result else {
            Issue.record("A pre-1996 death window must be .outsideCoverage, got \(envelope.result)")
            return
        }
        #expect(reason.contains("1996"))
        // The load-bearing assertion (parallels FreeCen FT-14): this is NOT
        // a clean negative, so NegativeSearchAggregator never records it and
        // QueryCache never caches it.
        #expect(!envelope.outcome.isCleanNegative)
        #expect(envelope.outcome.availability != .ok)

        let requests = await http.requestCount
        #expect(requests == 0, "out-of-coverage guard must fire before any wire request")
    }

    @MainActor
    @Test func inCoverageQueryProceedsToTheWire() async {
        // The mirror case: an in-coverage window must NOT be short-circuited —
        // it proceeds, parses, and a genuine empty IS a clean negative.
        let http = RecordingHTTPClient(body: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery(from: 2000, to: 2010, gender: .male))

        guard case .results(let records) = envelope.result else {
            Issue.record("An in-coverage query must proceed, got \(envelope.result)")
            return
        }
        #expect(records.isEmpty)
        #expect(envelope.outcome.isCleanNegative, "a genuine in-coverage empty IS a real negative")

        let requests = await http.requestCount
        #expect(requests == 1, "in-coverage query issues its page-0 request")
    }

    @MainActor
    @Test func soldierWillWindowProceedsToTheWire() async {
        // A male WWI-era death is covered by the soldier-wills carve-out even
        // though it predates the digital floor — it must reach the wire.
        let http = RecordingHTTPClient(body: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        let envelope = await source.searchWithOutcome(Self.probateQuery(from: 1917, to: 1917, gender: .male))

        guard case .results = envelope.result else {
            Issue.record("A soldier-wills-era male death must proceed, got \(envelope.result)")
            return
        }
        let requests = await http.requestCount
        #expect(requests == 1)
    }

    // MARK: - Helpers

    private static func probateQuery(from: Int?, to: Int?, gender: Gender?) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .probate,
            yearFrom: from, yearTo: to,
            gender: gender, region: .englandAndWales,
            sourceParams: .generic
        )
    }
}

/// Stub HTTP client that returns one canned body for any URL and counts
/// how many requests it received. An actor so the count is race-free.
/// Used to prove the T1-26 guard short-circuits before the wire.
actor RecordingHTTPClient: HTTPClient {
    private let body: Data
    private(set) var requestCount = 0
    private(set) var lastURL: URL?

    init(body: Data) {
        self.body = body
    }

    func get(url: URL, headers: [String: String]) async throws -> Data {
        requestCount += 1
        lastURL = url
        return body
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        requestCount += 1
        lastURL = url
        return body
    }
}
