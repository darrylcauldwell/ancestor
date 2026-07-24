import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// ImpossibleParentageRule hardening — the date check must compare CONSERVATIVE
/// bounds (parent's earliest possible birth vs child's latest possible birth)
/// so a widely-disputed / estimated birth date can't fire a false impossibility
/// from the midpoint of its range. Anchored to the real Gertrude Cauldwell case
/// (b.1920 with a mis-attached 1859 census → effective range [1859,1920],
/// midpoint ~1889, which collided with her 1889-born father Samuel).
struct ImpossibleParentageRuleTests {

    private func profile(id: String, first: String, birth: GenealogicalDate?, gender: Gender = .unknown) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: "Cauldwell",
            gender: gender, attributes: nil,
            birthDate: birth, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func range(_ lo: Int, _ hi: Int) -> GenealogicalDate {
        GenealogicalDate(original: "BET \(lo) AND \(hi)", earliest: lo, latest: hi,
                         isApproximate: true, qualifier: .between)
    }
    private func exact(_ y: Int) -> GenealogicalDate {
        GenealogicalDate(original: "\(y)", earliest: y, latest: y,
                         isApproximate: false, qualifier: .exact)
    }

    private func evaluateChild(_ child: Profile, parent: Profile) -> [AuditResult] {
        let edge = Relationship(
            id: UUID(), from: parent.id, to: child.id, type: .parent,
            role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        let snap = FamilyGraphSnapshot(
            profiles: [child.id: child, parent.id: parent], relationships: [edge])
        return ImpossibleParentageRule().evaluate(profile: child, snapshot: snap)
    }

    @Test func disputedChildBirthDoesNotFalseFire() {
        // Effective birth [1859,1920] (mis-attached 1859 census); father born
        // 1889 is in range, so the edge is NOT impossible.
        let child = profile(id: "child", first: "Gertrude", birth: range(1859, 1920))
        let parent = profile(id: "parent", first: "Samuel", birth: exact(1889), gender: .male)
        #expect(evaluateChild(child, parent: parent).isEmpty)
    }

    @Test func parentBornStrictlyAfterChildFires() {
        let child = profile(id: "child", first: "Child", birth: exact(1900))
        let parent = profile(id: "parent", first: "Parent", birth: exact(1920), gender: .male)
        #expect(evaluateChild(child, parent: parent).contains { $0.ruleID == "impossibleParentage" })
    }

    @Test func sameYearExactStillFires() {
        // A parent born the exact same year as the child (age 0) is impossible.
        let child = profile(id: "child", first: "Child", birth: exact(1900))
        let parent = profile(id: "parent", first: "Parent", birth: exact(1900), gender: .male)
        #expect(!evaluateChild(child, parent: parent).isEmpty)
    }

    @Test func normalParentGapDoesNotFire() {
        let child = profile(id: "child", first: "Child", birth: exact(1920))
        let parent = profile(id: "parent", first: "Parent", birth: exact(1889), gender: .male)
        #expect(evaluateChild(child, parent: parent).isEmpty)
    }

    @Test func contemporaryParentFiresEvenWithFuzzyDate() {
        // Joseph (1861) with Elizabeth (CAL ~1861, range 1860–1862) as parent:
        // she can't be his mother — a near-same-age fuzzy estimate must still
        // fire (the regression the conservative-bounds fix originally lost).
        let child = profile(id: "child", first: "Joseph", birth: exact(1861))
        let parent = profile(id: "parent", first: "Elizabeth", birth: range(1860, 1862))
        #expect(!evaluateChild(child, parent: parent).isEmpty)
    }

    @Test func plausiblyYoungParentDoesNotFireImpossible() {
        // A ~15-year gap is young but biologically possible — ParentAgeGap may
        // warn, but the "impossible" error must not fire.
        let child = profile(id: "child", first: "Child", birth: exact(1915))
        let parent = profile(id: "parent", first: "Parent", birth: exact(1900), gender: .male)
        #expect(evaluateChild(child, parent: parent).isEmpty)
    }
}
