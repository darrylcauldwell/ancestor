import Testing
import Foundation
@testable import AncestorKit

/// Unit tests for the E3 place-authority record type and its hierarchy +
/// temporal-validity resolution (MODEL_EVOLUTION_SPEC §Change3 / ADR-004 E3).
/// Pure value-type logic — no database, no bundle, no seed loading (the
/// registry-derived hierarchy and the migration are pinned in
/// `PlaceAuthorityRegistryTests` and `MigrationV36PlaceAuthorityTests`).
///
/// The fixture is a deliberately non-Derbyshire hierarchy for one test and a
/// small Derbyshire-shaped one for the boundary-year test — proving the
/// resolution logic is data-driven, not region-baked.
struct PlaceAuthorityTests {

    // A minimal, hand-built hierarchy: England → DBY → Belper-RD → {Crich,
    // Windley}, plus a successor district (Amber Valley, from 1994) that Crich
    // moved into. This is exactly the "one place, two dated district records"
    // shape the spec's schema sketch allows.
    private func derbyshireFixture() -> [PlaceAuthority] {
        [
            PlaceAuthority(id: "England", name: "England", kind: .country),
            PlaceAuthority(id: "DBY", name: "Derbyshire", kind: .county,
                           parentID: "England", county: "Derbyshire", country: "England"),
            // Belper RD: valid to 1994.
            PlaceAuthority(id: "DBY:Belper-RD", name: "Belper", kind: .registrationDistrict,
                           parentID: "DBY", validFrom: nil, validTo: 1994, freeBMDCode: "722"),
            // Amber Valley RD: valid from 1994 (successor to Belper).
            PlaceAuthority(id: "DBY:Amber Valley-RD", name: "Amber Valley", kind: .registrationDistrict,
                           parentID: "DBY", validFrom: 1994, validTo: nil, freeBMDCode: "406"),
            // Crich: a parish under Belper (to 1994), then Amber Valley (from 1994).
            PlaceAuthority(id: "DBY:Belper-RD/Crich", name: "Crich", kind: .parish,
                           parentID: "DBY:Belper-RD", validFrom: nil, validTo: 1994),
            PlaceAuthority(id: "DBY:Amber Valley-RD/Crich", name: "Crich", kind: .parish,
                           parentID: "DBY:Amber Valley-RD", validFrom: 1994, validTo: nil),
            // Windley: only ever under Belper.
            PlaceAuthority(id: "DBY:Belper-RD/Windley", name: "Windley", kind: .parish,
                           parentID: "DBY:Belper-RD"),
            // A town entry (place kind) rolling straight up to the county.
            PlaceAuthority(id: "DBY:Buxton", name: "Buxton", kind: .place,
                           parentID: "DBY", county: "Derbyshire", country: "England"),
        ]
    }

    // MARK: - AC1/AC2 — hierarchy roll-up: parish → district → county → country

    @Test func parishRollsUpToDistrictThenCountyThenCountry() {
        let h = derbyshireFixture()
        // Windley parish → Belper district → DBY county → England country.
        #expect(h.registrationDistrict(of: "DBY:Belper-RD/Windley")?.id == "DBY:Belper-RD")
        #expect(h.county(of: "DBY:Belper-RD/Windley")?.id == "DBY")
        #expect(h.country(of: "DBY:Belper-RD/Windley")?.id == "England")
    }

    @Test func ancestorsChainIsOrderedParentFirst() {
        let h = derbyshireFixture()
        let chain = h.ancestors(of: "DBY:Belper-RD/Windley").map(\.id)
        #expect(chain == ["DBY:Belper-RD", "DBY", "England"])
    }

    @Test func townRollsUpToCounty() {
        let h = derbyshireFixture()
        #expect(h.county(of: "DBY:Buxton")?.id == "DBY")
        // A town has no registration-district ancestor — honestly nil.
        #expect(h.registrationDistrict(of: "DBY:Buxton") == nil)
    }

    @Test func districtChildrenAreItsParishes() {
        let h = derbyshireFixture()
        let names = Set(h.parishes(inDistrict: "DBY:Belper-RD").map(\.name))
        #expect(names == ["Crich", "Windley"])
    }

    // MARK: - AC2 — temporal validity: same parish resolves differently either
    // side of the boundary year.

    @Test func parishResolvesToDifferentDistrictEitherSideOfBoundary() {
        let h = derbyshireFixture()
        // Before 1994: Crich registers in Belper.
        let pre = h.districts(forParish: "Crich", year: 1900, chapman: "DBY")
        #expect(pre.map(\.name) == ["Belper"])
        // After 1994: Crich registers in Amber Valley.
        let post = h.districts(forParish: "Crich", year: 2000, chapman: "DBY")
        #expect(post.map(\.name) == ["Amber Valley"])
    }

    @Test func districtValidityGatesTemporalLookup() {
        let h = derbyshireFixture()
        // Belper valid through 1994.
        #expect(h.place(id: "DBY:Belper-RD")?.valid(in: 1900) == true)
        #expect(h.place(id: "DBY:Belper-RD")?.valid(in: 2000) == false)
        // Amber Valley valid from 1994.
        #expect(h.place(id: "DBY:Amber Valley-RD")?.valid(in: 1900) == false)
        #expect(h.place(id: "DBY:Amber Valley-RD")?.valid(in: 2000) == true)
    }

