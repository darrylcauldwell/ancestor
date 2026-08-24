import Foundation
import os
import AncestorKit

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
    /// Chapman code of the historical county this district belongs to.
    /// 100% coverage as of the 2026-05 enrichment — every catalogue entry
    /// tagged from UKBMD's per-county and per-district pages, with hand
    /// overrides for post-1974 administrative-county districts mapped to
    /// their predominant historical Chapman code.
    let chapmanCode: String?
    let startYear: Int?
    let endYear: Int?
    /// Civil parishes within this registration district, per UKBMD's
    /// Table 1 listings. nil for districts whose parish list couldn't be
    /// scraped (404s, format variants). Used by `.parish`-scope queries
    /// and parish-aware geography scoring.
    let parishes: [String]?
    /// #31 — spelling variants this district is findable under (e.g.
    /// FreeBMD's "Ashborne" for Ashbourne). Data-derived: lives in
    /// freebmd-districts.json, never in code. nil for the vast majority.
    let aliases: [String]?

    init(name: String, code: String, chapmanCode: String?,
         startYear: Int?, endYear: Int?, parishes: [String]?,
         aliases: [String]? = nil) {
        self.name = name
        self.code = code
        self.chapmanCode = chapmanCode
        self.startYear = startYear
        self.endYear = endYear
        self.parishes = parishes
        self.aliases = aliases
    }

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
            let raw = try JSONDecoder().decode([FreeBMDDistrict].self, from: data)
            self.districts = raw.map(Self.cleaned(_:))
            Self.logger.info("Loaded \(self.districts.count) FreeBMD districts")
        } catch {
            Self.logger.error("Failed to load freebmd-districts.json: \(error.localizedDescription)")
            self.districts = []
        }
    }

    // MARK: - Parish-name hygiene

    /// The parish lists were scraped from UKBMD's HTML, and the entities came
    /// with them: 685 distinct parish names still carry a literal `&amp;`.
    /// Nothing downstream unescaped, while the RECORD side does
    /// (`FreeCenSource.swift:847`) — so the catalogue and the records lived in
    /// two namespaces that could never meet, and a real district was
    /// unreachable. `Wensley & Snitterton` (DBY/Bakewell from 1839, DBY/Matlock
    /// to 1838) is the case that surfaced it: the family's home township scored
    /// "unknown district" against a catalogue that already contained it.
    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, replacement) in [
            ("&amp;", "&"), ("&#39;", "'"), ("&apos;", "'"),
            ("&quot;", "\""), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—"),
        ] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// UKBMD's Table 1 carries footnote prose in the same column as parish
    /// names — "abolished 1.4.1935 and added to the parish of Ashwellthorpe."
    /// and ~97 others. They are not places and must not be indexed as such.
    static func isProseNotAPlace(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.count > 60 { return true }
        if t.hasSuffix(".") { return true }
        let lowered = t.lowercased()
        for marker in [" the parish of ", "abolished", "see also", "see table", "note ("] {
            if lowered.contains(marker) { return true }
        }
        return false
    }

    /// Every string a parish should be findable under: the name itself, the
    /// `&`↔`and` variant, and — for a compound civil parish — each constituent
    /// township. `Wensley & Snitterton` is one registration parish comprising
    /// two settlements, and a census names the settlement, not the compound;
    /// likewise `Dethick, Lea & Holloway`. Returned as ALIASES, so the whole
    /// name stays canonical and callers that preserve ambiguity
    /// (`PlaceAuthority.districts(forParish:year:chapman:)`) still see every
    /// candidate and can scope by county and year.
    static func lookupNames(forParish parish: String) -> [String] {
        let name = decodeEntities(parish)
        guard !name.isEmpty, !isProseNotAPlace(name) else { return [] }

        var names = [name]
        let andForm = name.replacingOccurrences(of: " & ", with: " and ")
        if andForm != name { names.append(andForm) }

        // Constituents. Split on "&" first, then on commas within — "Dethick,
        // Lea & Holloway" is three. A fragment is only kept if it still looks
        // like a place name; a bare initial or a stray word is dropped rather
        // than indexed as somewhere real.
        if name.contains("&") || name.lowercased().contains(" and ") {
            let parts = name
                .replacingOccurrences(of: " and ", with: " & ", options: .caseInsensitive)
                .components(separatedBy: "&")
                .flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 3 && $0.first?.isUppercase == true }
            if parts.count > 1 { names.append(contentsOf: parts) }
        }

        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Decode-time repair: unescape parish names and drop the prose rows.
    /// Compound names are LEFT WHOLE here — constituents are exposed through
    /// `lookupNames(forParish:)` as aliases, so `parishes` keeps meaning what
    /// its doc comment says it means (UKBMD's Table 1 listing).
    private static func cleaned(_ district: FreeBMDDistrict) -> FreeBMDDistrict {
        guard let parishes = district.parishes else { return district }
        let repaired = parishes
            .map(decodeEntities)
            .filter { !isProseNotAPlace($0) }
        return FreeBMDDistrict(
            name: district.name, code: district.code,
            chapmanCode: district.chapmanCode,
            startYear: district.startYear, endYear: district.endYear,
            parishes: repaired,
            aliases: district.aliases
        )
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

    /// Districts belonging to a given historical county (Chapman code).
    /// Case-insensitive. Returns empty array for unknown codes or codes
    /// not yet covered by the enrichment data (post-1974 modern composites).
    func districts(forChapmanCode code: String) -> [FreeBMDDistrict] {
        let needle = code.uppercased()
        return districts.filter { $0.chapmanCode?.uppercased() == needle }
    }

    /// First district whose name matches the given string (case-insensitive,
    /// trailing " district" stripped). Useful for reverse-mapping a record's
    /// district name to its catalogue entry — parishes, Chapman code, etc.
    func district(named name: String) -> FreeBMDDistrict? {
        let needle = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " district", with: "", options: .caseInsensitive)
            .lowercased()
        if let exact = districts.first(where: { d in
            ([d.name] + (d.aliases ?? [])).contains { $0.lowercased() == needle }
        }) {
            return exact
        }
        // #31 — abbreviation tolerance ("Chapel le F."), unique match only.
        let fuzzy = districts.filter { d in
            ([d.name] + (d.aliases ?? [])).contains {
                PlaceAuthority.abbreviatedNameMatches(query: needle, candidate: $0)
            }
        }
        return fuzzy.count == 1 ? fuzzy[0] : nil
    }

    /// First district that contains the given parish (case-insensitive),
    /// scoped to a particular Chapman code to disambiguate same-named
    /// parishes across counties. Returns nil if no match.
    func district(forParish parish: String, inChapman code: String) -> FreeBMDDistrict? {
        let needle = Self.decodeEntities(parish).lowercased()
        let upper = code.uppercased()
        let inCounty = districts.filter { $0.chapmanCode?.uppercased() == upper }

        // Whole-name match first, so a compound parish is never beaten by one
        // of its own constituents matching a different district.
        if let exact = inCounty.first(where: { d in
            d.parishes?.contains { $0.lowercased() == needle } ?? false
        }) { return exact }

        // Then aliases — the `&`↔`and` variant and constituent townships, so a
        // census naming "Wensley" or "Snitterton" reaches the "Wensley &
        // Snitterton" parish and thence its district.
        return inCounty.first { d in
            d.parishes?.contains { p in
                Self.lookupNames(forParish: p).contains { $0.lowercased() == needle }
            } ?? false
        }
    }
}
