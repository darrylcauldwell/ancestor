import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// FREEREG_INTEGRATION_SPEC §0/§1 — the FreeREG capability axes (place_ids,
/// witness, family, no_surname, nearby) and the MyopicVicar safety invariants
/// (the `region` bot honeypot, the 3-county cap). Ground truth: the live engine
/// FreeUKGen/MyopicVicar (`_form_freereg.html.erb`), validated 2026-07-29.
///
/// These pin the WIRE SHAPE only — `CapturingHTTPClient` returns empty bodies,
/// so the POST fires and `lastMultiFields` is captured regardless of parsing.
@MainActor
struct FreeREGQueryModelTests {

    // MARK: helpers

    private func keys(_ c: CapturingHTTPClient) -> [String] {
        (c.lastMultiFields ?? []).map(\.0)
    }
    private func values(_ c: CapturingHTTPClient, _ key: String) -> [String] {
        (c.lastMultiFields ?? []).filter { $0.0 == key }.map(\.1)
    }
    private func query(surname: String? = "Kenworthy", given: String? = nil,
                       params: FreeREGParams) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: given, recordType: .baptism,
            yearFrom: nil, yearTo: nil, gender: nil, region: nil,
            sourceParams: .freeREG(params), strictness: .strict
        )
    }

    // MARK: - region honeypot (§0.1)

    @Test func regionHoneypotIsNeverOnTheWire() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        // A maximal query — every axis set — still must not emit region.
        _ = await source.search(query(given: "John", params: FreeREGParams(
            chapmanCode: "DBY", placeIDs: ["1001"],
            includeWitnesses: true, includeFamilyMembers: true,
            noSurname: true, searchNearbyPlaces: true)))
        #expect(!keys(c).contains { $0.localizedCaseInsensitiveContains("region") },
                "search_query[region] is a bot honeypot and must never reach the wire")
    }

    // MARK: - county cap (§0.2, resolves FT-27)

    @Test func chapmanCodesCappedAtThree() {
        #expect(FreeREGParams.cappedChapmanCodes(["DBY", "NTT", "LEI", "STS", "YKS"]) == ["DBY", "NTT", "LEI"])
        #expect(FreeREGParams.cappedChapmanCodes(["DBY", "", "NTT"]) == ["DBY", "NTT"])
    }

    @Test func channelIslandsQuartetIsExemptFromTheCap() {
        let ci = ["ALD", "GSY", "JSY", "SRK"]
        #expect(FreeREGParams.cappedChapmanCodes(ci) == ci,
                "the Channel Islands quartet may exceed the 3-county cap together")
    }

    @Test func batchGroupSizesMatchTheEngineCap() {
        #expect(FreeREGParams.batchGroupSize == 3)
        #expect(FreeCenParams.batchGroupSize == 3, "FreeCEN shares the same MyopicVicar 3-county cap")
    }

    @Test func overFannedCodesAreCappedBeforeTheWire() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(params: FreeREGParams(chapmanCodes: ["DBY", "NTT", "LEI", "STS"])))
        #expect(values(c, "search_query[chapman_codes][]") == ["DBY", "NTT", "LEI"],
                "an over-fanned code list is capped to 3 before hitting the wire")
    }

    // MARK: - place_ids gate (FT-19)

    @Test func placeIDsEmitWithASingleCounty() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(params: FreeREGParams(chapmanCode: "DBY", placeIDs: ["1001", "1002"])))
        #expect(values(c, "search_query[place_ids][]") == ["1001", "1002"])
    }

    @Test func placeIDsDroppedWithMultipleCounties() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(params: FreeREGParams(chapmanCodes: ["DBY", "NTT"], placeIDs: ["1001"])))
        #expect(values(c, "search_query[place_ids][]").isEmpty,
                "the Places box only populates for a single county → drop place_ids when >1")
    }

    // MARK: - witness / family axes (FT-21)

    @Test func witnessAndFamilyAxesEmitWhenSet() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(params: FreeREGParams(
            chapmanCode: "DBY", includeWitnesses: true, includeFamilyMembers: true)))
        #expect(values(c, "search_query[witness]") == ["true"])
        #expect(values(c, "search_query[inclusive]") == ["true"])
    }

    @Test func capabilityAxesAbsentByDefault() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(params: FreeREGParams(chapmanCode: "DBY")))
        let k = keys(c)
        #expect(!k.contains("search_query[witness]"))
        #expect(!k.contains("search_query[inclusive]"))
        #expect(!k.contains("search_query[place_ids][]"))
        #expect(!k.contains("search_query[no_surname]"))
        #expect(!k.contains("search_query[search_nearby_places]"))
    }

    // MARK: - nearby requires a place

    @Test func nearbyDroppedWithoutAPlace() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(params: FreeREGParams(chapmanCode: "DBY", searchNearbyPlaces: true)))
        #expect(values(c, "search_query[search_nearby_places]").isEmpty,
                "radius search needs a selected place")
    }

    @Test func nearbyEmitsWithAPlace() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(params: FreeREGParams(
            chapmanCode: "DBY", placeIDs: ["1001"], searchNearbyPlaces: true)))
        #expect(values(c, "search_query[search_nearby_places]") == ["true"])
    }

    // MARK: - no_surname requires forename + county + place

    @Test func noSurnameNotEmittedWithoutForenameAndPlace() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        // no_surname requested but no forename / no place → must NOT emit it,
        // and (since there is no surname either) the search must not fire.
        _ = await source.search(query(surname: nil, given: nil,
                                      params: FreeREGParams(chapmanCode: "DBY", noSurname: true)))
        #expect(c.lastMultiFields == nil,
                "an invalid no-surname query (no forename, no place) must not hit the wire")
    }

    @Test func validNoSurnameSearchEmitsWithEmptyLastName() async {
        let c = CapturingHTTPClient()
        let source = FreeREGSource(http: c)
        _ = await source.search(query(surname: nil, given: "John",
                                      params: FreeREGParams(chapmanCode: "DBY", placeIDs: ["1001"], noSurname: true)))
        #expect(values(c, "search_query[no_surname]") == ["true"])
        #expect(values(c, "search_query[first_name]") == ["John"])
        #expect(values(c, "search_query[last_name]") == [""],
                "a valid no-surname search sends an empty last_name alongside no_surname=true")
        #expect(values(c, "search_query[place_ids][]") == ["1001"])
    }
}
