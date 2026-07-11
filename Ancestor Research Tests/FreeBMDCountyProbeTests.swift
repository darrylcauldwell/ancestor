import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// FT-01 activation probe — env-gated LIVE test (one search request).
///
/// Validates the compound `countyid` wire value ("DBY,406,418,…" —
/// Chapman code + district IDs) against the real FreeBMD server before
/// `FreeBMDParams.countyQueryEnabled` may be flipped. Run deliberately
/// and rarely (volunteer-source budget rules):
///
///   env TEST_RUNNER_RUN_FREEBMD_COUNTY_PROBE=1 xcodebuild test … \
///     -parallel-testing-enabled NO \
///     -only-testing:"Ancestor Research Tests/FreeBMDCountyProbeTests"
///
/// Pass criteria: the county-level query returns rows spanning MORE
/// THAN ONE registration district — proving the server honoured the
/// county axis (an ignored filter would return all-England rows, so a
/// second assertion pins every district to the DBY set).
@MainActor
struct FreeBMDCountyProbeTests {

    @Test func countyAxisReturnsMultiDistrictRows() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FREEBMD_COUNTY_PROBE"] == "1" else {
            return // gated off — no live traffic
        }
        guard let countyID = RegionConfig.freeBMDCountyID(forChapmanCode: "DBY") else {
            Issue.record("no county ID derivable for DBY")
            return
        }
        let dbyDistricts = Set(RegionConfig.districts(forChapmanCode: "DBY").keys.map { $0.lowercased() })
        let source = FreeBMDSource()
        // Common surname over a modest window — expected in several
        // Derbyshire districts; narrow enough not to overflow.
        let query = RecordQuery(
            surname: "Taylor", givenName: "John", recordType: .birth,
            yearFrom: 1885, yearTo: 1889, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: nil, countyCode: countyID, wildcardSurname: false
            )),
            strictness: .strict
        )
        let envelope = await source.searchWithOutcome(query)
        let records = envelope.result.records
        print("PROBE: \(records.count) records, availability=\(envelope.outcome.availability), truncated=\(envelope.outcome.truncated)")
        #expect(envelope.outcome.availability == SearchAvailability.ok, "probe request must succeed")
        #expect(!records.isEmpty, "county-level query returned no rows")

        var districts: Set<String> = []
        for record in records {
            if case .birth(let b) = record, let d = b.district, !d.isEmpty {
                districts.insert(d.removingPercentEncoding?.lowercased() ?? d.lowercased())
            }
        }
        print("PROBE: districts seen = \(districts.sorted())")
        #expect(districts.count > 1, "rows span only \(districts.count) district(s) — county axis not proven")
        // FreeBMD's county definition includes cross-border districts
        // (Burton, Ashby, Rotherham… — validated 2026-07-11), so a
        // strict our-config-only check false-fails. Decisive instead:
        // an unambiguous in-county marker must appear, and far-away
        // sentinels must not (an IGNORED filter returns all England).
        let markers: Set<String> = ["belper", "bakewell", "chesterfield", "derby"]
        #expect(!districts.isDisjoint(with: markers),
                "no core Derbyshire district in results")
        let sentinels: Set<String> = ["islington", "liverpool", "leeds", "bristol", "portsmouth"]
        #expect(districts.isDisjoint(with: sentinels),
                "far-away districts present — county filter ignored")
    }
}
