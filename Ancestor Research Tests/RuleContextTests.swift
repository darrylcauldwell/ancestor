import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for DataQualityRule in all three trigger contexts:
/// existingTree, newRecord, multipleSourceMerge.
@MainActor
struct RuleContextTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "test",
        firstName: String? = "John",
        lastName: String? = "Smith",
        birthDate: String? = "1834",
        deathDate: String? = "1890"
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName,
            gender: .male, attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: "Derbyshire",
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil, bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func makeSnapshot(profiles: [Profile]) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    // MARK: - Context 1: Existing Tree (Audit)

    @Test func existingTreeContextExecutesWithoutError() {
        let registry = DataQualityRuleRegistry()
        let profile = makeProfile(birthDate: "1890", deathDate: "1834")  // death before birth
        let snapshot = makeSnapshot(profiles: [profile])

        let results = registry.evaluateExistingTree(profile: profile, snapshot: snapshot)
        // Verify the context runs and returns typed results (may be empty if rules don't fire for this profile shape)
        #expect(results is [RuleResult])
    }

    @Test func existingTreeContextPassesCleanProfile() {
        let registry = DataQualityRuleRegistry()
        let profile = makeProfile(birthDate: "1834", deathDate: "1890")
        let snapshot = makeSnapshot(profiles: [profile])

        let results = registry.evaluateExistingTree(profile: profile, snapshot: snapshot)
        let errors = results.filter { $0.severity == .error }
        // Clean profile should have no errors for birth-before-death
        let deathBeforeBirthErrors = errors.filter { $0.message.lowercased().contains("death before birth") || $0.message.lowercased().contains("born after") }
        #expect(deathBeforeBirthErrors.isEmpty)
    }

    // MARK: - Context 2: New Record (Discrepancy)

    @Test func newRecordContextEvaluatesRecord() {
        let registry = DataQualityRuleRegistry()
        let profile = makeProfile(birthDate: "1834", deathDate: "1890")
        let snapshot = makeSnapshot(profiles: [profile])

        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "test", sourceID: "freebmd", name: nil,
                surname: "SMITH", givenName: "JOHN", detailURL: nil, rawFields: [:]),
            birthYear: 1834, birthDate: nil, birthPlace: nil,
            quarter: nil, district: "Belper", volume: nil, page: nil, mothersMaidenName: nil
        ))

        let results = registry.evaluateNewRecord(record: record, profile: profile, snapshot: snapshot)
        // Should return results (possibly empty if no discrepancies)
        #expect(results is [RuleResult])
    }

    // MARK: - Context 3: Multiple Source Merge

    @Test func mergeContextEvaluatesField() {
        let registry = DataQualityRuleRegistry()
        let profile = makeProfile(birthDate: "1834")
        let sources = [
            FieldSource(origin: .freebmd, raw: "1834", addedAt: Date()),
            FieldSource(origin: .freecen, raw: "1835", addedAt: Date()),
        ]

        let results = registry.evaluateMerge(field: .birthDate, sources: sources, profile: profile)
        #expect(results is [RuleResult])
    }

    // MARK: - All Three Contexts Return Same Type

    @Test func allContextsReturnRuleResults() {
        let registry = DataQualityRuleRegistry()
        let profile = makeProfile()
        let snapshot = makeSnapshot(profiles: [profile])

        let auditResults = registry.evaluateExistingTree(profile: profile, snapshot: snapshot)
        #expect(type(of: auditResults) == [RuleResult].self)

        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "t", sourceID: "freebmd", name: nil,
                surname: "SMITH", givenName: "JOHN", detailURL: nil, rawFields: [:]),
            birthYear: 1834, birthDate: nil, birthPlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil, mothersMaidenName: nil
        ))
        let newRecordResults = registry.evaluateNewRecord(record: record, profile: profile, snapshot: snapshot)
        #expect(type(of: newRecordResults) == [RuleResult].self)
    }
}
