import Testing
import Foundation
@testable import Ancestor_Research

/// Location gazetteer — the Derbyshire/Nottinghamshire villages added to
/// uk-places.json, and the matcher's tolerance for the trailing country /
/// Chapman-code noise that stored freeform locations carry (e.g.
/// "Loscoe, Derbyshire, England", "Turnditch, Derbyshire (DBY)"). Turnditch is
/// the exact false positive the user hit — a real village by Wirksworth, like
/// Kirk Ireton and Windley, that the bundled gazetteer simply lacked.
struct LocationGazetteerMatchTests {

    // MARK: - normalizeForMatch (pure)

    @Test func stripsTrailingCountryQualifier() {
        #expect(LocationGazetteer.normalizeForMatch("loscoe, derbyshire, england") == "loscoe, derbyshire")
        #expect(LocationGazetteer.normalizeForMatch("teversal, nottinghamshire, england") == "teversal, nottinghamshire")
        #expect(LocationGazetteer.normalizeForMatch("wirksworth, derbyshire, united kingdom") == "wirksworth, derbyshire")
    }

    @Test func stripsTrailingChapmanParenthetical() {
        #expect(LocationGazetteer.normalizeForMatch("turnditch, derbyshire (dby)") == "turnditch, derbyshire")
        #expect(LocationGazetteer.normalizeForMatch("hognaston, derbyshire (dby)") == "hognaston, derbyshire")
    }

    @Test func doesNotEmptyASingleTokenPlace() {
        // The country strip is comma-anchored, so a single-token place literally
        // named for a country (a village "Wales") is never emptied out.
        #expect(LocationGazetteer.normalizeForMatch("wales") == "wales")
        #expect(LocationGazetteer.normalizeForMatch("belper") == "belper")
    }

    // MARK: - Newly-added villages resolve to a single entry

    @Test func newVillagesMatchExactly() {
        let g = LocationGazetteer.shared
        #expect(g.match("Turnditch, Derbyshire").first?.id == "DBY:Turnditch")
        #expect(g.match("Windley, Derbyshire").first?.id == "DBY:Windley")
        #expect(g.match("Hognaston, Derbyshire").first?.id == "DBY:Hognaston")
        #expect(g.match("Carsington, Derbyshire").first?.id == "DBY:Carsington")
        #expect(g.match("Wensley, Derbyshire").first?.id == "DBY:Wensley")
        #expect(g.match("Pleasley, Derbyshire").first?.id == "DBY:Pleasley")
        #expect(g.match("Farnsfield, Nottinghamshire").first?.id == "NTT:Farnsfield")
        #expect(g.match("Shireoaks, Nottinghamshire").first?.id == "NTT:Shireoaks")
    }

    // MARK: - Messy stored forms now resolve (the false positives)

    @Test func messyStoredFormsNowResolve() {
        let g = LocationGazetteer.shared
        #expect(g.match("Turnditch, Derbyshire (DBY)").first?.id == "DBY:Turnditch")
        #expect(g.match("Loscoe, Derbyshire, England").first?.id == "DBY:Loscoe")
        #expect(g.match("Bonsall, Derbyshire, England").first?.id == "DBY:Bonsall")
        #expect(g.match("Unstone, Derbyshire, England").first?.id == "DBY:Unstone")
        #expect(g.match("Teversal, Nottinghamshire, England").first?.id == "NTT:Teversal")
        #expect(g.match("Middleton By Wirksworth, Derbyshire, England").first?.id == "DBY:MiddletonByWirksworth")
    }

    @Test func muggingtonSpellingVariantResolves() {
        // Tree spells it "Muggington"; the gazetteer entry is "Mugginton".
        #expect(LocationGazetteer.shared.match("Muggington, Derbyshire, England").first?.id == "DBY:Mugginton")
    }

    // MARK: - No regression on clean/existing forms

    @Test func existingCleanPlacesStillMatch() {
        let g = LocationGazetteer.shared
        #expect(g.match("Belper").first?.id == "DBY:Belper")
        #expect(g.match("Kirk Ireton, Derbyshire").first?.id == "DBY:KirkIreton")
        #expect(g.match("Chesterfield").first?.id == "DBY:Chesterfield")
    }
}
