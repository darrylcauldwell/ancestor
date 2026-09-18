import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// #EV29 — the Workbench Attention router's ordering, pinned so a single
/// firewall-queued fact can never sink beneath a pile of leads again.
@MainActor
struct WorkbenchAttentionLadderTests {

    private func item(_ id: String, name: String = "George Land",
                      pending: Int = 0, leads: Int = 0,
                      proposals: Int = 0, disputes: Int = 0) -> AttentionLadder.Item {
        AttentionLadder.Item(id: id, name: name, birthYear: nil,
                             pendingFacts: pending, leads: leads,
                             proposals: proposals, disputes: disputes)
    }

    // MARK: - The ladder

    /// The defect, in one assertion: the old sort was on a SUMMED count, so
    /// one pending fact ranked below any two leads — and runs mint leads by
    /// the dozen (60 on one profile, 2026-08-25).
    @Test func oneFirewallFactOutranksAPileOfLeads() {
        let noisy = item("@P2@", name: "Ann Land", leads: 60)
        let quiet = item("@P1@", name: "Zeb Land", pending: 1)
        #expect(AttentionLadder.ordered([noisy, quiet]).map(\.id) == ["@P1@", "@P2@"])
    }

    /// K1 before K2 — an open dispute means the stored value may be WRONG and
    /// only the user can choose, the same rationale that pins in #HR4.
    @Test func openDisputeLeadsThePendingFactBand() {
        let disputed = item("@P2@", disputes: 1)
        let pending = item("@P1@", pending: 9)
        #expect(AttentionLadder.ordered([pending, disputed]).map(\.id) == ["@P2@", "@P1@"])
    }

    @Test func proposalsOutrankLeadsOnlyRows() {
        let proposal = item("@P2@", proposals: 1)
        let leadsOnly = item("@P1@", leads: 30)
        #expect(AttentionLadder.ordered([leadsOnly, proposal]).map(\.id) == ["@P2@", "@P1@"])
    }

    /// K4/K5: leads break ties, they never set the band.
    @Test func withinABandMoreGatedWorkFirstThenLeads() {
        let a = item("@A@", pending: 1, leads: 40)
        let b = item("@B@", pending: 4, leads: 0)
        #expect(AttentionLadder.ordered([a, b]).map(\.id) == ["@B@", "@A@"])
        let c = item("@C@", pending: 1, leads: 2)
        let d = item("@D@", pending: 1, leads: 9)
        #expect(AttentionLadder.ordered([c, d]).map(\.id) == ["@D@", "@C@"])
    }

    /// K6/K7: run-stable, no dictionary-iteration jitter between reloads.
    @Test func identicalRowsOrderByNameThenID() {
        let z = item("@Z@", name: "Zeb Land", pending: 1)
        let a = item("@A@", name: "ann land", pending: 1)
        #expect(AttentionLadder.ordered([z, a]).map(\.id) == ["@A@", "@Z@"])
    }

    // MARK: - The fold

    /// The other half of the fix: ordering alone would just relocate the
    /// burial from row 40 to row 16.
    @Test func theFoldNeverHidesGatedWork() {
        var rows = (0..<20).map { item("@G\($0)@", name: "G\($0)", pending: 1) }
        rows += (0..<30).map { item("@L\($0)@", name: "L\($0)", leads: 5) }
        let ordered = AttentionLadder.ordered(rows)
        let n = AttentionLadder.visibleCount(ordered, cap: 15)
        #expect(n == 20)
        #expect(ordered.prefix(n).allSatisfy { $0.pendingFacts > 0 })
    }

    @Test func theFoldStillCapsALeadsOnlyTail() {
        var rows = (0..<3).map { item("@G\($0)@", name: "G\($0)", pending: 1) }
        rows += (0..<30).map { item("@L\($0)@", name: "L\($0)", leads: 5) }
        let ordered = AttentionLadder.ordered(rows)
        #expect(AttentionLadder.visibleCount(ordered, cap: 15) == 15)
    }

    // MARK: - Resolved disputes are not attention

    /// The amplifier: the router counted EVERY stored dispute, so a settled
    /// profile never left it and outranked live firewall work.
    @Test func aResolvedDisputeIsNotAttention() {
        let source = FieldSource(origin: .manual, raw: "1867", addedAt: .now)
        let accepted = FieldDispute(field: .birthDate, reason: .valueMismatch,
                                    competingSources: [], detectedAt: .now,
                                    resolution: .accepted(source))
        let manual = FieldDispute(field: .deathDate, reason: .valueMismatch,
                                  competingSources: [], detectedAt: .now,
                                  resolution: .manual("1901"))
        let deferred = FieldDispute(field: .birthLocation, reason: .noOverlap,
                                    competingSources: [], detectedAt: .now,
                                    resolution: .deferred)
        let open = FieldDispute(field: .deathLocation, reason: .noOverlap,
                                competingSources: [], detectedAt: .now)
        #expect(AttentionLadder.openDisputeCount([.birthDate: accepted]) == 0)
        #expect(AttentionLadder.openDisputeCount([.deathDate: manual]) == 0)
        // `.deferred` is parked, not decided — the profile card's conflict
        // strip and Health both still list it, so the router must too.
        #expect(AttentionLadder.openDisputeCount([.birthLocation: deferred]) == 1)
        #expect(AttentionLadder.openDisputeCount([.deathLocation: open]) == 1)
        #expect(AttentionLadder.openDisputeCount([
            .birthDate: accepted, .deathDate: manual,
            .birthLocation: deferred, .deathLocation: open
        ]) == 2)
    }
}
