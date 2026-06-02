import Testing
import Foundation
@testable import Ancestor_Research

/// Verifies the chapman-code derivation chain in `ResearchSubject.fromProfile`
/// and `fromUserInput`. The chain replaced the hardcoded `"DBY"` default
/// that silently misanchored non-Derbyshire profiles in any project that
/// hadn't been explicitly configured (see `feedback_no_hardcoded_regions`).
@MainActor
struct ResearchSubjectHomeChapmanDerivationTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "p1",
        firstName: String? = "George",
        lastName: String? = "Brooks",
        gender: Gender = .male,
        birthDate: GenealogicalDate? = nil,
        birthLocation: String? = nil,
        birthLocationCode: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, middleName: nil, lastName: lastName,
            marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
            gender: gender, attributes: nil,
            birthDate: birthDate,
            birthLocation: birthLocation,
            birthLocationCode: birthLocationCode,
            deathDate: nil, deathLocation: nil, deathLocationCode: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    private let emptySnapshot = FamilyGraphSnapshot(profiles: [:], relationships: [])

    // MARK: - Tier 1 — birthLocationCode (gazetteer ID)

    @Test func derivation_birthLocationCode_takesPrefixUpToColon() {
        // Gazetteer IDs are "{CHAPMAN}:{place}" (e.g. "DBY:Crich"). The
        // chapman prefix is the anchor — regardless of place specificity.
        let p = makeProfile(birthLocationCode: "DBY:Crich")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "DBY")
    }

    @Test func derivation_birthLocationCode_NonDBY_resolvesCorrectly() {
        // A Yorkshire profile must NOT default to Derbyshire just because
        // legacy code had that fallback. This is the exact regression the
        // refactor prevents.
        let p = makeProfile(birthLocationCode: "YKS:Sheffield")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "YKS")
    }

    @Test func derivation_birthLocationCode_withoutColon_treatedAsRawCode() {
        // Some imports may store the chapman code alone (no place suffix).
        // Still valid as a 3-letter Chapman code anchor.
        let p = makeProfile(birthLocationCode: "LND")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "LND")
    }

    @Test func derivation_birthLocationCode_invalidPrefix_fallsThrough() {
        // Anything that isn't a 3-letter alpha code → ignored, fall
        // through to next tier. Empty string from projectFallback means
        // returns "".
        let p = makeProfile(birthLocationCode: "ABCDE:Somewhere")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "")
    }

    @Test func derivation_birthLocationCode_lowercase_uppercased() {
        // Defensive: accept "dby:crich" and uppercase the result.
        let p = makeProfile(birthLocationCode: "dby:crich")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "DBY")
    }

    // MARK: - Tier 2 — birthLocation (free-text, catalogue lookup)

    @Test func derivation_birthLocation_resolvesViaDistrictCatalogue() {
        // "Belper" is a FreeBMD-catalogued registration district in DBY.
        let p = makeProfile(birthLocation: "Belper")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "DBY")
    }

    @Test func derivation_birthLocation_NonDBY_resolvesCorrectly() {
        // "Marylebone" is a London (LND) district.
        let p = makeProfile(birthLocation: "Marylebone")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "LND")
    }

    @Test func derivation_birthLocation_unrecognised_fallsThrough() {
        // A free-text place name that doesn't resolve via the catalogue
        // → fall through to project fallback.
        let p = makeProfile(birthLocation: "Somewhere not in the catalogue")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "YKS")
        #expect(result == "YKS")
    }

    // MARK: - Tier 3 — project fallback

    @Test func derivation_noProfileLocation_usesProjectFallback() {
        let p = makeProfile()
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "YKS")
        #expect(result == "YKS")
    }

    @Test func derivation_noProfileLocationAndNoProjectFallback_returnsEmpty() {
        // The critical regression-prevention test: a profile with no
        // location data in a project with no chapman setting → empty
        // string. NOT silently "DBY".
        let p = makeProfile()
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "")
    }

    // MARK: - Tier precedence

    @Test func derivation_birthLocationCode_winsOverProjectFallback() {
        let p = makeProfile(birthLocationCode: "YKS:Sheffield")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "DBY")
        #expect(result == "YKS")
    }

    @Test func derivation_birthLocationCode_winsOverBirthLocation() {
        // Edge case — profile has both set, perhaps from different
        // imports. The structured gazetteer ID wins because it's
        // unambiguous (no district-name collisions).
        let p = makeProfile(
            birthLocation: "Marylebone",        // would resolve LND
            birthLocationCode: "DBY:Crich"      // wins
        )
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "")
        #expect(result == "DBY")
    }

    @Test func derivation_birthLocation_winsOverProjectFallback() {
        // birthLocationCode nil, birthLocation set → catalogue lookup
        // wins over the project's tree-wide default.
        let p = makeProfile(birthLocation: "Marylebone")
        let result = ResearchSubject.deriveHomeChapmanCode(from: p, projectFallback: "DBY")
        #expect(result == "LND")
    }

    // MARK: - fromProfile builder integration

    @Test func fromProfile_threadsDerivedChapmanIntoSubject() {
        // The builder's `homeChapmanCode` parameter is treated as the
        // project fallback. Profile-derived chapman wins.
        let p = makeProfile(birthLocationCode: "YKS:Sheffield")
        let subject = ResearchSubject.fromProfile(
            p, snapshot: emptySnapshot, homeChapmanCode: "DBY"
        )
        #expect(subject.homeChapmanCode == "YKS")
    }

    @Test func fromProfile_emptyDefault_doesNotResolveToDBY() {
        // No location data, no project fallback → empty string. The
        // critical assertion: NO Derbyshire default lurks anywhere in
        // the builder chain.
        let p = makeProfile()
        let subject = ResearchSubject.fromProfile(p, snapshot: emptySnapshot)
        #expect(subject.homeChapmanCode == "")
    }

    // MARK: - fromUserInput

    @Test func fromUserInput_locationResolvedViaDistrictCatalogue() {
        let subject = ResearchSubject.fromUserInput(
            surname: "Smith", givenName: "John",
            birthYear: 1880, deathYear: nil,
            gender: .male, location: "Belper",
            homeChapmanCode: ""
        )
        #expect(subject.homeChapmanCode == "DBY")
    }

    @Test func fromUserInput_unrecognisedLocation_fallsBackToProjectSetting() {
        let subject = ResearchSubject.fromUserInput(
            surname: "Smith", givenName: "John",
            birthYear: 1880, deathYear: nil,
            gender: .male, location: "Some unmappable place",
            homeChapmanCode: "YKS"
        )
        #expect(subject.homeChapmanCode == "YKS")
    }

    @Test func fromUserInput_nilLocationAndNoFallback_returnsEmpty() {
        let subject = ResearchSubject.fromUserInput(
            surname: "Smith", givenName: "John",
            birthYear: 1880, deathYear: nil,
            gender: .male, location: nil,
            homeChapmanCode: ""
        )
        #expect(subject.homeChapmanCode == "")
    }

    // MARK: - Struct default

    @Test func structDefault_isEmptyNotDBY() {
        // Direct construction with no chapman supplied falls through to
        // the struct's stored default. Must be "" not "DBY".
        let subject = ResearchSubject(
            profileID: "p1", surname: "Smith", givenName: "John",
            mode: .extend
        )
        #expect(subject.homeChapmanCode == "")
    }
}
