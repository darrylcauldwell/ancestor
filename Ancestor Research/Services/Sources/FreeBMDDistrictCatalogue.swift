import Foundation
import os

/// One UK registration district as listed in FreeBMD's search dropdown.
///
/// `startYear` / `endYear` capture the period of validity:
///   - both nil → no qualifier, valid across FreeBMD's full coverage range
///   - startYear nil, endYear set → "to {year}" (e.g. Belper to Jun1994)
///   - startYear set, endYear nil → "from {year}" (e.g. High Peak from Jun1974)
///   - both set → explicit range (e.g. Ilkeston Jun1938-Mar1997)
///
/// Month granularity is dropped — we use year-bracket overlap for filtering.
nonisolated struct FreeBMDDistrict: Codable, Sendable, Hashable {
    let name: String
    let code: String
    let startYear: Int?
    let endYear: Int?

    /// True if this district was operating at any point in the given year range.
    func overlaps(years range: ClosedRange<Int>) -> Bool {
        let lower = startYear ?? Int.min
        let upper = endYear ?? Int.max
        return lower <= range.upperBound && upper >= range.lowerBound
    }
}

/// Bundled catalogue of all UK registration districts indexed by FreeBMD.
///
/// Loaded once from `Resources/Regions/freebmd-districts.json` (~1125 entries).
/// Used by SearchDispatcher when `ResearchScope == .national` — the local-scope
/// path keeps using the small per-region district list in `RegionConfig`.
nonisolated final class FreeBMDDistrictCatalogue: Sendable {
    static let shared = FreeBMDDistrictCatalogue()

    let districts: [FreeBMDDistrict]

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "FreeBMDDistrictCatalogue"
    )

    private init() {
        guard let url = Bundle.main.url(
            forResource: "freebmd-districts",
            withExtension: "json",
            subdirectory: "Regions"
        ) ?? Bundle.main.url(
            forResource: "freebmd-districts",
            withExtension: "json"
        ) else {
            Self.logger.error("freebmd-districts.json not found in bundle")
            self.districts = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            self.districts = try JSONDecoder().decode([FreeBMDDistrict].self, from: data)
            Self.logger.info("Loaded \(self.districts.count) FreeBMD districts")
        } catch {
            Self.logger.error("Failed to load freebmd-districts.json: \(error.localizedDescription)")
            self.districts = []
        }
    }

    /// All districts in the catalogue (~1125).
    func all() -> [FreeBMDDistrict] { districts }

    /// Districts whose validity range overlaps the given year window.
    /// Used to skip queries that can't possibly have results (e.g. South Derbyshire
    /// for an 1850 birth, since South Derbyshire only began Jun1997).
    func covering(years range: ClosedRange<Int>) -> [FreeBMDDistrict] {
        districts.filter { $0.overlaps(years: range) }
    }

    /// Convenience: districts overlapping the (yearFrom, yearTo) window from a RecordQuery.
    /// If both bounds are nil, returns the full catalogue.
    func covering(yearFrom: Int?, yearTo: Int?) -> [FreeBMDDistrict] {
        let lower = yearFrom ?? Int.min
        let upper = yearTo ?? Int.max
        guard lower <= upper else { return [] }
        return covering(years: lower...upper)
    }
}
