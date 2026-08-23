import Testing
import Foundation
@testable import Ancestor_Research

/// The scope picker is the contract, not a hint.
///
/// Owner 2026-08-23, on seeing `FreeBMD STS county deaths` while researching a
/// Derbyshire subject: *"what is visible from the outside is a picker
/// district/county/adjacent — if the inside does not perform like the outside
/// describes, that is the issue."*
///
/// He is right. A user who chose County asked for their county. Reaching into
/// Staffordshire breaks that promise however good the reason — and the reason
/// WAS good: a death is registered where the person died, so the dispatcher
/// added the subject's own recorded death/burial county. Sound genealogy,
/// wrong setting. The capability isn't lost, it moves to Adjacent, which
/// honestly describes it.
struct ScopePickerIsACeilingTests {

    /// FreeBMD county axes for Derbyshire, with Staffordshire offered as the
    /// subject's recorded death county.
    private func axes(scope: ResearchScope) -> [(districtCode: String?, countyCode: String?)] {
        SearchDispatcher.freeBMDGeoAxes(
            scope: scope,
            homeChapmanCode: "DBY",
            countyQueriesEnabled: true,
            yearFrom: 1850, yearTo: 1900,
            surname: "Thompson",
            extraCounties: ["STS"])
    }

    private var staffordshireIDs: Set<String> {
        Set(RegionConfig.freeBMDCountyIDs(forChapmanCode: "STS"))
    }

    private func countyCodes(_ axes: [(districtCode: String?, countyCode: String?)]) -> Set<String> {
        Set(axes.compactMap { $0.countyCode })
    }

    /// THE SPECIMEN: a County search must not reach Staffordshire.
    @Test func countyScopeStaysInsideTheChosenCounty() {
        let reached = countyCodes(axes(scope: .county))
        #expect(reached.isDisjoint(with: staffordshireIDs),
                "County scope reached Staffordshire — the picker said Derbyshire")
    }

    /// District is narrower still.
    @Test func districtScopeStaysInsideTheChosenCounty() {
        #expect(countyCodes(axes(scope: .district)).isDisjoint(with: staffordshireIDs))
    }

    /// The capability survives where it belongs: Adjacent still reaches the
    /// recorded death county. Without this the fix would just delete a feature.
    ///
    /// Tested with **Kent**, not Staffordshire — Staffordshire borders
    /// Derbyshire, so it arrives through the adjacency list anyway and would
    /// prove nothing about the extra-county arm. A man who moved to Kent and
    /// died there is the case this exists for.
    @Test func adjacentScopeStillReachesTheRecordedDeathCounty() {
        let kentIDs = Set(RegionConfig.freeBMDCountyIDs(forChapmanCode: "KEN"))
        let reached = countyCodes(SearchDispatcher.freeBMDGeoAxes(
            scope: .adjacent, homeChapmanCode: "DBY", countyQueriesEnabled: true,
            yearFrom: 1850, yearTo: 1900, surname: "Thompson", extraCounties: ["KEN"]))
        #expect(!reached.isDisjoint(with: kentIDs),
                "Adjacent must still probe the county the subject actually died in")
    }

    /// And County does not reach Kent either — the ceiling is about the picked
    /// scope, not about which county happens to be next door.
    @Test func countyScopeIgnoresADistantDeathCounty() {
        let kentIDs = Set(RegionConfig.freeBMDCountyIDs(forChapmanCode: "KEN"))
        let reached = countyCodes(SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "DBY", countyQueriesEnabled: true,
            yearFrom: 1850, yearTo: 1900, surname: "Thompson", extraCounties: ["KEN"]))
        #expect(reached.isDisjoint(with: kentIDs))
    }

    /// And the home county is never dropped at any scope — the ceiling lowers
    /// the top, it does not move the floor.
    @Test func theHomeCountyIsAlwaysSearched() {
        let derbyshire = Set(RegionConfig.freeBMDCountyIDs(forChapmanCode: "DBY"))
        for scope in [ResearchScope.district, .county, .adjacent] {
            #expect(!countyCodes(axes(scope: scope)).isDisjoint(with: derbyshire),
                    "home county missing at \(scope)")
        }
    }

    /// Adjacent picks up bordering counties regardless of the extras — that is
    /// what the setting means, and Staffordshire borders Derbyshire.
    @Test func adjacentIncludesBorderingCountiesWithoutAnyExtras() {
        let bare = SearchDispatcher.freeBMDGeoAxes(
            scope: .adjacent, homeChapmanCode: "DBY", countyQueriesEnabled: true,
            yearFrom: 1850, yearTo: 1900, surname: "Thompson", extraCounties: [])
        #expect(!countyCodes(bare).isDisjoint(with: staffordshireIDs))
    }
}
