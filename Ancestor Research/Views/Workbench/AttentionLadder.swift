import Foundation
import AncestorKit

/// #EV29 — the Workbench "Needs attention" router's ordering.
///
/// The router used to sort on a SUMMED count (`pendingFacts + leads +
/// proposals + disputes`), which makes queue KIND invisible: a profile with
/// one firewall-queued fact ranked below every profile carrying two leads,
/// and a research run mints leads by the dozen (60 on one profile,
/// 2026-08-25). The Evidence Firewall is the only route external research
/// enters the tree, so its queue sinking below the fold means facts sit
/// unreviewed forever.
///
/// The replacement is a lexicographic band ladder on queue KIND, modelled on
/// the shipped #HR4 `HealthTriage.Key` so the app's two routers order by the
/// same philosophy —
///
///   K1  dispute       an open disagreement leads: the stored value may be
///                     WRONG and only the user can choose (HR4's pin rationale)
///   K2  pending fact  the Evidence Firewall queue
///   K3  proposal      a structural edge awaiting approval
///   K4  gated work    within a band, more work a human must RULE on first
///   K5  leads         leads break ties; they NEVER set the band
///   K6  person        display name, case-insensitive
///   K7  profile id    kills the dictionary-iteration jitter between reloads
///
/// Pure and view-free so the ordering rules are testable without a host
/// (WorkbenchAttentionLadderTests).
enum AttentionLadder {

    struct Item: Identifiable, Sendable, Equatable {
        let id: String          // profile id
        let name: String
        let birthYear: Int?
        let pendingFacts: Int
        let leads: Int
        let proposals: Int
        let disputes: Int
        /// SC-6 follow-up (review M7): the profile is absent from the
        /// snapshot (soft-deleted, or an id the tree doesn't know). The row
        /// renders with a "not in tree" marker instead of silently dropping
        /// its queued work.
        let isOffSnapshot: Bool

        init(id: String, name: String, birthYear: Int?,
             pendingFacts: Int, leads: Int, proposals: Int, disputes: Int,
             isOffSnapshot: Bool = false) {
            self.id = id
            self.name = name
            self.birthYear = birthYear
            self.pendingFacts = pendingFacts
            self.leads = leads
            self.proposals = proposals
            self.disputes = disputes
            self.isOffSnapshot = isOffSnapshot
        }

        var total: Int { pendingFacts + leads + proposals + disputes }
        /// Work a human must RULE on: an open dispute, or something the
        /// Evidence Firewall parked. Leads are suggestions and never qualify.
        var gatedWork: Int { disputes + pendingFacts + proposals }
        var isGated: Bool { gatedWork > 0 }
    }

    struct Key: Comparable, Sendable {
        let disputeRank: Int
        let pendingFactRank: Int
        let proposalRank: Int
        let negatedGatedWork: Int
        let negatedLeads: Int
        let personKey: String
        let profileID: String

        static func < (a: Key, b: Key) -> Bool {
            // Seven parts — one past what tuple `<` supports, so chained
            // explicitly rather than silently dropping a key.
            if a.disputeRank != b.disputeRank { return a.disputeRank < b.disputeRank }
            if a.pendingFactRank != b.pendingFactRank { return a.pendingFactRank < b.pendingFactRank }
            if a.proposalRank != b.proposalRank { return a.proposalRank < b.proposalRank }
            if a.negatedGatedWork != b.negatedGatedWork { return a.negatedGatedWork < b.negatedGatedWork }
            if a.negatedLeads != b.negatedLeads { return a.negatedLeads < b.negatedLeads }
            if a.personKey != b.personKey { return a.personKey < b.personKey }
            return a.profileID < b.profileID
        }
    }

    static func key(for item: Item) -> Key {
        Key(disputeRank: item.disputes > 0 ? 0 : 1,
            pendingFactRank: item.pendingFacts > 0 ? 0 : 1,
            proposalRank: item.proposals > 0 ? 0 : 1,
            negatedGatedWork: -item.gatedWork,
            negatedLeads: -item.leads,
            personKey: item.name.localizedLowercase,
            profileID: item.id)
    }

    static func ordered(_ items: [Item]) -> [Item] {
        items.sorted { key(for: $0) < key(for: $1) }
    }

    /// How many rows render before the "Show all" fold. The cap bounds the
    /// leads-only tail but must NEVER swallow gated work — ordering alone
    /// would just relocate the burial from row 40 to row 16.
    static func visibleCount(_ ordered: [Item], cap: Int) -> Int {
        max(cap, ordered.prefix(while: { $0.isGated }).count)
    }

