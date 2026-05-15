import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_AXES_SPEC.md Change 1 — per-subject RegionConfig.
struct PerSubjectRegionConfigTests {

    // MARK: - AC1.1 — districts(forChapmanCode:) returns the Derbyshire map for "DBY"

    @Test func ac1_1_districtsForDBYReturnsDerbyshireMap() {
        let viaFactory = RegionConfig.districts(forChapmanCode: "DBY")
        let direct = RegionConfig.derbyshire.districts
        #expect(viaFactory == direct)
        // Spot checks — the factory output should include the known core districts.
        #expect(viaFactory["Belper"] == "722")
        #expect(viaFactory["Derby"] == "1016")
    }

    @Test func ac1_1_districtsForUnknownCodeReturnsEmpty() {
        // Truly unknown Chapman codes return empty.
        #expect(RegionConfig.districts(forChapmanCode: "ZZZ").isEmpty)
        #expect(RegionConfig.districts(forChapmanCode: "").isEmpty)
    }

    @Test func ac1_1_districtsForOtherCountiesUsesEnrichedCatalogue() {
        // After the freebmd-districts.json enrichment, every traditional UK
        // historical county that the FreeBMD catalogue covers gets a
        // populated district map via the FreeBMDDistrictCatalogue fallback.
        let leicester = RegionConfig.districts(forChapmanCode: "LEI")
        #expect(!leicester.isEmpty, "LEI should have districts from the enriched catalogue")
        #expect(leicester["Leicester"] != nil, "Leicester town should be a LEI district")

        let kent = RegionConfig.districts(forChapmanCode: "KEN")
        #expect(!kent.isEmpty, "KEN should have districts")
    }

    // MARK: - Parish coverage from the national enrichment

