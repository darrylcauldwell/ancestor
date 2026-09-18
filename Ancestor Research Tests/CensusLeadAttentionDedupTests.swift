import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV2 follow-up (review M5). Health's sync dropped every census lead-attention
/// finding for any profile the applied-census sweep (`censusUnabsorbed`) also
/// reported — a dedup keyed on profile alone. But the two rules cover
/// different records: an applied 1871 household must not silence an unapplied
/// 1891 lead naming an unrecorded sibling, and it must never silence the
/// contradiction rule at all, whose roster-vs-tree clashes the applied sweep
/// does not report. The dedup now keys on (profile, census year) and exempts
/// `censusLeadContradiction` entirely.
struct CensusLeadAttentionDedupTests {

    private func finding(_ ruleID: String, profileID: String = "p1", year: Int) -> AuditResult {
        // Mirrors CensusLeadAttentionAudit's real message shapes, which are the
        // only place a finding carries its census year.
        let message = ruleID == CensusLeadAttentionAudit.contradictionRuleID
            ? "Emma Gladwin's \(year) census lead contradicts the tree: born Derbyshire vs Sheffield."
            : "Emma Gladwin's \(year) census lead names 2 household members not on the tree (Ada, Walter) — review the lead on their profile."
        return AuditResult(
            profileID: profileID, profileName: "Emma Gladwin",
            severity: .warning,
            category: ruleID == CensusLeadAttentionAudit.contradictionRuleID ? .issue : .gap,
            ruleID: ruleID, message: message)
    }

    /// The exact EV2 specimen re-created by the profile-keyed dedup: an
    /// applied 1871 household on the same profile silenced BOTH of the 1891
    /// lead's findings. Other years' lead households must surface.
    @Test func otherYearsLeadHouseholdSurvivesAnAppliedCensus() {
        let unabsorbed = finding(CensusLeadAttentionAudit.unabsorbedRuleID, year: 1891)
        let clash = finding(CensusLeadAttentionAudit.contradictionRuleID, year: 1891)
        let out = HealthView.dedupedCensusLeadAttention(
            [unabsorbed, clash], absorbedYears: ["p1": [1871]])
        #expect(out.count == 2)
    }

    /// The one shape the dedup exists for — a `.savedAsLead` record the
    /// applied sweep already reported reads as unapplied to the lead sweep —
    /// still dedupes: same profile, same year.
    @Test func sameYearUnabsorbedLeadIsStillDeduped() {
        let unabsorbed = finding(CensusLeadAttentionAudit.unabsorbedRuleID, year: 1891)
        let out = HealthView.dedupedCensusLeadAttention(
            [unabsorbed], absorbedYears: ["p1": [1891]])
        #expect(out.isEmpty)
    }

    /// Contradiction findings are never deduped — the applied sweep reports
    /// missing kin, never clashes, so there is nothing they duplicate.
    @Test func contradictionFindingSurvivesEvenForTheSameYear() {
        let clash = finding(CensusLeadAttentionAudit.contradictionRuleID, year: 1891)
        let out = HealthView.dedupedCensusLeadAttention(
            [clash], absorbedYears: ["p1": [1891]])
        #expect(out.count == 1)
    }

    /// A profile the applied sweep never reported keeps everything.
    @Test func unreportedProfileKeepsAllFindings() {
        let unabsorbed = finding(CensusLeadAttentionAudit.unabsorbedRuleID, year: 1871)
        let out = HealthView.dedupedCensusLeadAttention(
            [unabsorbed], absorbedYears: ["other": [1871]])
        #expect(out.count == 1)
    }

    /// A message the year can't be read from keeps its finding — surfacing a
    /// household twice beats silencing it.
    @Test func unparseableMessageKeepsItsFinding() {
        let odd = AuditResult(
            profileID: "p1", profileName: "Emma Gladwin",
            severity: .warning, category: .gap,
            ruleID: CensusLeadAttentionAudit.unabsorbedRuleID,
            message: "A message with no year in the expected shape.")
        let out = HealthView.dedupedCensusLeadAttention(
            [odd], absorbedYears: ["p1": [1871, 1891]])
        #expect(out.count == 1)
    }

    /// The year parser is coupled to the producer's fixed message format —
    /// both rules' shapes parse, and prose years elsewhere do not confuse it.
    @Test func censusLeadYearReadsBothRuleShapes() {
        #expect(HealthView.censusLeadYear(
            in: finding(CensusLeadAttentionAudit.unabsorbedRuleID, year: 1891).message) == 1891)
        #expect(HealthView.censusLeadYear(
            in: finding(CensusLeadAttentionAudit.contradictionRuleID, year: 1861).message) == 1861)
        #expect(HealthView.censusLeadYear(in: "born about 1867 in Chesterfield") == nil)
    }
}
