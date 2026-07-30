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

    // MARK: - Catalogue-data regressions

    /// 2026-07-30 live-run miss: the catalogue carried Worksop district as
    /// DBY, so a Worksop-born subject (William Henry Keyworth) had every
    /// FreeREG/FreeCEN/FreeBMD query scoped to Derbyshire while his entire
    /// record trail sits in Nottinghamshire (verified by direct FreeREG
    /// search: baptism 21 Mar 1875 Worksop Priory, marriage 22 Mar 1896
    /// Worksop St John). Worksop district straddles the county border —
    /// its parish list includes Derbyshire parishes — but the district's
    /// attribution is Nottinghamshire.
    @Test func worksopDistrictResolvesToNottinghamshire() {
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Worksop") == "NTT")
        #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: "Worksop, Nottinghamshire, England") == "NTT")
    }

    /// 2026-07-30 catalogue audit: 119 of 1,121 districts carried a wrong
    /// county (the Worksop failure class — many are cross-border unions
    /// mis-attributed by the original enrichment). Full verified list in
    /// the audit record; this table pins a geographically-diverse sample
    /// so a catalogue regeneration can't silently reintroduce the class.
    @Test func auditedDistrictAttributionsHold() {
        let expected: [(district: String, chapman: String)] = [
            ("Basford", "NTT"),        // was DBY — same border as Worksop
            ("Bingham", "NTT"),        // was LEI
            ("Croydon", "SRY"),        // was KEN
            ("Kendal", "WES"),         // was LAN
            ("Huntingdon", "HUN"),     // was CAM
            ("Taunton", "SOM"),        // was DEV
            ("Wolverhampton", "STS"),  // was SAL
            ("Banbury", "OXF"),        // was GLS (cross-border union)
            ("Basingstoke", "HAM"),    // was BRK
            ("Bedminster", "SOM"),     // was GLS
            ("Goole", "WRY"),          // was ERY
            ("Uppingham", "RUT"),      // was LEI
            ("Wrexham", "DEN"),        // was CHS
            ("Ynys Mon", "AGY"),       // was CAE
            ("Edmonton", "MDX"),       // was ESS
        ]
        for (district, chapman) in expected {
            #expect(ChapmanCodeResolver.chapmanCode(forPlaceText: district) == chapman,
                    "\(district) must resolve to \(chapman)")
        }
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
