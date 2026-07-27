import Testing
import Foundation
@testable import Ancestor_Research

/// PlaceResolver — Stage 2 of the location-model pass: the free-text →
/// PlaceAuthority-id primitive the rebuilt geography gate will compose with.
/// Reads only the bundled gazetteer/registry (no UserDefaults), so it's
/// unaffected by the source-enablement isolation work.
struct PlaceResolverTests {

    // MARK: - resolve(placeText:)

    @Test func resolvesCleanPlaceToItsGazetteerID() {
        #expect(PlaceResolver.resolve(placeText: "Turnditch, Derbyshire") == "DBY:Turnditch")
        #expect(PlaceResolver.resolve(placeText: "Belper") == "DBY:Belper")
    }

    @Test func resolvesMessyStoredFormsViaNormalisation() {
        // Trailing country / Chapman noise is stripped by the matcher.
        #expect(PlaceResolver.resolve(placeText: "Loscoe, Derbyshire, England") == "DBY:Loscoe")
        #expect(PlaceResolver.resolve(placeText: "Turnditch, Derbyshire (DBY)") == "DBY:Turnditch")
    }

    @Test func resolvesBareCountyDespiteSubstringNoise() {
        // Every "…, Derbyshire" place contains "derbyshire", but the exact
        // county-name hit wins → the county node, not a random town.
        #expect(PlaceResolver.resolve(placeText: "Derbyshire") == "DBY")
        #expect(PlaceResolver.resolve(placeText: "Nottinghamshire") == "NTT")
    }

    @Test func exactNameWinsOverSubstringSiblings() {
        // "Chesterfield" resolves to itself even though it shares "…field"
        // with Dronfield / Farnsfield etc.
        #expect(PlaceResolver.resolve(placeText: "Chesterfield") == "DBY:Chesterfield")
    }

    @Test func declinesOnAmbiguityAndUnknown() {
        // A bare substring matching several places but naming none exactly →
        // decline rather than guess.
        #expect(PlaceResolver.resolve(placeText: "field") == nil)
        // Unknown / empty.
        #expect(PlaceResolver.resolve(placeText: "Nowhere, Atlantis") == nil)
        #expect(PlaceResolver.resolve(placeText: "") == nil)
        #expect(PlaceResolver.resolve(placeText: "   ") == nil)
    }

    // MARK: - resolveDistrict(name:)

    @Test func resolvesRegistrationDistrictName() {
        let id = PlaceResolver.resolveDistrict(name: "Belper", chapman: "DBY")
        #expect(id == "DBY:Belper-RD")
    }

    @Test func declinesUnknownDistrict() {
        #expect(PlaceResolver.resolveDistrict(name: "Nowhere-upon-Sea", chapman: "DBY") == nil)
    }
}
