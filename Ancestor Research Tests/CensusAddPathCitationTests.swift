import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Every affordance that turns a census roster row into a person must cite the
/// same household schedule. `addCensusFamily` learned to attach the citation,
/// but only the profile-card caller passed a URL — so the bulk "Add all N"
/// (`addMissingCensusRelatives`) and the per-row "Add" (`addCensusRelative`)
/// created people whose calculated birth years traced to nothing. Owner dogfood
/// 2026-08-25: nine people added in one click carried zero citations while four
/// added row-by-row were fully cited.
struct CensusAddPathCitationTests {

    // MARK: - Fixtures

    private func person(_ id: String, _ first: String, _ last: String, birthYear: Int?) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last, gender: nil,
            attributes: PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: .normal),
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func member(_ name: String, _ relationship: String, age: Int?,
                        isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age, isTarget: isTarget)
    }

    /// A census life-event carrying the household AND the schedule citation the
    /// apply path recorded — the shape a real applied census has on disk.
    private func citedCensusEvent(_ subjectID: String, year: Int,
                                  household: [HouseholdMember], url: String) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: subjectID, type: .census,
            date: GenealogicalDate(parsing: String(year)),
            details: .census(CensusDetails(household: household)),
            sources: [FieldSource(
                origin: SourceOrigin(identifier: "freecen"),
                raw: "Census \(year)",
                addedAt: Date(),
                citation: Citation(title: "Census \(year)", url: url, dateAccessed: Date(), notes: nil))])
    }

    // MARK: - Tests

    /// The bulk path ("Add all N"). Every person it creates cites the schedule.
    @MainActor
    @Test func addMissingCensusRelativesCitesCreatedPeopleToTheSchedule() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("samuel", "Samuel", "Wheeldon", birthYear: 1853), source: .gedcom)
        _ = try db.addProfile(person("john", "John", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addRelationship(parentEdge("john", "samuel"))

        let base = try db.buildSnapshot()
        let household = [
            member("John Wheeldon", "Head", age: 37),
            member("Samuel Wheeldon", "Son", age: 8, isTarget: true),
            member("Mary Wheeldon", "Daughter", age: 5)]
        let url = "https://www.freecen.org.uk/search_records/abc123/wheeldon-1861"
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = FamilyGraphSnapshot(
            profiles: base.profiles, relationships: base.relationships,
            lifeEvents: ["samuel": [citedCensusEvent("samuel", year: 1861,
                                                     household: household, url: url)]])

        appState.addMissingCensusRelatives(for: "samuel")

        let mary = try #require(appState.snapshot.profiles.values.first { $0.firstName == "Mary" },
                                "the missing sibling was created")
        #expect((mary.sources[.birthDate] ?? []).contains { $0.citation?.url == url },
                "a person created by the bulk path cites the household schedule")
    }

    /// The per-row path ("Add" beside one roster line) resolves the same URL.
    @MainActor
    @Test func addCensusRelativeCitesTheCreatedPersonToTheSchedule() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("ruth", "Ruth", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addProfile(person("john", "John", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("ruth", "john"))

        let base = try db.buildSnapshot()
        let household = [
            member("Ruth Wheeldon", "Wife", age: 37, isTarget: true),
            member("Hannah Wheeldon", "Dau", age: 8)]
        let url = "https://www.freecen.org.uk/search_records/def456/wheeldon-1861"
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = FamilyGraphSnapshot(
            profiles: base.profiles, relationships: base.relationships,
            lifeEvents: ["ruth": [citedCensusEvent("ruth", year: 1861,
                                                   household: household, url: url)]])

        appState.addCensusRelative(subjectID: "ruth",
                                   member: member("Hannah Wheeldon", "Dau", age: 8),
                                   relation: .child, censusYear: 1861)

        let hannah = try #require(appState.snapshot.profiles.values.first { $0.firstName == "Hannah" })
        #expect((hannah.sources[.birthDate] ?? []).contains { $0.citation?.url == url },
                "a person created by the per-row path cites the household schedule")
    }

    /// The in-law path creates a person from a census age too, so it cites the
    /// same schedule.
    @MainActor
    @Test func addSpouseParentFromInLawCitesTheSchedule() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("john", "John", "Cauldwell", birthYear: 1861), source: .gedcom)
        _ = try db.addProfile(person("eliza", "Elizabeth", "Cauldwell", birthYear: 1862), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("john", "eliza"))

        let base = try db.buildSnapshot()
        let household = [
            member("John Cauldwell", "Head", age: 30, isTarget: true),
            member("Elizabeth Cauldwell", "Wife", age: 29),
            member("Martha Barker", "Ma-Law", age: 66)]
        let url = "https://www.freecen.org.uk/search_records/ghi789/cauldwell-1891"
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = FamilyGraphSnapshot(
            profiles: base.profiles, relationships: base.relationships,
            lifeEvents: ["john": [citedCensusEvent("john", year: 1891,
                                                   household: household, url: url)]])

        appState.addSpouseParentFromInLaw(
            subjectID: "john", spouseID: "eliza",
            member: member("Martha Barker", "Ma-Law", age: 66), kind: .mother, censusYear: 1891)

        let martha = try #require(appState.snapshot.profiles.values.first { $0.firstName == "Martha" })
        #expect(martha.birthDate?.bestYear == 1825)
        #expect((martha.sources[.birthDate] ?? []).contains { $0.citation?.url == url },
                "the in-law's census-age birth year cites the household schedule")
    }

    /// The resolver refuses to hand back a URL it cannot tie to the year being
    /// added — a citation pointing at the wrong schedule is worse than none.
    @MainActor
    @Test func censusScheduleCitationURLRefusesAnUnmatchedYear() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("samuel", "Samuel", "Wheeldon", birthYear: 1853), source: .gedcom)

        let base = try db.buildSnapshot()
        let url = "https://www.freecen.org.uk/search_records/abc123/wheeldon-1861"
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = FamilyGraphSnapshot(
            profiles: base.profiles, relationships: base.relationships,
            lifeEvents: ["samuel": [citedCensusEvent("samuel", year: 1861, household: [], url: url)]])

        #expect(appState.censusScheduleCitationURL(subjectID: "samuel", censusYear: 1861) == url)
        #expect(appState.censusScheduleCitationURL(subjectID: "samuel", censusYear: 1871) == nil,
                "a different census year is not this schedule")
        #expect(appState.censusScheduleCitationURL(subjectID: "samuel", censusYear: nil) == nil,
                "an unknown year cannot be tied to a schedule")
    }
}
