import Foundation
import AncestorKit

/// #HR4 Severity Ladder — the deterministic ordering of the Health list.
///
/// Owner ruling (2026-08-25): red must never sit below amber, and quick wins
/// are "a factor likely equal to red hard-to-fix issues". The ladder answers
/// both without a blended score: one lexicographic sort on a six-part key.
/// Every position is explainable by reciting the keys in order —
///
///   K1  pin        genuine disagreements (correction/conflict disputes)
///                  first: the stored value may be WRONG and only the user
///                  can choose. Cosmetic refinement/note disputes do NOT
///                  pin — a conflict sweep of trivia must never bury the
///                  reds (pin-flood guard). Whether a dispute blocks the
///                  MCP auto-approval gate is a separate, precisely
///                  mirrored fact (`blocksAutoApproval`) shown as its own
///                  row badge — it is NOT what earns the pin.
///   K2  severity   red → amber → blue, from an explicit per-row-type table
///                  (no inference). Disputes run the full DiscrepancySeverity
///                  ladder — correction, conflict (both pinned), then
///                  refinement, then note — so worst-first survives inside
///                  the cosmetic band too.
///   K3  quick win  a deterministic one-click undoable fix leads its colour
///                  band — the "equal factor". Membership comes from ONE
///                  registry (`isOneClickFinding`) shared by the sort, the
///                  ⚡ badge, and the ⚡ Quick-wins chip, so they can never
///                  disagree. Compare/Resolve — and anything that merely
///                  ROUTES to the profile or fetches from the network — are
///                  judgement, never quick.
///   K4  rule label alphabetical by display label — stable as counts change.
///   K5  person     display name, case-insensitive, then profile id — kills
///                  the dictionary-iteration jitter between audit runs.
///   K6  value key  run-stable value-derived tiebreak (NEVER AuditResult.id,
///                  which is a fresh UUID every audit pass), carrying enough
///                  identity to make the key injective.
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
    /// `hasDatabase` mirrors the `appState.currentDatabase` guard the
    /// FreeBMD-enrich button sits behind.
    ///
    /// NOT one-click, though they look like it (review 2026-08-25):
    /// `censusUnabsorbed` / `parishFamilyUnabsorbed` have no AuditFixButton
    /// case at all — in the Health host their detail row renders "Review in
    /// profile" (a navigation: adding people is a tree change that must be
    /// confirmed in full context) or "Load household" (a network fetch).
    /// Neither is a deterministic undoable click, so neither earns the ⚡.
    static func isOneClickFinding(
        _ r: AuditResult, snapshot: FamilyGraphSnapshot, hasDatabase: Bool
    ) -> Bool {
        switch r.ruleID {
        case "censusParentUnlock":
            return true
        case "freebmdLinkMissing":
            return hasDatabase
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

    // MARK: - Disputes

    /// Only genuine disagreements earn the pin; refinement/note disputes band
    /// with the cosmetic rows so a trivia sweep can't bury the reds.
    static func disputePins(_ severity: DiscrepancySeverity?) -> Bool {
        severity == .correction || severity == .conflict
    }

    /// Mirrors the §14.3 MCP auto-approval refusal EXACTLY
    /// (`MCPServer.swift`: `WHERE entity_id = ? AND resolution IS NULL`, then
    /// fieldValue-on-the-target-field or any structural kind).
    ///
    /// Two consequences the pin does NOT capture, which is why this is its
    /// own predicate: severity is irrelevant to the gate (a cosmetic
    /// `refinement` dispute blocks its field exactly as a `correction`
    /// does), and a `deferred` dispute — which Health still lists as open —
    /// does NOT block, because the gate matches `resolution IS NULL` only.
    static func blocksAutoApproval(resolution: DisputeResolution?) -> Bool {
        resolution == nil
    }

    /// Row badge wording for a dispute that blocks the gate. A fieldValue
    /// dispute blocks only facts on ITS field; the structural kinds block
    /// everything on the profile.
    static func autoApprovalBadgeText(kind: DisputeKind, field: String) -> String {
        switch kind {
        case .fieldValue:
            let name = field.isEmpty ? "this field" : field
            return "Blocks \(name) auto-approval"
        case .timeline, .parentRole, .spouseIdentity:
            return "Blocks auto-approval"
        }
    }

    // MARK: - Key factories, one per Health row type

    static func findingKey(
        _ r: AuditResult, snapshot: FamilyGraphSnapshot, hasDatabase: Bool
    ) -> Key {
        let severityRank: Int = switch r.severity {
        case .error: 0
        case .warning: 1
        case .info: 2
        }
        return Key(
            pinRank: 1,
            severityRank: severityRank,
            quickWinRank: isOneClickFinding(r, snapshot: snapshot, hasDatabase: hasDatabase) ? 0 : 1,
            ruleLabel: prettyRule(r.ruleID),
            personKey: personKey(name: r.profileName, id: r.profileID),
            valueKey: "\(r.ruleID)|\(r.profileID)|\(r.message)")
    }

    /// `rowID` is the persisted `field_disputes` rowid — the final fence that
    /// makes the key injective. Two open disputes can legitimately share
    /// entity+field (different `kind`, or a deferred row beside a fresh
    /// detection), so kind and rowid both ride in K6.
    static func disputeKey(severity: DiscrepancySeverity?, kind: DisputeKind,
                           field: String, entityID: String, rowID: Int64,
                           personName: String?) -> Key {
        // The full DiscrepancySeverity ladder (correction > conflict >
        // refinement > note > none): the top two pin (0/1); the rest stay in
        // the cosmetic band but keep worst-first between themselves (2/3/4),
        // which is exactly the pre-HR4 `sorted { severity > severity }`.
        let severityRank: Int = switch severity {
        case .correction: 0
        case .conflict: 1
        case .refinement: 2
        case .note: 3
        case .none, .some(.none): 4
        }
        return Key(
            pinRank: disputePins(severity) ? 0 : 1,
            severityRank: severityRank,
            quickWinRank: 1,        // Resolve… is a decision, never a quick win
            ruleLabel: "Conflicts",
            personKey: personKey(name: personName ?? entityID, id: entityID),
            valueKey: "\(kind.rawValue)|\(field)|\(entityID)|\(rowID)")
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
