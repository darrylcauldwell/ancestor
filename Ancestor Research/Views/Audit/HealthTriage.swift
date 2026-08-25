import Foundation
import AncestorKit

/// #HR4 Severity Ladder — the deterministic ordering of the Health list.
///
/// Owner ruling (2026-08-25): red must never sit below amber, and quick wins
/// are "a factor likely equal to red hard-to-fix issues". The ladder answers
/// both without a blended score: one lexicographic sort on a six-part key.
/// Every position is explainable by reciting the keys in order —
///
///   K1  pin        correction/conflict disputes first: they are the only
///                  rows that BLOCK the MCP auto-approval gate (§14.3
///                  refuses on an open dispute). Cosmetic refinement/note
///                  disputes do NOT pin — a conflict-sweep of trivia must
///                  never bury the reds (pin-flood guard).
///   K2  severity   red → amber → blue, from an explicit per-row-type table
///                  (no inference). Inside the pin block this slot orders
///                  correction before conflict.
///   K3  quick win  a deterministic one-click undoable fix leads its colour
///                  band — the "equal factor". Membership comes from ONE
///                  registry (`isOneClickFinding`) shared by the sort, the
///                  ⚡ badge, and the ⚡ Quick-wins chip, so they can never
///                  disagree. Compare/Resolve are judgement, never quick.
///   K4  rule label alphabetical by display label — stable as counts change.
///   K5  person     display name, case-insensitive, then profile id — kills
///                  the dictionary-iteration jitter between audit runs.
///   K6  value key  run-stable value-derived tiebreak (NEVER AuditResult.id,
///                  which is a fresh UUID every audit pass).
///
/// Pure and view-free so the ordering rules are testable without a host
/// (HealthTriageTests).
enum HealthTriage {

    struct Key: Comparable, Sendable {
        let pinRank: Int
        let severityRank: Int
        let quickWinRank: Int
        let ruleLabel: String
        let personKey: String
        let valueKey: String

        static func < (a: Key, b: Key) -> Bool {
            (a.pinRank, a.severityRank, a.quickWinRank, a.ruleLabel, a.personKey, a.valueKey)
                < (b.pinRank, b.severityRank, b.quickWinRank, b.ruleLabel, b.personKey, b.valueKey)
        }
    }

    // MARK: - The one-click registry (K3)

    /// True iff this finding's primary action is a deterministic, undoable
    /// one-click fix. Guards mirror `AuditFixButton`'s switch EXACTLY — a
    /// row must never wear the ⚡ badge and then render no button.
    ///
    /// `censusUnabsorbed` / `parishFamilyUnabsorbed` count unconditionally:
    /// the audit only fires when an unabsorbed household/family exists, so
    /// the finding itself is the proposal signal (re-deriving the DB-backed
    /// proposal here would put evidence reads inside a sort comparator).
    static func isOneClickFinding(_ r: AuditResult, snapshot: FamilyGraphSnapshot) -> Bool {
        switch r.ruleID {
        case "censusParentUnlock", "freebmdLinkMissing",
             "censusUnabsorbed", "parishFamilyUnabsorbed":
            return true
        case "excessParentEdges":
            return r.relatedProfileIDs?.isEmpty == false
        case "missingCoParent":
            guard let coID = r.relatedProfileIDs?.first else { return false }
            return snapshot.profiles[coID] != nil
        case "marriedSurnameFromSpouse":
            guard let p = snapshot.profiles[r.profileID] else { return false }
            return MarriedSurnameFromSpouseRule.suggestion(for: p, in: snapshot) != nil
        case "censusAgeBirthYear":
            guard let p = snapshot.profiles[r.profileID] else { return false }
            return CensusAgeBirthYearRule.suggestion(for: p, in: snapshot) != nil
        case "givenNameContainsMiddle":
            return snapshot.profiles[r.profileID]?.impliedGivenMiddleSplit != nil
        case "censusRelationship":
            // Mirrors the fix button's "Add all N" guard (info kind, N > 1).
            guard r.severity == .info, let p = snapshot.profiles[r.profileID] else { return false }
            return CensusRelationshipReconciler.findings(for: p, in: snapshot)
                .filter { $0.kind == .missing }.count > 1
        default:
            return false
        }
    }

    // MARK: - Pinning (K1)

    /// Only genuine disagreements block the auto-approval machinery and earn
    /// the pin; refinement/note disputes band as blue judgement rows.
    static func disputePins(_ severity: DiscrepancySeverity?) -> Bool {
        severity == .correction || severity == .conflict
    }

    // MARK: - Key factories, one per Health row type

    static func findingKey(_ r: AuditResult, snapshot: FamilyGraphSnapshot) -> Key {
        let severityRank: Int = switch r.severity {
        case .error: 0
        case .warning: 1
        case .info: 2
        }
        return Key(
            pinRank: 1,
            severityRank: severityRank,
            quickWinRank: isOneClickFinding(r, snapshot: snapshot) ? 0 : 1,
            ruleLabel: prettyRule(r.ruleID),
            personKey: personKey(name: r.profileName, id: r.profileID),
            valueKey: "\(r.ruleID)|\(r.profileID)|\(r.message)")
    }

    static func disputeKey(severity: DiscrepancySeverity?, field: String,
                           entityID: String, personName: String?) -> Key {
        let pinned = disputePins(severity)
        // Inside the pin block K2 orders correction (0) before conflict (1);
        // unpinned cosmetic disputes band as blue judgement.
        let severityRank = pinned ? (severity == .correction ? 0 : 1) : 2
        return Key(
            pinRank: pinned ? 0 : 1,
            severityRank: severityRank,
            quickWinRank: 1,        // Resolve… is a decision, never a quick win
            ruleLabel: "Conflicts",
            personKey: personKey(name: personName ?? entityID, id: entityID),
            valueKey: "\(field)|\(entityID)")
    }

    static func duplicateClusterKey(firstName: String?, clusterID: String) -> Key {
        Key(pinRank: 1, severityRank: 1,          // amber judgement
            quickWinRank: 1,                       // Compare is judgement
            ruleLabel: "Duplicates",
            personKey: personKey(name: firstName ?? clusterID, id: clusterID),
            valueKey: clusterID)
    }

    static func contradictoryFactsKey(personName: String, profileID: String,
                                      demotableCount: Int) -> Key {
        Key(pinRank: 1, severityRank: 1,          // amber — issue-class
            quickWinRank: demotableCount > 0 ? 0 : 1,
            ruleLabel: "Contradictory facts",
            personKey: personKey(name: personName, id: profileID),
            valueKey: profileID)
    }

    /// Census backfill / death-age backfill / cite-census proposal rows:
    /// blue one-click apply actions, distinguished by their chip label.
    static func proposalKey(label: String, personName: String, id: String) -> Key {
        Key(pinRank: 1, severityRank: 2, quickWinRank: 0,
            ruleLabel: label,
            personKey: personKey(name: personName, id: id),
            valueKey: id)
    }

    // MARK: - Shared helpers

    /// "marriedSurnameFromSpouse" → "Married surname from spouse".
    /// (Moved from HealthView so the K4 label and the chip label are the
    /// same string by construction.)
    static func prettyRule(_ id: String) -> String {
        var out = ""
        for ch in id {
            if ch.isUppercase && !out.isEmpty { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst().lowercased()
    }

    /// Case-insensitive person ordering with the profile id folded in, so a
    /// person's rows stay contiguous even against a namesake.
    private static func personKey(name: String, id: String) -> String {
        name.localizedLowercase + "\u{1F}" + id
    }
}
