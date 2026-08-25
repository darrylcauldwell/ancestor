import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// `field_disputes.competing_sources` is frozen at detection time and never
/// revised, so a value whose record has since been discarded stayed on offer in
/// the Resolve-Dispute picker — and accepting it would write it back onto the
/// profile (owner dogfood 2026-08-25: "Dec 1865" was still selectable minutes
/// after that registration was discarded). `DisputeSheetItem` now drops the
/// withdrawn ones.
///
/// The rule is deliberately narrower than "not attested": `ConflictDetector`
/// synthesises `tree`-origin competitors for a canonical value no attested row
/// represents, and those must survive or the picker loses the side the user
/// usually wants. These pin both halves.
struct DisputeSheetLiveValuesTests {

    private func source(_ origin: String, _ raw: String) -> FieldSource {
        FieldSource(origin: SourceOrigin(identifier: origin), raw: raw,
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Two competing registrations from one source; the user discards one, which
    /// deletes its `field_sources` row and leaves the source's other row intact.
    @Test func discardedValueIsNotOffered() {
        let kept = source("freebmd", "Mar 1866")
        let discarded = source("freebmd", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [kept, discarded], attested: [kept])
        #expect(live.map(\.raw) == ["Mar 1866"])
    }

    /// Removal only drops the `field_sources` row when no OTHER kept record from
    /// the same source corroborates the value — so a still-attested value must
    /// keep its place in the picker.
    @Test func stillAttestedValueSurvives() {
        let a = source("freecen", "Wirksworth, Derbyshire")
        let b = source("gedcom", "Wirksworth")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [a, b], attested: [b, a])
        #expect(live.count == 2)
    }

    /// A source that holds no row on this field at all never had one to lose:
    /// the `tree` competitor `ConflictDetector` synthesises for an unsourced
    /// canonical value is the only way back to it, so it is never dropped.
    @Test func syntheticCanonicalCompetitorIsNeverDropped() {
        let canonical = source("tree", "1866")
        let candidate = source("freebmd", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [canonical, candidate], attested: [candidate])
        #expect(live.map(\.raw) == ["1866", "Dec 1865"])
    }

    /// Withdrawal is per (origin, value): the same value from a DIFFERENT source
    /// is a different attestation, so it cannot vouch for the discarded row.
    @Test func anotherSourcesRowDoesNotVouchForADiscardedOne() {
        let discarded = source("freebmd", "Dec 1865")
        let kept = source("freebmd", "Mar 1866")
        let elsewhere = source("freereg", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [discarded], attested: [kept, elsewhere])
        #expect(live.isEmpty)
    }

    @Test func matchIgnoresCaseAndSurroundingWhitespace() {
        let stored = source("probate", "  Matlock  ")
        let attested = source("probate", "matlock")
        let live = DisputeSheetItem.liveCompetingSources(stored: [stored], attested: [attested])
        #expect(live.count == 1)
    }

    /// The offered set can only SHRINK. A value the profile now carries but the
    /// detector never weighed is not smuggled into the picker — a resolution
    /// must never write a value that went through no conflict grading.
    @Test func liveSetNeverGrows() {
        let stored = source("freebmd", "Mar 1866")
        let newcomer = source("familysearch", "1867")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [stored], attested: [stored, newcomer])
        #expect(live.map(\.raw) == ["Mar 1866"])
    }
}
