import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// HR4 follow-up (review M6) — the quick-win registry's own definition
/// excludes anything that "fetches from the network", and its ⚡ badge
/// promises "Deterministic fix — one click, undoable". `freebmdLinkMissing`
/// satisfied neither: its only button, "Enrich from FreeBMD", runs live
/// FreeBMD queries (which can throttle, return nothing, or fail — the source
/// has a 60/300/900s circuit-breaker ladder) and its writes offer no undo.
/// A ⚡ clearance queue must never fire a volley of network calls at a
/// volunteer source, so the row is judgement — same ruling that ejected
/// censusUnabsorbed/parishFamilyUnabsorbed's "Load household".
@MainActor
struct QuickWinNetworkExclusionTests {

    private func finding(_ ruleID: String, severity: Severity) -> AuditResult {
        AuditResult(profileID: "@P1@", profileName: "George Land", severity: severity,
                    category: .issue, ruleID: ruleID, message: "m")
    }

    private var emptySnapshot: FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [:], relationships: [])
    }

    @Test func freebmdEnrichIsNeverAQuickWin() {
        // With a live database (the state that used to earn the ⚡)…
        #expect(!HealthTriage.isOneClickFinding(
            finding("freebmdLinkMissing", severity: .info),
            snapshot: emptySnapshot, hasDatabase: true))
        // …and without one.
        #expect(!HealthTriage.isOneClickFinding(
            finding("freebmdLinkMissing", severity: .info),
            snapshot: emptySnapshot, hasDatabase: false))
    }

    @Test func freebmdRowsSortAsJudgementWithinTheirBand() {
        // K3 must not lead the band with a network fetch: the row keys as
        // judgement (quickWinRank 1), so a genuine one-click outranks it.
        let freebmd = HealthTriage.findingKey(
            finding("freebmdLinkMissing", severity: .warning),
            snapshot: emptySnapshot, hasDatabase: true)
        #expect(freebmd.quickWinRank == 1)

        let genuineQuick = HealthTriage.findingKey(
            finding("censusParentUnlock", severity: .warning),
            snapshot: emptySnapshot, hasDatabase: true)
        #expect(genuineQuick < freebmd, "the deterministic local one-click leads the band")
    }
}
