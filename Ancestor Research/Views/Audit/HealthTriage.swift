import Foundation
import AncestorKit

/// #HR4 Severity Ladder — the deterministic ordering of the Health list.
///
/// Owner ruling (2026-08-25): red must never sit below amber, and quick wins
/// are "a factor likely equal to red hard-to-fix issues". The ladder answers
/// both without a blended score: one lexicographic sort on a seven-part key.
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
///                  (no inference). Unpinned disputes band BLUE; K2a
///                  (`withinBandRank`) then keeps them worst-first among
///                  themselves (refinement > note > ungraded) without
///                  sinking them below the band.
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
        /// Ordering INSIDE a colour band, for row types that grade finer than
        /// red/amber/blue. Only unpinned disputes use it (refinement > note >
        /// ungraded); everything else is 0, so it never perturbs the ladder.
        /// It exists because giving disputes their own severityRanks 3-4 put
        /// them in a fifth band *below* blue — including a structural
        /// `.note` dispute that blocks all auto-approval (review 2026-08-25).
        let withinBandRank: Int
        let quickWinRank: Int
        let ruleLabel: String
        let personKey: String
        let valueKey: String

        static func < (a: Key, b: Key) -> Bool {
            // Seven parts — one past what tuple `<` supports, so chained
            // explicitly rather than silently dropping a key.
            if a.pinRank != b.pinRank { return a.pinRank < b.pinRank }
            if a.severityRank != b.severityRank { return a.severityRank < b.severityRank }
            if a.withinBandRank != b.withinBandRank { return a.withinBandRank < b.withinBandRank }
            if a.quickWinRank != b.quickWinRank { return a.quickWinRank < b.quickWinRank }
            if a.ruleLabel != b.ruleLabel { return a.ruleLabel < b.ruleLabel }
            if a.personKey != b.personKey { return a.personKey < b.personKey }
            return a.valueKey < b.valueKey
        }
    }

    // MARK: - The one-click registry (K3)

    /// True iff the Health list renders a deterministic, undoable one-click
    /// fix for this finding — a row must never wear the ⚡ badge and then
    /// render no such button. That means mirroring BOTH sources of action in
    /// that list: `AuditFixButton`'s switch (and its guards), and the inline
    /// detail panels the list hosts beneath certain rows.
    ///
    /// NOT one-click, though they look like it (review 2026-08-25):
    /// `censusUnabsorbed` / `parishFamilyUnabsorbed` have no AuditFixButton
    /// case at all — in the Health host their detail row renders "Review in
    /// profile" (a navigation: adding people is a tree change that must be
    /// confirmed in full context) or "Load household" (a network fetch).
    /// Neither is a deterministic undoable click, so neither earns the ⚡.
    /// `freebmdLinkMissing` is ejected on the same ground (review M6): its
    /// only button, "Enrich from FreeBMD", runs live FreeBMD queries that can
    /// throttle, return nothing, or fail, and its writes have no undo — the
    /// registry's own definition (fetches from the network = judgement, never
    /// quick) rules it out, and a ⚡ clearance queue must never fire a volley
    /// of network calls at a volunteer source. `hasDatabase` (the
    /// `appState.currentDatabase` guard that button sits behind) stays in the
    /// signature for the callers' sake and for any future DB-gated LOCAL
    /// one-click. No branch below reads it — if you add one that does, this
    /// sentence is the thing to delete.
    static func isOneClickFinding(
        _ r: AuditResult, snapshot: FamilyGraphSnapshot, hasDatabase: Bool
    ) -> Bool {
        switch r.ruleID {
        case "censusParentUnlock":
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
            // AuditFixButton's "Add all N" needs N > 1, but the Health list
            // ALSO hosts the reconciliation panel, which renders a one-click
            // "Add <relation>" per missing relative at any N — so a single
            // missing relative is still a quick win here (review 2026-08-25).
            // EV33 follow-up (review C5): the panel's "Link <name>"
            // (unlinked-in-tree) and "Add <spouse>'s mother/father" (in-law)
            // buttons are one-clicks of the same deterministic class, and the
            // .info gap row fires for those households with zero .missing
            // findings — so membership comes from the rule's own shared
            // predicate, which walks every roster status the panel renders
            // (near-matches stay judgement, EV18).
            guard r.severity == .info, let p = snapshot.profiles[r.profileID] else { return false }
            return CensusRelationshipRule.hasOneClickReconciliation(for: p, in: snapshot)
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

    /// Fields will ever auto-approve — mirror of
    /// `MCPServer.autoApprovableFields` (that is the source of truth; names,
    /// gender and bio are excluded by design). A `fieldValue` dispute outside
    /// this set changes nothing, because such facts are refused earlier
    /// regardless, so claiming it "blocks auto-approval" would be false.
    static let autoApprovableFields: Set<String> = [
        "birthDate", "deathDate", "baptismDate", "burialDate",
        "birthLocation", "deathLocation",
        "marriageDate", "marriageLocation",
        "occupation", "address",
    ]

    /// Mirrors BOTH conjuncts of the refusal (`MCPServer`): the row must
    /// be unresolved (`resolution IS NULL`) AND either be a `fieldValue`
    /// dispute on a field the gate could otherwise commit, or one of the
    /// structural kinds, which block everything on the profile.
    ///
    /// Two consequences the pin does NOT capture, which is why this is its
    /// own predicate: severity is irrelevant to the gate (a cosmetic
    /// `refinement` blocks its field exactly as a `correction` does), and a
    /// `deferred` dispute — which Health still lists as open — does NOT
    /// block, because the gate matches `resolution IS NULL` only.
    static func blocksAutoApproval(
        kind: DisputeKind, field: String, resolution: DisputeResolution?
    ) -> Bool {
        guard resolution == nil else { return false }
        switch kind {
        case .fieldValue:
            return autoApprovableFields.contains(field)
        case .timeline, .parentRole, .spouseIdentity:
            return true
        }
    }

    /// Row badge wording. `fieldLabel` is the DISPLAY form ("Birth date"),
    /// not the raw key — the row already prints the prettified name beside
    /// this badge, and two spellings of one field on one row reads as two
    /// different things.
    static func autoApprovalBadgeText(kind: DisputeKind, fieldLabel: String) -> String {
        switch kind {
        case .fieldValue:
            let name = fieldLabel.isEmpty ? "this field" : fieldLabel
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
            withinBandRank: 0,
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
        // `?? .none` first, so the graded value is never confused with
        // Optional.none (DiscrepancySeverity has its own `.none` case).
        let graded = severity ?? DiscrepancySeverity.none
        // The top two pin (0/1). Everything else stays in the BLUE band (2)
        // rather than sinking beneath it, and keeps worst-first among
        // disputes via the within-band rank.
        let severityRank: Int = switch graded {
        case .correction: 0
        case .conflict: 1
        default: 2
        }
        let withinBandRank: Int = switch graded {
        case .refinement: 0
        case .note: 1
        case .none: 2
        default: 0
        }
        return Key(
            pinRank: disputePins(severity) ? 0 : 1,
            severityRank: severityRank,
            withinBandRank: withinBandRank,
            quickWinRank: 1,        // Resolve… is a decision, never a quick win
            ruleLabel: "Conflicts",
            personKey: personKey(name: personName ?? entityID, id: entityID),
            valueKey: "\(kind.rawValue)|\(field)|\(entityID)|\(rowID)")
    }

    static func duplicateClusterKey(firstName: String?, clusterID: String) -> Key {
        Key(pinRank: 1, severityRank: 1,          // amber judgement
            withinBandRank: 0,
            quickWinRank: 1,                       // Compare is judgement
            ruleLabel: "Duplicates",
            personKey: personKey(name: firstName ?? clusterID, id: clusterID),
            valueKey: clusterID)
    }

    static func contradictoryFactsKey(personName: String, profileID: String,
                                      demotableCount: Int) -> Key {
        Key(pinRank: 1, severityRank: 1,          // amber — issue-class
            withinBandRank: 0,
            quickWinRank: demotableCount > 0 ? 0 : 1,
            ruleLabel: "Contradictory facts",
            personKey: personKey(name: personName, id: profileID),
            valueKey: profileID)
    }

    /// Census backfill / death-age backfill / cite-census proposal rows:
    /// blue one-click apply actions, distinguished by their chip label.
    static func proposalKey(label: String, personName: String, id: String) -> Key {
        Key(pinRank: 1, severityRank: 2, withinBandRank: 0, quickWinRank: 0,
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
