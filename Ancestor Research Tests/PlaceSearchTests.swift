import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The affordance an **unresolved** row cannot do without.
///
/// Bolehill and Pilhough are real Derbyshire settlements that appear in neither
/// `uk-places.json` nor any district's parish list — so they produce no
/// candidates, and before this the only action a user could take on them was
/// "this isn't a place", which for a hamlet is simply false. Nothing in the data
/// separates an unlisted village from a street name; only a person knows.
@MainActor
struct PlaceSearchTests {

    private var registry: PlaceAuthorityRegistry { .shared }

    // MARK: - The case that drove it

    /// Bolehill is in neither catalogue — confirm the premise before testing the
    /// remedy, so this suite fails loudly if the data ever changes.
    @Test func bolehillIsGenuinelyAbsentFromTheCatalogue() {
        #expect(RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: "Bolehill", chapman: nil, year: 1948) == nil)
        #expect(RegistrationDistrictResolver.nationalCandidates(
            forPlaceOrDistrict: "Bolehill").isEmpty)
    }

    /// …and yet the user can still say where it is.
    @Test func youCanFindTheParishToPutItIn() {
        let hits = registry.search("Wirksworth", year: 1948)
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.place.kind == .parish && $0.place.name == "Wirksworth" },
                "got \(hits.map { "\($0.place.name) [\($0.place.kind)]" })")
    }

    // MARK: - Ranking

    /// The parish is the precise answer and the one a genealogist thinks in.
    @Test func parishesOutrankDistricts() {
        let hits = registry.search("Bakewell", year: 1861)
        guard let firstParish = hits.firstIndex(where: { $0.place.kind == .parish }),
              let firstDistrict = hits.firstIndex(where: { $0.place.kind == .registrationDistrict })
        else { return }   // one kind absent is fine; ordering is what matters
        #expect(firstParish < firstDistrict,
                "got \(hits.map { "\($0.place.name) [\($0.place.kind)]" })")
    }

    @Test func exactNamesOutrankPrefixesAndSubstrings() {
        let hits = registry.search("Matlock", year: 1861)
        #expect(hits.first?.place.name.caseInsensitiveCompare("Matlock") == .orderedSame,
                "got \(hits.prefix(3).map(\.place.name))")
    }

    @Test func aOneCharacterQueryReturnsNothing() {
        #expect(registry.search("W").isEmpty, "too broad to be useful; do not scan 38k nodes for it")
        #expect(registry.search("").isEmpty)
    }

    @Test func resultsAreCapped() {
        #expect(registry.search("a", limit: 10).count <= 10)
        #expect(registry.search("ton", limit: 5).count <= 5)
    }

    // MARK: - Telling same-named parishes apart

    /// Wirksworth is recorded under more than one district. A picker that showed
    /// two identical rows would be unusable, so each carries its hierarchy.
    @Test func theHierarchyLineDistinguishesSameNamedParishes() {
        let wirksworths = registry.search("Wirksworth").filter { $0.place.kind == .parish }
        let lines = Set(wirksworths.map(\.hierarchy))
        #expect(lines.count == wirksworths.count,
                "every row must be distinguishable — \(wirksworths.map(\.hierarchy))")
        #expect(lines.allSatisfy { $0.contains("district") || $0.contains("Derbyshire") },
                "\(lines)")
    }

    /// The hierarchy line must NOT carry the district's validity window.
    ///
    /// Wirksworth is filed under Bakewell (from 1839) and Belper (to 1994), and
    /// printing those beside two otherwise identical rows read as "choose by
    /// year" — when both cover every event from 1839 to 1994. The catalogue
    /// files a parish under every district that ever covered part of it; the
    /// year discriminates nothing.
    @Test func theHierarchyLineDoesNotImplyAYearChoice() {
        for hit in registry.search("Wirksworth").filter({ $0.place.kind == .parish }) {
            #expect(!hit.hierarchy.contains("from 1"), "\(hit.hierarchy)")
            #expect(!hit.hierarchy.contains("to 1"), "\(hit.hierarchy)")
        }
    }

    /// Both Wirksworth records really are live in 1891 — the premise of the
    /// objection above.
    @Test func bothWirksworthRecordsCoverAVictorianEvent() {
        let districts = registry.districts(forParish: "Wirksworth", year: 1891, chapman: "DBY")
        #expect(districts.count == 2, "got \(districts.map(\.name))")
    }

    /// Every hit knows the district it rolls up to, so family corroboration can
    /// be shown against it — the only real signal on this screen.
    @Test func everyHitCarriesItsDistrict() {
        for hit in registry.search("Wirksworth", year: 1891) {
            #expect(hit.districtID != nil, "\(hit.place.id)")
            #expect(hit.districtID?.hasSuffix("-RD") == true, "\(hit.districtID ?? "nil")")
        }
    }

    // MARK: - Era awareness

    /// A district that had not opened cannot be offered as somewhere to put an
    /// 1824 event, the same rule the candidate list follows.
    @Test func searchIsEraFiltered() {
        let victorian = registry.search("Bakewell", year: 1824).map(\.place.id)
        #expect(!victorian.contains("DBY:Bakewell-RD"), "Bakewell RD began 1839 — got \(victorian)")
        let later = registry.search("Bakewell", year: 1861).map(\.place.id)
        #expect(later.contains("DBY:Bakewell-RD"))
    }

    @Test func withoutAYearNothingIsFilteredOut() {
        #expect(registry.search("Bakewell").count >= registry.search("Bakewell", year: 1824).count)
    }

    // MARK: - What comes back is bindable

    /// Every hit must be a real PlaceAuthority id, or binding it would be
    /// rejected by the write-time guard.
    @Test func everyHitIsAValidPlaceCode() throws {
        for hit in registry.search("Wirksworth") {
            try ProjectDatabase.validatePlaceCode(hit.place.id)
        }
        for hit in registry.search("Youlgreave") {
            try ProjectDatabase.validatePlaceCode(hit.place.id)
        }
    }

    /// Binding a PARISH (not a district) must still roll up correctly, because
    /// that is what the search offers first.
    @Test func aParishIDRollsUpToItsDistrictAndCounty() {
        guard let parish = registry.search("Wirksworth", year: 1861)
            .first(where: { $0.place.kind == .parish }) else {
            Issue.record("no Wirksworth parish"); return
        }
        #expect(PlaceAuthorityRegistry.shared.registrationDistrict(ofID: parish.place.id) != nil)
        #expect(PlaceAuthorityRegistry.shared.county(ofID: parish.place.id)?.name == "Derbyshire")
    }
}