    /// SC-6 follow-up (review M7) — build the router's rows from the queue
    /// counts. `onSnapshot` resolves people the tree knows; `offSnapshot`
    /// resolves ids missing from the snapshot (the soft-deleted rows, loaded
    /// from the DB). An id in NEITHER still renders, labelled by its raw id.
    /// The old `guard let profile = snapshot.profiles[id] else { return nil }`
    /// silently dropped queued work attached to a soft-deleted profile —
    /// leads and pending facts don't cascade on soft-delete, and MCP can
    /// submit against any id — breaking the router's own store-wide
    /// guarantee ("nothing is ever reachable only by knowing which profile
    /// to open").
    static func rows(
        ids: Set<String>,
        pendingFacts: [String: Int],
        leads: [String: Int],
        proposals: [String: Int],
        disputes: [String: Int],
        onSnapshot: (String) -> (name: String, birthYear: Int?)?,
        offSnapshot: (String) -> (name: String, birthYear: Int?)?
    ) -> [Item] {
        ordered(ids.compactMap { id -> Item? in
            let resolvedOn = onSnapshot(id)
            let resolved = resolvedOn ?? offSnapshot(id)
            let item = Item(
                id: id,
                name: resolved?.name ?? "Unknown profile \(id)",
                birthYear: resolved?.birthYear,
                pendingFacts: pendingFacts[id] ?? 0,
                leads: leads[id] ?? 0,
                proposals: proposals[id] ?? 0,
                disputes: disputes[id] ?? 0,
                isOffSnapshot: resolvedOn == nil)
            return item.total > 0 ? item : nil
        })
    }

    /// A dispute still needs the user when unresolved, or explicitly PARKED
    /// (`.deferred` is "not decided" — the profile card and Health both still
    /// list a deferred dispute as open). A RESOLVED dispute is not attention:
    /// counting it kept settled profiles in the router forever and inflated
    /// their rank, breaking the view's own "a row disappears when its queues
    /// empty" contract.
    static func openDisputeCount(_ disputes: [ProfileField: FieldDispute]) -> Int {
        disputes.values.filter { $0.resolution == nil || $0.resolution == .deferred }.count
    }
}

/// #HR3 follow-up (review C6) — which `.research` audit findings the
/// Workbench "Research suggestions" section must surface ITSELF.
///
/// The Health recategorisation retired `.research` findings from Health on
/// the promise that the completeness engine already carries their reasons —
/// true for the missing-X rules, FALSE for evidence-derived prompts like
/// `fertilityGap`'s children shortfall ("1911: she stated 8 children born
/// alive; the tree has 6 — 2 unaccounted"), which has no completeness mirror
/// and therefore rendered NOWHERE in-app. This shaper picks out exactly the
/// unmirrored prompts so the suggestion rows carry them alongside the
/// "Missing: …" labels — and pulls their people INTO the list even at full
/// completeness. New `.research` rules are visible BY DEFAULT: a rule is
/// hidden here only when a completeness check demonstrably carries the same
/// signal (fail open into visibility, never the reverse — invisibility was
/// the defect).
///
/// Pure and view-free so the selection and ranking rules are testable
/// without a host (WorkbenchResearchPromptsTests).
enum WorkbenchResearchPrompts {

    /// Rules whose `.research` signal is a straight mirror of a
    /// `FamilyGraphSnapshot` completeness check — the suggestion row's
    /// "Missing: …" line already says it, so repeating the finding would
    /// only be noise.
    static let completenessMirroredRuleIDs: Set<String> = [
        "completenessScore",     // literally the completeness score
        "missingParents",        // hasParents
        "missingBirthDate",      // birthDate
        "missingDeathDate",      // deathDate
        "missingBirthLocation",  // birthLocation
        "missingDeathLocation",  // deathLocation
        "missingBio",            // bio
        "ancestorExtension"      // hasParents again, plus a source hint
    ]

    /// Per-profile reason texts for the unmirrored `.research` findings,
    /// deterministically ordered (rule, then message) so rows are
    /// reload-stable. Tree-level findings (empty profileID) are dropped —
    /// this surface is per-person. `.issue`/`.gap` findings never pass:
    /// those belong to Health, not here.
    static func unmirroredReasons(in results: [AuditResult]) -> [String: [String]] {
        var byProfile: [String: [AuditResult]] = [:]
        for result in results
        where result.category == .research
            && !completenessMirroredRuleIDs.contains(result.ruleID)
            && !result.profileID.isEmpty {
            byProfile[result.profileID, default: []].append(result)
        }
        return byProfile.mapValues { findings in
            findings
                .sorted { ($0.ruleID, $0.message) < ($1.ruleID, $1.message) }
                .map(\.message)
        }
    }

    /// Order the suggestion candidates: evidence-flagged people first (their
    /// prompt derives from applied evidence, not generic incompleteness — a
    /// woman at 7/7 with a fertility shortfall must still appear), least
    /// complete first within each group, id tiebreak for reload stability.
    /// The cap must NEVER swallow a flagged person — `max(cap, flagged)`,
    /// the same philosophy as `AttentionLadder.visibleCount`.
    static func rankedIDs(
        completenessScores: [String: Int],
        flagged: Set<String>,
        cap: Int
    ) -> [String] {
        let ordered = completenessScores.keys.sorted { a, b in
            let fa = flagged.contains(a)
            let fb = flagged.contains(b)
            if fa != fb { return fa }
            let sa = completenessScores[a] ?? 0
            let sb = completenessScores[b] ?? 0
            if sa != sb { return sa < sb }
            return a < b
        }
        let flaggedCount = ordered.prefix(while: { flagged.contains($0) }).count
        return Array(ordered.prefix(max(cap, flaggedCount)))
    }
}
