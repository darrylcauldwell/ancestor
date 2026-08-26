import Testing
import Foundation
@testable import Ancestor_Research

/// EV15 (owner dogfood 2026-08-26) — F2's coarser-place refinement filter.
///
/// William Gladwin carried an OPEN `birthLocation` dispute between the stored
/// "Teversal, Nottinghamshire, England" and the 1891 census's county-only
/// "Nottinghamshire". Those two do not disagree: the census simply says less.
/// The user was being asked to adjudicate a question with exactly one possible
/// answer, and the adjudication trace even recorded "Both derive county NTT"
/// before raising the dispute anyway.
///
/// Two things had to be true for that to happen. `stringFieldConflict`
/// collapsed only a TRAILING qualifier ("Belper" vs "Belper, Derbyshire"), so
/// it could not see a coarse value sitting in the MIDDLE of a fine one — and
/// place strings put it there routinely, because the broad tail ("England") is
/// inconsistently present. And `DisputeResolver`'s R1 rung is a documented
/// no-op that assumes refinements were filtered at detection, so nothing
/// downstream could rescue it.
///
/// The suppression cases below are the bug. The three guards under
/// "over-suppression" are the more important half of the file: suppressing a
/// genuine disagreement is over-merging, and over-merging is the direction the
/// user cannot undo.
struct ConflictDetectorPlaceRefinementTests {

    // MARK: - The live case

