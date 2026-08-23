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

    /// An unseeded surname yields NO variants — the dispatcher then fans out to
    /// a single query on the canonical spelling. Documents the real contract:
    /// every surname outside these ~30 seeds is searched one way only, which is
    /// why the list's coverage is the binding constraint on this whole feature.
    @Test func unseededSurnamesYieldNoVariants() {
        #expect(SurnameVariants.shared.variants(of: "Wheeldon").isEmpty)
        #expect(SurnameVariants.shared.variants(of: "Boam").isEmpty)
    }
}
