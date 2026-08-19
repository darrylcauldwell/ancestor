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
    /// Tiers, first hit wins:
    ///  1. The whole string as a registration district ("Belper", "Worksop")
    ///     — a bare district with no county token to weigh against it.
    ///  2. Any comma component (scanned from the END, where the county token
    ///     usually sits) as a **county name** ("Derbyshire" → DBY). A stated,
    ///     valid county outranks a per-component district guess: a bare town
    ///     read as a district is prone to cross-county name collisions
    ///     ("Middleton" is a Lancashire registration district *and* a
    ///     Derbyshire parish inside Bakewell RD), so when the text names a
    ///     real county that county is the authoritative signal. This is also
    ///     what rescues a bare-village-plus-county string like
    ///     "Ashford in the Water, Derbyshire" that no district match catches.
    ///  3. Any comma component as a registration district ("Belper" in
    ///     "Belper, Nowhereshire") — the fallback when no valid county token
    ///     is present, so an unqualified district still resolves.
    ///
    /// Ordering rationale (2026-08-12 dogfood fix): the previous order ran the
    /// per-component district scan (tier 3 here) *before* the county scan, so
    /// "Middleton, Derbyshire" matched the Lancashire "Middleton" district and
    /// scoped an entire Derbyshire research run to LAN — the explicit
    /// ", Derbyshire" was discarded by short-circuit. Promoting a *valid*
    /// county above the district-component guess fixes that while keeping the
    /// district fallback for strings whose trailing token is not a real county.
    static func chapmanCode(forPlaceText raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Tier 1 — full string as a registration district (a bare "Belper" /
        // "Worksop", where there is no county token to weigh).
        if let code = FreeBMDDistrictCatalogue.shared.district(named: name)?.chapmanCode {
            return code
        }

        let components = name
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Tier 2 — an explicitly stated, valid county (scanned from the end)
        // wins over a per-component district guess, which is prone to
        // cross-county bare-town name collisions.
        for component in components.reversed() {
            if let code = UKChapmanCodes.shared.chapmanCode(forCountyName: component) {
                return code
            }
        }

        // Tier 3 — no valid county token: fall back to any component as a
        // registration district ("Belper" in "Belper, Nowhereshire").
        for component in components {
            if let code = FreeBMDDistrictCatalogue.shared.district(named: component)?.chapmanCode {
                return code
            }
        }

        return nil
    }

    /// Parse the Chapman county prefix out of a gazetteer id like `"DBY:Crich"`.
    /// Nil for nil, empty, or anything without a 3-letter prefix.
    ///
    /// The structured twin of `chapmanCode(forPlaceText:)`, and it lives beside
    /// it for the same reason that one was pulled here: a code and its text are
    /// the two halves of one question, and every caller asks both. Keeping the
    /// parse private to `ResearchSubject` is what let the FreeBMD arm end up
    /// re-parsing a death county from text five lines from where the burial
    /// county arrived pre-derived (SUBJECT_PLACE_MODEL_SPEC).
    static func chapmanCode(forLocationCode code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty
        else { return nil }
        let prefix = code.firstIndex(of: ":").map { String(code[..<$0]) } ?? code
        let cleaned = prefix.trimmingCharacters(in: .whitespaces).uppercased()
        guard cleaned.count == 3, cleaned.allSatisfy(\.isLetter) else { return nil }
        return cleaned
    }
}
