import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV11 follow-up (review C4). The first fix dropped a withdrawn competitor
/// only when its origin still held ANOTHER row on the field — treating "origin
/// holds no row here" as proof of a synthesised competitor. But that is
/// equally the state record removal leaves when the removed row was that
/// origin's ONLY one: un-applying a freebmd registration deletes its
/// `field_sources` row while a DEFERRED dispute survives removal, so the
/// withdrawn "Dec 1865" stayed selectable in the Resolve picker and accepting
/// it wrote another family's registration back onto the profile with no
/// attestation behind it.
///
/// The discriminator is origin kind plus producer: only origins record removal
/// can never withdraw (`tree`, initial-import, manual, engine-derived) may
/// survive rowless — a record origin may do so solely on a `.runSweep`
/// dispute, whose candidate side is rowless by design (CL3 T-B detects run
/// discrepancies before any apply). These pin the new rule alongside the
/// original EV11 suite (`DisputeSheetLiveValuesTests`), which must keep
/// passing untouched.
struct DisputeWithdrawnRecordOriginTests {

    private func source(_ origin: String, _ raw: String) -> FieldSource {
        FieldSource(origin: SourceOrigin(identifier: origin), raw: raw,
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The confirmed C4 scenario: gedcom '1867' vs applied freebmd 'Dec 1865',
    /// dispute deferred, freebmd record then un-applied. The freebmd origin
    /// holds no row on the field afterwards — which must read as WITHDRAWN,
    /// not as "synthesised competitor that never had a row".
    @Test func withdrawnRecordOriginValueIsDroppedOnApplyDisputes() {
        let kept = source("gedcom", "1867")
        let withdrawn = source("freebmd", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [kept, withdrawn], attested: [kept], detectedBy: .applyEngine)
        #expect(live.map(\.raw) == ["1867"])
    }

    /// Pre-conflict-layer dispute blobs decode with no producer. Those all
    /// predate the run sweep, so they get the strict apply-side rule — a
    /// rowless record origin is a withdrawal there too.
    @Test func withdrawnRecordOriginValueIsDroppedOnLegacyDisputes() {
        let kept = source("gedcom", "1867")
        let withdrawn = source("freebmd", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [kept, withdrawn], attested: [kept])
        #expect(live.map(\.raw) == ["1867"])
    }

    /// CL3 T-B: a run-sweep dispute records the source's value BEFORE any
    /// apply, so its record-origin candidate legitimately has no
    /// `field_sources` row — dropping it would empty the picker of the very
    /// side the resolver exists to offer.
    @Test func runSweepCandidateSurvivesWithoutARow() {
        let canonical = source("tree", "1867")
        let candidate = source("freebmd", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [canonical, candidate], attested: [source("gedcom", "1867")],
            detectedBy: .runSweep)
        #expect(live.map(\.raw) == ["1867", "Dec 1865"])
    }

    /// The synthesised `tree` competitor (canonical value with no attested
    /// row, displaced values from the pending-facts accept path) survives
    /// under every producer — it is the only route back to that value.
    @Test func syntheticTreeCompetitorSurvivesEveryProducer() {
        let canonical = source("tree", "1866")
        let candidate = source("freebmd", "Dec 1865")
        for producer in [DisputeProducer.applyEngine, .runSweep, .consistencySweep] {
            let live = DisputeSheetItem.liveCompetingSources(
                stored: [canonical, candidate], attested: [candidate],
                detectedBy: producer)
            #expect(live.contains { $0.raw == "1866" })
        }
    }

    /// Initial-import and manual origins cannot be withdrawn by record
    /// removal (it deletes rows only for the removed record's own source ID),
    /// so their rowless competitors stay on offer even under the strict rule.
    @Test func nonRecordOriginsSurviveRowlessOnApplyDisputes() {
        let gedcom = source("gedcom", "1867")
        let manual = source("manual.record", "abt 1866")
        let candidate = source("freebmd", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [gedcom, manual, candidate], attested: [candidate],
            detectedBy: .applyEngine)
        #expect(live.map(\.raw) == ["1867", "abt 1866", "Dec 1865"])
    }

    /// The Emma Gladwin shape must keep working: the same origin still attests
    /// another value, so its discarded value is withdrawn regardless of
    /// producer — including `.runSweep`.
    @Test func sameOriginOtherRowStillMeansWithdrawnUnderRunSweep() {
        let kept = source("freebmd", "Mar 1866")
        let discarded = source("freebmd", "Dec 1865")
        let live = DisputeSheetItem.liveCompetingSources(
            stored: [kept, discarded], attested: [kept], detectedBy: .runSweep)
        #expect(live.map(\.raw) == ["Mar 1866"])
    }

    /// The full deferred-dispute sheet path: `DisputeSheetItem` re-derives the
    /// competing set with the dispute's own producer, so the Resolve sheet a
    /// deferred dispute opens no longer offers the withdrawn registration.
    @MainActor @Test func deferredDisputeSheetDropsTheWithdrawnValue() {
        let kept = source("gedcom", "1867")
        let withdrawn = source("freebmd", "Dec 1865")
        let dispute = FieldDispute(
            field: .birthDate, reason: .noOverlap,
            competingSources: [kept, withdrawn],
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            resolution: .deferred,
            kind: .fieldValue, severity: .conflict, detectedBy: .applyEngine)
        let profile = Profile(
            id: "p1", firstName: "Emma", lastName: "Gladwin",
            isDeleted: false,
            sources: [.birthDate: [kept]],
            disputes: [.birthDate: dispute])
        let item = DisputeSheetItem(profile: profile, dispute: dispute)
        #expect(item.dispute.competingSources.map(\.raw) == ["1867"])
    }
}
