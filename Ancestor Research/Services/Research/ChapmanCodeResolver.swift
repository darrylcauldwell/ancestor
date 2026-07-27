import Foundation

/// Canonical free-text place → Chapman **county** code resolver — the single
/// source of truth that replaces the divergent copies previously carried by
/// `ResearchSubject.chapmanCode(forPlaceText:)` and
/// `ConflictDetector.chapmanCode(forPlaceText:)`.
///
/// Those two disagreed: `ResearchSubject` fell back to a **county-name** scan
/// (resolved "Ashford in the Water, Derbyshire" but missed "Bakewell, Xshire"),
/// while `ConflictDetector` fell back to a per-component **district** scan (the
/// reverse). Neither was a superset, so the same place text could anchor a
/// subject one way and drive a conflict another. This unifies them by running
/// **all three tiers**, most-specific first, so it resolves a superset of what
/// either did — the "divergent parsers" debt the 2026-07-25 location audit
/// flagged.
///
/// No hardcoded regions: every code comes from the bundled
/// `FreeBMDDistrictCatalogue` (registration districts → Chapman) and
/// `UKChapmanCodes` (county names → Chapman). Country-agnostic.
nonisolated enum ChapmanCodeResolver {

    /// Resolve a free-text "Parish, County[, Country]" (or a bare district /
    /// county) to a Chapman county code, or nil when nothing resolves.
    ///
    /// Tiers, first hit wins (a registration-district match is more specific
    /// and reliable than a county-name-component match, so districts lead):
    ///  1. The whole string as a registration district ("Belper").
    ///  2. Each comma component as a registration district ("Belper" in
    ///     "Belper, Derbyshire", or "Bakewell" in "Bakewell R.D.").
    ///  3. Each comma component, scanned from the END (county is usually the
    ///     last-but-one token), as a county name ("Derbyshire" → DBY) — this is
    ///     what rescues a bare-village-plus-county string like
    ///     "Ashford in the Water, Derbyshire" that no district match catches.
    static func chapmanCode(forPlaceText raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Tier 1 — full string as a registration district.
        if let code = FreeBMDDistrictCatalogue.shared.district(named: name)?.chapmanCode {
            return code
        }

        let components = name
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Tier 2 — any component as a registration district.
        for component in components {
            if let code = FreeBMDDistrictCatalogue.shared.district(named: component)?.chapmanCode {
                return code
            }
        }

        // Tier 3 — any component (from the end) as a county name.
        for component in components.reversed() {
            if let code = UKChapmanCodes.shared.chapmanCode(forCountyName: component) {
                return code
            }
        }

        return nil
    }
}
