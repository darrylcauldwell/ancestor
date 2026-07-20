import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Query-side given-name variants (Stage 2): outbound searches fan the given
/// name across the nickname table so a person registered under a formal or
/// sibling name (Harry→HENRY, Elsie→ELIZABETH/BETTY) is found by the sources,
/// not merely recognised in returned records. Anchored to the Harry Marshall
/// case (possibly registered HENRY, invisible to every source until now).
@MainActor
struct GivenNameVariantFanoutTests {

    // MARK: - ScoringRules.givenNameVariants (pure)

    @Test func harryFansToHenry() {
        #expect(ScoringRules.givenNameVariants(of: "Harry") == ["HENRY"])
        #expect(ScoringRules.givenNameVariants(of: "Henry") == ["HARRY"])
    }

    /// Elsie → Elizabeth, and thence its sibling nicknames (transitive cluster).
    @Test func elsieReachesElizabethAndSiblings() {
        let v = Set(ScoringRules.givenNameVariants(of: "Elsie"))
        #expect(v.contains("ELIZABETH"))
        #expect(v.contains("BETTY"))
        #expect(v.contains("LIZZIE"))
        #expect(!v.contains("ELSIE"))   // never includes itself
    }

    /// From the canonical side too — Elizabeth reaches all its nicknames.
    @Test func elizabethReachesAllNicknames() {
        let v = Set(ScoringRules.givenNameVariants(of: "Elizabeth"))
        #expect(v.isSuperset(of: ["ELSIE", "BETTY", "LIZZIE"]))
    }

    /// Many-to-one canonical (Ada) resolves both directions.
    @Test func adaClusterResolvesBothWays() {
        let fromNick = Set(ScoringRules.givenNameVariants(of: "Adelaide"))
        #expect(fromNick.isSuperset(of: ["ADA", "ADELINE", "ADELA", "ADELINA"]))
    }

    @Test func unknownNameHasNoVariants() {
        #expect(ScoringRules.givenNameVariants(of: "Zebulon").isEmpty)
        #expect(ScoringRules.givenNameVariants(of: "").isEmpty)
    }

    // MARK: - Dispatcher fan-out at the .variant tier

    private func query(given: String?, surname: String?) -> RecordQuery {
        RecordQuery(surname: surname, givenName: given, recordType: .death,
                    yearFrom: 1962, yearTo: 1964, gender: .male, region: nil, sourceParams: .generic)
    }

    /// A "Harry" death query fans to include a "HENRY" probe at the variant tier.
    @Test func variantTierFansGivenNameForFreeBMD() {
        let fanned = SearchDispatcher.applyStrictness(
            [query(given: "Harry", surname: "Marshall")],
            strictness: .variant, source: FreeBMDSource())
        let givens = Set(fanned.compactMap { $0.givenName?.uppercased() })
        #expect(givens.contains("HARRY"), "original given name is still probed")
        #expect(givens.contains("HENRY"), "the formal-name variant is now probed too")
    }

    /// Surname-only queries (no given name) are not given-name-fanned — they
    /// stay on the surname-fan path with its storm guard.
    @Test func surnameOnlyQueryNotGivenNameFanned() {
        let fanned = SearchDispatcher.applyStrictness(
            [query(given: nil, surname: "Marshall")],
            strictness: .variant, source: FreeBMDSource())
        // Every resulting query still has a nil given name.
        #expect(fanned.allSatisfy { ($0.givenName ?? "").isEmpty })
    }

    /// The strict tier is unchanged — no given-name fan-out.
    @Test func strictTierDoesNotFan() {
        let fanned = SearchDispatcher.applyStrictness(
            [query(given: "Harry", surname: "Marshall")],
            strictness: .strict, source: FreeBMDSource())
        let givens = Set(fanned.compactMap { $0.givenName?.uppercased() })
        #expect(givens == ["HARRY"], "strict probes only the recorded given name")
    }
}
