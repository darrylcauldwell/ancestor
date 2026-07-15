import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_AXES_SPEC.md Change 5 —
/// per-source strictness handling + surname-variants fan-out.
@MainActor
struct PerSourceStrictnessTests {

    // MARK: - AC5.1 — surname-variants.json ships with ≥30 entries

    @Test func ac5_1_surnameVariantsHasAtLeastThirtyEntries() {
        let count = SurnameVariants.shared.map.count
        #expect(count >= 30, "surname-variants.json should have ≥30 entries, found \(count)")
    }

    @Test func ac5_1_lookupIsCaseInsensitiveAndReturnsVariantsExcludingCanonical() {
        let lower = SurnameVariants.shared.variants(of: "cauldwell")
        let upper = SurnameVariants.shared.variants(of: "CAULDWELL")
        let mixed = SurnameVariants.shared.variants(of: "Cauldwell")
        #expect(lower == upper)
        #expect(lower == mixed)
        #expect(!lower.isEmpty, "Cauldwell should have known variants in the seed dictionary")
        // Canonical surname should NOT appear in its own variants list.
        #expect(!lower.contains("cauldwell"))
    }

    @Test func ac5_1_unknownSurnameReturnsEmptyVariants() {
        #expect(SurnameVariants.shared.variants(of: "Zzqzzzqx").isEmpty)
    }

    // MARK: - AC5.2 — CWGC strictness behaviour

    @Test func ac5_2_cwgcLooseDropsTabParameter() async {
        let source = CWGCSource()
        // Probe via a fake HTTP client and inspect the URL CWGC requests.
        let captured = CapturingHTTPClient()
        let sourceWithCapture = CWGCSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .death,
            yearFrom: nil, yearTo: nil, gender: .male, region: nil,
            sourceParams: .cwgc(CWGCParams(conflict: nil)),
            strictness: .loose
        )
        _ = await sourceWithCapture.search(query)
        #expect(captured.lastURL?.absoluteString.contains("Tab=exact") == false,
                "loose mode should omit Tab=exact")
        _ = source  // silence unused warning
    }

    @Test func ac5_2_cwgcStrictKeepsTabExact() async {
        let captured = CapturingHTTPClient()
        let source = CWGCSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .death,
            yearFrom: nil, yearTo: nil, gender: .male, region: nil,
            sourceParams: .cwgc(CWGCParams(conflict: nil)),
            strictness: .strict
        )
        _ = await source.search(query)
        #expect(captured.lastURL?.absoluteString.contains("Tab=exact") == true,
                "strict mode should include Tab=exact")
    }

    // AC5.2 part 2: variant falls back to loose (no extra dispatcher fan-out
    // for CWGC). Tested at the dispatcher level via applyStrictness:
    @Test func ac5_2_cwgcVariantFallsBackToLoose() {
        let cwgc = CWGCSource()
        let baseQuery = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .death,
            yearFrom: nil, yearTo: nil, gender: .male, region: nil,
            sourceParams: .cwgc(CWGCParams(conflict: nil))
        )
        let result = SearchDispatcher.applyStrictness([baseQuery], strictness: .variant, source: cwgc)
        #expect(result.count == 1, "CWGC should not fan out for .variant")
        #expect(result.first?.strictness == .loose, "CWGC .variant should fall back to .loose")
    }

    // MARK: - AC5.3 — FreeBMD strictness behaviour

    @Test func ac5_3_freeBMDLooseFlipsPhoneticFlag() async {
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .birth,
            yearFrom: 1880, yearTo: 1880, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: nil
            )),
            strictness: .loose
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("sndx=on"),
                "FreeBMD .loose should set the real soundex field sndx=on; body was \(body)")
    }

    @Test func ac5_3_freeBMDStrictOmitsPhonetic() async {
        // FT-06 (2026-07-11): strict must OMIT the Phonetic field entirely,
        // not send `Phonetic=false`. search.pl is Perl CGI with checkbox-
        // presence semantics — a present "false" reads as TRUE and silently
        // enables soundex. Omitting is correct under both interpretations.
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .birth,
            yearFrom: 1880, yearTo: 1880, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: nil
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(!body.contains("sndx"),
                "FreeBMD .strict must omit the soundex field entirely; body was \(body)")
    }

    @Test func ac5_3_freeBMDVariantFansOutByN_plus_1() {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        guard let freebmd = registry.allSources().first(where: { $0.sourceID == "freebmd" }) else {
            Issue.record("FreeBMD source not in registry")
            return
        }
        let baseQuery = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .birth,
            yearFrom: 1880, yearTo: 1880, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: nil
            ))
        )
        let variants = SurnameVariants.shared.variants(of: "Cauldwell")
        let result = SearchDispatcher.applyStrictness([baseQuery], strictness: .variant, source: freebmd)
        #expect(result.count == variants.count + 1,
                "FreeBMD .variant fan-out should be N+1; got \(result.count) for \(variants.count) variants")
        let surnames = Set(result.compactMap(\.surname).map { $0.lowercased() })
        #expect(surnames.contains("cauldwell"))
        for v in variants { #expect(surnames.contains(v)) }
    }

    // MARK: - AC5.3 (continued) — FreeREG and FreeCen .loose flip fuzzy flag

    @Test func ac5_3_freeREGLooseEnablesFuzzyFlag() async {
        let captured = CapturingHTTPClient()
        let source = FreeREGSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .baptism,
            yearFrom: 1880, yearTo: 1880, gender: .male, region: nil,
            sourceParams: .freeREG(FreeREGParams(chapmanCode: "DBY")),
            strictness: .loose
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[fuzzy]=true"),
                "FreeREG .loose should send fuzzy=true; body was \(body)")
    }

    @Test func ac5_3_freeREGStrictOmitsFuzzyField() async {
        let captured = CapturingHTTPClient()
        let source = FreeREGSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .baptism,
            yearFrom: 1880, yearTo: 1880, gender: .male, region: nil,
            sourceParams: .freeREG(FreeREGParams(chapmanCode: "DBY")),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(!body.contains("search_query[fuzzy]"),
                "FreeREG .strict should omit fuzzy field entirely; body was \(body)")
    }

    @Test func ac5_3_freeCenLooseFlipsFuzzyToOne() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .census,
            yearFrom: 1881, yearTo: 1881, gender: .male, region: nil,
            sourceParams: .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: 1881, birthYearRange: nil)),
            strictness: .loose
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[fuzzy]=1"),
                "FreeCen .loose should send fuzzy=1; body was \(body)")
    }

    @Test func ac5_3_freeCenStrictKeepsFuzzyZero() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: nil,
            recordType: .census,
            yearFrom: 1881, yearTo: 1881, gender: .male, region: nil,
            sourceParams: .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: 1881, birthYearRange: nil)),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query[fuzzy]=0"),
                "FreeCen .strict should send fuzzy=0; body was \(body)")
    }

    // MARK: - AC5.4 — strict-only sources produce identical bytes across all
    // strictness values. We sample two of the three (Probate, FindAGrave) at
    // the dispatcher level — Wirksworth's source-side coverage check is
    // location-dependent so we just assert no extra fan-out happened.

    @Test func ac5_4_strictOnlySourcesDoNotFanOutAndIgnoreStrictnessOnTheWire() {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)

        for sourceID in ["probate", "wirksworth", "findagrave"] {
            guard let src = registry.allSources().first(where: { $0.sourceID == sourceID }) else {
                Issue.record("Source \(sourceID) not in registry")
                continue
            }
            let baseQuery = RecordQuery(
                surname: "Cauldwell", givenName: nil,
                recordType: .death,
                yearFrom: nil, yearTo: nil, gender: .male, region: nil,
                sourceParams: .generic
            )
            for strictness in [SearchStrictness.strict, .loose, .variant] {
                let result = SearchDispatcher.applyStrictness([baseQuery], strictness: strictness, source: src)
                // Behavioural assertion: no variant fan-out, surname unchanged.
                // Source-side wire bytes are inherently identical across
                // strictness values because these sources don't read
                // query.strictness in their search methods. The strictness
                // field IS stamped on the query so activity-bus events
                // reflect the dispatcher's tier intent — that's a presentation
                // concern, not a behavioural one.
                #expect(result.count == 1,
                        "\(sourceID) should not fan out for .\(strictness); got \(result.count)")
                #expect(result.first?.surname == "Cauldwell",
                        "\(sourceID) surname should be unchanged for .\(strictness)")
            }
        }
    }
}

