import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// #HR3 follow-up (review C6) — the Workbench "Research suggestions" section
/// must itself surface the `.research` audit findings the completeness
/// engine does NOT mirror. The recategorisation retired `.research` from
/// Health on the promise completeness carries the reasons — true for the
/// missing-X rules, false for evidence-derived prompts like fertilityGap's
/// children shortfall, which rendered NOWHERE in-app until this shaper.
@MainActor
struct WorkbenchResearchPromptsTests {

    private func finding(
        profileID: String = "@W1@", name: String = "Jane Land",
        category: AuditCategory, ruleID: String, message: String
    ) -> AuditResult {
        AuditResult(profileID: profileID, profileName: name,
                    severity: .info, category: category,
                    ruleID: ruleID, message: message)
    }

    // MARK: - Selection

    /// The defect, in one assertion: the fertilityGap children-shortfall is
    /// `.research` with no completeness mirror — it must survive selection
    /// or an evidence-derived signal renders nowhere in the app.
    @Test func fertilityGapShortfallSurvivesSelection() {
        let message = "1911: Jane Land stated 8 children born alive; the tree has 6 born before 1911 — 2 unaccounted."
        let reasons = WorkbenchResearchPrompts.unmirroredReasons(in: [
            finding(category: .research, ruleID: "fertilityGap", message: message)
        ])
        #expect(reasons["@W1@"] == [message])
    }

    /// Completeness-mirrored research rules stay off the rows — the
    /// suggestion row's "Missing: …" line already carries their signal.
    @Test func completenessMirroredRulesAreFiltered() {
        let reasons = WorkbenchResearchPrompts.unmirroredReasons(in: [
            finding(category: .research, ruleID: "missingBirthDate", message: "Jane Land — no birth date"),
            finding(category: .research, ruleID: "missingParents", message: "Jane Land — no parents"),
            finding(category: .research, ruleID: "completenessScore", message: "Jane Land — completeness 3/7"),
            finding(category: .research, ruleID: "ancestorExtension", message: "Jane Land (b.1850) — no parents, search FreeBMD to extend tree")
        ])
        #expect(reasons.isEmpty)
    }

    /// `.issue` and `.gap` findings belong to Health, never here. The
    /// fertilityGap RULE also emits an `.issue` (marriage-year mismatch);
    /// sharing a ruleID must not smuggle it onto this surface.
    @Test func nonResearchCategoriesNeverPass() {
        let reasons = WorkbenchResearchPrompts.unmirroredReasons(in: [
            finding(category: .issue, ruleID: "fertilityGap",
                    message: "1911: Jane Land's census implies marriage ~1894; the tree records 1901."),
            finding(category: .gap, ruleID: "someGapRule", message: "half-applied evidence")
        ])
        #expect(reasons.isEmpty)
    }

    /// Fail OPEN: a future `.research` rule this shaper has never heard of
    /// is visible by default — invisibility was the defect being fixed.
    @Test func unknownResearchRulesAreVisibleByDefault() {
        let reasons = WorkbenchResearchPrompts.unmirroredReasons(in: [
            finding(category: .research, ruleID: "someFutureRule", message: "Jane Land — go look at X")
        ])
        #expect(reasons["@W1@"] == ["Jane Land — go look at X"])
    }

    /// Tree-level findings (empty profileID) are dropped — this surface is
    /// per-person.
    @Test func treeLevelFindingsAreDropped() {
        let reasons = WorkbenchResearchPrompts.unmirroredReasons(in: [
            finding(profileID: "", category: .research, ruleID: "fertilityGap", message: "tree-wide note")
        ])
        #expect(reasons.isEmpty)
    }

    /// Deterministic reason order (rule, then message) — reload-stable rows.
    @Test func reasonsOrderByRuleThenMessage() {
        let reasons = WorkbenchResearchPrompts.unmirroredReasons(in: [
            finding(category: .research, ruleID: "zRule", message: "b"),
            finding(category: .research, ruleID: "aRule", message: "z"),
            finding(category: .research, ruleID: "zRule", message: "a")
        ])
        #expect(reasons["@W1@"] == ["z", "a", "b"])
    }

    /// Guard against drift between the shipped rule ids and the mirrored
    /// set's vocabulary: fertilityGap must never be classed as mirrored,
    /// and the mirrored entries must be spelled as the rules spell them.
    @Test func mirroredSetMatchesTheShippedRuleIDs() {
        #expect(FertilityGapRule().id == "fertilityGap")
        #expect(!WorkbenchResearchPrompts.completenessMirroredRuleIDs.contains(FertilityGapRule().id))
        #expect(WorkbenchResearchPrompts.completenessMirroredRuleIDs.contains(MissingParentsRule().id))
        #expect(WorkbenchResearchPrompts.completenessMirroredRuleIDs.contains(MissingBirthDateRule().id))
    }

    // MARK: - Ranking

    /// THE C6 assertion: a woman at FULL completeness carrying an
    /// evidence-derived prompt still makes the list — under the old
    /// least-complete-top-5 ranking she could never appear.
    @Test func fullyCompleteFlaggedWomanStillRanks() {
        let scores = ["@A@": 0, "@B@": 1, "@C@": 2, "@D@": 3, "@E@": 4, "@JANE@": 7]
        let ranked = WorkbenchResearchPrompts.rankedIDs(
            completenessScores: scores, flagged: ["@JANE@"], cap: 5)
        #expect(ranked.first == "@JANE@")
        #expect(ranked.count == 5)
    }

    /// The cap never swallows a flagged person — `max(cap, flagged)`, the
    /// same philosophy as `AttentionLadder.visibleCount`.
    @Test func capNeverSwallowsFlaggedPeople() {
        var scores: [String: Int] = [:]
        var flagged: Set<String> = []
        for i in 0..<8 {
            scores["@F\(i)@"] = 7
            flagged.insert("@F\(i)@")
        }
        for i in 0..<10 { scores["@U\(i)@"] = i % 7 }
        let ranked = WorkbenchResearchPrompts.rankedIDs(
            completenessScores: scores, flagged: flagged, cap: 5)
        #expect(ranked.count == 8)
        #expect(Set(ranked) == flagged)
    }

    /// Beneath the flagged band the launcher's original ranking survives:
    /// least-complete first, id tiebreak.
    @Test func unflaggedFillKeepsLeastCompleteOrdering() {
        let scores = ["@B@": 2, "@A@": 2, "@C@": 1, "@X@": 6]
        let ranked = WorkbenchResearchPrompts.rankedIDs(
            completenessScores: scores, flagged: [], cap: 3)
        #expect(ranked == ["@C@", "@A@", "@B@"])
    }
}
