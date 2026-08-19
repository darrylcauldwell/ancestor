import Foundation
import AncestorKit

/// SUBJECT_PLACE_MODEL_SPEC Slice 1.5 — the corpus replay diff.
///
/// Re-scores every record already stored in a project and emits a stable
/// fingerprint of what the decision core decided. Capture one before a change
/// and one after; every altered verdict, gate outcome and gate reason shows up
/// in the diff. Nothing that changes search width ships without this.
///
/// **Why a diff and not an assertion.** The obvious invariant — "more places may
/// widen what is SEARCHED but never what the scorer ACCEPTS" — is unachievable,
/// because no such firewall exists. `RecordScorer.applyExclusivity` demotes a
/// stored `.fact` as soon as a second undiscriminated `.fact` appears in the same
/// slot, and searching one more county for a death is exactly how one arrives.
/// `ContradictoryFactsAudit` re-runs that pass tree-wide over stored evidence, so
/// the demotion surfaces days later, in a Health audit, on a record the user
/// already applied, with nothing tying it back. A widening can therefore take
/// facts AWAY. That is the failure nobody watches for, and only a replay diff
/// over the real corpus catches it.
///
/// **So the replay runs BOTH stages.** Per-record `classify` alone would miss the
/// demotion entirely — it is not a property of any single record. The pass is
/// reproduced exactly as `ContradictoryFactsAudit.demotions` reproduces it:
/// same slots, same ghost rivals, same user-discard exemption.
///
/// **A replay row is not the stored verdict, and is not meant to be.** It is
/// "what today's code decides about this record", so a row can legitimately
/// differ from what the store holds — the profile has been edited since, or the
/// record was originally scored under a different `searchType` than its own
/// record type. That is drift between the store and the rules, which is
/// `ContradictoryFactsAudit`'s job to surface, not this one's. The harness
/// compares LIKE WITH LIKE: two replays under different code, over one corpus.
///
/// Pure and read-only — it loads, re-scores in memory, and returns. It never
/// writes, so replaying is always safe, including against the live project.
nonisolated enum ScoreReplay {

    /// One record's decision, reduced to what a diff should be sensitive to.
    struct Row: Sendable, Equatable, Comparable {
        let profileID: String
        let recordID: String
        let verdict: String
        /// `gate:outcome:reason` per gate, in the scorer's own order. The REASON
        /// is included deliberately: a verdict that survives while its reason
        /// changes means the same answer arrived by a different route, which is
        /// exactly the drift a refactor introduces.
        let gates: [String]

        var line: String {
            "\(profileID)|\(recordID)|\(verdict)|\(gates.joined(separator: ";"))"
        }

        static func < (a: Row, b: Row) -> Bool {
            a.profileID == b.profileID ? a.recordID < b.recordID : a.profileID < b.profileID
        }
    }

    /// What moved between two replays.
    struct Change: Sendable, Equatable {
        let profileID: String
        let recordID: String
        let before: Row?
        let after: Row?

        /// `demoted` is the dangerous direction — invariant (a). A fact the user
        /// may already have applied stops being a fact.
        var kind: String {
            switch (before, after) {
            case (nil, _): "appeared"
            case (_, nil): "disappeared"
            case let (b?, a?) where b.verdict != a.verdict:
                a.verdict == "fact" ? "promoted" : (b.verdict == "fact" ? "demoted" : "reverdicted")
            default: "reasons"
            }
        }

        var description: String {
            "\(kind) \(profileID)/\(recordID)\n  - \(before?.line ?? "«absent»")\n  + \(after?.line ?? "«absent»")"
        }
    }

    // MARK: - Replay

    /// Re-score every stored record for one profile, through both stages.
    ///
    /// The subject is rebuilt exactly as `CampaignReviewService` rebuilds it, so
    /// a replay reflects the same inputs the review surfaces show.
    static func replay(
        profileID: String, evidence: [EvidenceRecord],
        profile: Profile, snapshot: FamilyGraphSnapshot, homeChapmanCode: String
    ) -> [Row] {
        guard !evidence.isEmpty else { return [] }

        let subject = ResearchSubject.fromProfile(
            profile, snapshot: snapshot, mode: .extend, homeChapmanCode: homeChapmanCode)

        // Stage 1 — the four gates, per record, in a stable order.
        let ordered = evidence.sorted { $0.sourceRecordID < $1.sourceRecordID }
        let scored = ordered.map {
            RecordScorer.classify(
                record: $0.record, subject: subject, searchType: $0.record.recordType)
        }

        // Stage 2 — the cross-record exclusivity pass. Reproduced exactly as
        // ContradictoryFactsAudit reproduces it: a user-discarded row is neither
        // a rival nor a candidate, because "not them" resolves the contest.
        let discarded = Set(
            ordered.filter { $0.userStatus == .discarded }.map(\.sourceRecordID))
        let facts = scored.filter { $0.verdict == .fact && !discarded.contains($0.id) }
        // Ghosts come from STORED state, not from the re-score. `isExclusivityGhost`
        // tests for an `.exclusivity` softFail gate, which only the pass itself
        // appends — a freshly classified record can never carry one, so deriving
        // ghosts from `scored` would always yield an empty set and silently drop
        // the legacy flip-flop case the audit exists to catch. The stored gate is
        // real database state and is identical on both sides of a diff, so it
        // contributes no noise.
        let ghosts = ordered
            .filter { $0.verdict == .lead && $0.userStatus != .discarded }
            .map(\.asScoredRecord)
            .filter(RecordScorer.isExclusivityGhost)
        let settled = Dictionary(
            RecordScorer.applyExclusivity(facts, ghosts: ghosts).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })

        return scored.map { fresh in
            let final = settled[fresh.id] ?? fresh
            return Row(
                profileID: profileID,
                recordID: fresh.id,
                verdict: final.verdict.rawValue,
                gates: final.gates.map {
                    "\($0.gate.rawValue):\($0.outcome.rawValue):\(sanitise($0.reason))"
                })
        }
    }

    /// Re-score one profile straight from the database.
    static func replay(
        profileID: String, in db: ProjectDatabase, snapshot: FamilyGraphSnapshot
    ) -> [Row] {
        guard let profile = snapshot.profiles[profileID],
              let evidence = try? db.loadEvidenceForProfile(profileID)
        else { return [] }
        let home = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? ""
        return replay(profileID: profileID, evidence: evidence,
                      profile: profile, snapshot: snapshot, homeChapmanCode: home)
    }

    /// Re-score the whole tree, deterministically ordered so two runs diff line
    /// by line.
    static func replayAll(in db: ProjectDatabase, snapshot: FamilyGraphSnapshot) -> [Row] {
        let home = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? ""
        return snapshot.profiles.keys.sorted().flatMap { id -> [Row] in
            guard let profile = snapshot.profiles[id],
                  let evidence = try? db.loadEvidenceForProfile(id)
            else { return [] }
            return replay(profileID: id, evidence: evidence,
                          profile: profile, snapshot: snapshot, homeChapmanCode: home)
        }
    }

    // MARK: - Diff

    /// Every record whose decision moved, worst direction first. Empty means the
    /// change was behaviour-preserving over this corpus — which is the only
    /// evidence that claim can have.
    static func diff(before: [Row], after: [Row]) -> [Change] {
        func index(_ rows: [Row]) -> [String: Row] {
            Dictionary(rows.map { ("\($0.profileID)\u{1}\($0.recordID)", $0) },
                       uniquingKeysWith: { a, _ in a })
        }
        let old = index(before), new = index(after)
        let rank = ["demoted": 0, "disappeared": 1, "reverdicted": 2,
                    "promoted": 3, "appeared": 4, "reasons": 5]

        return Set(old.keys).union(new.keys).sorted()
            .compactMap { key -> Change? in
                let b = old[key], a = new[key]
                guard b?.line != a?.line else { return nil }
                let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
                return Change(profileID: parts.first ?? key,
                              recordID: parts.count > 1 ? parts[1] : "",
                              before: b, after: a)
            }
            .sorted { (rank[$0.kind] ?? 9, $0.profileID, $0.recordID)
                    < (rank[$1.kind] ?? 9, $1.profileID, $1.recordID) }
    }

    /// The changes that break invariant (a) — something accepted before is not
    /// accepted now. These are the ones that must block a ship.
    static func narrowings(_ changes: [Change]) -> [Change] {
        changes.filter { $0.before?.verdict == "fact" && $0.after?.verdict != "fact" }
    }

    // MARK: - Capture / restore

    /// A replay rendered for storage on disk — one line per record, stable
    /// order, so `diff(1)` on two captures is as good as the structured diff.
    static func report(_ rows: [Row]) -> String {
        rows.isEmpty ? "" : rows.map(\.line).joined(separator: "\n") + "\n"
    }

    /// Restore a capture written by `report`. Round-trips: `parse(report(r)) == r`.
    static func parse(_ text: String) -> [Row] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", maxSplits: 3,
                               omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4 else { return nil }
            return Row(profileID: f[0], recordID: f[1], verdict: f[2],
                       gates: f[3].isEmpty ? [] : f[3].split(separator: ";").map(String.init))
        }
    }

    /// Gate reasons are free prose written for humans and may contain the
    /// delimiters. Neutralise them so a capture always round-trips.
    private static func sanitise(_ reason: String) -> String {
        reason
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
