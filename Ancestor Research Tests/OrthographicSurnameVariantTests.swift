import Testing
import Foundation
@testable import Ancestor_Research

/// Surname variants generated from rules rather than curated one funeral at a
/// time.
///
/// Owner dogfood 2026-08-23: *"surname-variants.json appears to have been built
/// by trial and error — is there a more complete sweep we can perform?"* There
/// is. Reading the 30 seeds, four in five are instances of a handful of
/// productive rules, and Stevenson/Stephenson — which hid Mary's baptism, the
/// record naming both her parents — is simply the PH↔V rule nobody had hit yet.
struct OrthographicSurnameVariantTests {

    private func variants(_ s: String) -> Set<String> {
        Set(ScoringRules.orthographicSurnameVariants(of: s))
    }

    // MARK: - The rule that cost us a record

    @Test func stephensonReachesStevenson() {
        #expect(variants("Stephenson").contains("STEVENSON"))
    }

    @Test func stevensonReachesStephenson() {
        #expect(variants("Stevenson").contains("STEPHENSON"))
    }

    // MARK: - The rules the curated list was approximating

    @Test func terminalSilentE() {
        #expect(variants("Brown").contains("BROWNE"))
        #expect(variants("Clarke").contains("CLARK"))
        #expect(variants("Greene").contains("GREEN"))
    }

    @Test func yAndILeapfrog() {
        #expect(variants("Smith").contains("SMYTH"))
        #expect(variants("Whyte").contains("WHITE"))
    }

    @Test func medialPBeforeS() {
        #expect(variants("Thompson").contains("THOMSON"))
        #expect(variants("Thomson").contains("THOMPSON"))
    }

    @Test func agentSuffixDrift() {
        #expect(variants("Taylor").contains("TAYLER"))
        #expect(variants("Walker").contains("WALKAR"))
    }

    @Test func doubledInteriorConsonant() {
        #expect(variants("Willson").contains("WILSON"))
        #expect(variants("Robberts").contains("ROBERTS"))
    }

    // MARK: - Restraint

    /// A surname never generates itself.
    @Test func theOriginalIsNeverAVariantOfItself() {
        for name in ["Holmes", "Stevenson", "Smith", "Brown", "Taylor"] {
            #expect(!variants(name).contains(name.uppercased()))
        }
    }

    /// Bounded — every variant is a live request against a volunteer server.
    @Test func theFanOutIsCapped() {
        for name in ["Stephenson", "Wolstenholme", "Featherstonehaugh", "Brotherton"] {
            #expect(ScoringRules.orthographicSurnameVariants(of: name).count <= 6,
                    "\(name) fanned out too far")
        }
    }

    /// Short names and non-alphabetic input generate nothing — "Fox" has no
    /// room for a rule to bite without changing the name.
    @Test func shortAndOddInputsGenerateNothing() {
        #expect(ScoringRules.orthographicSurnameVariants(of: "Fox").isEmpty)
        #expect(ScoringRules.orthographicSurnameVariants(of: "").isEmpty)
        #expect(ScoringRules.orthographicSurnameVariants(of: "O'Brien").isEmpty)
        #expect(ScoringRules.orthographicSurnameVariants(of: "de la Mare").isEmpty)
    }

    /// Deterministic — the scorer is a deterministic sandwich and its inputs
    /// must be too.
    @Test func generationIsStable() {
        #expect(ScoringRules.orthographicSurnameVariants(of: "Stevenson")
            == ScoringRules.orthographicSurnameVariants(of: "stevenson"))
        #expect(ScoringRules.orthographicSurnameVariants(of: "Stevenson")
            == ScoringRules.orthographicSurnameVariants(of: "  STEVENSON  "))
    }

    // MARK: - Coverage against the curated seeds

    /// The point of the exercise: how much of the hand-built list do the rules
    /// reproduce? Whatever they miss IS the irregular list worth keeping by
    /// hand (Holmes/Hulme, Lee/Leigh — no rule turns an O into a U).
    @Test func theRulesReproduceMostOfTheCuratedSeeds() {
        let seeds = ["smith", "brown", "clark", "green", "king", "hill", "taylor",
                     "walker", "wilson", "thompson", "white", "adams", "roberts"]
        var reproduced = 0, total = 0
        for seed in seeds {
            let curated = Set(SurnameVariants.shared.variants(of: seed).map { $0.uppercased() })
            guard !curated.isEmpty else { continue }
            let generated = variants(seed)
            total += 1
            if !curated.isDisjoint(with: generated) { reproduced += 1 }
        }
        #expect(total > 0)
        #expect(reproduced >= total - 2,
                "rules reproduced \(reproduced)/\(total) curated seeds — expected nearly all")
    }
}