    @Test func wirksworthParishMapsToBelperDistrict() {
        // The user's UX-test case: Wirksworth is a parish in Belper
        // registration district. Reverse lookup must surface a district.
        let district = ScoringRules.districtForParish("Wirksworth", forHomeChapman: "DBY")
        #expect(district != nil)
        // Wirksworth appears in both Belper and Bakewell historically; either
        // is acceptable (it's a boundary parish).
        #expect(district == "Belper" || district == "Bakewell",
                "expected Belper or Bakewell; got \(String(describing: district))")
    }

    @Test func parishesAreAvailableForNonDerbyshireCounties() {
        // Pre-enrichment this returned empty for everywhere except DBY.
        // Now any district in the FreeBMD catalogue with a populated parish
        // list works — spot-check across 3 counties from the scrape data.
        let kent = ScoringRules.parishesInDistrict("Maidstone", forHomeChapman: "KEN")
        #expect(!kent.isEmpty, "Maidstone (KEN) should have parishes")

        let lei = ScoringRules.parishesInDistrict("Market Harborough", forHomeChapman: "LEI")
        #expect(!lei.isEmpty, "Market Harborough (LEI) should have parishes")

        let sts = ScoringRules.parishesInDistrict("Lichfield", forHomeChapman: "STS")
        #expect(!sts.isEmpty, "Lichfield (STS) should have parishes")
    }

    @Test func parishLookupIsCaseInsensitive() {
        let lower = ScoringRules.districtForParish("wirksworth", forHomeChapman: "DBY")
        let upper = ScoringRules.districtForParish("WIRKSWORTH", forHomeChapman: "DBY")
        let mixed = ScoringRules.districtForParish("Wirksworth", forHomeChapman: "DBY")
        #expect(lower != nil)
        #expect(lower == upper)
        #expect(lower == mixed)
    }

    @Test func ac1_1_factoryIsCaseInsensitive() {
        let upper = RegionConfig.districts(forChapmanCode: "DBY")
        let lower = RegionConfig.districts(forChapmanCode: "dby")
        let mixed = RegionConfig.districts(forChapmanCode: "Dby")
        #expect(upper == lower)
        #expect(upper == mixed)
    }

    // MARK: - AC1.2 — isLocalDistrict parameterised by home Chapman code
    //
    // Note: full LEI/Leicester coverage requires per-county data that will land
    // as RegionConfig configs are populated. These tests cover the parameterisation
    // mechanics — same input gives different output based on home code.

    @Test func ac1_2_belperIsLocalForDBYHome() {
        #expect(ScoringRules.isLocalDistrict("Belper", forHomeChapman: "DBY"))
    }

    @Test func ac1_2_belperIsNotLocalForLEIHome() {
        // Belper is in Derbyshire, not Leicestershire — must return false
        // even though LEI now has its own populated district set via the
        // enriched catalogue.
        #expect(!ScoringRules.isLocalDistrict("Belper", forHomeChapman: "LEI"))
    }

    @Test func ac1_2_leicesterIsLocalForLEIHome() {
        // Spec AC1.2 satisfied in full now — LEI subject sees Leicester as local
        // (previously this assertion was gated on per-county data not yet shipping).
        #expect(ScoringRules.isLocalDistrict("Leicester", forHomeChapman: "LEI"))
        #expect(ScoringRules.isLocalDistrict("LEICESTER", forHomeChapman: "LEI"),
                "case-insensitive lookup must apply to catalogue path too")
    }

    @Test func ac1_2_leicesterIsNotLocalForDBYHome() {
        // Leicester is in Leicestershire, not Derbyshire.
        #expect(!ScoringRules.isLocalDistrict("Leicester", forHomeChapman: "DBY"))
    }

    @Test func ac1_2_unknownCodeReturnsFalseForAllDistricts() {
        #expect(!ScoringRules.isLocalDistrict("Belper", forHomeChapman: "ZZZ"))
        #expect(!ScoringRules.isLocalDistrict("Leicester", forHomeChapman: "ZZZ"))
    }

    // MARK: - District lookup must be case-insensitive
    //
    // Regression: FreeBMD parses district names as uppercase ("BELPER")
    // and stores them as-is. RegionConfig's districtParishes dict keys are
    // title case ("Belper"). A case-sensitive lookup silently returned nil,
    // and the geography gate dropped to `softFail("unknown district: BELPER")`
    // — turning what should be a confirmed birth record into a "weak lead",
    // which made downstream parent-inference weak too. Surfaced 2026-05 in
    // manual UX testing.

    @Test func districtLookupIsCaseInsensitive() {
        let config = RegionConfig.derbyshire
        // The stored key is "Belper"; lookups must succeed regardless of case.
        #expect(config.isLocalDistrict("Belper"))
        #expect(config.isLocalDistrict("BELPER"))
        #expect(config.isLocalDistrict("belper"))
        #expect(config.isLocalDistrict("  Belper  "))
        #expect(config.isLocalDistrict("Belper district"))
        #expect(config.isLocalDistrict("BELPER DISTRICT"))
    }

    @Test func scoringRulesLocalDistrictIsCaseInsensitiveViaForHomeChapman() {
        // Same bug surface, through the parameterised scoring helper that
        // RecordScorer.checkGeography actually calls.
        #expect(ScoringRules.isLocalDistrict("BELPER", forHomeChapman: "DBY"))
        #expect(ScoringRules.isLocalDistrict("Belper", forHomeChapman: "DBY"))
    }

    @Test func ac1_2_nonLocalLookupIsHomeCountyAware() {
        // Manchester is in nonLocalDistricts for DBY — Chorlton maps to Manchester.
        #expect(ScoringRules.isNonLocal("Chorlton", forHomeChapman: "DBY") == "Manchester")
        // No LEI data so the lookup returns nil — honest "I don't know" rather than
        // borrowing Derbyshire's non-local list.
        #expect(ScoringRules.isNonLocal("Chorlton", forHomeChapman: "LEI") == nil)
    }

    // MARK: - AC1.3 — Project.homeChapmanCode + resolvedHomeChapmanCode fallback

    @Test func ac1_3_legacyProjectResolvesToDBY() {
        let legacy = Project(
            id: UUID(),
            name: "Test",
            source: .manual,
            homePersonID: nil,
            createdAt: Date(),
            lastRefreshed: nil,
            archivedAt: nil,
            homeChapmanCode: nil
        )
        #expect(legacy.resolvedHomeChapmanCode == "DBY")
    }

    @Test func ac1_3_projectWithExplicitCodeResolvesToThatCode() {
        let project = Project(
            id: UUID(),
            name: "Test",
            source: .manual,
            homePersonID: nil,
            createdAt: Date(),
            lastRefreshed: nil,
            archivedAt: nil,
            homeChapmanCode: "LEI"
        )
        #expect(project.resolvedHomeChapmanCode == "LEI")
    }

    // MARK: - AC1.4 partial — ResearchSubject carries the home Chapman code through to scorers
    //
    // Full integration (synthetic Leicestershire project end-to-end) requires per-county
    // data; tested here at the subject-construction layer.

    @Test func ac1_4_researchSubjectDefaultsToDBY() {
        let subject = ResearchSubject(
            profileID: nil,
            surname: "Test",
            givenName: "T",
            birthYearFrom: 1900,
            birthYearTo: 1900,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: nil,
            region: nil,
            mode: .extend,
            familyContext: nil
        )
        #expect(subject.homeChapmanCode == "DBY")
    }

    @Test func ac1_4_researchSubjectThreadsHomeCodeFromCaller() {
        let subject = ResearchSubject(
            profileID: nil,
            surname: "Test",
            givenName: "T",
            birthYearFrom: 1900,
            birthYearTo: 1900,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: nil,
            region: nil,
            mode: .extend,
            familyContext: nil,
            homeChapmanCode: "LEI"
        )
        #expect(subject.homeChapmanCode == "LEI")
    }
}
