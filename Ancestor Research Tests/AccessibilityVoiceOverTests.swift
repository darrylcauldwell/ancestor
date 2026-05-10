import Testing
import Foundation
@testable import Ancestor_Research

/// M24 — VoiceOver coverage for tree-canvas profile nodes. Canvas drawings
/// are opaque to assistive tech, so the tree view layers an accessibility
/// element per profile that reads the label produced by
/// `TreeAccessibilityLabel.nodeAccessibilityLabel(...)`. These tests pin
/// the label format so VoiceOver speech stays consistent and never reads
/// raw SF Symbol names.
struct AccessibilityVoiceOverTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "p1",
        firstName: String? = "Mary",
        lastName: String? = "Smith",
        birthDate: String? = nil,
        deathDate: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .female,
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

    private func makeCompleteness(
        score: Int,
        maximum: Int = 7,
        potentiallyLiving: Bool = false
    ) -> ProfileCompleteness {
        ProfileCompleteness(
            score: score,
            maximum: maximum,
            missing: [],
            potentiallyLiving: potentiallyLiving
        )
    }

    // MARK: - Label content

    @Test func labelIncludesNameBirthAndDeathYearsWhenBothPresent() {
        let profile = makeProfile(birthDate: "1842", deathDate: "1910")
        let comp = makeCompleteness(score: 6)

        let label = TreeAccessibilityLabel.nodeAccessibilityLabel(
            profile: profile,
            completeness: comp
        )

        #expect(label.contains("Mary Smith"))
        #expect(label.contains("born 1842"))
        #expect(label.contains("died 1910"))
        #expect(label.contains("6 of 7 facts"))
        // Must not leak raw SF Symbol names.
        #expect(!label.contains("checkmark"))
        #expect(!label.contains("systemImage"))
    }

    @Test func labelMarksPotentiallyLivingWhenOnlyBirthYearKnown() {
        let profile = makeProfile(birthDate: "1985", deathDate: nil)
        let comp = makeCompleteness(score: 3, potentiallyLiving: true)

        let label = TreeAccessibilityLabel.nodeAccessibilityLabel(
            profile: profile,
            completeness: comp
        )

        #expect(label.contains("Mary Smith"))
        #expect(label.contains("born 1985"))
        #expect(label.contains("living"))
        #expect(!label.contains("died"))
        #expect(label.contains("3 of 7 facts"))
    }

    @Test func labelHandlesProfileWithNoDates() {
        let profile = makeProfile(birthDate: nil, deathDate: nil)
        let comp = makeCompleteness(score: 2)

        let label = TreeAccessibilityLabel.nodeAccessibilityLabel(
            profile: profile,
            completeness: comp
        )

        #expect(label.contains("Mary Smith"))
        #expect(!label.contains("born"))
        #expect(!label.contains("died"))
        #expect(!label.contains("living"))
        #expect(label.contains("2 of 7 facts"))
        #expect(!label.isEmpty)
    }

    @Test func labelFallsBackToUnknownWhenDisplayNameIsBlank() {
        let profile = makeProfile(firstName: nil, lastName: nil)
        let comp = makeCompleteness(score: 0)

        let label = TreeAccessibilityLabel.nodeAccessibilityLabel(
            profile: profile,
            completeness: comp
        )

        #expect(label.hasPrefix("Unknown profile"))
        #expect(label.contains("0 of 7 facts"))
        #expect(!label.isEmpty)
    }

    @Test func hintIsStableAndDescribesNodeActions() {
        // Hint must mention the canvas keyboard interactions so VoiceOver
        // users know what's available beyond a plain double-tap.
        let hint = TreeAccessibilityLabel.nodeAccessibilityHint
        #expect(!hint.isEmpty)
        #expect(hint.lowercased().contains("space"))
        #expect(hint.lowercased().contains("return"))
    }
}
