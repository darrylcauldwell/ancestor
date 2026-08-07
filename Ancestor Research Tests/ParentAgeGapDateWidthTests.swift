import Testing
import Foundation
import AncestorKit

/// The parent-age-gap audit fires ERROR when `parentBirth.latest + 14 >
/// childBirth.earliest`. A census birth stored as "abt YYYY" (±5) widens both
/// ends, so a comfortable ~22-year midpoint gap collapses at the edges (parent
/// latest, child earliest) to ~12 and false-fires — the live Sarah A Thompson /
/// Elizabeth Burnett and Walter / Elizabeth A Beresford red errors. Since
/// 2026-08-07 `addCensusFamily` stores census-age births as calculated ±1
/// (CAL), so the same gap stays safe. These pin the date-width effect on the
/// rule (the observable reason the CAL fix matters).
struct ParentAgeGapDateWidthTests {

    private func profile(_ id: String, _ birth: String) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: "P", middleName: nil, lastName: id,
            marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
            gender: .unknown, attributes: nil,
            birthDate: GenealogicalDate(parsing: birth),
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func gapFindings(parentBirth: String, childBirth: String) -> [AuditResult] {
        let parent = profile("parent", parentBirth)
        let child = profile("child", childBirth)
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snap = FamilyGraphSnapshot(
            profiles: ["parent": parent, "child": child],
            relationships: [rel]
        )
        return ParentAgeGapRule().evaluate(profile: child, snapshot: snap)
    }

    /// The bug: a comfortable 22-year midpoint gap (1823 → 1845) stored as
    /// "abt" (±5) false-fires ERROR — parent latest 1828 + 14 = 1842 > child
    /// earliest 1840.
    @Test func aboutWidthFalseFiresOnComfortableGap() {
        #expect(gapFindings(parentBirth: "abt 1823", childBirth: "abt 1845")
            .contains { $0.severity == .error })
    }

    /// The fix: the same gap as calculated ±1 (CAL) does NOT fire — parent
    /// latest 1824 + 14 = 1838 < child earliest 1844.
    @Test func calculatedWidthDoesNotFireOnComfortableGap() {
        #expect(gapFindings(parentBirth: "CAL 1823", childBirth: "CAL 1845").isEmpty)
    }

    /// CAL still catches a genuinely too-small gap (10 years) — parent latest
    /// 1836 + 14 = 1850 > child earliest 1844.
    @Test func calculatedWidthStillCatchesRealViolation() {
        #expect(gapFindings(parentBirth: "CAL 1835", childBirth: "CAL 1845")
            .contains { $0.severity == .error })
    }
}
