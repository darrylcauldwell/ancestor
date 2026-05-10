import Testing
import Foundation
@testable import Ancestor_Research

struct StatisticsCalculatorTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String,
        firstName: String? = "Test",
        lastName: String? = "Person",
        gender: Gender? = .male,
        birthDate: String? = nil,
        deathDate: String? = nil,
        birthLocation: String? = nil,
        deathLocation: String? = nil,
        bio: String? = nil,
        sources: [ProfileField: [FieldSource]] = [:]
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
            sources: sources,
            disputes: [:]
        )
    }

    private func makeSnapshot(
        profiles: [Profile],
        relationships: [Relationship] = []
    ) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: relationships)
    }

    private func parentRel(parent: String, child: String) -> Relationship {
        Relationship(
            id: UUID(),
            from: parent, to: child,
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func source(_ raw: String = "GEDCOM") -> FieldSource {
        FieldSource(origin: .gedcom, raw: raw, addedAt: Date())
    }

    // MARK: - Lifespan

    @Test func averageLifespanSkipsProfilesWithoutDeath() {
        let p1 = makeProfile(id: "a", birthDate: "1900", deathDate: "1980") // 80
        let p2 = makeProfile(id: "b", birthDate: "1850", deathDate: "1910") // 60
        let p3 = makeProfile(id: "c", birthDate: "1990", deathDate: nil)    // living
        let snapshot = makeSnapshot(profiles: [p1, p2, p3])
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [])
        #expect(stats.averageLifespanYears == 70.0)
        #expect(stats.profileCount == 3)
        #expect(stats.livingPotentially == 1)
    }

    @Test func averageLifespanReturnsNilWhenNoEligibleProfiles() {
        let p1 = makeProfile(id: "a", birthDate: "1990", deathDate: nil)
        let p2 = makeProfile(id: "b", birthDate: nil, deathDate: "1910")
        let snapshot = makeSnapshot(profiles: [p1, p2])
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [])
        #expect(stats.averageLifespanYears == nil)
    }

    // MARK: - Surnames

    @Test func topSurnamesReturnsHighestCountsWithTiesBrokenAlphabetically() {
        // Smith x3, Jones x2, Brown x2 → Smith, Brown (alphabetical), Jones
        let profiles = [
            makeProfile(id: "1", lastName: "Smith"),
            makeProfile(id: "2", lastName: "Smith"),
            makeProfile(id: "3", lastName: "smith"), // case-folded into Smith
            makeProfile(id: "4", lastName: "Jones"),
            makeProfile(id: "5", lastName: "Jones"),
            makeProfile(id: "6", lastName: "Brown"),
            makeProfile(id: "7", lastName: "Brown"),
        ]
        let snapshot = makeSnapshot(profiles: profiles)
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [])
        #expect(stats.topSurnames.count == 3)
        #expect(stats.topSurnames[0].surname == "Smith")
        #expect(stats.topSurnames[0].count == 3)
        // Tie on count = 2 → Brown alphabetically before Jones.
        #expect(stats.topSurnames[1].surname == "Brown")
        #expect(stats.topSurnames[1].count == 2)
        #expect(stats.topSurnames[2].surname == "Jones")
        #expect(stats.topSurnames[2].count == 2)
    }

    // MARK: - Locations

    @Test func topBirthLocationsReturnsTop20() {
        // 25 distinct locations, each with a unique count 1..25 → top 20 keeps the
        // highest-count locations and drops the smallest 5.
        var profiles: [Profile] = []
        var idx = 0
        for n in 1...25 {
            for _ in 0..<n {
                idx += 1
                profiles.append(makeProfile(
                    id: "p\(idx)",
                    birthLocation: "Town \(n)"
                ))
            }
        }
        let snapshot = makeSnapshot(profiles: profiles)
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [])
        #expect(stats.topBirthLocations.count == 20)
        #expect(stats.topBirthLocations.first?.count == 25)
        // Smallest in the top-20 should be the 6th-most-populous town (count 6).
        #expect(stats.topBirthLocations.last?.count == 6)
    }

    // MARK: - Source coverage

    @Test func sourceCoveragePercentZeroForUnsourcedTree() {
        let p1 = makeProfile(
            id: "a",
            firstName: "Anne",
            lastName: "Bell",
            gender: .female,
            birthDate: "1900",
            sources: [:]
        )
        let snapshot = makeSnapshot(profiles: [p1])
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [])
        #expect(stats.sourceCoveragePercent == 0)
        #expect(stats.sourcedFieldCount == 0)
        // 4 valued fields: firstName, lastName, gender, birthDate.
        #expect(stats.valuedFieldCount == 4)
    }

    @Test func sourceCoveragePercent100WhenEveryValuedFieldSourced() {
        let allFields: [ProfileField] = [.firstName, .lastName, .gender, .birthDate, .birthLocation, .deathDate, .deathLocation, .bio]
        let sources: [ProfileField: [FieldSource]] = Dictionary(
            uniqueKeysWithValues: allFields.map { ($0, [source()]) }
        )
        let p1 = makeProfile(
            id: "a",
            firstName: "Anne",
            lastName: "Bell",
            gender: .female,
            birthDate: "1900",
            deathDate: "1980",
            birthLocation: "Derby",
            deathLocation: "Sheffield",
            bio: "Notes here",
            sources: sources
        )
        let snapshot = makeSnapshot(profiles: [p1])
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [])
        #expect(stats.sourceCoveragePercent == 100)
        #expect(stats.sourcedFieldCount == 8)
        #expect(stats.valuedFieldCount == 8)
    }

    // MARK: - Generations

    @Test func maxAncestorGenerationsZeroWithoutHomePerson() {
        let p1 = makeProfile(id: "a")
        let p2 = makeProfile(id: "b")
        let rel = parentRel(parent: "a", child: "b")
        let snapshot = makeSnapshot(profiles: [p1, p2], relationships: [rel])
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [])
        #expect(stats.maxAncestorGenerations == 0)
        #expect(stats.maxDescendantGenerations == 0)
        #expect(stats.totalAncestorsFromHome == 0)
        #expect(stats.totalDescendantsFromHome == 0)
    }

    @Test func generationsBfsFromHomePerson() {
        // Three-generation chain: grandparent → parent → home → child.
        let gp = makeProfile(id: "gp")
        let p = makeProfile(id: "p")
        let home = makeProfile(id: "home")
        let child = makeProfile(id: "child")
        let snapshot = makeSnapshot(
            profiles: [gp, p, home, child],
            relationships: [
                parentRel(parent: "gp", child: "p"),
                parentRel(parent: "p", child: "home"),
                parentRel(parent: "home", child: "child"),
            ]
        )
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: "home", sessions: [])
        #expect(stats.maxAncestorGenerations == 2)   // p, gp
        #expect(stats.maxDescendantGenerations == 1) // child
        #expect(stats.totalAncestorsFromHome == 2)
        #expect(stats.totalDescendantsFromHome == 1)
    }

    // MARK: - Time invested

    @Test func totalHoursInvestedSumsSessionDurations() {
        let now = Date()
        let s1 = ResearchSession(
            id: UUID(),
            startedAt: now.addingTimeInterval(-3600),
            endedAt: now.addingTimeInterval(-1800), // 30 min
            focusSetID: nil,
            profilesAdded: 0, profilesEdited: 0, disputesResolved: 0,
            hypothesesCreated: 0, hypothesesPromoted: 0,
            questionsCreated: 0, questionsResolved: 0, notesCreated: 0,
            transactionIDs: []
        )
        let s2 = ResearchSession(
            id: UUID(),
            startedAt: now.addingTimeInterval(-1800),
            endedAt: now,                            // 30 min
            focusSetID: nil,
            profilesAdded: 0, profilesEdited: 0, disputesResolved: 0,
            hypothesesCreated: 0, hypothesesPromoted: 0,
            questionsCreated: 0, questionsResolved: 0, notesCreated: 0,
            transactionIDs: []
        )
        let snapshot = makeSnapshot(profiles: [makeProfile(id: "a")])
        let stats = StatisticsCalculator.compute(snapshot: snapshot, homePersonID: nil, sessions: [s1, s2])
        // Allow tiny float drift on the 30-min boundary.
        #expect(abs(stats.totalHoursInvested - 1.0) < 0.001)
    }
}
