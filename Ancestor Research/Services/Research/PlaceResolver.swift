import Foundation
import AncestorKit

/// Resolves free-text places (and registration-district names) to typed
/// `PlaceAuthority` ids — the Stage-2 primitive of the location-model pass
/// (`AncestorApp/LOCATION_MODEL_SPEC.md`). The dormant `PlaceAuthority`
/// hierarchy was queryable only from an already-structured id; nothing turned
/// a raw "Turnditch, Derbyshire" — or a record's "Belper" district field —
/// into an id. This is that missing resolver, and it is what the rebuilt
/// geography gate (Stage 3) composes with `ancestors(of:)` / `county(of:)` /
/// `valid(in:)` to decide containment instead of substring-matching.
///
/// Pure and deterministic: reads only the bundled `LocationGazetteer` +
/// `PlaceAuthorityRegistry`. Declines on ambiguity ("when in doubt, split") so
/// it never binds a place to the wrong county.
nonisolated enum PlaceResolver {

    /// Resolve a free-text place string ("Turnditch, Derbyshire", "Belper",
    /// "Derbyshire", or the messy "Loscoe, Derbyshire, England") to a
    /// `PlaceAuthority` id — a county id ("DBY") or a place id ("DBY:Turnditch").
    /// A gazetteer entry's id IS its PlaceAuthority id, so this composes the
    /// gazetteer's noise-tolerant `match` with a strict disambiguation rule:
    ///   • exactly one candidate → that id;
    ///   • several candidates but the top-ranked one is an EXACT name or
    ///     "name, county" hit → that id (so "Derbyshire" resolves to the DBY
    ///     county node even though every "…, Derbyshire" place also contains
    ///     the substring, and "Chesterfield" wins over other "…field" names);
    ///   • otherwise nil — genuinely ambiguous, do not guess.
    static func resolve(placeText: String, gazetteer: LocationGazetteer = .shared) -> String? {
        let matches = gazetteer.match(placeText)
        guard let top = matches.first else { return nil }
        if matches.count == 1 { return top.id }
        let q = LocationGazetteer.normalizeForMatch(
            placeText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if top.name.lowercased() == q || top.displayName.lowercased() == q {
            return top.id
        }
        return nil
    }

    /// Resolve a registration-district NAME (a BMD/census record's `district`
    /// field, e.g. "Belper") to its registration-district `PlaceAuthority` id
    /// ("DBY:Belper-RD"), optionally constrained to a Chapman county and valid
    /// in `year` (successor/predecessor aware). Delegates to the registry via
    /// `RegionConfig.districtAuthority` — the one existing hint→authority path.
    static func resolveDistrict(name: String, chapman: String? = nil, year: Int? = nil) -> String? {
        RegionConfig.districtAuthority(matchingHint: name, chapman: chapman, year: year)?.id
    }
}
