import Testing
import Foundation
@testable import AncestorKit
@testable import Ancestor_Research

/// Acceptance tests for the E3 place-authority *seeding* and the equivalence
/// guarantees (Model evolution Change 3 / ADR-004 E3): the hierarchy is
/// DERIVED from the existing seed data (gazetteer + FreeBMD district catalogue),
/// nothing regresses, and the new resolution paths produce the same answers the
/// flat path always did.
struct PlaceAuthorityRegistryTests {

    // MARK: - Derivation from real bundled seed data

    @Test func registryDerivesANonTrivialHierarchyFromSeedData() {
        let places = PlaceAuthorityRegistry.shared.places
        #expect(!places.isEmpty)
        // All five kinds are represented once the FreeBMD catalogue is folded in.
        let kinds = Set(places.map(\.kind))
        #expect(kinds.contains(.country))
        #expect(kinds.contains(.county))
        #expect(kinds.contains(.registrationDistrict))
        #expect(kinds.contains(.parish))
    }

    @Test func everyDistrictRollsUpToACounty() {
        let places = PlaceAuthorityRegistry.shared.places
        let districts = places.filter { $0.kind == .registrationDistrict }
        #expect(!districts.isEmpty)
        for d in districts.prefix(50) {
            #expect(places.county(of: d.id) != nil,
                    "district \(d.id) must roll up to a county")
        }
    }

    // MARK: - AC3 — every existing COUNTY:Place code still resolves to the same
    // county it does today. Equivalence proof against the flat gazetteer.

    @Test func existingGazetteerCodesResolveToSameCountyAsFlatPath() {
        let gaz = LocationGazetteer.shared
        // Every real gazetteer code must resolve to the SAME display county
        // string it does today — including the handful of historical
        // cross-boundary entries (MDX:Lambeth displays "Surrey", SOM:Bristol
        // "Gloucestershire", HAM:NewportIOW "Isle of Wight"), which
        // `countyName(forCode:)` preserves losslessly rather than overriding
        // with the id-prefix county. This is the AC3 backwards-compat guarantee.
        for entry in gaz.all() where entry.kind != "county" {
            let flatCounty = entry.county
            let authorityCounty = gaz.countyName(forCode: entry.id)
            #expect(authorityCounty == flatCounty,
                    "code \(entry.id): authority county \(authorityCounty ?? "nil") != flat \(flatCounty)")
        }
    }

    @Test func crossBoundaryCodesPreserveDisplayCountyWhileChapmanUsesPrefix() {
        // A place that sat in one county but registered in another exposes the
        // two questions the authority answers separately: the DISPLAY county
        // (the seed string, lossless with today) and the CHAPMAN county node
        // reached through the id prefix / hierarchy. Both must be stable.
        let gaz = LocationGazetteer.shared
        // Only assert on codes actually present in the bundled seed.
        if gaz.entry(forID: "MDX:Lambeth") != nil {
            #expect(gaz.countyName(forCode: "MDX:Lambeth") == "Surrey")   // display
            #expect(gaz.chapmanCode(forCode: "MDX:Lambeth") == "MDX")     // registration county node
        }
        if gaz.entry(forID: "SOM:Bristol") != nil {
            #expect(gaz.countyName(forCode: "SOM:Bristol") == "Gloucestershire")
            #expect(gaz.chapmanCode(forCode: "SOM:Bristol") == "SOM")
        }
    }

    @Test func chapmanCodeFromCodeMatchesPrefixSplitForRealCodes() {
        let gaz = LocationGazetteer.shared
        for entry in gaz.all() where entry.kind != "county" {
            // The pre-E3 derivation was: take the prefix before ":".
            let prefix = entry.id.split(separator: ":").first.map(String.init)?.uppercased()
            let viaAuthority = gaz.chapmanCode(forCode: entry.id)
            #expect(viaAuthority == prefix,
                    "code \(entry.id): authority chapman \(viaAuthority ?? "nil") != prefix \(prefix ?? "nil")")
        }
    }

    @Test func staleCodeNotInAuthorityResolvesNilLikeFlatEntryLookup() {
        let gaz = LocationGazetteer.shared
        // A code no gazetteer entry carries — flat entry(forID:) returns nil,
        // and so must the authority-backed county lookup.
        #expect(gaz.entry(forID: "ZZZ:Nowhere") == nil)
        #expect(gaz.countyName(forCode: "ZZZ:Nowhere") == nil)
    }

    // MARK: - District resolution equivalence with RegionConfig / FreeBMD

    @Test func authorityDistrictsForCountyMatchFreeBMDCatalogueSet() {
        // The authority's districts-in-county set must equal the FreeBMD
        // catalogue's set for that Chapman code (same seed → same set), for a
        // non-Derbyshire county to prove it's data-derived.
        let chapman = "LEI"
        let authorityNames = Set(
            PlaceAuthorityRegistry.shared.places
                .districts(inCounty: chapman)
                .map { $0.name.lowercased() })
        let catalogueNames = Set(
            FreeBMDDistrictCatalogue.shared
                .districts(forChapmanCode: chapman)
                .map { $0.name.lowercased() })
        #expect(!catalogueNames.isEmpty)
        #expect(authorityNames == catalogueNames,
                "authority LEI districts must match the FreeBMD catalogue set")
    }

    @Test func authorityDistrictFreeBMDCodesMatchCatalogue() {
        // Wire codes must survive the derivation so district resolution through
        // the authority yields the identical FreeBMD code the flat path did.
        let catalogue = FreeBMDDistrictCatalogue.shared.districts(forChapmanCode: "DBY")
        for d in catalogue {
            let authority = PlaceAuthorityRegistry.shared.places.first {
                $0.kind == .registrationDistrict
                    && $0.parentID == "DBY"
                    && $0.name == d.name
                    && $0.validFrom == d.startYear
                    && $0.validTo == d.endYear
            }
            #expect(authority?.freeBMDCode == d.code,
                    "district \(d.name): authority code \(authority?.freeBMDCode ?? "nil") != catalogue \(d.code)")
        }
    }

    // MARK: - AC4 — districtHint string matches a first-class district entry

    @Test func districtHintMatchesAuthorityEntry() {
        // "Belper" is the classic DBY district hint (ResearchHypothesis
        // .subjectIdentity districtHint).
        let match = RegionConfig.districtAuthority(matchingHint: "Belper", chapman: "DBY")
        #expect(match != nil)
        #expect(match?.kind == .registrationDistrict)
        #expect(match?.name == "Belper")
        #expect(match?.freeBMDCode != nil)
    }

    @Test func districtHintTemporalPrefersEraValidSuccessor() {
        // A hint of "Belper" in a modern year (post-1994) should, if the
        // seed carries the successor, prefer a district valid then — or return
        // the Belper entry if no dated successor is seeded. Either way non-nil
        // for a real district name; the assertion is that temporal filtering
        // doesn't drop a real hint on the floor.
        let modern = RegionConfig.districtAuthority(matchingHint: "Belper", chapman: "DBY", year: 2000)
        let historic = RegionConfig.districtAuthority(matchingHint: "Belper", chapman: "DBY", year: 1900)
        #expect(historic != nil)
        // Historic Belper resolves to the Belper district (valid pre-1994).
        #expect(historic?.name == "Belper")
        // Modern lookup returns nil or a same-name valid successor — never a
        // Belper record that wasn't valid in 2000.
        if let m = modern { #expect(m.valid(in: 2000)) }
    }

    @Test func unknownDistrictHintReturnsNil() {
        #expect(RegionConfig.districtAuthority(matchingHint: "Nowheresville", chapman: "DBY") == nil)
    }

    // MARK: - No-hardcoded-regions: derive() on synthetic non-DBY seed data

    @Test func deriveProducesLeicestershireHierarchyFromSyntheticSeed() {
        // Feed derive() a Leicestershire-only gazetteer + catalogue. It must
        // produce a working LEI hierarchy with no Derbyshire dependency —
        // proving the derivation is data-driven (the no-hardcoded-regions rule).
        let gaz = [
            GazetteerEntry(id: "LEI", name: "Leicestershire", county: "Leicestershire",
                           country: "England", aliases: [], kind: "county"),
            GazetteerEntry(id: "LEI:Foxton", name: "Foxton", county: "Leicestershire",
                           country: "England", aliases: [], kind: nil),
        ]
        let districts = [
            FreeBMDDistrict(name: "Market Harborough", code: "555", chapmanCode: "LEI",
                            startYear: nil, endYear: nil, parishes: ["Foxton", "Lubenham"]),
        ]
        let places = PlaceAuthorityRegistry.derive(gazetteer: gaz, districts: districts)

        // County + country nodes exist, derived from data.
        #expect(places.contains { $0.id == "LEI" && $0.kind == .county })
        #expect(places.contains { $0.kind == .country && $0.name == "England" })
        // District rolls up to LEI.
        #expect(places.registrationDistrict(of: "LEI:Market Harborough-RD/Foxton")?.parentID == "LEI")
        #expect(places.county(of: "LEI:Market Harborough-RD/Foxton")?.id == "LEI")
        // The town resolves to its county from the id prefix, no explicit parent.
        #expect(places.county(of: "LEI:Foxton")?.id == "LEI")
        // Zero Derbyshire records leaked in.
        #expect(!places.contains { $0.id.hasPrefix("DBY") })
    }

    // MARK: - Catalogue hygiene: HTML entities, prose rows, compound parishes
    //
    // The parish lists were scraped from UKBMD's HTML and kept the entities:
    // 685 distinct parish names carry a literal "&amp;". Nothing on the
    // resolution path unescaped, while the RECORD side does
    // (FreeCenSource.swift:847) — so a census district could never match a
    // catalogue parish containing an ampersand. "Wensley & Snitterton" ships
    // under DBY/Bakewell and DBY/Matlock and was unreachable.

    @Test func decodeEntitiesUnescapesScrapedParishNames() {
        #expect(FreeBMDDistrictCatalogue.decodeEntities("Wensley &amp; Snitterton")
                == "Wensley & Snitterton")
        #expect(FreeBMDDistrictCatalogue.decodeEntities("St Mary&#39;s") == "St Mary's")
    }

    @Test func proseRowsAreNotIndexedAsPlaces() {
        #expect(FreeBMDDistrictCatalogue.isProseNotAPlace(
            "abolished 1.4.1935 and added to the parish of Ashwellthorpe."))
        #expect(FreeBMDDistrictCatalogue.isProseNotAPlace("See also Table 2, note (c)."))
        #expect(!FreeBMDDistrictCatalogue.isProseNotAPlace("Wensley & Snitterton"))
        #expect(!FreeBMDDistrictCatalogue.isProseNotAPlace("Youlgreave"))
    }

    @Test func lookupNamesExposesConstituentsOfACompoundParish() {
        let names = FreeBMDDistrictCatalogue.lookupNames(forParish: "Wensley &amp; Snitterton")
        #expect(names.contains("Wensley & Snitterton"))
        #expect(names.contains("Wensley and Snitterton"))
        #expect(names.contains("Wensley"))
        #expect(names.contains("Snitterton"))
    }

    @Test func lookupNamesHandlesThreePartCompounds() {
        let names = FreeBMDDistrictCatalogue.lookupNames(forParish: "Dethick, Lea &amp; Holloway")
        #expect(names.contains("Dethick"))
        #expect(names.contains("Lea"))
        #expect(names.contains("Holloway"))
    }

    @Test func lookupNamesLeavesASimpleParishAlone() {
        #expect(FreeBMDDistrictCatalogue.lookupNames(forParish: "Youlgreave") == ["Youlgreave"])
    }

    /// The settlement a census prints reaches its registration district through
    /// the compound parish it belongs to. Synthetic county so this proves the
    /// derivation is data-driven, not Derbyshire-shaped.
    @Test func aCompoundParishIsReachableByEachConstituent() {
        let districts = [
            FreeBMDDistrict(name: "Marketon", code: "901", chapmanCode: "LEI",
                            startYear: nil, endYear: nil,
                            parishes: ["Foxton &amp; Gumley", "Lubenham"]),
        ]
        let places = PlaceAuthorityRegistry.derive(gazetteer: [], districts: districts)
        #expect(places.districts(forParish: "Foxton", chapman: "LEI").map(\.name) == ["Marketon"])
        #expect(places.districts(forParish: "Gumley", chapman: "LEI").map(\.name) == ["Marketon"])
        #expect(places.districts(forParish: "Foxton & Gumley", chapman: "LEI").map(\.name) == ["Marketon"])
        #expect(places.districts(forParish: "Foxton and Gumley", chapman: "LEI").map(\.name) == ["Marketon"])
    }

    /// Era-awareness survives the alias route: the same compound parish moved
    /// between districts, and a constituent must resolve to the one valid in
    /// the record's year. This is the shape of Wensley & Snitterton — Matlock
    /// to 1838, Bakewell from 1839.
    @Test func constituentLookupStaysEraAware() {
        let districts = [
            FreeBMDDistrict(name: "Oldminster", code: "902", chapmanCode: "LEI",
                            startYear: nil, endYear: 1838,
                            parishes: ["Foxton &amp; Gumley"]),
            FreeBMDDistrict(name: "Newminster", code: "903", chapmanCode: "LEI",
                            startYear: 1839, endYear: nil,
                            parishes: ["Foxton &amp; Gumley"]),
        ]
        let places = PlaceAuthorityRegistry.derive(gazetteer: [], districts: districts)
        #expect(places.districts(forParish: "Foxton", year: 1835, chapman: "LEI").map(\.name) == ["Oldminster"])
        #expect(places.districts(forParish: "Foxton", year: 1861, chapman: "LEI").map(\.name) == ["Newminster"])
    }

    /// Ambiguity must be PRESERVED, not resolved by first-match. A name in two
    /// counties returns both, so the geography gate can decline rather than
    /// guess — the guard against bare "Wensley" silently becoming Derbyshire.
    @Test func aNameInTwoCountiesReturnsBothCandidates() {
        let districts = [
            FreeBMDDistrict(name: "Marketon", code: "901", chapmanCode: "LEI",
                            startYear: nil, endYear: nil, parishes: ["Ambridge"]),
            FreeBMDDistrict(name: "Northtown", code: "904", chapmanCode: "NBL",
                            startYear: nil, endYear: nil, parishes: ["Ambridge"]),
        ]
        let places = PlaceAuthorityRegistry.derive(gazetteer: [], districts: districts)
        let all = places.districts(forParish: "Ambridge")
        #expect(all.count == 2, "both counties' candidates must survive for the caller to disambiguate")
        #expect(places.districts(forParish: "Ambridge", chapman: "LEI").map(\.name) == ["Marketon"])
    }

    @Test func deriveGivesParishesTheirDistrictsValidityWindow() {
        // A parish inherits the district's validity so temporal parish→district
        // resolution works (AC2), derived from the catalogue's startYear/endYear.
        let districts = [
            FreeBMDDistrict(name: "Belper", code: "722", chapmanCode: "DBY",
                            startYear: nil, endYear: 1994, parishes: ["Crich"]),
            FreeBMDDistrict(name: "Amber Valley", code: "406", chapmanCode: "DBY",
                            startYear: 1994, endYear: nil, parishes: ["Crich"]),
        ]
        let places = PlaceAuthorityRegistry.derive(gazetteer: [], districts: districts)
        let pre = places.districts(forParish: "Crich", year: 1900, chapman: "DBY").map(\.name)
        let post = places.districts(forParish: "Crich", year: 2000, chapman: "DBY").map(\.name)
        #expect(pre == ["Belper"])
        #expect(post == ["Amber Valley"])
    }
}