    @Test func parishLookupWithoutYearReturnsAllMatchingDistricts() {
        let h = derbyshireFixture()
        // No year → both the Belper and Amber Valley Crich records surface.
        let all = Set(h.districts(forParish: "Crich", chapman: "DBY").map(\.name))
        #expect(all == ["Belper", "Amber Valley"])
    }

    @Test func unboundedValidityIsAlwaysValid() {
        // A place with nil/nil bounds (the common stable case) is valid in any year.
        let p = PlaceAuthority(id: "DBY", name: "Derbyshire", kind: .county)
        #expect(p.valid(in: 1600))
        #expect(p.valid(in: 2100))
        #expect(p.overlaps(years: 1837...1974))
    }

    // MARK: - AC4 — districtHint string matches a district entry

    @Test func districtNamedMatchesCaseAndSuffixInsensitively() {
        let h = derbyshireFixture()
        #expect(h.district(named: "Belper")?.id == "DBY:Belper-RD")
        #expect(h.district(named: "BELPER")?.id == "DBY:Belper-RD")
        #expect(h.district(named: "Belper District")?.id == "DBY:Belper-RD")
        #expect(h.district(named: "belper rd")?.id == "DBY:Belper-RD")
    }

    @Test func districtNamedScopedByChapmanDisambiguates() {
        // Two districts of the same name in different counties: chapman scoping
        // picks the right one. (Ashford exists in KEN and DBY.)
        let h: [PlaceAuthority] = [
            PlaceAuthority(id: "KEN:Ashford-RD", name: "Ashford", kind: .registrationDistrict, parentID: "KEN"),
            PlaceAuthority(id: "DBY:Ashford-RD", name: "Ashford", kind: .registrationDistrict, parentID: "DBY"),
        ]
        #expect(h.district(named: "Ashford", chapman: "KEN")?.id == "KEN:Ashford-RD")
        #expect(h.district(named: "Ashford", chapman: "DBY")?.id == "DBY:Ashford-RD")
    }

    // MARK: - No-hardcoded-regions: a non-Derbyshire hierarchy resolves the same

    @Test func nonDerbyshireHierarchyResolvesFromDataAlone() {
        // A Leicestershire-only hierarchy — zero Derbyshire records. The
        // resolution logic must roll parish → district → county with no DBY
        // literal anywhere (feedback_no_hardcoded_regions).
        let lei: [PlaceAuthority] = [
            PlaceAuthority(id: "England", name: "England", kind: .country),
            PlaceAuthority(id: "LEI", name: "Leicestershire", kind: .county,
                           parentID: "England", county: "Leicestershire", country: "England"),
            PlaceAuthority(id: "LEI:Market Harborough-RD", name: "Market Harborough",
                           kind: .registrationDistrict, parentID: "LEI", freeBMDCode: "999"),
            PlaceAuthority(id: "LEI:Market Harborough-RD/Foxton", name: "Foxton",
                           kind: .parish, parentID: "LEI:Market Harborough-RD"),
        ]
        #expect(lei.county(of: "LEI:Market Harborough-RD/Foxton")?.id == "LEI")
        #expect(lei.registrationDistrict(of: "LEI:Market Harborough-RD/Foxton")?.name == "Market Harborough")
        #expect(lei.districts(forParish: "Foxton", chapman: "LEI").map(\.name) == ["Market Harborough"])
        #expect(lei.districts(inCounty: "LEI").map(\.freeBMDCode) == ["999"])
    }

    // MARK: - Guards

    @Test func unknownIDResolvesToNilNotCrash() {
        let h = derbyshireFixture()
        #expect(h.county(of: "ZZZ:Nowhere") == nil)
        #expect(h.ancestors(of: "ZZZ:Nowhere").isEmpty)
        #expect(h.registrationDistrict(of: "ZZZ:Nowhere") == nil)
    }

    @Test func cyclicParentLinksDoNotSpin() {
        // Corrupt data: A → B → A. The bounded walk must terminate.
        let cyclic: [PlaceAuthority] = [
            PlaceAuthority(id: "A", name: "A", kind: .place, parentID: "B"),
            PlaceAuthority(id: "B", name: "B", kind: .place, parentID: "A"),
        ]
        let chain = cyclic.ancestors(of: "A")
        #expect(chain.count <= 2) // terminates, doesn't hang
    }

    // MARK: - Codable round-trip (sidecar durability)

    @Test func placeAuthorityRoundTripsThroughCodable() throws {
        let original = PlaceAuthority(
            id: "DBY:Belper-RD", name: "Belper", kind: .registrationDistrict,
            parentID: "DBY", validFrom: 1837, validTo: 1994,
            county: "Derbyshire", country: "England",
            aliases: ["Belper RD"], freeBMDCode: "722")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaceAuthority.self, from: data)
        #expect(decoded == original)
    }
}