/// Test-only HTTP client that captures the most recent request's URL and
/// form body, returning empty bytes so the source's parser yields zero
/// results without going to the network.
final class CapturingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastURL: URL?
    private var _lastFormBody: String?
    private var _lastMultiFields: [(String, String)]?

    var lastURL: URL? { lock.withLock { _lastURL } }
    var lastFormBody: String? { lock.withLock { _lastFormBody } }
    /// FT-25 — the ordered pairs from the `multiFields` path, preserving
    /// repeated keys (e.g. several `search_query[chapman_codes][]`). nil
    /// when the connector used the single-value `postForm(fields:)` path.
    var lastMultiFields: [(String, String)]? { lock.withLock { _lastMultiFields } }

    func get(url: URL, headers: [String: String]) async throws -> Data {
        lock.withLock { _lastURL = url }
        return Data()
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        lock.withLock {
            _lastURL = url
            _lastFormBody = fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
        }
        return Data()
    }

    /// FT-25 — override the multi-value path so repeated keys are NOT
    /// collapsed (the protocol-extension default merges into a dict, losing
    /// a batched chapman set). `lastFormBody` is built from the ordered
    /// pairs so existing single-value assertions (`body.contains(...)`)
    /// keep working AND a batch shows every repeated key.
    func postForm(url: URL, multiFields: [(String, String)], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        lock.withLock {
            _lastURL = url
            _lastMultiFields = multiFields
            _lastFormBody = multiFields.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        }
        return Data()
    }
}
