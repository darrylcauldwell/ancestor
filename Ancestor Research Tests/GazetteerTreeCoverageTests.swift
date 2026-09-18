import Testing
import Foundation
@testable import Ancestor_Research

/// EXHAUSTIVE coverage + correctness check over every distinct location string
/// dumped from the owner's live tree — the fixture list below is the dump, and
/// extending it extends the check.
///
/// Two questions, asked of ALL of them rather than a sample:
///   1. Does it resolve to a registration district at all?
///   2. When it resolves, is the answer's county CONSISTENT with the county the
///      string itself states? A string saying "Derbyshire" that resolves to
///      Staffordshire is worse than not resolving — the geography gate would
///      pass or fail a record for the wrong reason.
///
/// Question 2 is the one that matters. Coverage can be traded off; a wrong
/// county cannot. The corpus is deliberately real rather than synthetic: these
/// are the strings the app actually meets.
@MainActor
struct GazetteerTreeCoverageTests {

    /// Corpus checks resolve against a representative event year, because
    /// EVERY production caller supplies one — `ApplyEngine` passes the record's
    /// `birthYear`, `RecordScorer` passes the record/subject year. Resolving
    /// with `year: nil` exercises a path the app does not use, and answers
    /// conservatively by design: a parish that moved between districts has more
    /// than one valid answer when the era is unknown, and the resolver declines
    /// rather than picking one. 1861 is a census year in the middle of the
    /// tree's documented range.
    static let representativeYear = 1861

    /// Every distinct `Profile.location` in the tree, verbatim — including the
    /// malformed ones, which are part of the test.
    static let treeLocations: [String] = [
        "- (or Dublin), County Dublin (or Ireland)",
        "Alport, Derbyshire", "Alport, Derbyshire (DBY)",
        "Alport, Youlgreave, Derbyshire, England",
        "Ashborne", "Ashbourne", "Ashbourne, Derbyshire",
        "Ashbourne, Derbyshire, England",
        "Bakewell", "Bakewell, Derbyshire",
        "Bishop Storford",
        "Bolehill, Derbyshire, England",
        "Bolton, Lancashire",
        "Bonsall, Derbyshire", "Bonsall, Derbyshire, England",
        "Brackenfield, Derbyshire",
        "Bridge Town (Darley Bridge), Wensley, Derbyshire",
        "Calling Low, Youlgreave, Derbyshire",
        "Chesterfield", "Chesterfield, Derbyshire", "Chesterfield, Derbyshire, England",
        "City Hospital, Derby",
        "Clayton (Doncaster) (or Clayton), Yorkshire, West Riding (or Yorkshire)",
        "Cromford, Derbyshire", "Cromford, Derbyshire (DBY)", "Cromford, Derbyshire, England",
        "Darley Bridge, Derbyshire", "Darley Bridge, Derbyshire (DBY)",
        "Darley Hall",
        "Derby", "Derbyshire",
        "Farnsfield, Nottinghamshire (NTT)",
        "Forsbrook, Staffordshire",
        "Grindon, Staffordshire",
        "Harpswell, Lincolnshire",
        "Harthill, Derbyshire (DBY)",
        "Holloway, Derbyshire (DBY)",
        "Holmgate, Derbyshire", "Holmgate, North Wingfield, Derbyshire",
        "Hulland, Derbyshire",
        "Kedleston, Derbyshire",
        "Kingsley, Staffordshire",
        "Kirk Ireton, Derbyshire, England",
        "Leland", "Leyland",
        "Longcliffe Wharf, Derbyshire",
        "Loscoe, Derbyshire, England",
        "Middleton By Wirksworth, Derbyshire, England",
        "Middleton, Derbyshire", "Middleton, Derbyshire (DBY)",
        "Milford, Derbyshire",
        "Muggington, Derbyshire, England",
        "Pilhough, Derbyshire", "Pilhough, Derbyshire (DBY)",
        "Pleasley, Derbyshire",
        "Priestcliffe, Derbyshire",
        "Radbourne, Derbyshire", "Radford",
        "Sheffield, Yorkshire",
        "Stanton-in-Peak, Derbyshire",
        "Staveley, Derbyshire",
        "Taddington, Derbyshire", "Taddington, Derbyshire (DBY)",
        "Teversal, Nottinghamshire, England",
        "Trent, Newark, Nottinghamshire",
        "Turnditch", "Turnditch, Derbyshire", "Turnditch, Derbyshire (DBY)",
        "Turnditch, Derbyshire, England",
        "Unstone, Derbyshire, England",
        "Warslow, Staffordshire",
        "Warwickshire, England",
        "Wensley, Darley, Derbyshire", "Wensley, Derbyshire, England",
        "Weston Underwood", "Weston Underwood, Derbyshire",
        "Willoughton, Lincolnshire",
        "Windley, Derbyshire",
        "Wingerworth, Derbyshire",
        "Winster",
        "Wirksworth", "Wirksworth, Derbyshire", "Wirksworth, Derbyshire (DBY)",
        "Wirksworth, Derbyshire, England",
        "Worksop", "Worksop, Nottinghamshire, England",
        "Yeldersley, Derbyshire",
        "Longcliffe Wharf, Derbyshire", "Holmgate, Derbyshire",
    ]

