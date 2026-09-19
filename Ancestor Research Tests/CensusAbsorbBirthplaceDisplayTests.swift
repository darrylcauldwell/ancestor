import Testing
import Foundation
@testable import Ancestor_Research

/// The census-absorb capsule surfaces the subject's own census birthplace so a
/// namesake household (a target row born elsewhere than the profile records) is
/// caught before its parents are grafted on (owner dogfood 2026-08-07: George
/// Ward's "Add 3 family members" would have adopted a Derby-born household onto
/// an Ashbourne man). These cover the town-key comparison that decides whether
/// the profile's recorded birthplace is shown beside the census one.
struct CensusAbsorbBirthplaceDisplayTests {

    // MARK: - placeTownKey

    @Test func townKeyDropsCountyTail() {
        #expect(AppState.placeTownKey("Ashbourne, Derbyshire") == "ashbourne")
        #expect(AppState.placeTownKey("Milford, Derbyshire (DBY)") == "milford")
        #expect(AppState.placeTownKey("  Derby  ") == "derby")
    }

    @Test func townKeyNilForEmpty() {
        #expect(AppState.placeTownKey(nil) == nil)
        #expect(AppState.placeTownKey("") == nil)
        #expect(AppState.placeTownKey("   ") == nil)
        #expect(AppState.placeTownKey(",") == nil)
    }

    // MARK: - placesDivergeAtTown

    /// The George Ward case: census target born Derby, profile records Ashbourne
    /// — different towns, so the birthplace is surfaced for the human to catch.
    @Test func divergesWhenTownsDiffer() {
        #expect(AppState.placesDivergeAtTown("Derby", "Ashbourne, Derbyshire"))
        #expect(AppState.placesDivergeAtTown("Ashbourne", "Derby"))
    }

    /// County tails and casing never cause a false divergence.
    @Test func sameTownDoesNotDiverge() {
        #expect(!AppState.placesDivergeAtTown("Ashbourne", "Ashbourne, Derbyshire"))
        #expect(!AppState.placesDivergeAtTown("MILFORD, Derbyshire", "milford"))
    }

    /// Missing data never flags — a divergence needs a usable place on both sides.
    @Test func missingPlaceNeverDiverges() {
        #expect(!AppState.placesDivergeAtTown(nil, "Derby"))
        #expect(!AppState.placesDivergeAtTown("Derby", nil))
        #expect(!AppState.placesDivergeAtTown("Derby", ""))
    }

    /// A substring nesting (rare in practice) is treated as the same place, not a
    /// divergence — "Derby" ⊂ "Derby St Peter".
    @Test func substringNestingDoesNotDiverge() {
        #expect(!AppState.placesDivergeAtTown("Derby", "Derby St Peter"))
    }

    /// DOCUMENTED non-goal: a registration-district vs town pair (Milford sits in
    /// Belper district) DOES diverge at the token — the capsule surfaces it as a
    /// neutral juxtaposition, not a block. A principled place-nesting check is
    /// deferred to the `PlaceAuthority` hierarchy (`#S1-6b`).
    @Test func districtTownPairStillDivergesByDesign() {
        #expect(AppState.placesDivergeAtTown("Milford", "Belper"))
    }
}
