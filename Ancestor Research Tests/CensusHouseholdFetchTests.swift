import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The on-demand FreeCen household-fetch tail: `censusNeedsHousehold` decides
/// whether a specific census still has a roster to pull (FreeCen enriches only
/// the top search hit, so non-top-hit censuses arrive roster-less).
struct CensusHouseholdFetchTests {

    private func census(detailURL: String?, household: [HouseholdMember]?) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: "c", sourceID: "freecen", detailURL: detailURL, rawFields: [:]),
            censusYear: 1861, household: household))
    }

    @Test func needsHouseholdOnlyWhenADetailURLExistsAndTheRosterIsEmpty() {
        // The John W Thompson shape: a FreeCen census with a detail page but no roster.
        #expect(AppState.censusNeedsHousehold(
            census(detailURL: "https://www.freecen.org.uk/search_records/x", household: nil)))

        // Already enriched (the top-hit case) → nothing to fetch.
        #expect(!AppState.censusNeedsHousehold(census(
            detailURL: "https://www.freecen.org.uk/search_records/x",
            household: [HouseholdMember(name: "John Thompson", relationship: "Head", age: 55)])))

        // No detail URL → can't fetch a roster.
        #expect(!AppState.censusNeedsHousehold(census(detailURL: nil, household: nil)))
        #expect(!AppState.censusNeedsHousehold(census(detailURL: "", household: nil)))

        // Not a census at all.
        let marriage = SourceRecord.marriage(MarriageRecord(
            common: RecordCommon(id: "m", sourceID: "freebmd", rawFields: [:]),
            marriageYear: 1915, marriageDate: nil, marriagePlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil, spouseName: nil))
        #expect(!AppState.censusNeedsHousehold(marriage))
    }
}
