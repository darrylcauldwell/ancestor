import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-28 (dropped estatepostcode/estatetitle; courtType
/// dead plumbing) and T1-29 (multi-given firstnames sent unverified;
/// first-token coercion). Parsing tests assert the previously-dropped
/// fields now land on the record; wire tests assert the request the
/// connector actually builds. Idiom: ConnectorOutcomeMappingTests /
/// ProbatePagingTests.
struct ProbateFieldParsingTests {

    // MARK: - T1-28: postcode / title parsing

    @Test func postcodeAndTitleParsedIntoTypedFieldsAndRawFields() {
        let body = Data(#"""
        {"entries": [{"uid": "uid-1", "properties": {
            "hmctsgrant:surname": "CAULDWELL",
            "hmctsgrant:firstnames": "JENNIFER",
            "hmctsgrant:estatetitle": "MRS",
            "hmctsgrant:estatepostcode": "DE4 3AB",
            "hmctsgrant:estateaddressline1": "12 High Street",
            "hmctsgrant:dateofdeath": "2005-03-01T00:00:00.000Z"
        }}], "resultsCount": 1}
        """#.utf8)

        let records = ProbateSource.parseJSON(body, surname: "CAULDWELL")
        #expect(records.count == 1)
        guard case .probate(let r) = records[0] else {
            Issue.record("Expected a probate record")
            return
        }
        #expect(r.postcode == "DE4 3AB", "estatepostcode lands in the typed field (was dropped pre-T1-28)")
        #expect(r.title == "MRS", "estatetitle lands in the typed field (was dropped pre-T1-28)")
        // Also exposed in rawFields for read sites that don't thread typed fields.
        #expect(r.common.rawFields["postcode"] == "DE4 3AB")
        #expect(r.common.rawFields["title"] == "MRS")
    }

    @Test func missingPostcodeAndTitleLeaveNilAndAbsentRawKeys() {
        let body = Data(#"""
        {"entries": [{"uid": "uid-2", "properties": {
            "hmctsgrant:surname": "CAULDWELL",
            "hmctsgrant:firstnames": "ROBERT",
            "hmctsgrant:dateofdeath": "2005-03-01T00:00:00.000Z"
        }}], "resultsCount": 1}
        """#.utf8)

        let records = ProbateSource.parseJSON(body, surname: "CAULDWELL")
        guard case .probate(let r) = records[0] else {
            Issue.record("Expected a probate record")
            return
        }
        #expect(r.postcode == nil, "absent postcode is nil, not empty string")
        #expect(r.title == nil, "absent title is nil, not empty string")
        #expect(r.common.rawFields["postcode"] == nil, "empty fields are dropped from rawFields")
        #expect(r.common.rawFields["title"] == nil)
    }

    // MARK: - T1-29: firstnames first-token coercion (pure)

    @Test func firstGivenNameTakesFirstTokenOnly() {
        #expect(ProbateSource.firstGivenName("Ernest Victor") == "Ernest")
        #expect(ProbateSource.firstGivenName("  Mary   Ann  ") == "Mary")
        #expect(ProbateSource.firstGivenName("Robert") == "Robert")
    }

    @Test func firstGivenNameHandlesEmptyAndNil() {
        #expect(ProbateSource.firstGivenName(nil) == nil)
        #expect(ProbateSource.firstGivenName("") == nil)
        #expect(ProbateSource.firstGivenName("   ") == nil)
    }

    // MARK: - T1-29: only the first given token goes on the wire

    @MainActor
    @Test func multiGivenFirstnamesSendsFirstTokenOnly() async {
        let http = RecordingHTTPClient(body: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        _ = await source.searchWithOutcome(Self.probateQuery(given: "Ernest Victor"))

        let items = await Self.queryItems(http)
        let firstnames = items.first { $0.name == "hmcts_grant_schema_firstnames" }?.value
        #expect(firstnames == "ERNEST",
                "multi-given 'Ernest Victor' must send first token uppercased only (FreeBMD/FAG lesson)")
    }

    @MainActor
    @Test func noGivenNameSendsNoFirstnamesParam() async {
        let http = RecordingHTTPClient(body: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        _ = await source.searchWithOutcome(Self.probateQuery(given: nil))

        let items = await Self.queryItems(http)
        #expect(!items.contains { $0.name == "hmcts_grant_schema_firstnames" },
                "no given name → the firstnames param is omitted, not sent empty")
    }

    // MARK: - T1-28: courtType is wired (no longer dead plumbing)

    @MainActor
    @Test func courtTypeParamGoesOnTheWireWhenSet() async {
        let http = RecordingHTTPClient(body: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        let query = RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .probate,
            yearFrom: 2000, yearTo: 2010,
            gender: .male, region: .englandAndWales,
            sourceParams: .probate(ProbateParams(courtType: "administration"))
        )
        _ = await source.searchWithOutcome(query)

        let items = await Self.queryItems(http)
        let grantDocType = items.first { $0.name == "hmcts_grant_schema_grantdocTypeOf" }?.value
        #expect(grantDocType == "ADMINISTRATION",
                "a set courtType now reaches the wire uppercased (T1-28: no longer dead plumbing)")
    }

    @MainActor
    @Test func courtTypeDefaultsToEmptyWhenUnset() async {
        // Existing callers pass .generic (or nil courtType) → unchanged "".
        let http = RecordingHTTPClient(body: Data(#"{"entries": [], "resultsCount": 0}"#.utf8))
        let source = ProbateSource(http: http)
        _ = await source.searchWithOutcome(Self.probateQuery(given: "Robert"))

        let items = await Self.queryItems(http)
        let grantDocType = items.first { $0.name == "hmcts_grant_schema_grantdocTypeOf" }?.value
        #expect(grantDocType == "", "unset courtType keeps the pre-T1-28 empty 'all grant types' filter")
    }

    // MARK: - Helpers

    private static func probateQuery(given: String?) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: given,
            recordType: .probate,
            yearFrom: 2000, yearTo: 2010,
            gender: .male, region: .englandAndWales,
            sourceParams: .generic
        )
    }

    private static func queryItems(_ http: RecordingHTTPClient) async -> [URLQueryItem] {
        guard let url = await http.lastURL,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return []
        }
        return items
    }
}
