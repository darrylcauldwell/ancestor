import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Pins which audit findings get the plain "Research" launch button
/// (AuditFixButton). Owner sweep 2026-08-12: research-resolvable GAP rows
/// (missing birth/death date/location, missing parents, end-of-line ancestor,
/// completeness, unlinked spouse, incomplete name) rendered only Edit Profile /
/// Add Question / Dismiss — none of which fills a value that must be *found*.
/// A Research button (reusing the existing fertilityGap launch) closes that
/// loop. These tests guard the set against drift and against double-offering
/// research on rules that already carry their own bespoke affordance.
struct AuditFixButtonResearchGapTests {

    @Test func everyResearchResolvableGapOffersResearch() {
        let set = AuditFixButton.researchResolvableGapRuleIDs
        for id in [
            "missingParents", "missingBirthDate", "missingBirthLocation",
            "missingDeathDate", "missingDeathLocation", "ancestorExtension",
            "completenessScore", "unlinkedSpouseForFemaleSubject", "incompleteName",
        ] {
            #expect(set.contains(id), "\(id) is a find-it-not-type-it gap and should offer Research")
        }
    }

    /// Rules that already render a deterministic fix, a bespoke research/enrich
    /// button, or are deliberately out of scope must NOT also be in the plain
    /// research set, or the row would show two competing research affordances
    /// (fertilityGap/freebmdLinkMissing) or an inappropriate one (missingBio is
    /// synthesis; datelessReadsAsLiving is fixed by inferring a date).
    @Test func rulesWithTheirOwnAffordanceAreNotDoubleOffered() {
        let set = AuditFixButton.researchResolvableGapRuleIDs
        for id in [
            "fertilityGap", "freebmdLinkMissing", "marriedSurnameFromSpouse",
            "censusAgeBirthYear", "duplicateDetection", "givenNameContainsMiddle",
            "missingCoParent", "excessParentEdges", "censusParentUnlock",
            "censusRelationship", "missingBio", "datelessReadsAsLiving",
        ] {
            #expect(!set.contains(id), "\(id) has its own affordance — must not double-offer Research")
        }
    }

    /// A typo'd rule id would silently never match (falling to EmptyView). Every
    /// id in the set must be a real built-in rule id.
    @Test func everyResearchGapIDIsARealRule() {
        let builtIn = Set(AuditRules.builtIn.map(\.id))
        for id in AuditFixButton.researchResolvableGapRuleIDs {
            #expect(builtIn.contains(id), "\(id) is not a real AuditRules.builtIn rule id — likely a typo")
        }
    }

    @Test func helpTextIsTailoredForKeyRulesAndHasASaneDefault() {
        #expect(AuditFixButton.researchGapHelp(forRuleID: "ancestorExtension").contains("extend"))
        #expect(AuditFixButton.researchGapHelp(forRuleID: "missingParents").contains("parents"))
        // Unknown / generic ids still get a non-empty, sensible fallback.
        #expect(!AuditFixButton.researchGapHelp(forRuleID: "completenessScore").isEmpty)
    }

    /// Freshness gate (scope-I follow-up): the Research button relabels to
    /// "Re-research" and annotates the age once the host knows a last-run date,
    /// so a recently-searched profile isn't re-hammered on a whim.
    @Test func researchButtonRelabelsAndAnnotatesByFreshness() {
        // Never searched → plain "Research", no age note.
        #expect(AuditFixButton.researchButtonTitle(lastResearched: nil) == "Research")
        #expect(AuditFixButton.researchAgeNote(lastResearched: nil) == "")
        // Known completion → "Re-research" + a human age note.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(AuditFixButton.researchButtonTitle(lastResearched: now) == "Re-research")
        #expect(AuditFixButton.researchAgeNote(lastResearched: now, now: now).contains("today"))
        #expect(AuditFixButton.researchAgeNote(
            lastResearched: now.addingTimeInterval(-3 * 86_400), now: now).contains("3 days ago"))
        #expect(AuditFixButton.researchAgeNote(
            lastResearched: now.addingTimeInterval(-86_400), now: now).contains("1 day ago"))
    }
}
