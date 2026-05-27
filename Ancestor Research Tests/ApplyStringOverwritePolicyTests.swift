import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the apply-path string-overwrite policy (#15).
///
/// Strings have no precision axis like dates, so the directional
/// "Check Before Overwrite" rule (`feedback_check_before_overwrite.md`)
/// is implemented via provenance tiers (`SourceOrigin.tier`):
///
///     initialImport (gedcom, wikitree)
///         < researchSource (freebmd, freereg, freecen, familysearch, …)
///         < userAuthoritative (manual.*)
///
/// A higher-tier candidate overrides a lower-tier existing value. Same
/// tier never overrides — that's a disambiguation problem owned by the
/// multi-hypothesis slice. Defensive default when existing is set but
/// audit log is empty: don't overwrite (preserve user data).
///
/// Anchored to the George Herbert Brooks symptom 2026-05-27: profile
/// shows `birthLocation = Basford` (wikitree initial import) but a
/// 31-source FREEBMD cluster confirmed `Belper`. Origin-tier rule must
/// allow freebmd (researchSource) to overrule wikitree (initialImport).
@MainActor
struct ApplyStringOverwritePolicyTests {

    private func source(origin: SourceOrigin) -> FieldSource {
        FieldSource(origin: origin, raw: "x", addedAt: Date())
    }

    // MARK: - Higher-tier overrides

    @Test func freebmdOverridesWikitreeInitialImport() {
        // The canonical George case: Basford (wikitree) yields to Belper
        // (freebmd cluster).
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Basford",
            existingSources: [source(origin: .wikitree)],
            candidateOrigin: .freebmd
        )
        #expect(result)
    }

    @Test func freebmdOverridesGedcomInitialImport() {
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Basford",
            existingSources: [source(origin: .gedcom)],
            candidateOrigin: .freebmd
        )
        #expect(result)
    }

    @Test func manualOverridesResearchSource() {
        // User-typed location takes over a freebmd-derived one — but in
        // practice user edits are made through a different code path; this
        // just pins that the tier comparison is symmetric.
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Belper",
            existingSources: [source(origin: .freebmd)],
            candidateOrigin: .manualMemory
        )
        #expect(result)
    }

    // MARK: - Same-tier / lower-tier do NOT override

    @Test func researchSourceDoesNotOverrideAnotherResearchSource() {
        // freebmd vs freecen — same tier. Don't auto-pick; the
        // multi-hypothesis slice resolves disagreements via corroborating
        // evidence.
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Belper",
            existingSources: [source(origin: .freebmd)],
            candidateOrigin: .freecen
        )
        #expect(!result)
    }

    @Test func initialImportDoesNotOverrideResearchSource() {
        // Going the wrong way: a wikitree value can't replace a freebmd
        // value. Preserves the citation-grade evidence.
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Belper",
            existingSources: [source(origin: .freebmd)],
            candidateOrigin: .wikitree
        )
        #expect(!result)
    }

    @Test func researchSourceDoesNotOverrideManual() {
        // User-typed wins over research source — never silently overwrite a
        // user's decision.
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Belper, Derbyshire",
            existingSources: [source(origin: .manualMemory)],
            candidateOrigin: .freebmd
        )
        #expect(!result)
    }

    // MARK: - Picks highest tier when multiple sources exist

    @Test func highestExistingTierWins() {
        // If existing has been touched by multiple sources (e.g. initial
        // wikitree import AND a later manual confirmation), the *highest*
        // tier sets the bar. A research-source candidate can't override
        // because manual is on file.
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Belper",
            existingSources: [
                source(origin: .wikitree),
                source(origin: .manualMemory),
            ],
            candidateOrigin: .freebmd
        )
        #expect(!result)
    }

    // MARK: - Empty existing

    @Test func writesWhenExistingIsNil() {
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: nil,
            existingSources: [],
            candidateOrigin: .freebmd
        )
        #expect(result)
    }

    @Test func writesWhenExistingIsEmptyString() {
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "   ",
            existingSources: [],
            candidateOrigin: .freebmd
        )
        #expect(result)
    }

    // MARK: - Defensive: existing set but no audit log

    @Test func defensiveDefaultRefusesToOverwriteWhenSourcesAreEmpty() {
        // Profile field is set but field_sources audit log is empty —
        // could mean corruption or a code path that skipped the log.
        // Either way, refuse to overwrite. Preserves the user's data;
        // the candidate still lands as an alternative fact via the
        // caller's else-branch.
        let result = ResearchViewModel.shouldOverwriteStringField(
            existing: "Belper",
            existingSources: [],
            candidateOrigin: .freebmd
        )
        #expect(!result)
    }
}
