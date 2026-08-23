import Testing
import Foundation
@testable import Ancestor_Research

/// The seeded surname variants the dispatcher fans out on at `.variant`
/// strictness.
///
/// Owner dogfood 2026-08-23. Mary STEVENSON's marriage register spells her with
/// a **v**; her 1823 Youlgreave baptism spells her with a **ph**. Same woman,
/// same church, twenty-three years apart, different clerk. `surname-variants.json`
/// carried 30 seed surnames and no Stevenson entry at all, so the fan-out never
/// probed STEPHENSON and her baptism — the record naming both her parents — was
/// unreachable from inside the app.
struct SurnameVariantSeedTests {

    @Test func stevensonReachesTheStephensonSpelling() {
        let variants = SurnameVariants.shared.variants(of: "Stevenson")
            .map { $0.lowercased() }
        #expect(variants.contains("stephenson"),
                "the ph spelling is the commonest form of this name in Derbyshire registers")
    }

    /// Both directions — a subject recorded as STEPHENSON must reach STEVENSON
    /// too, since the lookup is by key and carries no reverse index.
    @Test func theVariantIsSymmetric() {
        let fromPh = SurnameVariants.shared.variants(of: "Stephenson").map { $0.lowercased() }
        #expect(fromPh.contains("stevenson"))
    }

    /// Case-insensitive, as the loader documents.
    @Test func lookupIgnoresCase() {
        #expect(!SurnameVariants.shared.variants(of: "STEVENSON").isEmpty)
        #expect(!SurnameVariants.shared.variants(of: "stevenson").isEmpty)
    }

    /// The pre-existing seeds still resolve — the edit must not have broken the
    /// file (a malformed JSON silently loads as empty).
    @Test func theExistingSeedsSurvive() {
        #expect(SurnameVariants.shared.variants(of: "Holmes")
            .map { $0.lowercased() }.contains("holme"),
            "Elizabeth HOLME scored against Jacob HOLMES through this entry")
        #expect(SurnameVariants.shared.variants(of: "Cauldwell")
            .map { $0.lowercased() }.contains("caldwell"))
        #expect(SurnameVariants.shared.variants(of: "Thompson")
            .map { $0.lowercased() }.contains("thomson"))
    }

    /// An unseeded surname yields NO curated variants — the generated rules
    /// then carry it. Since 2026-08-23 the curated list exists only for
    /// IRREGULARS, so a plain name having no entry is correct, not a gap.
    @Test func unseededSurnamesYieldNoCuratedVariants() {
        #expect(SurnameVariants.shared.variants(of: "Zebedee").isEmpty)
        #expect(!ScoringRules.orthographicSurnameVariants(of: "Zebedee").isEmpty,
                "…but the rules still give it spellings to try")
    }

    // MARK: - Irregulars the rules cannot reach

    /// Pairs read off a SINGLE FreeBMD volume/page in Aug 2026 — one
    /// registration transcribed two ways, which is evidence rather than a
    /// guess. No rule produces M↔N or a dropped syllable.
    @Test func observedSamePagePairsAreSeeded() {
        #expect(SurnameVariants.shared.variants(of: "Newnes").contains("newmes"),
                "19/333 carried both spellings of one marriage")
        #expect(SurnameVariants.shared.variants(of: "Gardom").contains("gardon"))
        #expect(SurnameVariants.shared.variants(of: "Bateman").contains("batman"))
        #expect(SurnameVariants.shared.variants(of: "Moseley").contains("mosley"))
    }

    /// …and they are symmetric, because the lookup has no reverse index.
    @Test func observedPairsWorkFromEitherSpelling() {
        #expect(SurnameVariants.shared.variants(of: "Newmes").contains("newnes"))
        #expect(SurnameVariants.shared.variants(of: "Gardon").contains("gardom"))
        #expect(SurnameVariants.shared.variants(of: "Batman").contains("bateman"))
        #expect(SurnameVariants.shared.variants(of: "Mosley").contains("moseley"))
    }

    /// Local surnames from the working tree whose drift no rule generates.
    @Test func derbyshireIrregularsAreSeeded() {
        #expect(SurnameVariants.shared.variants(of: "Wheeldon").contains("wheldon"))
        #expect(SurnameVariants.shared.variants(of: "Redfern").contains("redfearn"))
        #expect(SurnameVariants.shared.variants(of: "Bonsall").contains("bonsal"))
        #expect(SurnameVariants.shared.variants(of: "Sims").contains("simms"))
        #expect(SurnameVariants.shared.variants(of: "Hodgkinson").contains("hodkinson"))
    }

    /// The comment keys are not surnames. The loader takes only array values,
    /// so they drop out — but a future editor could break that silently.
    @Test func commentKeysAreNotLoadedAsSurnames() {
        #expect(SurnameVariants.shared.variants(of: "_comment").isEmpty)
        #expect(SurnameVariants.shared.variants(of: "_observed_comment").isEmpty)
        #expect(SurnameVariants.shared.variants(of: "_derbyshire_comment").isEmpty)
    }

    /// No entry lists itself — a self-reference would emit a duplicate query.
    @Test func noEntryListsItself() {
        for name in ["Holmes", "Stevenson", "Wheeldon", "Newnes", "Moseley", "Sims"] {
            #expect(!SurnameVariants.shared.variants(of: name).contains(name.lowercased()),
                    "\(name) lists itself")
        }
    }
}
