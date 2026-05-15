import Foundation
import os

/// One UK Chapman code — the historical 3-letter identifier for a county/area.
/// Used by FreeCen and FreeREG to scope searches geographically.
nonisolated struct UKChapmanCode: Codable, Sendable, Hashable {
    let code: String        // e.g. "DBY"
    let name: String        // e.g. "Derbyshire"
    let country: String     // "England" | "Wales" | "Scotland" | "Channel Islands" | "Isle of Man"
}

/// Bundled catalogue of UK Chapman codes used by scope-aware sources.
///
/// Loaded once from `Resources/Regions/uk-chapman-codes.json` (~90 entries).
/// Used by SearchDispatcher when `ResearchScope == .national` for FreeCen and
/// FreeREG. The local-scope path keeps using a single Chapman code from `RegionConfig`.
nonisolated final class UKChapmanCodes: Sendable {
    static let shared = UKChapmanCodes()

    let codes: [UKChapmanCode]

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "UKChapmanCodes"
    )

    private init() {
        guard let url = Bundle.main.url(
            forResource: "uk-chapman-codes",
            withExtension: "json",
            subdirectory: "Regions"
        ) ?? Bundle.main.url(
            forResource: "uk-chapman-codes",
            withExtension: "json"
        ) else {
            Self.logger.error("uk-chapman-codes.json not found in bundle")
            self.codes = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            self.codes = try JSONDecoder().decode([UKChapmanCode].self, from: data)
            Self.logger.info("Loaded \(self.codes.count) UK Chapman codes")
        } catch {
            Self.logger.error("Failed to load uk-chapman-codes.json: \(error.localizedDescription)")
            self.codes = []
        }
    }

    /// All Chapman codes in the catalogue.
    func all() -> [UKChapmanCode] { codes }

    /// England and Wales only — the coverage of FreeBMD and most of FreeREG.
    func englandAndWales() -> [UKChapmanCode] {
        codes.filter { $0.country == "England" || $0.country == "Wales" }
    }

    /// England, Wales, and Scotland — FreeCen's coverage.
    func gbAndChannelIslands() -> [UKChapmanCode] {
        codes.filter {
            $0.country == "England" || $0.country == "Wales" ||
            $0.country == "Scotland" || $0.country == "Channel Islands"
        }
    }
}
