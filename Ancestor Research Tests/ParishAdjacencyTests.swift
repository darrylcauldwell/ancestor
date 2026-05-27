import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 8 — parish-level geography tolerance.
/// Two concerns:
///   1. `isLocalParish`: census records citing parish-level birthplaces
///      like "Windley" should pass the geography gate even though the
///      string doesn't contain "Derbyshire" verbatim — Windley → Belper
///      district → DBY local.
///   2. `parishesShareLocalDistrict`: cross-census birthplace drift
///      (Mugginton vs Windley) should be treated as tolerable when the
///      parishes resolve to the same local district. Mirrors Python
///      `census_birthplace_reliability` concern.
@MainActor
struct ParishAdjacencyTests {

    // MARK: - isLocalParish

    @Test func isLocalParish_recognisesBelperDistrictParish() {
        // Windley is a Derbyshire parish in Belper district. Without the
        // parish lookup, the gate's "contains 'derby'" substring check
        // misses it and soft-fails the record.
        #expect(ScoringRules.isLocalParish("Windley", forHomeChapman: "DBY"))
    }

    @Test func isLocalParish_recognisesMugginton() {
        // Mugginton is listed in RegionConfig's Belper district parishes
        // (the canonical "1871 Mugginton" census-drift example).
        #expect(ScoringRules.isLocalParish("Mugginton", forHomeChapman: "DBY"))
    }

    @Test func isLocalParish_missingParishFlagsCatalogueGap() {
        // Bolehill IS a Derbyshire hamlet (near Wirksworth — Ida Louisa
        // Land grew up there) but isn't yet in the RegionConfig parish
        // catalogue. This test pins the gap so we know what catalogue
        // entries to add when we curate the next batch. When Bolehill
        // is added to RegionConfig.swift's Wirksworth-district list,
        // flip the assertion to expect true.
        #expect(!ScoringRules.isLocalParish("Bolehill", forHomeChapman: "DBY"),
                "Bolehill not yet catalogued — flag for region-config curation. Flip when added.")
    }

    @Test func isLocalParish_rejectsUnknownParish() {
        // A parish that doesn't appear in any local district's catalogue
        // shouldn't be classified as local.
        #expect(!ScoringRules.isLocalParish("Atlantis", forHomeChapman: "DBY"))
    }

    @Test func isLocalParish_caseInsensitive() {
        #expect(ScoringRules.isLocalParish("windley", forHomeChapman: "DBY"))
        #expect(ScoringRules.isLocalParish("WINDLEY", forHomeChapman: "DBY"))
    }

    // MARK: - parishesShareLocalDistrict (adjacent-parish tolerance)

    @Test func parishesShareLocalDistrict_sameParishIsTriviallyAdjacent() {
        #expect(ScoringRules.parishesShareLocalDistrict(
            "Windley", "Windley", forHomeChapman: "DBY"
        ))
    }

    @Test func parishesShareLocalDistrict_sameDistrictNeighbours() {
        // Mugginton and Windley both fall under Belper district →
        // treated as adjacent. The Python-noted Victorian census-drift
        // case ("1871: Mugginton, 1881: Windley") no longer reads as a
        // contradiction.
        #expect(ScoringRules.parishesShareLocalDistrict(
            "Mugginton", "Windley", forHomeChapman: "DBY"
        ))
    }

    @Test func parishesShareLocalDistrict_caseInsensitive() {
        #expect(ScoringRules.parishesShareLocalDistrict(
            "mugginton", "WINDLEY", forHomeChapman: "DBY"
        ))
    }

    @Test func parishesShareLocalDistrict_rejectsUnknownParish() {
        // An unknown parish can't be claimed adjacent to anything —
        // false rather than throwing.
        #expect(!ScoringRules.parishesShareLocalDistrict(
            "Atlantis", "Windley", forHomeChapman: "DBY"
        ))
    }

    @Test func parishesShareLocalDistrict_rejectsEmptyInput() {
        #expect(!ScoringRules.parishesShareLocalDistrict(
            "", "Windley", forHomeChapman: "DBY"
        ))
        #expect(!ScoringRules.parishesShareLocalDistrict(
            "Windley", "", forHomeChapman: "DBY"
        ))
    }
}