/// Binding an unresolved row to a parish found by search — the end-to-end path.
@MainActor
struct UnresolvedPlaceBindingTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func rows(_ db: ProjectDatabase) throws -> [PlaceInventory.Row] {
        PlaceInventory.build(
            profiles: Array(try db.buildSnapshot().profiles.values),
            decisions: PlaceDecisionSet(decisions: try db.loadPlaceDecisions()))
    }

    @Test func anUnresolvedHamletCanBeSettledAgainstItsParish() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "jen", firstName: "Jennifer", lastName: "Holmes", gender: .female,
                    birthDate: GenealogicalDate(parsing: "1948"),
                    birthLocation: "Bolehill", isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)

        guard let row = try rows(db).first(where: { $0.text == "Bolehill" }) else {
            Issue.record("row missing"); return
        }
        #expect(row.confidence == .unresolved)
        #expect(row.candidates.isEmpty, "precondition: nothing to pick from")

        guard let parish = PlaceAuthorityRegistry.shared.search("Wirksworth", year: 1948)
            .first(where: { $0.place.kind == .parish }) else {
            Issue.record("no Wirksworth parish"); return
        }
        let written = try PlaceInventory.bind(
            row, occurrenceIDs: Set(row.occurrences.map(\.id)), to: parish.place.id,
            reason: "Bolehill is a hamlet in Wirksworth parish", in: db)

        #expect(written == 1)
        let settled = try rows(db).first { $0.text == "Bolehill" }
        #expect(settled?.needsDecision == false, "the row must actually leave the queue")
        #expect(settled?.occurrences.first?.decision?.placeAuthorityID == parish.place.id)
        #expect(settled?.occurrences.first?.decision?.reason.contains("Wirksworth") == true)
    }

    /// The display text is never rewritten — the tree still says "Bolehill".
    @Test func settlingDoesNotRenameThePlace() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "jen", firstName: "Jennifer", lastName: "Holmes", gender: .female,
                    birthLocation: "Bolehill", isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        let row = try rows(db).first { $0.text == "Bolehill" }!
        guard let parish = PlaceAuthorityRegistry.shared.search("Wirksworth")
            .first(where: { $0.place.kind == .parish }) else { return }
        try PlaceInventory.bindAll(row, to: parish.place.id, reason: "hamlet in the parish", in: db)

        #expect(try db.loadProfile(id: "jen")?.birthLocation == "Bolehill")
    }
}

