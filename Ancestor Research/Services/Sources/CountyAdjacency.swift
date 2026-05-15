import Foundation
import os

/// Bundled single-hop adjacency map between UK Chapman-coded counties.
///
/// Loaded once from `Resources/Regions/county-adjacency.json` (~94 entries).
/// Coverage: 43 English (39 traditional + LND + MDX + 3 Yorkshire Ridings),
/// 13 Welsh, 33 Scottish, 4 Channel Islands, 1 Isle of Man. Pre-1974 ceremonial
/// boundaries. Ireland (32 pre-1922 counties) excluded pending Irish Chapman
/// codes being added to `uk-chapman-codes.json`.
///
/// Adjacency is **symmetric**: if `A` lists `B`, `B` lists `A`. Enforced by
/// `RegionConfigAdjacencyTests`. Sea-only boundaries (Anglesey↔Caernarfon,
/// Bute↔Argyll across the Firth of Clyde) are intentionally omitted —
/// adjacent-scope research escalates by district fan-out and historical
/// counties separated only by water don't share district catalogues anyway.
nonisolated final class CountyAdjacency: Sendable {
    static let shared = CountyAdjacency()

    let map: [String: [String]]

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "CountyAdjacency"
    )

    private init() {
        guard let url = Bundle.main.url(
            forResource: "county-adjacency",
            withExtension: "json",
            subdirectory: "Regions"
        ) ?? Bundle.main.url(
            forResource: "county-adjacency",
            withExtension: "json"
        ) else {
            Self.logger.error("county-adjacency.json not found in bundle")
            self.map = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            // Allow string-array values plus a `_comment` string field — strip
            // any non-array entries during decode rather than failing.
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var parsed: [String: [String]] = [:]
            for (key, value) in raw {
                if let arr = value as? [String] { parsed[key] = arr }
            }
            self.map = parsed
            Self.logger.info("Loaded \(self.map.count) county adjacency entries")
        } catch {
            Self.logger.error("Failed to load county-adjacency.json: \(error.localizedDescription)")
            self.map = [:]
        }
    }

    /// Adjacent Chapman codes for a given county code. Empty array for codes
    /// that are island chains, sea-bounded, or unknown. Case-insensitive input;
    /// returned codes are uppercase as stored in the JSON.
    func neighbours(of code: String) -> [String] {
        map[code.uppercased()] ?? []
    }
}
