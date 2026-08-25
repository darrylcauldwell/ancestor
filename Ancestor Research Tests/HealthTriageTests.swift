import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// #HR4 Severity Ladder — the Health list's ordering rules, pinned so a
/// change to any key silently reordering the list is a test failure, not a
/// dogfood surprise. Owner ruling 2026-08-25: red never below amber; quick
/// wins an equal factor, expressed as the within-band leader + ⚡ chip.
@MainActor
struct HealthTriageTests {

    private func profile(_ id: String, first: String?, last: String? = "Land") -> Profile {
        Profile(id: id, externalIDs: [:], firstName: first, lastName: last,
                gender: nil, attributes: nil,
                birthDate: nil, birthLocation: nil,
                deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func snapshot(_ profiles: Profile...) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }),
            relationships: [])
    }

    private func finding(
        _ ruleID: String, severity: Severity, profileID: String = "@P1@",
        name: String = "George Land", message: String = "m",
        related: [String]? = nil
    ) -> AuditResult {
        AuditResult(profileID: profileID, profileName: name, severity: severity,
                    category: .issue, ruleID: ruleID, message: message,
                    relatedProfileIDs: related)
    }

    // MARK: - The ladder itself

    @Test func theLadderOrdersPinThenRedThenAmberThenBlue() {
        let snap = snapshot()
        let pinCorrection = HealthTriage.disputeKey(
            severity: .correction, field: "birthDate", entityID: "@A@", personName: "Ann")
        let pinConflict = HealthTriage.disputeKey(
            severity: .conflict, field: "birthDate", entityID: "@B@", personName: "Bea")
        let red = HealthTriage.findingKey(finding("birthBeforeDeath", severity: .error), snapshot: snap)
        let amber = HealthTriage.findingKey(finding("phantomSpouse", severity: .warning), snapshot: snap)
        let blue = HealthTriage.findingKey(finding("suspectLocation", severity: .info), snapshot: snap)

        #expect(pinCorrection < pinConflict, "within the pin block, correction before conflict")
        #expect(pinConflict < red)
        #expect(red < amber)
        #expect(amber < blue)
    }

    @Test func cosmeticDisputesDoNotPin() {
        // Pin-flood guard: a conflict sweep dumping refinement/note disputes
        // must never bury the reds — those band as blue judgement instead.
        let snap = snapshot()
        let refinement = HealthTriage.disputeKey(
            severity: .refinement, field: "birthDate", entityID: "@A@", personName: "Ann")
        let note = HealthTriage.disputeKey(
            severity: .note, field: "birthDate", entityID: "@A@", personName: "Ann")
        let red = HealthTriage.findingKey(finding("birthBeforeDeath", severity: .error), snapshot: snap)
        let amber = HealthTriage.findingKey(finding("phantomSpouse", severity: .warning), snapshot: snap)

        #expect(HealthTriage.disputePins(.correction) && HealthTriage.disputePins(.conflict))
        #expect(!HealthTriage.disputePins(.refinement) && !HealthTriage.disputePins(.note)
                && !HealthTriage.disputePins(nil))
        #expect(red < refinement && amber < refinement, "cosmetic disputes sit in the blue band")
        #expect(red < note && amber < note)
    }

    @Test func oneClickLeadsItsBandButNeverOutranksSeverity() {
        let snap = snapshot()
        // censusParentUnlock is amber + one-click; phantomSpouse amber judgement.
        let amberQuick = HealthTriage.findingKey(finding("censusParentUnlock", severity: .warning), snapshot: snap)
        let amberJudge = HealthTriage.findingKey(finding("phantomSpouse", severity: .warning), snapshot: snap)
        #expect(amberQuick < amberJudge, "one-click leads within the amber band")

        // The owner's original complaint, inverted and pinned: a blue
        // quick win must NEVER sort above a red judgement row.
        let blueQuick = HealthTriage.proposalKey(label: "Census backfill", personName: "Lilian Brooks", id: "b:1")
        let redJudge = HealthTriage.findingKey(finding("birthBeforeDeath", severity: .error), snapshot: snap)
        #expect(redJudge < blueQuick, "severity dominates effort — reds never buried")
    }

    @Test func rulesBatchAlphabeticallyAndPeopleSortCaseInsensitively() {
        let snap = snapshot()
        // Same band + same quick-win rank: labels alphabetical.
        let junk = HealthTriage.findingKey(finding("junkInName", severity: .warning), snapshot: snap)
        let muddled = HealthTriage.findingKey(finding("muddledIdentity", severity: .warning), snapshot: snap)
        #expect(junk < muddled, "\"Junk in name\" < \"Muddled identity\" alphabetically")

        // Same rule: people alphabetical, case-insensitive.
        let ann = HealthTriage.findingKey(
            finding("phantomSpouse", severity: .warning, profileID: "@A@", name: "ann land"), snapshot: snap)
        let bert = HealthTriage.findingKey(
            finding("phantomSpouse", severity: .warning, profileID: "@B@", name: "Bert Land"), snapshot: snap)
        #expect(ann < bert)
    }

    @Test func keysAreValueDerivedAndRunStable() {
        // AuditResult.id is a fresh UUID every audit pass — the key must not
        // depend on it, or scroll position reshuffles between runs.
        let snap = snapshot()
        let a = HealthTriage.findingKey(finding("phantomSpouse", severity: .warning), snapshot: snap)
        let b = HealthTriage.findingKey(finding("phantomSpouse", severity: .warning), snapshot: snap)
        #expect(!(a < b) && !(b < a), "identical content (fresh UUIDs) → identical keys")
    }

    // MARK: - The one-click registry mirrors AuditFixButton's guards

    @Test func alwaysOneClickRules() {
        let snap = snapshot()
        for id in ["censusParentUnlock", "freebmdLinkMissing",
                   "censusUnabsorbed", "parishFamilyUnabsorbed"] {
            #expect(HealthTriage.isOneClickFinding(
                finding(id, severity: .warning), snapshot: snap), "\(id) is always one-click")
        }
    }

    @Test func judgementRowsAreNeverOneClick() {
        let snap = snapshot()
        for id in ["duplicateDetection", "phantomSpouse", "birthBeforeDeath",
                   "muddledIdentity", "missingParents", "parishKinUnreadable"] {
            #expect(!HealthTriage.isOneClickFinding(
                finding(id, severity: .warning), snapshot: snap),
                "\(id) needs judgement or research — no ⚡")
        }
    }

    @Test func guardedRulesMatchTheirButtonGuards() {
        // excessParentEdges: button renders only with relatedProfileIDs.
        let snap = snapshot(profile("@P1@", first: "George"), profile("@CO@", first: "Hannah"))
        #expect(HealthTriage.isOneClickFinding(
            finding("excessParentEdges", severity: .error, related: ["@X@"]), snapshot: snap))
        #expect(!HealthTriage.isOneClickFinding(
            finding("excessParentEdges", severity: .error, related: nil), snapshot: snap))
        #expect(!HealthTriage.isOneClickFinding(
            finding("excessParentEdges", severity: .error, related: []), snapshot: snap))

        // missingCoParent: the co-parent must exist to offer "Add <name>".
        #expect(HealthTriage.isOneClickFinding(
            finding("missingCoParent", severity: .warning, related: ["@CO@"]), snapshot: snap))
        #expect(!HealthTriage.isOneClickFinding(
            finding("missingCoParent", severity: .warning, related: ["@GONE@"]), snapshot: snap))

        // givenNameContainsMiddle: only when the split actually computes.
        let two = snapshot(profile("@P1@", first: "John Henry"))
        let one = snapshot(profile("@P1@", first: "John"))
        #expect(HealthTriage.isOneClickFinding(
            finding("givenNameContainsMiddle", severity: .info), snapshot: two))
        #expect(!HealthTriage.isOneClickFinding(
            finding("givenNameContainsMiddle", severity: .info), snapshot: one))
    }

    // MARK: - Synthetic row keys

    @Test func syntheticRowsBandCorrectly() {
        let backfill = HealthTriage.proposalKey(label: "Census backfill", personName: "A", id: "b:1")
        #expect(backfill.severityRank == 2 && backfill.quickWinRank == 0 && backfill.pinRank == 1)

        let demotable = HealthTriage.contradictoryFactsKey(personName: "A", profileID: "@A@", demotableCount: 2)
        let heldBack = HealthTriage.contradictoryFactsKey(personName: "A", profileID: "@A@", demotableCount: 0)
        #expect(demotable.severityRank == 1, "contradictory facts are amber — issue-class")
        #expect(demotable.quickWinRank == 0 && heldBack.quickWinRank == 1,
                "the ⚡ follows whether Demote can actually act")

        let cluster = HealthTriage.duplicateClusterKey(firstName: "George Land", clusterID: "@A@")
        #expect(cluster.severityRank == 1 && cluster.quickWinRank == 1,
                "duplicates are amber judgement — Compare is never a quick win")
    }
}
