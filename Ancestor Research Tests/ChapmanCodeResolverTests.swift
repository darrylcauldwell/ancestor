import Testing
import Foundation
@testable import Ancestor_Research

/// ChapmanCodeResolver — the single canonical free-text → Chapman county code
/// resolver that replaced the divergent copies in ResearchSubject and
/// ConflictDetector. These characterization tests pin the unified three-tier
/// behaviour, including the two cases the old parsers each got wrong.
struct ChapmanCodeResolverTests {

    // MARK: - Tier 3: county-name fallback (ResearchSubject had, ConflictDetector lacked)

    @Test func resolvesBareVillagePlusCountyViaCountyName() {
        // No district named "Ashford in the Water"; the "Derbyshire" component
        // is what resolves it. ConflictDetector's old district-only scan
        // returned nil here.
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Ashford in the Water, Derbyshire") == "DBY")
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Turnditch, Derbyshire") == "DBY")
    }

    @Test func resolvesBareCounty() {
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Derbyshire") == "DBY")
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Nottinghamshire") == "NTT")
    }

    // MARK: - Tier 1/2: registration-district match

    @Test func resolvesBareRegistrationDistrict() {
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Belper") == "DBY")
    }

    @Test func resolvesDistrictComponentWhenCountyAbsent() {
        // Component "Belper" is a registration district → DBY, even though the
        // trailing token is not a real county. ResearchSubject's old
        // county-only component scan returned nil here.
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Belper, Nowhereshire") == "DBY")
    }

    // MARK: - Non-resolving inputs

    @Test func declinesEmptyAndUnknown() {
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "") == nil)
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "   ") == nil)
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Nowhere, Atlantis") == nil)
    }

    // MARK: - Delegation: the two wrappers now agree

    @Test func researchSubjectAndConflictDetectorWrappersAgree() {
        let cases = [
            "Belper", "Belper, Derbyshire", "Ashford in the Water, Derbyshire",
            "Turnditch, Derbyshire", "Derbyshire", "Belper, Nowhereshire",
            "Nowhere, Atlantis", "",
        ]
        for c in cases {
            #expect(
                ResearchSubject.chapmanCode(forPlaceText: c)
                    == ConflictDetector.chapmanCode(forPlaceText: c),
                "wrappers disagree for \(c)")
            #expect(
                ResearchSubject.chapmanCode(forPlaceText: c)
                    == ChapmanCodeResolver.chapmanCode(forPlaceText: c),
                "wrapper diverges from canonical for \(c)")
        }
    }
}
