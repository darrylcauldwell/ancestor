import Testing
import Foundation
@testable import Ancestor_Research

struct SourcingIntegrityTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "p1",
        firstName: String? = "Jane",
        lastName: String? = "Doe",
        gender: Gender? = .female,
        birthDate: String? = "1900",
        birthLocation: String? = "London",
        deathDate: String? = "1970",
        deathLocation: String? = "London",
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

    private func source(_ origin: SourceOrigin, raw: String = "ref") -> FieldSource {
        FieldSource(origin: origin, raw: raw, addedAt: Date())
    }

    private func snapshot(_ profiles: [Profile]) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    // MARK: - No sources at all

    @Test func profileWithNoSources_allPopulatedFieldsUnsourced() {
        let profile = makeProfile(bio: "Lived in London.")
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))

        // 8 populated fields: firstName, lastName, gender, birthDate, birthLocation,
        // deathDate, deathLocation, bio
        #expect(report.totalFields == 8)
        #expect(report.unsourced.count == 8)
        #expect(report.estimateOnly.isEmpty)
        #expect(report.manualOnly.isEmpty)

        let fields = Set(report.unsourced.map { $0.field })
        #expect(fields.contains(.firstName))
        #expect(fields.contains(.lastName))
        #expect(fields.contains(.gender))
        #expect(fields.contains(.birthDate))
        #expect(fields.contains(.birthLocation))
        #expect(fields.contains(.deathDate))
        #expect(fields.contains(.deathLocation))
        #expect(fields.contains(.bio))
    }

    // MARK: - Estimate-only

    @Test func profileWithEstimateSourceOnBirthDate_appearsInEstimateOnly() {
        let profile = makeProfile(
            birthDate: "1900",
            sources: [.birthDate: [source(.manualEstimate)]]
        )
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))

        // birthDate must be in estimateOnly...
        #expect(report.estimateOnly.contains(where: { $0.field == .birthDate }))
        // ...and NOT in unsourced
        #expect(!report.unsourced.contains(where: { $0.field == .birthDate }))
        // estimate is also a manual origin, so it should also be in manualOnly
        #expect(report.manualOnly.contains(where: { $0.field == .birthDate }))
    }

    // MARK: - Manual-only (non-estimate)

    @Test func profileWithManualMemorySource_appearsInManualOnlyButNotEstimateOnly() {
        let profile = makeProfile(
            birthDate: "1900",
            sources: [.birthDate: [source(.manualMemory)]]
        )
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))

        #expect(report.manualOnly.contains(where: { $0.field == .birthDate }))
        #expect(!report.estimateOnly.contains(where: { $0.field == .birthDate }))
        #expect(!report.unsourced.contains(where: { $0.field == .birthDate }))
    }

    // MARK: - Clean (non-manual source)

    @Test func profileWithFreeBMDSource_appearsInNoCategory() {
        let profile = makeProfile(
            birthDate: "1900",
            sources: [.birthDate: [source(.freebmd)]]
        )
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))

        #expect(!report.unsourced.contains(where: { $0.field == .birthDate }))
        #expect(!report.estimateOnly.contains(where: { $0.field == .birthDate }))
        #expect(!report.manualOnly.contains(where: { $0.field == .birthDate }))
    }

    // MARK: - Mixed manual + non-manual

    @Test func profileWithMixedSources_birthDateClean() {
        let profile = makeProfile(
            birthDate: "1900",
            sources: [.birthDate: [source(.manualMemory), source(.freebmd)]]
        )
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))

        // Mixed = at least one non-manual = clean.
        #expect(!report.manualOnly.contains(where: { $0.field == .birthDate }))
        #expect(!report.estimateOnly.contains(where: { $0.field == .birthDate }))
        #expect(!report.unsourced.contains(where: { $0.field == .birthDate }))
    }

    // MARK: - totalFields counts populated only

    @Test func totalFields_countsPopulatedOnly_skipsNilAndEmptyBio() {
        // Only firstName + birthDate populated; bio is nil.
        let profile = makeProfile(
            firstName: "Solo",
            lastName: nil,
            gender: nil,
            birthDate: "1900",
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil
        )
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))
        #expect(report.totalFields == 2)
    }

    @Test func totalFields_emptyStringBioIsSkipped() {
        let profile = makeProfile(
            firstName: "Solo",
            lastName: nil,
            gender: nil,
            birthDate: nil,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: ""
        )
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))
        #expect(report.totalFields == 1) // only firstName
    }

    @Test func totalFields_unknownGenderIsSkipped() {
        let profile = makeProfile(
            firstName: nil,
            lastName: nil,
            gender: .unknown,
            birthDate: nil,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil
        )
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))
        #expect(report.totalFields == 0)
    }

    // MARK: - Empty snapshot

    @Test func emptySnapshot_allArraysEmpty() {
        let report = SourcingIntegrityAnalyser.analyse(snapshot: .empty)
        #expect(report.totalFields == 0)
        #expect(report.unsourced.isEmpty)
        #expect(report.estimateOnly.isEmpty)
        #expect(report.manualOnly.isEmpty)
    }

    // MARK: - Issue identity

    @Test func issueID_combinesProfileAndField() {
        let profile = makeProfile(id: "abc", firstName: "Jane")
        let report = SourcingIntegrityAnalyser.analyse(snapshot: snapshot([profile]))
        let firstNameIssue = report.unsourced.first(where: { $0.field == .firstName })
        #expect(firstNameIssue?.id == "abc:firstName")
        #expect(firstNameIssue?.profileID == "abc")
        #expect(firstNameIssue?.displayValue == "Jane")
    }
}
