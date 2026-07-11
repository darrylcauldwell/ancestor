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
        let needle = parish.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let chapmanUpper = chapman?.trimmingCharacters(in: .whitespaces).uppercased()

        // Candidate parish records matching the name (or an alias).
        let candidateParishes = filter { p in
            guard p.kind == .parish else { return false }
            let names = ([p.name] + p.aliases).map { $0.lowercased() }
            guard names.contains(needle) else { return false }
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

        // Resolve each to its district, filter districts by validity in `year`.
        var byID: [String: PlaceAuthority] = [:]
        for p in candidateParishes {
            guard let district = registrationDistrict(of: p.id) else { continue }
            if let y = year, !district.valid(in: y) { continue }
            byID[district.id] = district
        }
        return byID.values.sorted { $0.id < $1.id }
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
        return filter { d in
            guard d.kind == .registrationDistrict else { return false }
            let names = ([d.name] + d.aliases).map { $0.lowercased() }
            guard names.contains(needle) else { return false }
            if let cu = chapmanUpper { return d.parentID?.uppercased() == cu }
            return true
        }
        .sorted { $0.id < $1.id }
        .first
    }
}
