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

    // MARK: - ScoringRules.orthographicGivenNameVariants (pure)

    /// Owner dogfood 2026-08-22. Harriet Holmes's own 1891 census was invisible to
    /// every FreeCen probe: the enumerator wrote HARRIETT with two t's, and the
    /// nickname cluster has nothing to say about a name spelled two ways (it is
    /// not a different name). So no query ever went out under the spelling the
    /// record was actually filed under.
    @Test func harrietFansToTheDoubledSpellingAndBack() {
        #expect(ScoringRules.orthographicGivenNameVariants(of: "Harriet") == ["HARRIETT"])
        #expect(ScoringRules.orthographicGivenNameVariants(of: "Harriett") == ["HARRIET"])
    }

    /// The other near-universal Victorian pair.
    @Test func annFansToAnneAndBack() {
        #expect(ScoringRules.orthographicGivenNameVariants(of: "Ann") == ["ANNE"])
        #expect(ScoringRules.orthographicGivenNameVariants(of: "Anne") == ["ANN"])
    }

    /// ANN must never undouble to AN — the 5-letter floor on rule 1. A junk probe
    /// costs a volunteer-run source a request and returns nothing.
    @Test func shortDoubledNamesDoNotUndouble() {
        let v = ScoringRules.orthographicGivenNameVariants(of: "Ann")
        #expect(!v.contains("AN"))
    }

    /// No generative letter-swapping: HARRIET gains a T, not a trailing E.
    @Test func noJunkTrailingEOnOrdinaryNames() {
        let v = ScoringRules.orthographicGivenNameVariants(of: "Harriet")
        #expect(!v.contains("HARRIETE"))
        #expect(ScoringRules.orthographicGivenNameVariants(of: "Mary").isEmpty)
        #expect(ScoringRules.orthographicGivenNameVariants(of: "Eve").isEmpty)
    }

    /// Never returns the input itself, whatever the rules produce.
    @Test func orthographicVariantsNeverIncludeTheInput() {
        for n in ["Harriet", "Harriett", "Ann", "Anne", "William", "Samuel"] {
            #expect(!ScoringRules.orthographicGivenNameVariants(of: n)
                .contains(n.uppercased()))
        }
    }

    // MARK: - Orthographic variants reach the wire

    /// The whole point: a variant-tier probe for HARRIET must also go out as
    /// HARRIETT, so her own census stops being unreachable.
    @Test func variantTierFansOrthographicSpellings() {
        let fanned = SearchDispatcher.applyStrictness(
            [query(given: "Harriet", surname: "Holmes")],
            strictness: .variant, source: FreeCenSource())
        let givens = Set(fanned.compactMap { $0.givenName?.uppercased() })
        #expect(givens.contains("HARRIET"), "the recorded spelling is still probed")
        #expect(givens.contains("HARRIETT"), "and so is the census's spelling")
    }

    /// Nickname and orthographic axes compose without either repeating a given
    /// name. The fan-out is a surname × given-name cross product, so a given name
    /// legitimately recurs once per surname variant — the assertion is scoped to
    /// a single surname, which is where a collision would actually show.
    @Test func nicknameAndOrthographicFanoutsDoNotCollide() {
        let fanned = SearchDispatcher.applyStrictness(
            [query(given: "Ann", surname: "Holmes")],
            strictness: .variant, source: FreeCenSource())
        let givensForOriginalSurname = fanned
            .filter { ($0.surname ?? "").uppercased() == "HOLMES" }
            .compactMap { $0.givenName?.uppercased() }
        #expect(givensForOriginalSurname.contains("ANNE"))
        #expect(givensForOriginalSurname.count == Set(givensForOriginalSurname).count,
                "no duplicate probes for a single surname")
    }
}
