import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EVIDENCE_ABSORPTION_SPEC Change 1 — a census carries the subject's
/// birthplace off-agenda. `ApplyEngine.censusBirthLocation` composes it into
/// the *anchor-able* string that `applyFactToSubject` routes to the
/// birthLocation field, so a discovered "Alport" can finally anchor the
/// subject (live case: Abraham Twyford, born Alport 1888, stranded on
/// anchorless National search until his own census supplied his birthplace).
struct CensusBirthLocationAbsorptionTests {

    private func census(place: String?, county: String?) -> CensusRecord {
        CensusRecord(
            common: RecordCommon(id: "c1", sourceID: "freecen", rawFields: [:]),
            censusYear: 1891, birthPlace: place, birthCounty: county)
    }

    @Test func placePlusCountyComposesAnchorableString() {
        // "Alport" alone is a village, not a district — it won't derive a
        // Chapman anchor. Appending the county is what unblocks the subject.
        #expect(ApplyEngine.censusBirthLocation(census(place: "Alport", county: "Derbyshire"))
                == "Alport, Derbyshire")
    }

    @Test func countyNotDuplicatedWhenAlreadyNamed() {
        #expect(ApplyEngine.censusBirthLocation(census(place: "Alport, Derbyshire", county: "Derbyshire"))
                == "Alport, Derbyshire")
        // Case-insensitive containment — don't append a county the place spells differently-cased.
        #expect(ApplyEngine.censusBirthLocation(census(place: "Bakewell, DERBYSHIRE", county: "Derbyshire"))
                == "Bakewell, DERBYSHIRE")
    }

    @Test func bareBirthPlaceStillAbsorbed() {
        #expect(ApplyEngine.censusBirthLocation(census(place: "Sheffield", county: nil))
                == "Sheffield")
    }

    @Test func countyOnlyFallsBackToCounty() {
        #expect(ApplyEngine.censusBirthLocation(census(place: nil, county: "Derbyshire"))
                == "Derbyshire")
        #expect(ApplyEngine.censusBirthLocation(census(place: "   ", county: "Derbyshire"))
                == "Derbyshire")
    }

    @Test func noBirthplaceYieldsNothingToAbsorb() {
        #expect(ApplyEngine.censusBirthLocation(census(place: nil, county: nil)) == nil)
        #expect(ApplyEngine.censusBirthLocation(census(place: "  ", county: "  ")) == nil)
    }

    @Test func composedStringDerivesTheAnchor() {
        // The end-to-end point of Change 1: the absorbed value anchors the subject.
        let composed = ApplyEngine.censusBirthLocation(census(place: "Alport", county: "Derbyshire"))
        let profile = Profile(
            id: "p", externalIDs: [:], firstName: "Abraham", lastName: "Twyford",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: composed, birthLocationCode: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        #expect(ResearchSubject.deriveHomeChapmanCode(from: profile, projectFallback: "") == "DBY",
                "absorbed 'Alport, Derbyshire' must anchor the subject to DBY")
    }
}