/// Streets that carry a settlement's name, and spellings of one village.
@MainActor
struct PlaceVariantAndStreetTests {

    // MARK: - Streets

    /// "Bakewell Rd" resolved to Bakewell registration district and scored
    /// Medium — the app confidently placing a road as a town.
    @Test func aStreetNamedAfterATownDoesNotResolveToIt() {
        let hit = RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: "Bakewell Rd", chapman: nil, year: 1891)
        #expect(hit == nil, "got \(hit?.districts.map(\.name) ?? [])")
        #expect(RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Bakewell Rd", chapman: nil, year: 1891) == nil)
    }

    @Test func streetSuffixesAreRecognised() {
        for street in ["Bakewell Rd", "Chapel Row", "South Church St", "Kilton Rd",
                       "Burn Lane", "Speedwell Old Row", "Church Street"] {
            #expect(RegistrationDistrictResolver.isStreetAddress(street), "\(street)")
        }
    }

    /// Only a trailing WORD counts, so real place names survive.
    @Test func realPlacesEndingInThoseLettersAreUntouched() {
        for place in ["Ridgeway", "Broadway", "Wirksworth", "Holloway", "Alstonefield"] {
            #expect(!RegistrationDistrictResolver.isStreetAddress(place), "\(place)")
        }
        // A street token inside a fuller string still leaves the place segment usable.
        #expect(RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Bakewell Rd, Bakewell, Derbyshire", chapman: nil, year: 1891) != nil)
    }

    // MARK: - Variants

    @Test func spellingsOfOneVillageShareAKey() {
        let keys = ["Wirksworth", "Wirksworth, Derbyshire", "Wirksworth, Derbyshire (DBY)",
                    "Wirksworth, Derbyshire, England"].map(PlaceInventory.variantKey(for:))
        #expect(Set(keys).count == 1, "got \(keys)")
        #expect(keys.first == "wirksworth")
    }

    @Test func pilhoughAndTurnditchVariantsCollapseToo() {
        #expect(PlaceInventory.variantKey(for: "Pilhough")
                == PlaceInventory.variantKey(for: "Pilhough, Derbyshire"))
        #expect(PlaceInventory.variantKey(for: "Turnditch")
                == PlaceInventory.variantKey(for: "Turnditch, Derbyshire (DBY)"))
    }

    /// A QUALIFIER is never dropped. Middleton and Middleton By Wirksworth are
    /// two different villages, and merging them would be the Bakewell mistake
    /// wearing a new hat.
    @Test func aQualifierKeepsTwoVillagesApart() {
        #expect(PlaceInventory.variantKey(for: "Middleton, Derbyshire (DBY)")
                != PlaceInventory.variantKey(for: "Middleton By Wirksworth, Derbyshire, England"))
        #expect(PlaceInventory.variantKey(for: "Alport, Derbyshire")
                != PlaceInventory.variantKey(for: "Alport, Youlgreave, Derbyshire"))
    }

    @Test func aBareCountyDoesNotCollapseToNothing() {
        #expect(!PlaceInventory.variantKey(for: "Derbyshire").isEmpty,
                "stripping every segment would group all counties together")
    }
}

