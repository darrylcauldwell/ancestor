import Testing
import Foundation
@testable import Ancestor_Research

/// M19 — `ProfileDiff.differingFields` powers the Comparison view's
/// row-by-row highlighting. These tests pin down the comparison rules:
///
/// - identical profiles → empty diff
/// - genuine value mismatches detected
/// - whitespace and case folded before comparing
/// - nil vs concrete value counts as a difference
/// - empty / whitespace-only string treated the same as nil
@MainActor
struct ProfileDiffTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "p",
        firstName: String? = nil,
        lastName: String? = nil,
        gender: Gender? = nil,
        birthDate: String? = nil,
        birthLocation: String? = nil,
        deathDate: String? = nil,
        deathLocation: String? = nil,
        bio: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: gender,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            bio: bio,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    // MARK: - Tests

    @Test func differingFieldsEmptyForIdenticalProfiles() {
        let a = makeProfile(
            id: "a",
            firstName: "Mary",
            lastName: "Smith",
            gender: .female,
            birthDate: "1880",
            birthLocation: "London",
            deathDate: "1950",
            deathLocation: "London",
            bio: "Brief biography"
        )
        let b = makeProfile(
            id: "b",
            firstName: "Mary",
            lastName: "Smith",
            gender: .female,
            birthDate: "1880",
            birthLocation: "London",
            deathDate: "1950",
            deathLocation: "London",
            bio: "Brief biography"
        )
        #expect(ProfileDiff.differingFields(left: a, right: b).isEmpty)
    }

    @Test func differingFieldsDetectsBirthYearDifference() {
        let a = makeProfile(id: "a", firstName: "John", lastName: "Doe", birthDate: "1880")
        let b = makeProfile(id: "b", firstName: "John", lastName: "Doe", birthDate: "1885")
        let diff = ProfileDiff.differingFields(left: a, right: b)
        #expect(diff == [.birthDate])
    }

    @Test func differingFieldsTrimsWhitespace() {
        let a = makeProfile(id: "a", firstName: "Mary ")
        let b = makeProfile(id: "b", firstName: "Mary")
        let diff = ProfileDiff.differingFields(left: a, right: b)
        #expect(!diff.contains(.firstName))
    }

    @Test func differingFieldsCaseInsensitive() {
        let a = makeProfile(id: "a", birthLocation: "London")
        let b = makeProfile(id: "b", birthLocation: "LONDON")
        let diff = ProfileDiff.differingFields(left: a, right: b)
        #expect(!diff.contains(.birthLocation))
    }

    @Test func differingFieldsTreatsNilVsValueAsDiff() {
        let a = makeProfile(id: "a", firstName: "Henry")
        let b = makeProfile(id: "b", firstName: nil)
        let diff = ProfileDiff.differingFields(left: a, right: b)
        #expect(diff.contains(.firstName))
    }

    @Test func differingFieldsEmptyStringSameAsNil() {
        let a = makeProfile(id: "a", bio: "")
        let b = makeProfile(id: "b", bio: nil)
        let diff = ProfileDiff.differingFields(left: a, right: b)
        #expect(!diff.contains(.bio))

        // And whitespace-only is also treated as nil.
        let c = makeProfile(id: "c", bio: "   \n  ")
        #expect(!ProfileDiff.differingFields(left: c, right: b).contains(.bio))
    }
}
