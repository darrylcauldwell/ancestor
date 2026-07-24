import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// GivenNameContainsMiddleRule + `Profile.impliedGivenMiddleSplit` — flags
/// profiles whose `firstName` packed the middle name into the given field
/// (the GEDCOM-import shape, e.g. "Lilian Mary" with an empty `middleName`).
/// The audit chip and the Cleanse fix share this one detection helper, so the
/// tests pin the helper's behaviour directly as well as through the rule.
struct GivenNameContainsMiddleRuleTests {

    private func profile(first: String?, middle: String? = nil, last: String? = "Brooks") -> Profile {
        Profile(
            id: "p1", externalIDs: [:], firstName: first, middleName: middle, lastName: last,
            gender: .female, attributes: nil,
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func snapshot(_ p: Profile) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [p.id: p], relationships: [])
    }

    // MARK: - Split helper

    @Test func splitsFirstTokenAsGivenRemainderAsMiddle() {
        let split = profile(first: "Lilian Mary").impliedGivenMiddleSplit
        #expect(split?.first == "Lilian")
        #expect(split?.middle == "Mary")
    }

    @Test func multipleMiddleTokensAllGoToMiddle() {
        let split = profile(first: "George Eric Vaughn").impliedGivenMiddleSplit
        #expect(split?.first == "George")
        #expect(split?.middle == "Eric Vaughn")
    }

    @Test func singleTokenGivenHasNoSplit() {
        #expect(profile(first: "John").impliedGivenMiddleSplit == nil)
    }

    @Test func existingMiddleNameSuppressesSplit() {
        // middleName already set — trust the existing structure, don't re-split.
        #expect(profile(first: "Lilian Mary", middle: "Ann").impliedGivenMiddleSplit == nil)
    }

    @Test func emptyGivenHasNoSplit() {
        #expect(profile(first: nil).impliedGivenMiddleSplit == nil)
    }

    // MARK: - Audit rule

    @Test func ruleFiresOnFoldedGiven() {
        let p = profile(first: "Lilian Mary")
        let results = GivenNameContainsMiddleRule().evaluate(profile: p, snapshot: snapshot(p))
        #expect(results.count == 1)
        #expect(results.first?.ruleID == "givenNameContainsMiddle")
        #expect(results.first?.severity == .info)
    }

    @Test func ruleSilentWhenAlreadySplit() {
        let p = profile(first: "Lilian", middle: "Mary")
        #expect(GivenNameContainsMiddleRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func ruleSilentOnSingleTokenGiven() {
        let p = profile(first: "John")
        #expect(GivenNameContainsMiddleRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func ruleIsRegisteredInBuiltIns() {
        #expect(AuditRules.builtIn.contains { $0.id == "givenNameContainsMiddle" })
    }
}
