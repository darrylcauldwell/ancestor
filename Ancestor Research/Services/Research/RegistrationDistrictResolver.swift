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
        // When the caller supplies no county, take the one the STRING states.
        // Genealogical place text carries it — "Alport, Youlgreave, Derbyshire"
        // — and without it two things break: the parish tier is skipped
        // entirely (`district(forParish:inChapman:)` requires a code), and a
        // bare first segment can match a same-named district in the wrong
        // county. "Middleton, Derbyshire" resolved to LAN:Middleton-RD until
        // this was added — a wrong-county answer, worse than none.
        let scope: [String?] = chapman.map { [$0] }
            ?? { let s = statedChapmanScope(in: placeOrDistrict); return s.isEmpty ? [nil] : s }()
        for token in segments(of: placeOrDistrict) {
            // 1. PARISH HOP, era-aware. Was `district(forParish:inChapman:)` —
            //    first-match and validity-blind, so "Middleton" for an 1824
            //    birth answered Bakewell RD, which did not exist until 1839.
            //    `districts(forParish:year:chapman:)` filters on the validity
            //    window and returns EVERY candidate, so an impossible district
            //    is eliminated rather than silently chosen. It also works with
            //    no county, which the old lookup could not do at all.
            let parishCandidates = dedupedByID(scope.flatMap {
                PlaceAuthorityRegistry.shared.districts(forParish: token, year: year, chapman: $0)
            })

            // Ties are the NORM, not an edge case: UKBMD's Table 1 lists a
            // parish under every district that ever covered part of it, so
            // Cromford is in both Bakewell and Belper at 1861. Declining on a
            // tie would gut coverage. Declining only on a CROSS-COUNTY tie is
            // the line that matters — a wrong county mis-scores the geography
            // gate, whereas a rival district in the right county does not.
            //
            // Within a county the answer is chosen deterministically (by id) so
            // this stays a canonicalisation: `conflictsWithConfirmedBirth`
            // compares two resolutions of different strings and needs the same
            // input to give the same output, not the "true" district. Callers
            // that need to KNOW it was a tie ask `candidates(…)`, which is what
            // the confidence score is built from.
            // County taken from the id prefix ("DBY:Bakewell-RD"), not from
            // `county(of:)`: a compactMap over that silently DROPS candidates
            // whose county node fails to resolve, so a genuinely cross-county
            // tie could collapse to one entry and slip through. Bare
            // "Middleton" did exactly that and resolved into Lancashire.
            let counties = Set(parishCandidates.map {
                String($0.id.split(separator: ":").first ?? "").uppercased()
            })
            if counties.count > 1 { continue }
            if let best = parishCandidates.map(\.id).sorted().first { return best }

            // 2. Registration-district name, canonicalised where needed
            //    (FreeBMD indexes "Ashborne"; the catalogue has "Ashbourne").
            // Ids, not nodes: `resolveDistrict` can return an id the authority
            // registry has no node for, and looking one up to dedupe would drop a
            // resolution that used to work. The county is in the id prefix anyway.
            let byName = Set(scope.compactMap { code in
                PlaceResolver.resolveDistrict(
                    name: canonicalName(token, chapman: code) ?? token, chapman: code, year: year)
            })
            let nameCounties = Set(byName.map {
                String($0.split(separator: ":").first ?? "").uppercased()
            })
            if nameCounties.count > 1 { continue }
            if let id = byName.sorted().first { return id }
        }
        return nil
    }

    /// The Chapman code a place string STATES about itself — an explicit
    /// "(DBY)" suffix, or a segment that is literally a county name
    /// ("Alport, Youlgreave, Derbyshire").
    ///
    /// Deliberately NOT `ChapmanCodeResolver.chapmanCode(forPlaceText:)`, which
    /// also matches place names and so answers confidently for text that states
    /// no county at all: a bare "Middleton" returns **LAN**. Scoping resolution
    /// by that guess made every countyless Middleton Lancastrian. A county the
    /// string names is a fact; a county inferred from a place name is a guess,
    /// and a guess must not narrow the search.
    static func statedChapman(in placeText: String) -> String? {
        if let open = placeText.lastIndex(of: "("), let close = placeText.lastIndex(of: ")"), open < close {
            let inside = placeText[placeText.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces).uppercased()
            if inside.count == 3, inside.allSatisfy(\.isLetter) { return inside }
        }
        for segment in segments(of: placeText) {
            if let code = UKChapmanCodes.shared.chapmanCode(forCountyName: segment) { return code }
        }
        return nil
    }

    /// The county codes a place string's stated county permits — normally the one
    /// code `statedChapman` found, but every subdivision when that county is
    /// filed only under its parts.
    ///
    /// "Sheffield, Yorkshire" states YKS. No registration district is filed under
    /// YKS; they all sit under WRY, ERY and NRY. Scoping to YKS therefore matched
    /// nothing — a string that said MORE about where it was resolved to LESS.
    /// Widening to "no county" instead would be worse: bare "Clayton" then
    /// resolves into Staffordshire and Sussex, and a wrong county is the one
    /// error the geography gate cannot recover from. Expanding YKS to its three
    /// ridings keeps the constraint the text actually supplied.
    ///
    /// Empty means unscoped.
    static func statedChapmanScope(in placeText: String) -> [String] {
        guard let code = statedChapman(in: placeText) else { return [] }
        if !FreeBMDDistrictCatalogue.shared.districts(forChapmanCode: code).isEmpty { return [code] }
        return subdivisions(of: code)
    }

    /// County codes whose catalogue name extends `code`'s — "Yorkshire" →
    /// "Yorkshire — East Riding", "… North Riding", "… West Riding". Matched on
    /// the name because the Chapman list records no parent/child link.
    static func subdivisions(of code: String) -> [String] {
        let all = UKChapmanCodes.shared.codes
        guard let parent = all.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame })
        else { return [] }
        let prefix = parent.name.lowercased() + " "
        return all
            .filter { $0.code != parent.code && $0.name.lowercased().hasPrefix(prefix) }
            .map(\.code)
            .sorted()
    }

    /// Every registration district a place string could mean, with the segment
    /// that produced them — the ambiguity `districtID` has to collapse in order
    /// to stay a canonicalisation.
    ///
    /// This is the input to a confidence score: one candidate is near-certain,
    /// four rival Middletons is a coin-flip that a human should settle. It
    /// exists so the ambiguity is REPORTED rather than silently resolved —
    /// "Middleton, Derbyshire" for an 1824 birth answered Bakewell RD, a
    /// district that did not exist until 1839, and nothing surfaced that.
    ///
    /// Returns the candidates for the FIRST segment that matches anything, so
    /// "Alport, Youlgreave, Derbyshire" reports Youlgreave's districts rather
    /// than Derbyshire's entire set.
    ///
    /// `parishes` are the distinct settlements the segment names — the honest
    /// measure of ambiguity, which `districts` is not (see
    /// `PlaceAuthority.parishRecords(named:year:chapman:)`). `eliminated` are the
    /// districts the year ruled out, kept rather than dropped so a narrowing can
    /// be shown as a narrowing: "Bakewell — began 1839" is the difference between
    /// an answer a user can check and one they have to trust.
    struct Candidates: Sendable {
        let matchedSegment: String
        /// Every parish record the segment matches, deliberately NOT year-filtered.
        /// A parish record inherits its district's validity window, so filtering
        /// by year answers "was this jurisdiction in force" — not "did this
        /// settlement exist". Bakewell's `Middleton` record disappears at 1824
        /// because Bakewell RD began in 1839; the village did not disappear, and
        /// it is still a rival reading of the word "Middleton".
        let parishes: [PlaceAuthority]
        let districts: [PlaceAuthority]
        let eliminated: [(district: PlaceAuthority, reason: String)]

        /// Distinct settlements sharing this name. Two records for one parish
        /// under successive districts count once.
        var distinctPlaceNames: [String] {
            Array(Set(parishes.map(\.name))).sorted()
        }
    }

    static func candidates(
        forPlaceOrDistrict placeOrDistrict: String, chapman: String?, year: Int?
    ) -> Candidates? {
        // `[nil]` means "one unscoped pass"; a stated county contributes one pass
        // per permitted code, so a county filed under subdivisions (Yorkshire →
        // the three ridings) still constrains the search instead of vetoing it.
        let scope: [String?] = chapman.map { [$0] }
            ?? { let s = statedChapmanScope(in: placeOrDistrict); return s.isEmpty ? [nil] : s }()
        let places = PlaceAuthorityRegistry.shared.places

        for token in segments(of: placeOrDistrict) {
            let parishRecords = scope.flatMap {
                PlaceAuthorityRegistry.shared.parishRecords(named: token, year: nil, chapman: $0)
            }
            let districts = dedupedByID(scope.flatMap {
                PlaceAuthorityRegistry.shared.districts(forParish: token, year: year, chapman: $0)
            })
            if !districts.isEmpty {
                return Candidates(matchedSegment: token, parishes: dedupedByID(parishRecords),
                                  districts: districts,
                                  eliminated: eliminatedByYear(token, scope: scope,
                                                               year: year, surviving: districts))
            }

            let nodes = dedupedByID(scope.compactMap { code -> PlaceAuthority? in
                let districtName = canonicalName(token, chapman: code) ?? token
                guard let id = PlaceResolver.resolveDistrict(name: districtName, chapman: code, year: year)
                else { return nil }
                return places.place(id: id)
            })
            if !nodes.isEmpty {
                return Candidates(matchedSegment: token, parishes: [], districts: nodes,
                                  eliminated: eliminatedByYear(token, scope: scope,
                                                               year: year, surviving: nodes))
            }
        }
        return nil
    }

    /// Every district in the country a place string could name, ignoring the
    /// county the string states and any validity window.
    ///
    /// The escape hatch behind the scored list. The stated county is normally the
    /// best constraint available, but it is sometimes simply WRONG — emigrants
    /// described by where they ended up, a transcription error, a county boundary
    /// that moved under the family. A list locked to the stated county would trap
    /// exactly those cases with no way out, so the user can always widen. Never
    /// the default: this returns dozens of Middletons and is only useful once a
    /// person has decided the narrow list is missing their answer.
    static func nationalCandidates(forPlaceOrDistrict placeOrDistrict: String) -> [PlaceAuthority] {
        let places = PlaceAuthorityRegistry.shared.places
        for token in segments(of: placeOrDistrict) {
            let districts = dedupedByID(PlaceAuthorityRegistry.shared.districts(forParish: token, year: nil, chapman: nil))
            if !districts.isEmpty { return districts }
            if let id = PlaceResolver.resolveDistrict(name: token, chapman: nil, year: nil),
               let node = places.place(id: id) {
                return [node]
            }
        }
        return []
    }

    private static func dedupedByID(_ places: [PlaceAuthority]) -> [PlaceAuthority] {
        var byID: [String: PlaceAuthority] = [:]
        for p in places { byID[p.id] = p }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// Districts the year removed, each with the window that removed it.
    private static func eliminatedByYear(
        _ token: String, scope: [String?], year: Int?, surviving: [PlaceAuthority]
    ) -> [(district: PlaceAuthority, reason: String)] {
        guard let year else { return [] }
        let survivingIDs = Set(surviving.map(\.id))
        return dedupedByID(scope.flatMap {
            PlaceAuthorityRegistry.shared.districts(forParish: token, year: nil, chapman: $0)
        })
            .filter { !survivingIDs.contains($0.id) }
            .map { district in
                let reason: String
                if let from = district.validFrom, year < from {
                    reason = "began \(from)"
                } else if let to = district.validTo, year > to {
                    reason = "ended \(to)"
                } else {
                    reason = "not valid in \(year)"
                }
                return (district, reason)
            }
    }

    /// A place string's comma segments, narrowest first — "Alport, Youlgreave,
    /// Derbyshire" → ["Alport", "Youlgreave", "Derbyshire"].
    ///
    /// Only the FIRST segment used to be tried, so a hamlet that the catalogue
    /// does not list ("Alport") lost the parish sitting right beside it in the
    /// same string ("Youlgreave", a real Bakewell parish). Genealogical place
    /// text is written narrowest-to-widest by convention, so walking outwards
    /// takes the most precise answer available and stops there — it never
    /// widens past the first segment that resolves. Trailing Chapman suffixes
    /// ("(DBY)") and empty fragments are dropped.
    static func segments(of placeText: String) -> [String] {
        placeText
            .split(separator: ",")
            .map { seg -> String in
                var s = String(seg)
                if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
                    s.removeSubrange(open...close)
                }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// The canonical registration-district NAME a place resolves to ("Crich" →
    /// "Belper", "Ashborne" → "Ashbourne"), for display in the hierarchy line of
    /// the location picker. A parish resolves via its containing district; a bare
    /// district name canonicalises to itself. nil when the place isn't a known
    /// parish or district (a hamlet with no catalogue entry, or a county) — the
    /// caller then shows no RD line rather than guessing. Shares the exact
    /// parish→district / canonicalisation logic `districtID` uses, so the picker's
    /// displayed RD and the id the scorer/apply resolve can never disagree.
    static func districtName(forPlace place: String, chapman: String?) -> String? {
        for token in segments(of: place) {
            if let chapman,
               let rd = FreeBMDDistrictCatalogue.shared.district(forParish: token, inChapman: chapman) {
                return rd.name
            }
            if let canonical = canonicalName(token, chapman: chapman) { return canonical }
        }
        return nil
    }

    /// Map a possibly-variant registration-district name to the catalogue's
    /// canonical spelling — FreeBMD indexes "Ashborne" where UKBMD's catalogue
    /// has "Ashbourne". Exact match first; else a consonant-skeleton match
    /// (vowels dropped) scoped to the same Chapman county and accepted ONLY when
    /// unique, so a transcription variant resolves but distinct districts never
    /// collide. nil when unresolved or ambiguous.
    static func canonicalName(_ name: String, chapman: String?) -> String? {
        // County-scoped exact match FIRST when the county is known. The
        // unscoped `district(named:)` returns whichever same-named district
        // sorts first in the catalogue, so "Middleton" for a Derbyshire subject
        // came back as Lancashire's Middleton RD. Scoping is only a preference,
        // not a filter — an unscoped fallback still runs below, so a district
        // that genuinely has no entry in the stated county still resolves.
        if let chapman,
           let scoped = FreeBMDDistrictCatalogue.shared.districts(forChapmanCode: chapman)
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return scoped.name
        }
        // Unscoped exact match only when NO county is known. If the county IS
        // known and the name isn't in it, resolving to some other county's
        // district would be overruling what the string says about itself —
        // decline instead and let the next segment try.
        guard let chapman else {
            return FreeBMDDistrictCatalogue.shared.district(named: name)?.name
        }
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
