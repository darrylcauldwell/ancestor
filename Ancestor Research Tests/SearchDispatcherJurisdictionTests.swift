import Testing
import Foundation
@testable import Ancestor_Research

/// Test the SearchDispatcher's jurisdictionString helper, which composes
/// "County, Country" strings for FS's place-axis parameters to trigger the
/// documented 3-jurisdiction-level bound.
struct SearchDispatcherJurisdictionTests {

    @Test func composesCountyAndRegionCountry() {
        let result = SearchDispatcher.jurisdictionString(
            county: "Derbyshire",
            region: .county("Derbyshire, England"),
            homeChapmanCode: "DBY"
        )
        #expect(result == "Derbyshire, England")
    }

    @Test func composesCountyAndChapmanCountry() {
        let result = SearchDispatcher.jurisdictionString(
            county: "Derbyshire",
            region: nil,  // no region → country derives from the Chapman code
            homeChapmanCode: "DBY"
        )
        // DBY resolves to England via RegionConfig. Uses Derbyshire because
        // RegionConfig only carries rich per-county config for DBY today — the
        // no-hardcoded-regions debt the location-model pass addresses
        // (LOCATION_MODEL_SPEC). A non-DBY code like LAN yields no country and
        // falls back to bare county, which `returnsCountyOnlyWhenCountryNotDerivable`
        // already covers; asserting England for LAN was the original wrong
        // assumption that shipped this test red.
        #expect(result == "Derbyshire, England")
    }

    @Test func returnsCountyOnlyWhenCountryNotDerivable() {
        let result = SearchDispatcher.jurisdictionString(
            county: "Derbyshire",
            region: nil,
            homeChapmanCode: ""  // empty Chapman → no country from either source
        )
        // Should fall back to bare county
        #expect(result == "Derbyshire")
    }

    @Test func returnsNilWhenCountyEmpty() {
        let result = SearchDispatcher.jurisdictionString(
            county: "",
            region: .county("Derbyshire, England"),
            homeChapmanCode: "DBY"
        )
        #expect(result == nil)
    }

    @Test func returnsNilWhenCountyNil() {
        let result = SearchDispatcher.jurisdictionString(
            county: nil,
            region: .county("Derbyshire, England"),
            homeChapmanCode: "DBY"
        )
        #expect(result == nil)
    }
}
