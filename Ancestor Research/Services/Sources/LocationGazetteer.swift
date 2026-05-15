import Foundation
import os

/// One UK place — town, parish, or county. Used by LocationPicker for typeahead
/// matching when a user enters a birth/death location, so that "Ashford" can be
/// disambiguated between Kent / Middlesex / Derbyshire / etc.
nonisolated struct GazetteerEntry: Codable, Sendable, Hashable, Identifiable {
    let id: String          // "DBY:Crich", "KEN:Ashford" — stable structured ID
    let name: String        // "Crich"
    let county: String      // "Derbyshire"
    let country: String     // "England" | "Wales" | "Scotland" | etc.
    let aliases: [String]   // common spelling/format variants
    /// "county" for top-level county entries; nil for towns/parishes within counties.
    let kind: String?

    /// Display string suitable for showing the chosen value back to the user
    /// in a profile field: "Crich, Derbyshire".
    var displayName: String {
        if kind == "county" { return name }
        return "\(name), \(county)"
    }

    /// All strings that match this entry — used by the typeahead filter.
    var searchableTerms: [String] {
        var terms = [name, displayName]
        terms.append(contentsOf: aliases)
        return terms
    }
}

/// Bundled UK places gazetteer. Loaded once from
/// `Resources/Regions/uk-places.json` (~300 starter entries — counties,
/// major cities, all Derbyshire detail, common disambiguous places).
///
/// Used by LocationPicker for typeahead match. Future expansion: pull a full
/// GENUKI extract for ~12k parish-level entries.
nonisolated final class LocationGazetteer: Sendable {
    static let shared = LocationGazetteer()

    let places: [GazetteerEntry]

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "LocationGazetteer"
    )

    private init() {
        guard let url = Bundle.main.url(
            forResource: "uk-places",
            withExtension: "json",
            subdirectory: "Regions"
        ) ?? Bundle.main.url(
            forResource: "uk-places",
            withExtension: "json"
        ) else {
            Self.logger.error("uk-places.json not found in bundle")
            self.places = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            self.places = try JSONDecoder().decode([GazetteerEntry].self, from: data)
            Self.logger.info("Loaded \(self.places.count) UK places")
        } catch {
            Self.logger.error("Failed to load uk-places.json: \(error.localizedDescription)")
            self.places = []
        }
    }

    /// All entries.
    func all() -> [GazetteerEntry] { places }

    /// Typeahead match. Returns up to `limit` entries whose name, displayName,
    /// or any alias contains the query (case-insensitive). Sorted with exact
    /// prefix-of-name matches first, then alphabetically.
    func match(_ query: String, limit: Int = 10) -> [GazetteerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let matches = places.filter { entry in
            entry.searchableTerms.contains { $0.lowercased().contains(q) }
        }

        // Rank: exact name match → prefix name match → alias match → contains match
        let ranked = matches.sorted { a, b in
            func score(_ e: GazetteerEntry) -> Int {
                let nameLower = e.name.lowercased()
                if nameLower == q { return 0 }
                if nameLower.hasPrefix(q) { return 1 }
                if e.aliases.contains(where: { $0.lowercased().hasPrefix(q) }) { return 2 }
                return 3
            }
            let sa = score(a), sb = score(b)
            if sa != sb { return sa < sb }
            return a.name < b.name
        }
        return Array(ranked.prefix(limit))
    }

    /// Look up an entry by stable ID. Returns nil if the ID isn't in the bundled
    /// gazetteer (e.g. a stale code from an older release).
    func entry(forID id: String) -> GazetteerEntry? {
        places.first { $0.id == id }
    }
}
