import Foundation

/// Hierarchy and temporal-validity resolution over a `[PlaceAuthority]`
/// (MODEL_EVOLUTION_SPEC §Change3 / ADR-004 E3).
///
/// Kept as free functions on `Array` — exactly as E1's
/// `Array where Element == ExternalIdentifier` — so the resolution rules are
/// unit-testable in isolation and reusable by the app-side registry, the
/// gazetteer, and RegionConfig backing without any of them owning the logic.
/// Nothing here hardcodes a region: every answer is a walk over the records the
/// caller supplied, which are themselves derived from seed data.
public nonisolated extension Array where Element == PlaceAuthority {

    /// The record with the given `id`, or `nil`. O(n); registries that resolve
    /// hot should build an index (the app-side one does).
    func place(id: String) -> PlaceAuthority? {
        first { $0.id == id }
    }

    /// The chain from `id` up to the top of the hierarchy, **excluding** the
    /// starting place itself: its parent, grandparent, … up to the country.
    /// Empty when `id` is unknown or already top-level. Bounded against corrupt
    /// cyclic `parentID` links (append-only seed data shouldn't produce them,
    /// but a bad row must not spin) by the record count and a seen-set.
    func ancestors(of id: String) -> [PlaceAuthority] {
        var result: [PlaceAuthority] = []
        var seen: Set<String> = [id]
        var currentID: String? = place(id: id)?.parentID
        while let cid = currentID, !seen.contains(cid), result.count <= count {
            guard let node = place(id: cid) else { break }
            result.append(node)
            seen.insert(cid)
            currentID = node.parentID
        }
        return result
    }

    /// The nearest ancestor (or `self`) of the given `kind`, walking up from
    /// `id`. Returns the starting place when it is already of `kind`. `nil` when
    /// no place of that kind sits on the chain. This is the single primitive the
    /// county/district roll-ups below are built on.
    func nearest(_ kind: PlaceKind, from id: String) -> PlaceAuthority? {
        if let start = place(id: id), start.kind == kind { return start }
        return ancestors(of: id).first { $0.kind == kind }
    }

    /// The county a place rolls up to (AC1 roll-up), walking parish → district →
    /// **county**. Prefers a `.county` node on the ancestor chain; falls back to
    /// the record's own `county` string when the chain is incomplete (e.g. a
    /// bare town whose county parent wasn't seeded). `nil` only when neither is
    /// available.
    func county(of id: String) -> PlaceAuthority? {
        nearest(.county, from: id)
    }

    /// The country a place rolls up to.
    func country(of id: String) -> PlaceAuthority? {
        nearest(.country, from: id)
    }

    /// The registration district a place rolls up to (parish → **district**).
    /// Returns the place itself when it is already a district. `nil` for a place
    /// with no district ancestor (a bare county, or a town not resolved to a
    /// parish under a district).
    func registrationDistrict(of id: String) -> PlaceAuthority? {
        nearest(.registrationDistrict, from: id)
    }

    /// Direct children of `id` — the places whose `parentID` is `id`.
    func children(of id: String) -> [PlaceAuthority] {
        filter { $0.parentID == id }
    }

    /// Parishes recorded under a registration district, optionally filtered to
    /// those valid in `year`. The temporal filter is what makes "a parish that
    /// changed jurisdiction resolves differently either side of the boundary
    /// year" (AC2) work: the same parish name may appear under two district
    /// records with disjoint validity windows.
    func parishes(inDistrict districtID: String, year: Int? = nil) -> [PlaceAuthority] {
        children(of: districtID).filter { child in
            child.kind == .parish && (year.map { child.valid(in: $0) } ?? true)
        }
    }

    /// Resolve a parish **by name** to the registration district (and its
    /// county) valid in `year` (AC2). The pivot query of UK BMD research: "which
    /// district did parish P register in, in year Y?"
    ///
    /// - Matches parish records by case-insensitive name or alias.
    /// - Among candidate parish records, keeps those whose own validity window
    ///   contains `year` (when `year` is given); if none carries a window, all
    ///   candidates remain (unbounded validity is the common case).
    /// - Returns the district each surviving parish sits under, then filters to
    ///   districts valid in `year`. A parish that moved between districts across
    ///   a boundary year therefore resolves to different districts either side.
    ///
    /// When `chapman` is supplied it disambiguates same-named parishes across
    /// counties (Ashford in KEN vs DBY), mirroring
    /// `FreeBMDDistrictCatalogue.district(forParish:inChapman:)`.
    ///
    /// Returns every distinct matching district (usually one). Deterministic
    /// order: by district id.
    func districts(forParish parish: String, year: Int? = nil, chapman: String? = nil) -> [PlaceAuthority] {
        // Resolve each to its district, filter districts by validity in `year`.
        var byID: [String: PlaceAuthority] = [:]
        for p in parishRecords(named: parish, year: year, chapman: chapman) {
            guard let district = registrationDistrict(of: p.id) else { continue }
            if let y = year, !district.valid(in: y) { continue }
            byID[district.id] = district
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// The parish records a name (or alias) matches — the step `districts(forParish:)`
    /// takes before collapsing to districts.
    ///
    /// Exposed because the two counts answer different questions and only one of
    /// them is ambiguity. "Warslow" matches ONE parish ("Warslow & Elkstones")
    /// filed under two districts, because Leek was reorganised into Staffordshire
    /// Moorlands in 1974 — same place, two jurisdictions. "Middleton" in Derbyshire
    /// matches TWO parishes ("Middleton" under Bakewell, "Middleton & Smerrill"
    /// under Matlock) — two different settlements that share a name. Counting
    /// districts calls the first ambiguous and, once a validity window has knocked
    /// one district out, calls the second certain. Counting distinct parish names
    /// gets both right, which is what the place inventory's confidence score needs.
    ///
    /// Deterministic order: by id.
    func parishRecords(named parish: String, year: Int? = nil, chapman: String? = nil) -> [PlaceAuthority] {
        let needle = PlaceAuthority.foldedName(parish)
        guard !needle.isEmpty else { return [] }
        let byName = filter { p in
            p.kind == .parish
                && ([p.name] + p.aliases).contains { PlaceAuthority.foldedName($0) == needle }
        }
        return refineParishRecords(byName, year: year, chapman: chapman)
    }

    /// The county and validity filters `parishRecords(named:)` applies once its
    /// name match is done. Split out so an indexed caller
    /// (`PlaceAuthorityRegistry.parishRecords`) can skip the linear name scan and
    /// still apply byte-identical filtering — two implementations of this
    /// predicate would drift, and it decides which district a place resolves to.
    func refineParishRecords(
        _ candidates: [PlaceAuthority], year: Int?, chapman: String?
    ) -> [PlaceAuthority] {
        let chapmanUpper = chapman?.trimmingCharacters(in: .whitespaces).uppercased()
        return candidates.filter { p in
            // Chapman scoping: the parish's district ancestor must be in-county.
            if let cu = chapmanUpper, let parentID = p.parentID {
                let districtChapman = place(id: parentID)?.parentID // district → county id
                // county id is "{CHAPMAN}"; compare its uppercased form.
                if let cid = districtChapman, cid.uppercased() != cu { return false }
            }
            // Temporal: if the parish record itself carries a window, respect it.
            if let y = year, (p.validFrom != nil || p.validTo != nil), !p.valid(in: y) {
                return false
            }
            return true
        }
        .sorted { $0.id < $1.id }
    }

    /// Registration districts belonging to a county (by Chapman code), optionally
    /// filtered to those valid in a year window. Backs
    /// `RegionConfig.districts(forChapmanCode:)` through the authority with the
    /// identical set. County id convention is the bare Chapman code ("DBY").
    func districts(inCounty chapman: String, years range: ClosedRange<Int>? = nil) -> [PlaceAuthority] {
        let countyID = chapman.trimmingCharacters(in: .whitespaces).uppercased()
        return filter { d in
            d.kind == .registrationDistrict
                && d.parentID?.uppercased() == countyID
                && (range.map { d.overlaps(years: $0) } ?? true)
        }
    }

    /// Case-insensitive lookup of a registration district by name (optionally
    /// scoped to a county), the helper AC4 asks for: a `districtHint` string can
    /// be matched against district entries without changing the hypothesis
    /// payload. Strips a trailing " district"/" RD" suffix like the existing
    /// catalogue lookup. Returns the first match in deterministic (id) order.
    func district(named name: String, chapman: String? = nil) -> PlaceAuthority? {
        let needle = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " district", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " rd", with: "", options: .caseInsensitive)
            .lowercased()
        guard !needle.isEmpty else { return nil }
        let chapmanUpper = chapman?.trimmingCharacters(in: .whitespaces).uppercased()
        let districts = filter { d in
            guard d.kind == .registrationDistrict else { return false }
            if let cu = chapmanUpper, d.parentID?.uppercased() != cu { return false }
            return true
        }
        let exact = districts.filter { d in
            ([d.name] + d.aliases).map { $0.lowercased() }.contains(needle)
        }
        if let hit = exact.sorted(by: { $0.id < $1.id }).first { return hit }

        // #31 — GRO/FreeBMD abbreviation tolerance ("Chapel le F." →
        // "Chapel en le Frith", "Ashton u. Lyne" → "Ashton under Lyne").
        // Accepted ONLY when exactly one catalogue district matches; an
        // ambiguous abbreviation declines rather than guesses ("when in
        // doubt, split").
        let fuzzy = districts.filter { d in
            ([d.name] + d.aliases).contains {
                PlaceAuthority.abbreviatedNameMatches(query: needle, candidate: $0)
            }
        }
        return fuzzy.count == 1 ? fuzzy[0] : nil
    }
}

extension PlaceAuthority {
    /// True when `query` is a plausibly-abbreviated rendering of `candidate`
    /// — the GRO quarterly indexes and FreeBMD print district names with
    /// dot-abbreviated and elided connective words. Pure and region-free:
    /// tokens are compared in order, a dot-suffixed query token matches the
    /// candidate token by prefix, and connective words in the candidate
    /// ("en", "le", "upon", "under", …) may be skipped. Both strings must be
    /// fully consumed (candidate modulo connectives), so "Chapel" alone does
    /// NOT match "Chapel en le Frith".
    public nonisolated static func abbreviatedNameMatches(query: String, candidate: String) -> Bool {
        func tokens(_ s: String) -> [String] {
            s.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "-" })
                .map(String.init)
        }
        let connectives: Set<String> = ["en", "le", "la", "in", "on", "upon",
                                        "under", "the", "of", "and", "&", "u", "u."]
        let q = tokens(query)
        let c = tokens(candidate)
        guard !q.isEmpty, !c.isEmpty else { return false }

        func tokenMatches(_ qt: String, _ ct: String) -> Bool {
            if qt == ct { return true }
            if qt.hasSuffix(".") {
                let stem = String(qt.dropLast())
                return !stem.isEmpty && ct.hasPrefix(stem)
            }
            return false
        }

        var ci = 0
        for (qi, qt) in q.enumerated() {
            // Skip candidate connectives — unless the query token itself is
            // one, in which case it must line up with a real token.
            while ci < c.count, connectives.contains(c[ci]), !tokenMatches(qt, c[ci]) {
                ci += 1
            }
            guard ci < c.count, tokenMatches(qt, c[ci]) else { return false }
            if qi == 0, ci != 0 { return false }  // first tokens must align
            ci += 1
        }
        // Candidate leftovers must all be connectives.
        while ci < c.count {
            guard connectives.contains(c[ci]) else { return false }
            ci += 1
        }
        return true
    }
}