    @Test func countyOnlyCensusPlaceAgainstFullParishIsNotAConflict() {
        // ["nottinghamshire"] is a SUBSEQUENCE of
        // ["teversal", "nottinghamshire", "england"], but not a contiguous
        // suffix — precisely the shape the trailing-qualifier collapse misses.
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Teversal, Nottinghamshire, England",
            existingSources: [],
            candidate: "Nottinghamshire",
            candidateOrigin: .freecen,
            profileID: "gladwin-william"
        )
        #expect(conflict == nil)
    }

    @Test func theRefinementFilterIsSymmetric() {
        // The same pair with the sides swapped. `ConflictSweep` re-reads every
        // attested value against the canonical one, so whichever of the two
        // happens to be canonical, the answer must be the same — an
        // asymmetric filter would leave the dispute open on one arm.
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Nottinghamshire",
            existingSources: [],
            candidate: "Teversal, Nottinghamshire, England",
            candidateOrigin: .freecen,
            profileID: "gladwin-william"
        )
        #expect(conflict == nil)
    }

    @Test func townAndCountyAgainstBareCountyIsNotAConflict() {
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Sheffield, Yorkshire",
            existingSources: [],
            candidate: "Yorkshire",
            candidateOrigin: .freecen,
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    @Test func deathLocationGetsTheSameFilter() {
        // Both location fields flow through F2; the filter is gated on the
        // field being a location, not on it being the birth one.
        let conflict = ConflictDetector.stringFieldConflict(
            field: .deathLocation,
            existing: "Chesterfield, Derbyshire, England",
            existingSources: [],
            candidate: "Derbyshire",
            candidateOrigin: SourceOrigin(identifier: "probate"),
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    @Test func trailingQualifierCollapseStillHolds() {
        // Pre-existing behaviour, pinned here so the EV15 filter can never be
        // "simplified" into replacing it: the trailing collapse runs before
        // the county derivation, this one runs after, and they are not
        // interchangeable.
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Belper",
            existingSources: [],
            candidate: "Belper, Derbyshire",
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    // MARK: - Guards against over-suppression

    @Test func twoParishesInOneCountyStillConflict() {
        // THE test. Equal component counts, neither a subsequence of the
        // other: Whittington and Unstone are different places that happen to
        // sit in one county (and one registration district). Filtering this as
        // a "refinement" would be over-merging — "when in doubt, split".
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Whittington, Derbyshire",
            existingSources: [],
            candidate: "Unstone, Derbyshire",
            candidateOrigin: .freecen,
            profileID: "p1"
        )
        #expect(conflict != nil)
        #expect(conflict?.kind == .fieldValue)
        #expect(conflict?.reason == .valueMismatch)
    }

    @Test func sameParishDifferentCountyStillGradesConflict() {
        // Proves the county-derivation check still runs, and still upgrades:
        // one Teversal cannot be in two counties. No hardcoded regions — the
        // codes come from the bundled catalogues.
        let ntt = ConflictDetector.chapmanCode(forPlaceText: "Teversal, Nottinghamshire")
        let dby = ConflictDetector.chapmanCode(forPlaceText: "Teversal, Derbyshire")
        guard let ntt, let dby, ntt != dby else {
            Issue.record("Catalogue fixture assumption failed: \(String(describing: ntt)) vs \(String(describing: dby))")
            return
        }
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Teversal, Nottinghamshire",
            existingSources: [],
            candidate: "Teversal, Derbyshire",
            candidateOrigin: .freecen,
            profileID: "p1"
        )
        #expect(conflict?.severity == .conflict)
        #expect(conflict?.reasoning.contains("counties differ") == true)
    }

    @Test func nestingComponentsDoNotOverrideACountyDisagreement() {
        // The ordering guard. "Sheffield" derives WRY from the registration-
        // district catalogue; "Sheffield, Derbyshire, England" derives DBY
        // from its stated county token. The components nest perfectly — the
        // coarse side IS a subsequence of the fine one — but the two values
        // contradict each other, so the county check's `.conflict` verdict
        // wins and the dispute stays open for the human.
        let bare = ConflictDetector.chapmanCode(forPlaceText: "Sheffield")
        let qualified = ConflictDetector.chapmanCode(forPlaceText: "Sheffield, Derbyshire, England")
        guard let bare, let qualified, bare != qualified else {
            Issue.record("Catalogue fixture assumption failed: \(String(describing: bare)) vs \(String(describing: qualified))")
            return
        }
        // Confirm the pair really does exercise the new filter's predicate —
        // otherwise this test would pass for the wrong reason.
        #expect(ConflictDetector.isPlaceRefinement("Sheffield", "Sheffield, Derbyshire, England"))

        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Sheffield",
            existingSources: [],
            candidate: "Sheffield, Derbyshire, England",
            candidateOrigin: .freecen,
            profileID: "p1"
        )
        #expect(conflict?.severity == .conflict)
    }

    @Test func theRefinementFilterIsLocationOnly() {
        // Synthetic (name fields rarely carry commas) but the gate has to
        // hold: comma components mean "narrower place inside broader place"
        // only for locations, and `stringFieldConflict` is also the string arm
        // for name fields via the pending-facts accept path.
        let conflict = ConflictDetector.stringFieldConflict(
            field: .lastName,
            existing: "Gladwin, Hewkin, Wheatman",
            existingSources: [],
            candidate: "Hewkin",
            candidateOrigin: .gedcom,
            profileID: "p1"
        )
        #expect(conflict != nil)
    }

    // MARK: - isPlaceRefinement, directly

    @Test func aCoarserPlaceIsASubsequenceNotASuffix() {
        #expect(ConflictDetector.isPlaceRefinement(
            "Nottinghamshire", "Teversal, Nottinghamshire, England"))
        // Order carries meaning — place strings run narrow→broad — so the same
        // components in the wrong order are not a refinement.
        #expect(ConflictDetector.isPlaceRefinement(
            "England, Teversal", "Teversal, Nottinghamshire, England") == false)
    }

    @Test func equalComponentCountsAreNeverARefinement() {
        #expect(ConflictDetector.isPlaceRefinement(
            "Whittington, Derbyshire", "Unstone, Derbyshire") == false)
        // Both say two things; the first is broader but not strictly fewer
        // components, so it survives to the human rather than being filtered.
        #expect(ConflictDetector.isPlaceRefinement(
            "Derbyshire, England", "Belper, Derbyshire") == false)
    }

    @Test func unrelatedPlacesAreNotRefinements() {
        #expect(ConflictDetector.isPlaceRefinement("Bakewell", "Belper, Derbyshire") == false)
        #expect(ConflictDetector.isPlaceRefinement("", "Belper, Derbyshire") == false)
    }

    @Test func refinementComparisonIgnoresCaseAndWhitespace() {
        #expect(ConflictDetector.isPlaceRefinement(
            "  NOTTINGHAMSHIRE ", "Teversal,   Nottinghamshire , England"))
    }
}