/// Rows whose uses straddle a district opening or closing.
@MainActor
struct BoundarySpanningTests {

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func add(_ db: ProjectDatabase, _ id: String, _ year: String, _ place: String) throws {
        _ = try db.addProfile(
            Profile(id: id, firstName: id, lastName: "X", gender: .male,
                    birthDate: GenealogicalDate(parsing: year), birthLocation: place,
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
    }

    private func row(_ db: ProjectDatabase, _ text: String) throws -> PlaceInventory.Row {
        PlaceInventory.build(
            profiles: Array(try db.buildSnapshot().profiles.values),
            decisions: PlaceDecisionSet(decisions: try db.loadPlaceDecisions())
        ).first { $0.text == text }!
    }

    // MARK: - Detection

    /// Bakewell RD opened in 1839. A row holding 1830 and 1891 events straddles
    /// it, and the era filter rules Bakewell out for the WHOLE row on account of
    /// the earlier event — hiding a legitimate answer for the later one.
    @Test func anOpeningInsideTheSpanIsReported() throws {
        let db = try makeDB()
        try add(db, "early", "1830", "Wirksworth")
        try add(db, "late", "1891", "Wirksworth")

        let r = try row(db, "Wirksworth")
        #expect(r.boundariesCrossed.contains { $0.year == 1839 && $0.opened },
                "got \(r.boundariesCrossed.map { "\($0.districtName) \($0.year)" })")
        #expect(r.candidates.map(\.name) == ["Belper"], "precondition: filtered by the earliest year")
    }

    @Test func aClosingInsideTheSpanIsReported() throws {
        let db = try makeDB()
        try add(db, "mid", "1980", "Cromford")
        try add(db, "modern", "2000", "Cromford")

        let r = try row(db, "Cromford")
        #expect(r.boundariesCrossed.contains { $0.year == 1994 && !$0.opened },
                "got \(r.boundariesCrossed.map { "\($0.districtName) \($0.year)" })")
    }

    /// A row that does not straddle anything says nothing — the warning has to
    /// stay rare or it becomes wallpaper.
    @Test func aSingleEraRowReportsNothing() throws {
        let db = try makeDB()
        try add(db, "a", "1861", "Wirksworth")
        try add(db, "b", "1871", "Wirksworth")
        #expect(try row(db, "Wirksworth").boundariesCrossed.isEmpty)
    }

    @Test func undatedUsesCannotStraddleAnything() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "n", firstName: "No", lastName: "Date", gender: .male,
                    birthLocation: "Wirksworth", isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        #expect(try row(db, "Wirksworth").boundariesCrossed.isEmpty)
    }

    // MARK: - The subset that fits

    @Test func theFittingSubsetExcludesWhatTheDistrictCannotHold() throws {
        let db = try makeDB()
        try add(db, "mid", "1980", "Cromford")
        try add(db, "modern", "2000", "Cromford")

        let r = try row(db, "Cromford")
        let all = Set(r.occurrences.map(\.id))
        let fitting = PlaceInventory.occurrenceIDsFitting(r, districtID: "DBY:Belper-RD", within: all)

        #expect(fitting.count == 1, "Belper closed in 1994")
        let fittingYear = r.occurrences.first { fitting.contains($0.id) }?.year
        #expect(fittingYear == 1980)
    }

    /// An undated use fits anything — refusing it would strand rows that have no
    /// year at all, which is most of an imported tree.
    @Test func anUndatedUseFitsAnyDistrict() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "n", firstName: "No", lastName: "Date", gender: .male,
                    birthLocation: "Cromford", isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        let r = try row(db, "Cromford")
        let fitting = PlaceInventory.occurrenceIDsFitting(
            r, districtID: "DBY:Belper-RD", within: Set(r.occurrences.map(\.id)))
        #expect(fitting.count == 1)
    }

    /// End to end: the refused bind, then the subset, then the remainder.
    @Test func aSpanningRowSettlesInTwoPasses() throws {
        let db = try makeDB()
        try add(db, "mid", "1980", "Cromford")
        try add(db, "modern", "2000", "Cromford")
        let r = try row(db, "Cromford")
        let all = Set(r.occurrences.map(\.id))

        #expect(throws: PlaceInventory.BindError.self) {
            try PlaceInventory.bind(r, occurrenceIDs: all, to: "DBY:Belper-RD", in: db)
        }

        let fitting = PlaceInventory.occurrenceIDsFitting(r, districtID: "DBY:Belper-RD", within: all)
        #expect(try PlaceInventory.bind(r, occurrenceIDs: fitting, to: "DBY:Belper-RD", in: db) == 1)

        // The remainder settles independently against a district that can hold it.
        let after = try row(db, "Cromford")
        let remaining = Set(after.occurrences.filter { !$0.isBound }.map(\.id))
        #expect(remaining.count == 1)
        #expect(try PlaceInventory.bind(after, occurrenceIDs: remaining,
                                        to: "DBY:Bakewell-RD", in: db) == 1)

        let settled = try row(db, "Cromford")
        #expect(settled.needsDecision == false, "both halves settled, different districts")
        #expect(Set(settled.occurrences.compactMap(\.decision?.placeAuthorityID)).count == 2,
                "one string, two answers — which is the whole point of per-field decisions")
    }
}
