import Testing
import Foundation
import SwiftUI
@testable import Ancestor_Research

/// ResearchConfigSheet contract — post SOURCE_WEIGHTING companion change
/// (2026-07-15): ONE adaptive research action; the Depth picker is retired.
/// The legacy modes survive only as (a) the scope-seeding heuristic and
/// (b) the MCP/watcher override surface.
@MainActor
struct ResearchConfigSheetTests {

    @Test func scopePickerHasSixOptions() {
        // parish, district, county, adjacent, national, international (DS-11).
        #expect(ResearchScope.allCases.count == 6)
    }

    @Test func defaultScopeMatchesSpecTable() {
        #expect(ResearchConfigSheet.defaultScope(for: .verify) == .district)
        #expect(ResearchConfigSheet.defaultScope(for: .extend) == .county)
        #expect(ResearchConfigSheet.defaultScope(for: .discover) == .adjacent)
        #expect(ResearchConfigSheet.defaultScope(for: .all) == .national)
        #expect(ResearchConfigSheet.defaultScope(for: .adaptive) == .county)
    }

    @Test func estimatedDurationCoversEveryModeScopePair() {
        for mode in [ResearchMode.verify, .extend, .discover, .all, .adaptive] {
            for scope in ResearchScope.allCases {
                let duration = ResearchConfigSheet.estimatedDuration(mode: mode, scope: scope)
                #expect(!duration.isEmpty,
                        "estimatedDuration empty for (\(mode), \(scope))")
            }
        }
    }

    @Test func adaptiveEstimatesFlagEarlyStop() {
        // The one in-app action stops when the gaps are answered — the
        // estimate must say so, or the upper bound reads as a promise.
        for scope in ResearchScope.allCases {
            let duration = ResearchConfigSheet.estimatedDuration(mode: .adaptive, scope: scope)
            #expect(duration.contains("stops when answered"),
                    "adaptive estimate for \(scope) must flag the early stop; got '\(duration)'")
        }
    }

    @Test func adaptiveConfigHasNoVerifyEarlyStopAndFullLadder() {
        let config = ResearchConfig.preset(for: .adaptive)
        #expect(config.mode == .adaptive)
        #expect(config.forceRefreshNegatives == false,
                "adaptive consults the cross-run negative cache")
        #expect(SearchDispatcher.strictnessLadder(for: .adaptive) == [.strict, .loose, .variant],
                "adaptive walks the full ladder, escalating only on conclusive miss")
    }
}