    /// The Chapman code a string ASSERTS about itself, from an explicit "(DBY)"
    /// suffix or a county name anywhere in the text. nil when the string names
    /// no county — those can't be correctness-checked, only counted.
    private func assertedChapman(_ s: String) -> String? {
        if let open = s.lastIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let inside = s[s.index(after: open)..<close].trimmingCharacters(in: .whitespaces).uppercased()
            if inside.count == 3, inside.allSatisfy(\.isLetter) { return inside }
        }
        let lowered = s.lowercased()
        for (county, code) in [
            ("derbyshire", "DBY"), ("staffordshire", "STS"), ("nottinghamshire", "NTT"),
            ("lincolnshire", "LIN"), ("lancashire", "LAN"), ("warwickshire", "WAR"),
            ("yorkshire", "YKS"),
        ] where lowered.contains(county) {
            return code
        }
        return nil
    }

    /// THE test that matters: nothing may resolve into a county the string
    /// itself contradicts. Run over every location, with every failure
    /// collected so one bad row doesn't mask the rest.
    @Test func noTreeLocationResolvesIntoAContradictoryCounty() {
        var contradictions: [String] = []
        for loc in Self.treeLocations {
            guard let asserted = assertedChapman(loc) else { continue }
            // Yorkshire's ridings are separate Chapman codes; treat any of them
            // as consistent with a bare "Yorkshire".
            let acceptable: Set<String> = asserted == "YKS"
                ? ["YKS", "NRY", "ERY", "WRY"] : [asserted]
            guard let id = RegistrationDistrictResolver.districtID(
                forPlaceOrDistrict: loc, chapman: nil, year: Self.representativeYear
            ) else { continue }
            let resolvedChapman = String(id.split(separator: ":").first ?? "").uppercased()
            if !acceptable.contains(resolvedChapman) {
                contradictions.append("\(loc) — asserts \(asserted), resolved \(resolvedChapman) (\(id))")
            }
        }
        #expect(contradictions.isEmpty,
                "location strings resolved into a county they contradict:\n\(contradictions.joined(separator: "\n"))")
    }

    /// Coverage, reported rather than asserted at a threshold — a hard number
    /// here would just get bumped whenever it failed. What IS asserted is that
    /// the strings we specifically researched and know the answer for resolve.
    @Test func knownAnswerLocationsResolve() {
        // Each verified by hand against the parish registers during the
        // 2026-08-15/17 Stevenson-Wain research; the expected registration
        // district is the one the catalogue lists the parish under.
        let known: [(String, String)] = [
            ("Warslow, Staffordshire", "STS"),
            ("Holloway, Derbyshire (DBY)", "DBY"),
            ("Wensley, Darley, Derbyshire", "DBY"),
            ("Alport, Youlgreave, Derbyshire, England", "DBY"),
            ("Calling Low, Youlgreave, Derbyshire", "DBY"),
            ("Holmgate, North Wingfield, Derbyshire", "DBY"),
            ("Bridge Town (Darley Bridge), Wensley, Derbyshire", "DBY"),
            ("Taddington, Derbyshire", "DBY"),
            ("Cromford, Derbyshire", "DBY"),
            ("Wirksworth, Derbyshire", "DBY"),
        ]
        var misses: [String] = []
        for (loc, expectedChapman) in known {
            guard let id = RegistrationDistrictResolver.districtID(
                forPlaceOrDistrict: loc, chapman: nil, year: Self.representativeYear
            ) else {
                misses.append("\(loc) — did not resolve at all")
                continue
            }
            let got = String(id.split(separator: ":").first ?? "").uppercased()
            if got != expectedChapman {
                misses.append("\(loc) — expected \(expectedChapman), got \(got) (\(id))")
            }
        }
        #expect(misses.isEmpty, "known-answer locations failed:\n\(misses.joined(separator: "\n"))")
    }

    /// The residue, pinned. Whatever does NOT resolve is listed here explicitly
    /// so the number is visible and any change — a regression that loses
    /// coverage, or a gain that should shorten the list — fails this test
    /// rather than passing silently.
    @Test func theUnresolvedResidueIsExactlyWhatWeExpect() {
        // Categorised, because the categories decide what (if anything) to
        // build next. Only the first group is a gazetteer-coverage problem.
        let expected: Set<String> = [
            // (a) TRUE HAMLETS — real places, genuinely absent from the
            // catalogue's parish lists. These are the only rows a curated
            // overlay would actually add value for: 9 strings, 8 places.
            "Alport, Derbyshire", "Alport, Derbyshire (DBY)",
            "Bolehill, Derbyshire, England",
            "Darley Bridge, Derbyshire", "Darley Bridge, Derbyshire (DBY)",
            "Holmgate, Derbyshire",
            "Longcliffe Wharf, Derbyshire",
            "Pilhough, Derbyshire", "Pilhough, Derbyshire (DBY)",
            "Priestcliffe, Derbyshire",
            "Stanton-in-Peak, Derbyshire",

            // (b) CORRECTLY DECLINED — the name spans more than one COUNTY and
            // the string names none, so resolving it would pick a county on the
            // caller's behalf. A same-county tie does NOT decline (see
            // rivalDistrictsAreReportedRatherThanHidden) — only a cross-county
            // one, because that is the tie the geography gate would mis-score.
            "Weston Underwood",

            // (c) NOT A DISTRICT — a county is not a registration district.
            // "Sheffield, Yorkshire" left this list once a stated county filed
            // only under subdivisions (YKS → WRY/ERY/NRY) began expanding to
            // them instead of vetoing the search.
            "Derbyshire", "Warwickshire, England",

            // (d) NOT PLACES / MALFORMED — typos and non-settlements. These
            // want correcting in the tree, not adding to a gazetteer.
            // ("Ashborne" left this list on 2026-08-24 — it is FreeBMD's own
            // recurring rendering of Ashbourne, not a tree typo, so #31 made
            // it a data-derived alias in freebmd-districts.json.)
            "- (or Dublin), County Dublin (or Ireland)",
            "Bishop Storford",      // typo: Bishop's Stortford
            "Clayton (Doncaster) (or Clayton), Yorkshire, West Riding (or Yorkshire)",
            "Darley Hall",          // a house, not a settlement
            "Leland",               // typo: Leyland
        ]
        let unresolved = Set(Self.treeLocations.filter {
            RegistrationDistrictResolver.districtID(forPlaceOrDistrict: $0, chapman: nil, year: Self.representativeYear) == nil
        })
        let newlyBroken = unresolved.subtracting(expected)
        let newlyFixed = expected.subtracting(unresolved)
        #expect(newlyBroken.isEmpty, "regression — these stopped resolving:\n\(newlyBroken.sorted().joined(separator: "\n"))")
        #expect(newlyFixed.isEmpty, "improvement — shorten the pinned list:\n\(newlyFixed.sorted().joined(separator: "\n"))")
    }

    // MARK: - Era elimination
    //
    // Derbyshire alone has four Middletons: Middleton by Wirksworth (Ashbourne
    // RD), a bare Middleton (Bakewell RD, 1839–), Middleton & Smerrill and
    // Stoney Middleton (Bakewell from 1839, Matlock to 1838). Ruth Brailsford
    // was born "Middleton, Derbyshire" in 1824 and the app answered Bakewell —
    // a district that did not exist for another fifteen years.

    @Test func aDistrictThatDidNotYetExistIsNotAnAnswer() {
        let id = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Middleton, Derbyshire", chapman: nil, year: 1824
        )
        #expect(id?.contains("Bakewell") != true,
                "Bakewell RD began in 1839 and cannot hold an 1824 event — got \(id ?? "nil")")
    }

    /// Ambiguity is REPORTED, not hidden. `districtID` must stay a
    /// canonicalisation — `conflictsWithConfirmedBirth` compares resolutions of
    /// two different strings and needs determinism, not truth — so it answers
    /// even when rivals exist. `candidates(…)` is where the rivals surface, and
    /// it is what a confidence score is computed from.
    ///
    /// Declining on every tie was tried and rejected on the evidence: UKBMD
    /// lists a parish under every district that ever covered part of it, so
    /// Cromford is in both Bakewell and Belper at 1861. Ties are the norm and
    /// declining on them cost 15 real places.
    @Test func rivalDistrictsAreReportedRatherThanHidden() {
        let result = RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: "Middleton, Derbyshire", chapman: nil, year: nil)
        #expect((result?.districts.count ?? 0) > 1,
                "Derbyshire has four Middletons — the rivals must be visible to the caller")
        #expect(RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Middleton, Derbyshire", chapman: nil, year: nil) != nil,
                "…while the canonicalising API still answers deterministically")
    }

    /// A cross-COUNTY tie is different in kind and still declines: a wrong
    /// county mis-scores the geography gate, where a rival district in the
    /// right county does not.
    @Test func aCrossCountyTieStillDeclines() {
        // "Middleton" bare, no county stated anywhere — DBY, LAN, NBL, ERY…
        let id = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Middleton", chapman: nil, year: nil)
        #expect(id == nil, "a name spanning counties must not be resolved into one of them — got \(id ?? "nil")")
    }

    /// Era elimination must not cost coverage where the answer is unambiguous:
    /// a parish valid in the year still resolves.
    @Test func eraFilteringDoesNotBreakAnUnambiguousDatedPlace() {
        let id = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Wensley And Snitterton, Derbyshire", chapman: nil, year: 1861
        )
        #expect(id?.contains("Bakewell") == true,
                "1861 is inside Bakewell's window (from 1839) — got \(id ?? "nil")")
    }

    /// The no-year path is deliberately conservative, and that is a contract
    /// worth pinning: a parish that moved between districts (Taddington sat in
    /// Matlock to 1838 and Bakewell from 1839) has no single right answer when
    /// the era is unknown, so it declines. Callers that know the year get the
    /// answer; callers that don't get an honest nil rather than a coin-flip.
    @Test func anEventYearNarrowsTheCandidateSet() {
        // Taddington sat in Matlock RD to 1838 and Bakewell RD from 1839, so
        // supplying the year is what turns two answers into one. This is the
        // whole value of era elimination, stated as a property rather than a
        // single case.
        let undated = RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: "Taddington, Derbyshire", chapman: nil, year: nil)
        let dated = RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: "Taddington, Derbyshire", chapman: nil, year: 1861)
        #expect((dated?.districts.count ?? 0) < (undated?.districts.count ?? 0),
                "a known year must eliminate districts that did not exist then")
        #expect(dated?.districts.allSatisfy { !$0.id.contains("Matlock") } == true,
                "Matlock RD ended in 1838 and cannot hold an 1861 event")
    }

    /// Non-places and typos must NOT resolve. A wrong confident answer for
    /// "Darley Hall" (a house) or "City Hospital, Derby" is worse than none.
    @Test func nonPlacesDoNotResolveToSomewhereReal() {
        var wrong: [String] = []
        for junk in ["Darley Hall", "City Hospital, Derby", "- (or Dublin), County Dublin (or Ireland)"] {
            if let id = RegistrationDistrictResolver.districtID(
                forPlaceOrDistrict: junk, chapman: nil, year: nil
            ) {
                // "City Hospital, Derby" legitimately reaches Derby via its
                // second segment — that is correct, not a false positive.
                if !junk.lowercased().contains("derby") {
                    wrong.append("\(junk) -> \(id)")
                }
            }
        }
        #expect(wrong.isEmpty, "non-places resolved: \(wrong)")
    }
}
