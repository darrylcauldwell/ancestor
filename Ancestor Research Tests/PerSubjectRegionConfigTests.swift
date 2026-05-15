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
        // Non-DBY codes don't have data yet (will fill in as per-county configs ship).
        // Empty map is honest — callers downgrade local-boosting rather than mis-classify.
        #expect(RegionConfig.districts(forChapmanCode: "LEI").isEmpty)
        #expect(RegionConfig.districts(forChapmanCode: "ZZZ").isEmpty)
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
        // No LEI data, so Belper isn't claimed as local for a Leicestershire subject.
        // Once LEI config lands, this stays correct (Belper is in Derbyshire, not Leicestershire).
        #expect(!ScoringRules.isLocalDistrict("Belper", forHomeChapman: "LEI"))
    }

    @Test func ac1_2_unknownCodeReturnsFalseForAllDistricts() {
        #expect(!ScoringRules.isLocalDistrict("Belper", forHomeChapman: "ZZZ"))
        #expect(!ScoringRules.isLocalDistrict("Leicester", forHomeChapman: "ZZZ"))
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
