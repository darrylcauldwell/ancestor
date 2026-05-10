import Testing
import Foundation
@testable import Ancestor_Research

/// M16.6 — manual-mode guidance framing. When the project is small +
/// manual, gap-style audit results are surfaced through a friendlier
/// `guidanceMessage` rather than the canonical warning copy. Errors and
/// consistency rules are unaffected.
struct ManualGuidanceTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "test",
        firstName: String? = "John",
        lastName: String? = "Smith",
        birthDate: String? = nil,
        deathDate: String? = nil
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
            disputes: [:]
        )
    }

    private func makeSnapshot(profiles: [Profile]) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    // MARK: - Engine attaches guidance only in manual mode

    @Test func auditEngineEmitsGuidanceWhenManualMode() {
        // Profile with no birth date — MissingBirthDateRule fires.
        let profile = makeProfile(birthDate: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = AuditEngine.audit(snapshot, isManualGuidanceMode: true)
        let missing = results.first { $0.ruleID == "missingBirthDate" }
        #expect(missing != nil)
        #expect(missing?.guidanceMessage != nil)
        #expect(missing?.guidanceMessage?.contains("birth date") == true)
        #expect(missing?.guidanceMessage?.contains(profile.displayName) == true)
    }

    @Test func auditEngineEmitsCanonicalWhenNotManualMode() {
        // Same profile, default mode → no guidance, canonical warning copy
        // is the only message.
        let profile = makeProfile(birthDate: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = AuditEngine.audit(snapshot)
        let missing = results.first { $0.ruleID == "missingBirthDate" }
        #expect(missing != nil)
        #expect(missing?.guidanceMessage == nil)
    }

    // MARK: - Per-rule guidance helper

    @Test func missingBirthDateRuleProvidesGuidanceText() {
        let profile = makeProfile()
        let guidance = MissingBirthDateRule().guidanceMessage(profile: profile)
        #expect(guidance != nil)
        #expect(guidance?.contains("birth date") == true)
        #expect(guidance?.contains("John Smith") == true)
    }
}
