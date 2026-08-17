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
