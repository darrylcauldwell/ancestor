import Testing
import Foundation
@testable import Ancestor_Research

/// M16.3 — audit rules read disputes via `Profile.effectiveDate(_:)`.
/// When a date field has competing sources, rules see the union range
/// across all of them, not just the stored point value. Rule fires only
/// when the violation holds across the entire range — the conservative
/// bound promise from DESIGN.md §5.7.
struct AuditDisputeAwarenessTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "test",
        firstName: String? = "John",
        lastName: String? = "Smith",
        birthDate: String? = nil,
        deathDate: String? = nil,
        disputes: [ProfileField: FieldDispute] = [:]
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: disputes
        )
    }

    private func makeSnapshot(
        profiles: [Profile],
        relationships: [Relationship] = []
    ) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: relationships)
    }

    private func birthDispute(rawValues: [String]) -> FieldDispute {
        let competing = rawValues.map {
            FieldSource(origin: .manual, raw: $0, addedAt: Date())
        }
        return FieldDispute(
            field: .birthDate,
            reason: .noOverlap,
            competingSources: competing,
            detectedAt: Date(),
            resolution: nil
        )
    }

    // MARK: - Foundation helper

    @Test func effectiveDateReturnsStoredWhenNoDispute() {
        let profile = makeProfile(birthDate: "1880")
        let result = profile.effectiveDate(.birthDate)
        #expect(result?.earliest == 1880)
        #expect(result?.latest == 1880)
    }

    @Test func effectiveDateReturnsUnionWhenDisputed() {
        // Two sources spanning 1870-1880 ("BET 1870 AND 1880") and
        // 1900-1910 ("BET 1900 AND 1910"). Union should be 1870..1910.
        let dispute = birthDispute(rawValues: [
            "BET 1870 AND 1880",
            "BET 1900 AND 1910",
        ])
        let profile = makeProfile(
            birthDate: "BET 1870 AND 1880",
            disputes: [.birthDate: dispute]
        )
        let result = profile.effectiveDate(.birthDate)
        #expect(result?.earliest == 1870)
        #expect(result?.latest == 1910)
    }

    // MARK: - Rules respect the union range

    @Test func birthBeforeDeathRespectsUnionRangeWhenDisputed() {
        // Disputed birth (1870-1880 vs 1900-1910) → union 1870..1910.
        // Death = 1895. Union covers 1895, so the rule must NOT fire —
        // there is a plausible birth/death ordering across all sources.
        let dispute = birthDispute(rawValues: [
            "BET 1870 AND 1880",
            "BET 1900 AND 1910",
        ])
        let profile = makeProfile(
            birthDate: "BET 1870 AND 1880",
            deathDate: "1895",
            disputes: [.birthDate: dispute]
        )
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        // Union earliest 1870 vs death.latest 1895: 1870 > 1895 false → no error.
        // Union bestYear (1870+1910)/2 = 1890; death bestYear 1895; 1890 > 1895 false → no warning.
        #expect(results.isEmpty)
    }

    @Test func parentAgeGapUsesUnionWhenChildBirthDisputed() {
        // Parent born 1860. Child has disputed birth: "1870" vs "1875".
        // Union 1870..1875. Stored value 1870 alone might trigger; with
        // the wider range, rule still fires only when violation holds —
        // here parent.latest(1860)+14 = 1874, child.earliest 1870, so
        // 1874 > 1870 true → ERROR. Verifying union doesn't suppress
        // genuine errors.
        let dispute = birthDispute(rawValues: ["1870", "1875"])
        let parent = makeProfile(id: "parent", birthDate: "1860")
        let child = makeProfile(
            id: "child",
            birthDate: "1870",
            disputes: [.birthDate: dispute]
        )
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentAgeGapRule().evaluate(profile: child, snapshot: snapshot)
        // Union earliest 1870; parent.latest 1860 + 14 = 1874 > 1870 → ERROR
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    // MARK: - Regression — non-disputed fields behave as before

    @Test func nonDisputedFieldsBehaveAsBefore() {
        // Stays-the-same regression: a plain birthDate without disputes
        // produces the same audit results as before M16.3.
        let profile = makeProfile(birthDate: "1920", deathDate: "1668")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }
}
