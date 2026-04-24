import Testing
import Foundation
@testable import Ancestor_Research

struct AuditEngineTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "test",
        firstName: String? = "John",
        lastName: String? = "Smith",
        birthDate: String? = nil,
        deathDate: String? = nil,
        birthLocation: String? = nil,
        bio: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: bio,
            sources: [:],
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

    // MARK: - Birth Before Death

    @Test func birthBeforeDeath_exactDates_error() {
        let profile = makeProfile(birthDate: "1920", deathDate: "1668")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    @Test func birthBeforeDeath_validDates_noIssue() {
        let profile = makeProfile(birthDate: "1880", deathDate: "1960")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func birthBeforeDeath_approximateDates_warningOnly() {
        // ABT 1890 → range 1885-1895. Death 1888. Earliest(1885) < latest(1888) so no error.
        // But bestYear(1890) > bestYear(1888) → warning.
        let profile = makeProfile(birthDate: "ABT 1890", deathDate: "1888")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
    }

    @Test func birthBeforeDeath_missingDate_skips() {
        let profile = makeProfile(birthDate: "1880", deathDate: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func birthBeforeDeath_unboundedRange_skipsError() {
        // AFT 1920 → earliest=1920, latest=nil. Death 1900.
        // earliest(1920) > latest(1900) — but we can't use this because
        // birth.earliest is used, not birth.latest. Let me check...
        // Actually: birth.earliest(1920) > death.latest(1900) → ERROR. This is correct.
        let profile = makeProfile(birthDate: "AFT 1920", deathDate: "BEF 1900")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    // MARK: - Parent Age Gap

    @Test func parentAgeGap_tooYoung_error() {
        let parent = makeProfile(id: "parent", birthDate: "1874")
        let child = makeProfile(id: "child", birthDate: "1887")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentAgeGapRule().evaluate(profile: child, snapshot: snapshot)
        // 1874 + 14 = 1888 > 1887 → ERROR
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    @Test func parentAgeGap_adequate_noIssue() {
        let parent = makeProfile(id: "parent", birthDate: "1860")
        let child = makeProfile(id: "child", birthDate: "1887")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentAgeGapRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func parentAgeGap_stepParent_skips() {
        let parent = makeProfile(id: "step", birthDate: "1880")
        let child = makeProfile(id: "child", birthDate: "1887")
        let rel = Relationship(
            id: UUID(), from: "step", to: "child",
            type: .parent, role: .father, subtype: .step,
            marriageDate: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentAgeGapRule().evaluate(profile: child, snapshot: snapshot)
        // Step-parent — rule doesn't apply
        #expect(results.isEmpty)
    }

    // MARK: - Lifespan

    @Test func lifespan_exceeds110_error() {
        let profile = makeProfile(birthDate: "1800", deathDate: "1920")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = LifespanRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    @Test func lifespan_normal_noIssue() {
        let profile = makeProfile(birthDate: "1880", deathDate: "1960")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = LifespanRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Marriage Age

    @Test func marriageAge_tooYoung_error() {
        let profile = makeProfile(id: "person", birthDate: "1880")
        let spouse = makeProfile(id: "spouse")
        let rel = Relationship(
            id: UUID(), from: "person", to: "spouse",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: GenealogicalDate(parsing: "1890"), divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [profile, spouse], relationships: [rel])
        let results = MarriageAgeRule().evaluate(profile: profile, snapshot: snapshot)
        // 1890 < 1880 + 16 = 1896 → ERROR (married at age 10)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    // MARK: - No Marriage After Death

    @Test func noMarriageAfterDeath_error() {
        let profile = makeProfile(id: "person", deathDate: "1885")
        let spouse = makeProfile(id: "spouse")
        let rel = Relationship(
            id: UUID(), from: "person", to: "spouse",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: GenealogicalDate(parsing: "1890"), divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [profile, spouse], relationships: [rel])
        let results = NoMarriageAfterDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    // MARK: - Missing Data Rules

    @Test func missingParents_detected() {
        let profile = makeProfile()
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingParentsRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    @Test func missingParents_hasParent_ok() {
        let parent = makeProfile(id: "parent")
        let child = makeProfile(id: "child")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .unknown,
            marriageDate: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = MissingParentsRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func missingBirthDate_detected() {
        let profile = makeProfile(birthDate: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingBirthDateRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    @Test func missingBio_detected() {
        let profile = makeProfile(bio: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingBioRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    @Test func missingBio_hasBio_ok() {
        let profile = makeProfile(bio: "A biography of John Smith.")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingBioRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Duplicate Detection

    @Test func duplicateDetection_sameNameAndYear() {
        let a = makeProfile(id: "a", firstName: "Mabel", lastName: "Cauldwell", birthDate: "1897")
        let b = makeProfile(id: "b", firstName: "Mabel", lastName: "Cauldwell", birthDate: "1897")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.message.contains("Possible duplicate") == true)
    }

    @Test func duplicateDetection_differentNames_noMatch() {
        let a = makeProfile(id: "a", firstName: "John", lastName: "Smith", birthDate: "1880")
        let b = makeProfile(id: "b", firstName: "Mary", lastName: "Jones", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func duplicateDetection_nicknames() {
        let a = makeProfile(id: "a", firstName: "Bill", lastName: "Smith", birthDate: "1880")
        let b = makeProfile(id: "b", firstName: "William", lastName: "Smith", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        // Bill/William are nicknames → high similarity
        #expect(results.count == 1)
    }

    @Test func duplicateDetection_spellingVariant() {
        let a = makeProfile(id: "a", firstName: "John", lastName: "Caldwell", birthDate: "1880")
        let b = makeProfile(id: "b", firstName: "John", lastName: "Cauldwell", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        // Caldwell/Cauldwell → AU/A swap → 0.95 similarity
        #expect(results.count == 1)
    }

    // MARK: - Name Similarity

    @Test func nameSimilarity_exact() {
        #expect(nameSimilarity("Smith", "Smith") == 1.0)
    }

    @Test func nameSimilarity_auSwap() {
        #expect(nameSimilarity("Caldwell", "Cauldwell") == 0.95)
    }

    @Test func nameSimilarity_nickname() {
        #expect(nameSimilarity("Bill", "William") == 0.85)
        #expect(nameSimilarity("Bob", "Robert") == 0.85)
        #expect(nameSimilarity("Peggy", "Margaret") == 0.85)
    }

    @Test func nameSimilarity_contains() {
        #expect(nameSimilarity("Mary", "Mary Ann") == 0.8)
    }

    @Test func nameSimilarity_noMatch() {
        #expect(nameSimilarity("John", "Mary") == 0.0)
    }

    // MARK: - Full Audit on Real GEDCOM

    @Test func auditRealGEDCOM() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let testDir = thisFile.deletingLastPathComponent()
        let repoRoot = testDir.deletingLastPathComponent()
        let path = repoRoot.appendingPathComponent("Cauldwell Family Tree.ged").path

        let parsed = try GEDCOMParser.parse(fileAt: path)
        let summary = AuditEngine.auditGrouped(parsed.snapshot)

        #expect(summary.profilesChecked == 216)
        #expect(summary.total > 0)
        // Should find some missing data at minimum
        #expect(!summary.warnings.isEmpty || !summary.info.isEmpty)
    }
}
