import Foundation
import os
import AncestorKit

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

    // MARK: - E3 hierarchy + temporal validity (MODEL_EVOLUTION_SPEC §Change3)
    //
    // Additive, all-optional so pre-E3 `uk-places.json` entries (which carry
    // none of these keys) still decode losslessly — Swift's synthesized Codable
    // decodes a missing key as nil for an Optional. These give a gazetteer entry
    // a home in the typed place hierarchy without changing what any existing
    // `COUNTY:Place` code resolves to; the app-side `PlaceAuthorityRegistry`
    // derives full `PlaceAuthority` records from these plus the FreeBMD district
    // catalogue. The GENUKI ~12k-parish import targets this shape directly.

    /// The `id` of this entry's hierarchical parent — a town's county
    /// ("DBY:Crich" → "DBY"), a parish's registration district. `nil` for a
    /// top-level county entry or when the seed data doesn't yet carry the link
    /// (the registry infers a county parent from the id's Chapman prefix).
    let parentID: String?

    /// Inclusive lower year bound on this entry's jurisdictional validity, or
    /// `nil` for unbounded (the common case for a stable town/county).
    let validFrom: Int?

    /// Inclusive upper year bound, or `nil` for unbounded.
    let validTo: Int?

    /// Memberwise init with defaults for the E3 hierarchy fields, so existing
    /// call sites that construct a `GazetteerEntry` with only the original
    /// id/name/county/country/aliases/kind keep compiling (back-compat, same as
    /// E1's `Profile.init`). Decoding old JSON goes through the synthesized
    /// `Codable`, which fills the missing optional keys with nil.
    init(
        id: String,
        name: String,
        county: String,
        country: String,
        aliases: [String],
        kind: String?,
        parentID: String? = nil,
        validFrom: Int? = nil,
        validTo: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.county = county
        self.country = country
        self.aliases = aliases
        self.kind = kind
        self.parentID = parentID
        self.validFrom = validFrom
        self.validTo = validTo
    }

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

    /// Normalise a location string for matching by dropping trailing noise that
    /// stored freeform values carry but gazetteer terms don't: a Chapman-code
    /// parenthetical ("Turnditch, Derbyshire (DBY)") and a trailing country
    /// qualifier after a comma ("Loscoe, Derbyshire, England"). Reduces both to
    /// "place, county" so they resolve to the same entry as a clean value would.
    /// Input and output are lower-cased. The country strip REQUIRES a preceding
    /// comma so a single-token place literally named for a country (e.g. a
    /// village "Wales") is never emptied out.
    static func normalizeForMatch(_ lowercasedQuery: String) -> String {
        var s = lowercasedQuery
        // Trailing Chapman parenthetical: " (dby)", "(ntt)".
        if let r = s.range(of: #"\s*\([a-z]{2,3}\)\s*$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        // Trailing country qualifier, comma-anchored.
        if let r = s.range(
            of: #",\s*(england|wales|scotland|northern ireland|united kingdom|uk|great britain|gb)\.?\s*$"#,
            options: .regularExpression
        ) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// Typeahead match. Returns up to `limit` entries whose name, displayName,
    /// or any alias contains the query (case-insensitive). Sorted with exact
    /// prefix-of-name matches first, then alphabetically.
    func match(_ query: String, limit: Int = 10) -> [GazetteerEntry] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let q = Self.normalizeForMatch(raw)
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

    // MARK: - E3 place-authority backing (MODEL_EVOLUTION_SPEC §Change3)

    /// Resolve a stored `birthLocationCode`/`deathLocationCode`
    /// (`COUNTY:Place` gazetteer id) to its **display county string**, exactly
    /// as today's `entry(forID:).county` returns it — lossless with the flat
    /// path (AC3). Crucially this preserves the handful of historical
    /// cross-boundary entries where the display county disagrees with the id's
    /// Chapman prefix (e.g. `MDX:Lambeth` displays "Surrey" though it registered
    /// Middlesex-side; Bristol; Newport IoW). Those are a *feature* of the seed
    /// data — the place sat in one county but registered in another — and the
    /// hierarchy's Chapman-coded county node (Middlesex) answers a different
    /// question (see `chapmanCode(forCode:)`). Falls back to the authority's
    /// county node only when the flat entry is absent, so a future
    /// GENUKI-imported code with no flat gazetteer row still resolves through
    /// the hierarchy. Returns `nil` for a stale code in neither.
    func countyName(forCode code: String) -> String? {
        if let county = entry(forID: code)?.county { return county }
        return PlaceAuthorityRegistry.shared.county(ofID: code)?.name
    }

    /// The Chapman code a stored `COUNTY:Place` id rolls up to, via the
    /// authority hierarchy. Equivalent to the existing prefix-split derivation
    /// (`ResearchSubject.chapmanCodeFromLocationCode`) for every real code, but
    /// resolved through the typed county node rather than by string slicing.
    func chapmanCode(forCode code: String) -> String? {
        PlaceAuthorityRegistry.shared.county(ofID: code)?.id
    }
}
