import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// SC-6 follow-up (review M7) — the Attention router must never silently
/// drop queued work whose profile is missing from the snapshot: soft-delete
/// doesn't cascade to leads or pending facts, and MCP can submit against any
/// id. The row builder is pure so the store-wide guarantee ("nothing is ever
/// reachable only by knowing which profile to open") is a test.
@MainActor
struct WorkbenchAttentionOffSnapshotTests {

    /// The defect, in one assertion: 3 leads + 2 pending facts on a
    /// soft-deleted John Land used to vanish from the router entirely —
    /// invisible on every surface, with no count anywhere hinting they exist.
    @Test func softDeletedProfilesQueuedWorkStillRenders() {
        let rows = AttentionLadder.rows(
            ids: ["@JOHN@"],
            pendingFacts: ["@JOHN@": 2],
            leads: ["@JOHN@": 3],
            proposals: [:], disputes: [:],
            onSnapshot: { _ in nil },                   // not in the snapshot
            offSnapshot: { _ in ("John Land", 1861) })  // soft-deleted row in DB
        #expect(rows.count == 1)
        #expect(rows[0].name == "John Land")
        #expect(rows[0].birthYear == 1861)
        #expect(rows[0].isOffSnapshot)
        #expect(rows[0].pendingFacts == 2)
        #expect(rows[0].leads == 3)
    }

    /// An id the DB doesn't know either (an MCP submission against a bogus
    /// id) gets a labelled placeholder row — still never a silent drop.
    @Test func unknownIDGetsALabelledPlaceholderRow() {
        let rows = AttentionLadder.rows(
            ids: ["@GHOST@"],
            pendingFacts: [:],
            leads: ["@GHOST@": 1],
            proposals: [:], disputes: [:],
            onSnapshot: { _ in nil },
            offSnapshot: { _ in nil })
        #expect(rows.count == 1)
        #expect(rows[0].name.contains("@GHOST@"))
        #expect(rows[0].isOffSnapshot)
    }

    /// Snapshot resolution wins and is NOT marked off-snapshot — the
    /// fallback never fires for people the tree knows.
    @Test func snapshotResolutionWinsAndIsNotMarked() {
        let rows = AttentionLadder.rows(
            ids: ["@ANN@"],
            pendingFacts: ["@ANN@": 1],
            leads: [:], proposals: [:], disputes: [:],
            onSnapshot: { _ in ("Ann Land", 1843) },
            offSnapshot: { _ in ("WRONG", nil) })
        #expect(rows[0].name == "Ann Land")
        #expect(!rows[0].isOffSnapshot)
    }

    /// Zero-work ids still produce no row — the fallback must not resurrect
    /// an empty row for every soft-deleted profile in the project.
    @Test func zeroWorkOffSnapshotIDsProduceNoRow() {
        let rows = AttentionLadder.rows(
            ids: ["@EMPTY@"],
            pendingFacts: [:], leads: [:], proposals: [:], disputes: [:],
            onSnapshot: { _ in nil },
            offSnapshot: { _ in ("Someone", nil) })
        #expect(rows.isEmpty)
    }

    /// Off-snapshot rows ride the same ladder: one firewall-queued fact on a
    /// soft-deleted profile still outranks a live profile's pile of leads.
    @Test func offSnapshotRowsRankByTheSameLadder() {
        let rows = AttentionLadder.rows(
            ids: ["@DEL@", "@LIVE@"],
            pendingFacts: ["@DEL@": 1],
            leads: ["@LIVE@": 40],
            proposals: [:], disputes: [:],
            onSnapshot: { $0 == "@LIVE@" ? ("Live Land", nil) : nil },
            offSnapshot: { $0 == "@DEL@" ? ("Del Land", nil) : nil })
        #expect(rows.map(\.id) == ["@DEL@", "@LIVE@"])
    }
}
