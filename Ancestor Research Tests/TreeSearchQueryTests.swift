import Testing
import Foundation
@testable import Ancestor_Research

struct TreeSearchQueryTests {

    private func makeProfile(
        id: String = UUID().uuidString,
        firstName: String? = nil,
        lastName: String? = nil,
        birthDate: String? = nil,
        birthLocation: String? = nil,
        deathDate: String? = nil,
        deathLocation: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: nil,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    // MARK: - Empty query

    @Test func emptyQueryIsEmptyAndMatchesEverything() {
        let query = TreeSearchQuery.parse("")
        #expect(query.isEmpty == true)

        let p1 = makeProfile(firstName: "William", lastName: "Land", birthDate: "1834")
        let p2 = makeProfile(firstName: "Mary", lastName: "Smith")
        #expect(query.matches(p1) == true)
        #expect(query.matches(p2) == true)
    }

    @Test func whitespaceOnlyQueryIsEmpty() {
        let query = TreeSearchQuery.parse("   \t  ")
        #expect(query.isEmpty == true)
    }

    // MARK: - Name only

    @Test func nameOnlyMatchesSubstring() {
        let query = TreeSearchQuery.parse("Land")
        #expect(query.name == "Land")
        #expect(query.location == nil)
        #expect(query.bornAfter == nil)
        #expect(query.bornBefore == nil)

        let william = makeProfile(firstName: "William", lastName: "Land")
        let mary = makeProfile(firstName: "Mary", lastName: "Smith")
        #expect(query.matches(william) == true)
        #expect(query.matches(mary) == false)
    }

    @Test func nameMatchIsCaseInsensitive() {
        let query = TreeSearchQuery.parse("LAND")
        let william = makeProfile(firstName: "William", lastName: "Land")
        #expect(query.matches(william) == true)
    }

    // MARK: - Birth year

    @Test func bornSingleYearMatchesExactly() {
        let query = TreeSearchQuery.parse("born 1834")
        #expect(query.bornAfter == 1834)
        #expect(query.bornBefore == 1834)
        #expect(query.name == nil)

        let exact = makeProfile(birthDate: "1834")
        let off = makeProfile(birthDate: "1835")
        #expect(query.matches(exact) == true)
        #expect(query.matches(off) == false)
    }

    @Test func bornYearRangeIsInclusive() {
        let query = TreeSearchQuery.parse("born 1830-1850")
        #expect(query.bornAfter == 1830)
        #expect(query.bornBefore == 1850)

        let inside = makeProfile(birthDate: "1840")
        let lowerEdge = makeProfile(birthDate: "1830")
        let upperEdge = makeProfile(birthDate: "1850")
        let below = makeProfile(birthDate: "1829")
        let above = makeProfile(birthDate: "1851")

        #expect(query.matches(inside) == true)
        #expect(query.matches(lowerEdge) == true)
        #expect(query.matches(upperEdge) == true)
        #expect(query.matches(below) == false)
        #expect(query.matches(above) == false)
    }

    @Test func profileWithoutBirthDateExcludedByYearFilter() {
        let query = TreeSearchQuery.parse("born 1830-1850")
        let unknown = makeProfile(firstName: "Unknown", lastName: "Person")
        #expect(query.matches(unknown) == false)
    }

    // MARK: - Death year

    @Test func diedSingleYearMatches() {
        let query = TreeSearchQuery.parse("died 1875")
        #expect(query.diedAfter == 1875)
        #expect(query.diedBefore == 1875)

        let match = makeProfile(deathDate: "1875")
        let miss = makeProfile(deathDate: "1880")
        #expect(query.matches(match) == true)
        #expect(query.matches(miss) == false)
    }

    @Test func diedYearRangeMatches() {
        let query = TreeSearchQuery.parse("died 1870-1880")
        let match = makeProfile(deathDate: "1875")
        let miss = makeProfile(deathDate: "1860")
        #expect(query.matches(match) == true)
        #expect(query.matches(miss) == false)
    }

    @Test func profileWithoutDeathDateExcludedByYearFilter() {
        let query = TreeSearchQuery.parse("died 1875")
        let alive = makeProfile(birthDate: "1840")
        #expect(query.matches(alive) == false)
    }

    // MARK: - Location

    @Test func bornInLocationParsesAsLocation() {
        let query = TreeSearchQuery.parse("born in Derbyshire")
        #expect(query.location == "Derbyshire")
        #expect(query.name == nil)
        #expect(query.bornAfter == nil)

        let derby = makeProfile(firstName: "X", birthLocation: "Belper, Derbyshire")
        let london = makeProfile(firstName: "Y", birthLocation: "London")
        #expect(query.matches(derby) == true)
        #expect(query.matches(london) == false)
    }

    @Test func inLocationParsesAsLocationWithoutBornPrefix() {
        let query = TreeSearchQuery.parse("in Belper")
        #expect(query.location == "Belper")
        #expect(query.name == nil)

        let belper = makeProfile(birthLocation: "Belper, Derbyshire")
        let other = makeProfile(birthLocation: "Sheffield")
        #expect(query.matches(belper) == true)
        #expect(query.matches(other) == false)
    }

    @Test func locationMatchesEitherBirthOrDeath() {
        let query = TreeSearchQuery.parse("in Derbyshire")
        let bornThere = makeProfile(birthLocation: "Derbyshire", deathLocation: "London")
        let diedThere = makeProfile(birthLocation: "London", deathLocation: "Derbyshire")
        #expect(query.matches(bornThere) == true)
        #expect(query.matches(diedThere) == true)
    }

    @Test func multiWordLocationCollectsUntilEndOfInput() {
        let query = TreeSearchQuery.parse("in South Wingfield")
        #expect(query.location == "South Wingfield")

        let match = makeProfile(birthLocation: "South Wingfield, Derbyshire")
        let miss = makeProfile(birthLocation: "Wingfield Park")
        #expect(query.matches(match) == true)
        #expect(query.matches(miss) == false)
    }

    @Test func profileWithoutLocationExcludedByLocationFilter() {
        let query = TreeSearchQuery.parse("in Derbyshire")
        let noLocation = makeProfile(firstName: "No", lastName: "Location")
        #expect(query.matches(noLocation) == false)
    }

    // MARK: - Combined

    @Test func combinedQueryAndsAllCriteria() {
        let query = TreeSearchQuery.parse("Land born 1830-1850 Derbyshire")
        #expect(query.name == "Land")
        #expect(query.bornAfter == 1830)
        #expect(query.bornBefore == 1850)
        #expect(query.location == "Derbyshire")

        let perfect = makeProfile(
            firstName: "William",
            lastName: "Land",
            birthDate: "1840",
            birthLocation: "Belper, Derbyshire"
        )
        let wrongName = makeProfile(
            firstName: "John",
            lastName: "Smith",
            birthDate: "1840",
            birthLocation: "Belper, Derbyshire"
        )
        let wrongYear = makeProfile(
            firstName: "William",
            lastName: "Land",
            birthDate: "1860",
            birthLocation: "Belper, Derbyshire"
        )
        let wrongLocation = makeProfile(
            firstName: "William",
            lastName: "Land",
            birthDate: "1840",
            birthLocation: "London"
        )

        #expect(query.matches(perfect) == true)
        #expect(query.matches(wrongName) == false)
        #expect(query.matches(wrongYear) == false)
        #expect(query.matches(wrongLocation) == false)
    }

    @Test func combinedNameAndBornQueryWithoutLocation() {
        let query = TreeSearchQuery.parse("Smith born 1900")
        #expect(query.name == "Smith")
        #expect(query.bornAfter == 1900)
        #expect(query.bornBefore == 1900)
        #expect(query.location == nil)
    }

    // MARK: - Malformed input

    @Test func malformedBornFallsThroughToName() {
        let query = TreeSearchQuery.parse("born abc")
        // "born" with non-year argument falls through; both tokens become
        // part of the name fragment.
        #expect(query.name == "born abc")
        #expect(query.bornAfter == nil)
        #expect(query.bornBefore == nil)
    }

    @Test func malformedDiedFallsThroughToName() {
        let query = TreeSearchQuery.parse("died xyz")
        #expect(query.name == "died xyz")
        #expect(query.diedAfter == nil)
    }

    @Test func bornInWithNoLocationIsGraceful() {
        // "born in" at end of input — no words to collect.
        let query = TreeSearchQuery.parse("born in")
        #expect(query.location == nil)
        // Query is non-empty if name captured the leftover. We accept
        // either degenerate parsing as long as no crash.
        _ = query.matches(makeProfile(firstName: "anyone"))
    }

    @Test func bareYearWithoutModifierStaysInName() {
        // Per spec: bare 4-digit number not preceded by a modifier is
        // treated as part of the name. "Henry VIII 1509" still partially
        // matches on name.
        let query = TreeSearchQuery.parse("Henry VIII 1509")
        #expect(query.bornAfter == nil)
        #expect(query.diedAfter == nil)
        #expect(query.name?.contains("Henry") == true)
        #expect(query.name?.contains("1509") == true)
    }
}
