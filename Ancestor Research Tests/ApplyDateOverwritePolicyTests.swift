import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the apply-path date-overwrite policy.
///
/// Background: `applyDateField` originally implemented "Check Before
/// Overwrite" as `if existing == nil`. That treated any set value as
/// untouchable — including wide GEDCOM ranges like `BET 1869 AND 1896`,
/// which then blocked 31-source cluster-confirmed quarters like
/// `Dec 1883` from ever reaching `Profile.birthDate`. Anchored to the
/// George Herbert Brooks symptom observed 2026-05-27.
///
/// Fix: the rule is directional — overwrite only when the candidate's
/// year-span is *strictly narrower* than the existing value's. Equal or
/// wider candidates go to `recordAlternativeFact` for evidence-log only.
@MainActor
struct ApplyDateOverwritePolicyTests {

    // MARK: - Narrowing direction

    @Test func overwritesWhenExistingIsNil() {
        let candidate = GenealogicalDate(parsing: "Dec 1883")
        #expect(ApplyEngine.shouldOverwriteDateField(existing: nil, candidate: candidate))
    }

    @Test func overwritesWhenCandidateIsStrictlyNarrower() {
        // The canonical George Brooks case: wide GEDCOM range vs precise
        // BMD quarter. Span 0 < span 27 → overwrite.
        let existing = GenealogicalDate(parsing: "BET 1869 AND 1896")
        let candidate = GenealogicalDate(parsing: "Dec 1883")
        #expect(ApplyEngine.shouldOverwriteDateField(existing: existing, candidate: candidate))
    }

    @Test func overwritesWhenCandidateNarrowsAnApproximateWindow() {
        // ABT 1880 → ±5 → span 10. Candidate is a precise quarter.
        let existing = GenealogicalDate(parsing: "ABT 1880")
        let candidate = GenealogicalDate(parsing: "Mar 1882")
        #expect(ApplyEngine.shouldOverwriteDateField(existing: existing, candidate: candidate))
    }

    // MARK: - Preserving precision (the original rule)

    @Test func keepsExistingWhenCandidateIsWider() {
        // A precise existing value must never be replaced by a wide range.
        // This is the original "Check Before Overwrite" rule — the bug fix
        // must not regress it.
        let existing = GenealogicalDate(parsing: "Dec 1883")
        let candidate = GenealogicalDate(parsing: "BET 1869 AND 1896")
        #expect(!ApplyEngine.shouldOverwriteDateField(existing: existing, candidate: candidate))
    }

    @Test func keepsExistingWhenCandidateIsEquallyPrecise() {
        // Same span — could be agreement or disagreement. Either way, no
        // overwrite. Disagreement (Jun 1870 vs Dec 1883) is a disambiguation
        // problem owned by multi-hypothesis investigation, not this layer.
        let existing = GenealogicalDate(parsing: "Jun 1870")
        let candidate = GenealogicalDate(parsing: "Dec 1883")
        #expect(!ApplyEngine.shouldOverwriteDateField(existing: existing, candidate: candidate))
    }

    @Test func keepsExistingWhenCandidateMatchesExactly() {
        let existing = GenealogicalDate(parsing: "Dec 1883")
        let candidate = GenealogicalDate(parsing: "Dec 1883")
        #expect(!ApplyEngine.shouldOverwriteDateField(existing: existing, candidate: candidate))
    }

    // MARK: - Edge cases

    @Test func treatsUnparseableExistingAsInfiniteSpan() {
        // Existing date with nil earliest/latest (e.g. "?" or garbage)
        // should not block a precise candidate.
        let existing = GenealogicalDate(parsing: "?")
        let candidate = GenealogicalDate(parsing: "Dec 1883")
        // existing has nil earliest/latest → yearSpan == .max → overwrite.
        #expect(ApplyEngine.shouldOverwriteDateField(existing: existing, candidate: candidate))
    }

    @Test func openEndedExistingIsWiderThanPreciseCandidate() {
        // "AFT 1880" has earliest=1880, latest=nil → span treated as .max.
        // A precise candidate must overwrite.
        let existing = GenealogicalDate(parsing: "AFT 1880")
        let candidate = GenealogicalDate(parsing: "Dec 1883")
        #expect(ApplyEngine.shouldOverwriteDateField(existing: existing, candidate: candidate))
    }
}
