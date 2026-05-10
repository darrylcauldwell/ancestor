import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `ImportAsCorrectionsEngine` (M22 — DESIGN.md §13). Verifies
/// that a GEDCOM-style snapshot is split into direct additions plus
/// workbench hypotheses without auto-merging differing values.
struct ImportAsCorrectionsTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        birthDate: String? = nil,
        deathDate: String? = nil,
        externalIDs: [String: String] = [:]
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: externalIDs,
            firstName: firstName,
            lastName: lastName,
            gender: nil,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func snapshot(_ profiles: [Profile]) -> FamilyGraphSnapshot {
        var dict: [String: Profile] = [:]
        for p in profiles { dict[p.id] = p }
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    // MARK: - Tests

    @Test func identicalGEDCOMProducesZeroHypotheses() {
        let p = makeProfile(id: "a", firstName: "John", lastName: "Smith", birthDate: "1880")
        let snap = snapshot([p])

        let result = ImportAsCorrectionsEngine.diff(
            importedSnapshot: snap,
            existingSnapshot: snap,
            sourceLabel: "test.ged"
        )

        #expect(result.hypotheses.isEmpty)
        #expect(result.newProfiles.isEmpty)
        #expect(result.unchangedCount == 1)
    }

    @Test func oneFieldDiffProducesOneHypothesis() {
        // Match by name + birth-year overlap (±2). Different IDs.
        let existingP = makeProfile(
            id: "existing-a",
            firstName: "John", lastName: "Smith",
            birthDate: "1880"
        )
        let importedP = makeProfile(
            id: "imported-a",
            firstName: "John", lastName: "Smith",
            birthDate: "1881" // ±1 — within tolerance
        )

        let result = ImportAsCorrectionsEngine.diff(
            importedSnapshot: snapshot([importedP]),
            existingSnapshot: snapshot([existingP]),
            sourceLabel: "relatives.ged"
        )

        #expect(result.newProfiles.isEmpty)
        #expect(result.hypotheses.count == 1)
        #expect(result.unchangedCount == 0)

        let h = result.hypotheses[0]
        if case let .fieldValue(profileID, field, value) = h.claim {
            #expect(profileID == "existing-a")  // claim points at existing tree's ID
            #expect(field == .birthDate)
            #expect(value == "1881")
        } else {
            Issue.record("Expected .fieldValue claim, got \(h.claim)")
        }
        #expect(h.confidence == .speculation)
        #expect(h.status == .active)
        #expect(!h.contradictingEvidence.isEmpty) // existing value recorded
    }

    @Test func newProfileInImportIsAddedDirectly() {
        let existing = makeProfile(id: "a", firstName: "John", lastName: "Smith", birthDate: "1880")
        let novel = makeProfile(id: "b", firstName: "Mary", lastName: "Jones", birthDate: "1885")

        let result = ImportAsCorrectionsEngine.diff(
            importedSnapshot: snapshot([novel]),
            existingSnapshot: snapshot([existing]),
            sourceLabel: "test.ged"
        )

        #expect(result.newProfiles.count == 1)
        #expect(result.newProfiles.first?.id == "b")
        #expect(result.hypotheses.isEmpty)
        #expect(result.unchangedCount == 0)
    }

    @Test func removedProfileInImportIsIgnored() {
        // Profile exists in existing tree but not in import — must NOT
        // appear as a new profile, must NOT generate a soft-delete
        // hypothesis. Documented behaviour: imports never auto-remove.
        let onlyInExisting = makeProfile(id: "ghost", firstName: "Ghost", lastName: "Person", birthDate: "1700")

        let result = ImportAsCorrectionsEngine.diff(
            importedSnapshot: snapshot([]),  // empty import
            existingSnapshot: snapshot([onlyInExisting]),
            sourceLabel: "test.ged"
        )

        #expect(result.newProfiles.isEmpty)
        #expect(result.hypotheses.isEmpty)
        #expect(result.unchangedCount == 0)
    }

    @Test func hypothesisReasoningIncludesSourceLabel() {
        let existing = makeProfile(id: "x", firstName: "John", lastName: "Smith", birthDate: "1880")
        let imported = makeProfile(id: "y", firstName: "John", lastName: "Smith", birthDate: "1882")

        let result = ImportAsCorrectionsEngine.diff(
            importedSnapshot: snapshot([imported]),
            existingSnapshot: snapshot([existing]),
            sourceLabel: "relatives_2026.ged"
        )

        #expect(result.hypotheses.count == 1)
        let reasoning = result.hypotheses[0].reasoning
        #expect(reasoning.contains("relatives_2026.ged"))
    }

    @Test func nilToValueProducesHypothesis() {
        // Existing profile has no firstName; imported has "Mary". Match
        // happens via lastName + birth year (firstName is nil so we'd
        // miss the name path — use external ID for this test).
        let existing = makeProfile(
            id: "x", firstName: nil, lastName: "Smith", birthDate: "1880",
            externalIDs: ["wikitree": "Smith-1"]
        )
        let imported = makeProfile(
            id: "y", firstName: "Mary", lastName: "Smith", birthDate: "1880",
            externalIDs: ["wikitree": "Smith-1"]
        )

        let result = ImportAsCorrectionsEngine.diff(
            importedSnapshot: snapshot([imported]),
            existingSnapshot: snapshot([existing]),
            sourceLabel: "test.ged"
        )

        #expect(result.newProfiles.isEmpty)
        // At least one hypothesis for the nil → "Mary" change.
        let firstNameHypothesis = result.hypotheses.first { h in
            if case let .fieldValue(_, field, value) = h.claim {
                return field == .firstName && value == "Mary"
            }
            return false
        }
        #expect(firstNameHypothesis != nil)
        // "fill-in" branch — no contradicting evidence.
        #expect(firstNameHypothesis?.contradictingEvidence.isEmpty == true)
    }
}
