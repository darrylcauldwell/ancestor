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

    /// Findings default to "a live DB is open" — the Health host's normal state.
    private func key(_ r: AuditResult, _ snap: FamilyGraphSnapshot,
                     hasDatabase: Bool = true) -> HealthTriage.Key {
        HealthTriage.findingKey(r, snapshot: snap, hasDatabase: hasDatabase)
    }

    private func isOneClick(_ r: AuditResult, _ snap: FamilyGraphSnapshot,
                            hasDatabase: Bool = true) -> Bool {
        HealthTriage.isOneClickFinding(r, snapshot: snap, hasDatabase: hasDatabase)
    }

    private func dispute(
        _ severity: DiscrepancySeverity?, kind: DisputeKind = .fieldValue,
        field: String = "birthDate", entity: String = "@A@", rowID: Int64 = 1,
        name: String? = "Ann Land"
    ) -> HealthTriage.Key {
        HealthTriage.disputeKey(severity: severity, kind: kind, field: field,
                                entityID: entity, rowID: rowID, personName: name)
    }

    // MARK: - The ladder itself

    /// Rule IDs chosen so their K4 labels run REVERSE-alphabetically to
    /// their severities ("Unsourced bio" > "Muddled identity" > "Junk in
    /// name") — otherwise the assertion passes on the label key and would
    /// stay green with the severity key deleted (review 2026-08-25).
    @Test func theLadderOrdersPinThenRedThenAmberThenBlue() {
        let snap = snapshot()
        let pinCorrection = dispute(.correction, entity: "@A@", name: "Ann")
        let pinConflict = dispute(.conflict, entity: "@B@", name: "Bea")
        let red = key(finding("unsourcedBio", severity: .error), snap)
        let amber = key(finding("muddledIdentity", severity: .warning), snap)
        let blue = key(finding("junkInName", severity: .info), snap)
        #expect(red.ruleLabel > amber.ruleLabel && amber.ruleLabel > blue.ruleLabel,
                "premise: the labels oppose the severities, so only K2 can order these")

        #expect(pinCorrection < pinConflict, "within the pin block, correction before conflict")
        #expect(pinConflict < red)
        #expect(red < amber)
        #expect(amber < blue)
    }

    @Test func cosmeticDisputesDoNotPin() {
        // Pin-flood guard: a conflict sweep dumping refinement/note disputes
        // must never bury the reds — those band with the cosmetic rows.
        let snap = snapshot()
        let refinement = dispute(.refinement)
        let note = dispute(.note)
        let red = key(finding("birthBeforeDeath", severity: .error), snap)
        let amber = key(finding("phantomSpouse", severity: .warning), snap)

        #expect(HealthTriage.disputePins(.correction) && HealthTriage.disputePins(.conflict))
        #expect(!HealthTriage.disputePins(.refinement) && !HealthTriage.disputePins(.note)
                && !HealthTriage.disputePins(nil))
        #expect(red < refinement && amber < refinement, "cosmetic disputes sit below the reds")
        #expect(red < note && amber < note)
    }

    /// Review fix 2026-08-25 — collapsing every unpinned dispute to one rank
    /// lost the worst-first order inside the cosmetic band that the pre-HR4
    /// list had.
    @Test func cosmeticDisputesKeepWorstFirstBetweenThemselves() {
        #expect(dispute(.refinement, entity: "@Z@", name: "Zach")
                < dispute(.note, entity: "@A@", name: "Ann"),
                "a refinement outranks a note even on an alphabetically later person")
        #expect(dispute(.note) < dispute(nil), "a graded note outranks an ungraded dispute")
    }

    /// Second review 2026-08-25 — giving disputes their own ranks 3/4 put
    /// them in a fifth band BELOW blue, so a structural `.note` dispute that
    /// blocks all auto-approval sorted dead last. Unpinned disputes must band
    /// blue and grade within it.
    @Test func unpinnedDisputesStayInsideTheBlueBand() {
        let snap = snapshot()
        let blueFinding = key(finding("suspectLocation", severity: .info), snap)
        for severity in [DiscrepancySeverity.refinement, .note, DiscrepancySeverity.none] {
            #expect(dispute(severity).severityRank == blueFinding.severityRank,
                    "\(severity) must share the blue band, not sink beneath it")
        }
        // A structural note-severity dispute (ConflictDetector emits these)
        // must not end up under every backfill proposal.
        let structural = dispute(.note, kind: .spouseIdentity, field: "")
        let proposal = HealthTriage.proposalKey(
            label: "Census backfill", personName: "Zzz Person", id: "b:9")
        #expect(structural.severityRank == proposal.severityRank)
    }

    @Test func oneClickLeadsItsBandButNeverOutranksSeverity() {
        let snap = snapshot()
        // Both amber, same person. The quick win's label sorts AFTER the
        // judgement row's ("Census parent unlock" > "Birth before death"), so
        // only K3 can put it first — with K3 removed this goes red.
        // (Was freebmdLinkMissing until review M6 ejected it from the
        // registry — its only click is a network fetch.)
        let amberQuick = key(finding("censusParentUnlock", severity: .warning), snap)
        let amberJudge = key(finding("birthBeforeDeath", severity: .warning), snap)
        #expect(amberQuick.ruleLabel > amberJudge.ruleLabel,
                "premise: the label opposes the quick-win rank")
        #expect(amberQuick < amberJudge, "one-click leads within the amber band")

        // The owner's original complaint, inverted and pinned: a blue
        // quick win must NEVER sort above a red judgement row.
        let blueQuick = HealthTriage.proposalKey(label: "Census backfill", personName: "Lilian Brooks", id: "b:1")
        let redJudge = key(finding("birthBeforeDeath", severity: .error), snap)
        #expect(redJudge < blueQuick, "severity dominates effort — reds never buried")
    }

    @Test func rulesBatchAlphabeticallyAndPeopleSortCaseInsensitively() {
        let snap = snapshot()
        // Same band + same quick-win rank: labels alphabetical.
        let junk = key(finding("junkInName", severity: .warning), snap)
        let muddled = key(finding("muddledIdentity", severity: .warning), snap)
        #expect(junk < muddled, "\"Junk in name\" < \"Muddled identity\" alphabetically")

        // Same rule: people alphabetical, case-insensitive.
        let ann = key(finding("phantomSpouse", severity: .warning, profileID: "@A@", name: "ann land"), snap)
        let bert = key(finding("phantomSpouse", severity: .warning, profileID: "@B@", name: "Bert Land"), snap)
        #expect(ann < bert)
    }

    @Test func keysAreValueDerivedAndRunStable() {
        // AuditResult.id is a fresh UUID every audit pass — the key must not
        // depend on it, or scroll position reshuffles between runs.
        let snap = snapshot()
        let a = key(finding("phantomSpouse", severity: .warning), snap)
        let b = key(finding("phantomSpouse", severity: .warning), snap)
        #expect(!(a < b) && !(b < a), "identical content (fresh UUIDs) → identical keys")
    }

    /// Review fix 2026-08-25 — two open disputes can share entity+field (a
    /// different `kind`, or a deferred row beside a fresh detection), so the
    /// key must still separate them or their order falls outside the ladder.
    @Test func disputeKeysAreInjective() {
        let fieldValue = dispute(.conflict, kind: .fieldValue, rowID: 7)
        let timeline = dispute(.conflict, kind: .timeline, rowID: 8)
        let sameKindDifferentRow = dispute(.conflict, kind: .fieldValue, rowID: 9)
        #expect(fieldValue < timeline || timeline < fieldValue, "kind separates them")
        #expect(fieldValue < sameKindDifferentRow, "the persisted rowid is the final fence")
    }

    // MARK: - The one-click registry mirrors AuditFixButton's guards

    @Test func alwaysOneClickRules() {
        let snap = snapshot()
        #expect(isOneClick(finding("censusParentUnlock", severity: .warning), snap))
    }

    /// Review fix 2026-08-25 — these two LOOK like quick wins and are not:
    /// they have no AuditFixButton case, and in the Health host their detail
    /// row renders "Review in profile" (a navigation) or "Load household" (a
    /// network fetch). Badging them ⚡ promised a click that doesn't exist.
    @Test func routedAndNetworkActionsAreNotQuickWins() {
        let snap = snapshot()
        #expect(!isOneClick(finding("censusUnabsorbed", severity: .warning), snap))
        #expect(!isOneClick(finding("parishFamilyUnabsorbed", severity: .warning), snap))
    }

    @Test func judgementRowsAreNeverOneClick() {
        let snap = snapshot()
        for id in ["duplicateDetection", "phantomSpouse", "birthBeforeDeath",
                   "muddledIdentity", "missingParents", "parishKinUnreadable"] {
            #expect(!isOneClick(finding(id, severity: .warning), snap),
                    "\(id) needs judgement or research — no ⚡")
        }
    }

    @Test func guardedRulesMatchTheirButtonGuards() {
        // excessParentEdges: button renders only with relatedProfileIDs.
        let snap = snapshot(profile("@P1@", first: "George"), profile("@CO@", first: "Hannah"))
        #expect(isOneClick(finding("excessParentEdges", severity: .error, related: ["@X@"]), snap))
        #expect(!isOneClick(finding("excessParentEdges", severity: .error, related: nil), snap))
        #expect(!isOneClick(finding("excessParentEdges", severity: .error, related: []), snap))

        // missingCoParent: the co-parent must exist to offer "Add <name>".
        #expect(isOneClick(finding("missingCoParent", severity: .warning, related: ["@CO@"]), snap))
        #expect(!isOneClick(finding("missingCoParent", severity: .warning, related: ["@GONE@"]), snap))

        // givenNameContainsMiddle: only when the split actually computes.
        let two = snapshot(profile("@P1@", first: "John Henry"))
        let one = snapshot(profile("@P1@", first: "John"))
        #expect(isOneClick(finding("givenNameContainsMiddle", severity: .info), two))
        #expect(!isOneClick(finding("givenNameContainsMiddle", severity: .info), one))

        // The suggestion-gated pair: no suggestion computes on a bare
        // snapshot (no spouse, no census), so no ⚡ is promised.
        #expect(!isOneClick(finding("marriedSurnameFromSpouse", severity: .warning), snap))
        #expect(!isOneClick(finding("censusAgeBirthYear", severity: .warning), snap))
        // censusRelationship needs .info AND an actionable census roster —
        // none exists on a snapshot with no census life events. (The positive
        // cases live in CensusReconciliationQuickWinTests.)
        #expect(!isOneClick(finding("censusRelationship", severity: .warning), snap))
        #expect(!isOneClick(finding("censusRelationship", severity: .info), snap))
    }

    // MARK: - Auto-approval badge mirrors the gate, not the pin

    /// Review fix 2026-08-25. The gate (`MCPServer`: `resolution IS NULL`,
    /// then fieldValue-on-target or any structural kind) never reads
    /// severity — so the badge must not key off the pin, which does.
    @Test func autoApprovalBadgeFollowsTheGateNotTheSeverity() {
        // A cosmetic refinement still blocks its field: badged, though unpinned.
        #expect(HealthTriage.blocksAutoApproval(
            kind: .fieldValue, field: "birthDate", resolution: nil))
        #expect(!HealthTriage.disputePins(.refinement),
                "…while still not earning the pin — the two are independent")
    }

    @Test func aDeferredDisputeDoesNotBlockTheGate() {
        // Health lists deferred disputes as open, but the gate matches
        // `resolution IS NULL` only — badging one would be a false claim.
        #expect(!HealthTriage.blocksAutoApproval(
            kind: .fieldValue, field: "birthDate", resolution: .deferred))
        #expect(!HealthTriage.blocksAutoApproval(
            kind: .timeline, field: "", resolution: .manual("chose the register")))
    }

    /// Second review 2026-08-25 — the gate has TWO conjuncts. A fieldValue
    /// dispute on a field auto-approval never touches (names, gender, bio)
    /// blocks nothing, so claiming it does is a false badge.
    @Test func onlyDisputesTheGateActuallyConsultsAreBadged() {
        for field in ["birthDate", "deathLocation", "marriageDate", "occupation"] {
            #expect(HealthTriage.blocksAutoApproval(
                kind: .fieldValue, field: field, resolution: nil), "\(field) is gate-relevant")
        }
        for field in ["firstName", "lastName", "gender", "bio", ""] {
            #expect(!HealthTriage.blocksAutoApproval(
                kind: .fieldValue, field: field, resolution: nil),
                "\(field) is never auto-approved, so no dispute on it can block")
        }
        // Structural kinds block everything on the profile, field irrelevant.
        for kind in [DisputeKind.timeline, .parentRole, .spouseIdentity] {
            #expect(HealthTriage.blocksAutoApproval(kind: kind, field: "", resolution: nil))
        }
    }

    @Test func badgeTextNamesTheFieldOnlyForFieldValueDisputes() {
        // The caller passes the DISPLAY label, so the badge and the field
        // name printed beside it on the row agree.
        #expect(HealthTriage.autoApprovalBadgeText(kind: .fieldValue, fieldLabel: "Birth date")
                == "Blocks Birth date auto-approval")
        #expect(HealthTriage.autoApprovalBadgeText(kind: .timeline, fieldLabel: "")
                == "Blocks auto-approval", "structural kinds block everything on the profile")
        #expect(HealthTriage.autoApprovalBadgeText(kind: .parentRole, fieldLabel: "")
                == "Blocks auto-approval")
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
