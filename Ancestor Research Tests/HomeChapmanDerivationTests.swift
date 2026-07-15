import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// `deriveHomeChapmanCode` must extract the research anchor from a freeform
/// birth location whose parish/village is NOT a registration district (owner
/// report 2026-07-15: "Ashford in the Water, Derbyshire" still defaulted the
/// subject to anchor-less National, triggering a slow national census sweep).
struct HomeChapmanDerivationTests {

    private func profile(birthLocation: String?, code: String? = nil) -> Profile {
        Profile(
            id: "p", externalIDs: [:], firstName: "Wilhelmina", lastName: "Wright",
            gender: .female, attributes: nil,
            birthDate: nil, birthLocation: birthLocation, birthLocationCode: code,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
    }

    @Test func villagePlusCountyExtractsTheCounty() {
        let code = ResearchSubject.deriveHomeChapmanCode(
            from: profile(birthLocation: "Ashford in the Water, Derbyshire"),
            projectFallback: "")
        #expect(code == "DBY", "county must be extracted from a non-district parish string; got '\(code)'")
    }

    @Test func bareCountyName() {
        #expect(ResearchSubject.deriveHomeChapmanCode(
            from: profile(birthLocation: "Derbyshire"), projectFallback: "") == "DBY")
    }

    @Test func placeCountyCountryTriple() {
        #expect(ResearchSubject.deriveHomeChapmanCode(
            from: profile(birthLocation: "Youlgreave, Derbyshire, England"),
            projectFallback: "") == "DBY")
    }

    @Test func registrationDistrictStillMatches() {
        // The pre-existing district path must keep working (Bakewell IS a district).
        #expect(ResearchSubject.deriveHomeChapmanCode(
            from: profile(birthLocation: "Bakewell"), projectFallback: "") == "DBY")
    }

    @Test func structuredLocationCodeWins() {
        #expect(ResearchSubject.deriveHomeChapmanCode(
            from: profile(birthLocation: "somewhere odd", code: "DBY:Ashford"),
            projectFallback: "") == "DBY")
    }

    @Test func unknownLocationFallsBackToProjectSetting() {
        #expect(ResearchSubject.deriveHomeChapmanCode(
            from: profile(birthLocation: "Nowhere-in-Particular"),
            projectFallback: "STS") == "STS")
        #expect(ResearchSubject.deriveHomeChapmanCode(
            from: profile(birthLocation: nil), projectFallback: "") == "")
    }
}
