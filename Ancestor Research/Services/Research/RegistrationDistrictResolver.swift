import Foundation
import AncestorKit

/// Canonical resolver from a place-or-district string to its GRO registration
/// district `PlaceAuthority` id ("DBY:Ashbourne-RD").
///
/// LOCATION_MODEL_SPEC Part II — the single place the app turns a birthplace or a
/// BMD record's `district` field into a typed registration-district id. Extracted
/// from the Slice B(i) birth-conflict guard so the two consumers can never drift:
///   • `RecordScorer.conflictsWithConfirmedBirth` (review layer) — discriminates
///     a same-year namesake birth by comparing resolved RDs.
///   • `ApplyEngine.applyFactToSubject` (apply layer, Slice C) — populates
///     `Profile.birthRegistrationDistrict` from an applied birth record.
///
/// Pure and deterministic: reads only the bundled `FreeBMDDistrictCatalogue`,
/// `ChapmanCodeResolver`, and `PlaceResolver`. Declines (nil) on ambiguity or
/// when a place can't be resolved — callers fall back rather than guess.
nonisolated enum RegistrationDistrictResolver {

    /// The subject's county Chapman code — from its coded birthplace
    /// (`DBY:Hognaston` → `DBY`), else a trailing "(DBY)" in the display string,
    /// else parsed from the free-text birthplace. Reading the suffix directly
    /// avoids the county-name resolver's parallel-fragile `UKChapmanCodes.shared`
    /// hop (the flake B(i) hit under the full suite).
    static func chapman(birthLocationCode: String?, birthLocation: String?) -> String? {
        if let code = birthLocationCode,
           let c = code.split(separator: ":").first, !c.isEmpty { return String(c) }
        guard let text = birthLocation, !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let inside = text[text.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces).uppercased()
            if inside.count == 3, inside.allSatisfy(\.isLetter) { return inside }
        }
        return ChapmanCodeResolver.chapmanCode(forPlaceText: text)
    }

    /// Convenience: derive the Chapman code straight from a `Profile`'s birth
    /// fields.
    static func chapman(forProfile profile: Profile) -> String? {
        chapman(birthLocationCode: profile.birthLocationCode, birthLocation: profile.birthLocation)
    }

    /// Resolve a place-or-district string to its registration-district
    /// `PlaceAuthority` id. A parish (Hognaston) resolves via its containing
    /// district's name; a bare district name (Belper, or a record's `district`
    /// field, including FreeBMD's "Ashborne" spelling) resolves directly. nil
    /// when unresolvable.
    static func districtID(forPlaceOrDistrict placeOrDistrict: String, chapman: String?, year: Int?) -> String? {
        let token = (placeOrDistrict.split(separator: ",").first.map(String.init) ?? placeOrDistrict)
            .trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }
        let districtName: String
        if let chapman,
           let rd = FreeBMDDistrictCatalogue.shared.district(forParish: token, inChapman: chapman) {
            districtName = rd.name                          // parish → its district
        } else if let canonical = canonicalName(token, chapman: chapman) {
            districtName = canonical                         // FreeBMD "Ashborne" → "Ashbourne"
        } else {
            districtName = token
        }
        return PlaceResolver.resolveDistrict(name: districtName, chapman: chapman, year: year)
    }

    /// Map a possibly-variant registration-district name to the catalogue's
    /// canonical spelling — FreeBMD indexes "Ashborne" where UKBMD's catalogue
    /// has "Ashbourne". Exact match first; else a consonant-skeleton match
    /// (vowels dropped) scoped to the same Chapman county and accepted ONLY when
    /// unique, so a transcription variant resolves but distinct districts never
    /// collide. nil when unresolved or ambiguous.
    static func canonicalName(_ name: String, chapman: String?) -> String? {
        if let d = FreeBMDDistrictCatalogue.shared.district(named: name) { return d.name }
        guard let chapman else { return nil }
        func skeleton(_ s: String) -> String {
            String(s.lowercased().filter { $0.isLetter && !"aeiou".contains($0) })
        }
        let target = skeleton(name)
        guard !target.isEmpty else { return nil }
        let names = Set(FreeBMDDistrictCatalogue.shared.districts(forChapmanCode: chapman)
            .filter { skeleton($0.name) == target }
            .map(\.name))
        return names.count == 1 ? names.first : nil
    }
}
