import Foundation
import AncestorKit

/// Subject place model Slice 1.5 — the corpus replay diff.
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
        rows(from: diagnose(profileID: profileID, evidence: evidence,
                            profile: profile, snapshot: snapshot,
                            homeChapmanCode: homeChapmanCode))
    }

    /// The fingerprint, derived from the full diagnosis. One code path, so the
    /// gate and the drift analysis can never disagree about what was decided.
    static func rows(from details: [Detail]) -> [Row] {
        details.map { d in
            Row(profileID: d.profileID, recordID: d.recordID,
                verdict: d.finalVerdict.rawValue,
                gates: d.finalGates.map {
                    "\($0.gate.rawValue):\($0.outcome.rawValue):\(sanitise($0.reason))"
                })
        }
    }

    /// Everything a drift investigation needs about one record, including the
    /// two intermediate results a `Row` deliberately collapses.
    struct Detail: Sendable {
        let profileID: String
        let recordID: String
        let sourceID: String
        /// `record.recordType` — what the record itself says it is.
        let intrinsicType: RecordType
        /// `evidence_records.record_type` — what the row was FILED as. These
        /// can differ, and where they do the original `searchType` is
        /// unrecoverable, which is a limit on any replay's fidelity.
        let filedType: RecordType
        let storedVerdict: RecordVerdict
        /// Empty on pre-v44 rows, which persisted no gates. An empty stored
        /// gate list is "unknown", NOT "no gates fired" — nothing may be
        /// concluded from comparing against it.
        let storedGates: [GateResult]
        let userStatus: UserReviewStatus
        let appliedAt: Date?
        let scoredAt: Date
        let isEnrichment: Bool
        /// Verdict from `classify` ALONE — before the cross-record pass. The
        /// split that separates "a per-record gate now rejects this" from "the
        /// exclusivity pass demotes it", which have entirely different causes.
        let preExclusivityVerdict: RecordVerdict
        let preExclusivityGates: [GateResult]
        let finalVerdict: RecordVerdict
        let finalGates: [GateResult]
        /// The same record re-scored under the FILED type instead of the
        /// intrinsic one. Identical to `preExclusivityVerdict` whenever the two
        /// types agree; where they differ this measures how much of any drift
        /// is an artefact of the replay's `searchType` choice rather than a real
        /// change in the rules.
        let filedTypeVerdict: RecordVerdict

        /// This row was scored against a subject the replay does not rebuild.
        ///
        /// `ResearchPipeline`'s child-gap probe (:817-823) mutates a COPY of
        /// the subject — `givenName = nil`, `birthYearFrom/To = nil`, surname
        /// swapped to the family surname — and dispatches it for `[.death]`
        /// only, to sweep for infant deaths in a birth gap. `ScoreReplay`
        /// rebuilds exactly one subject per profile from `fromProfile` and has
        /// no way to reconstruct a probe subject, so for these rows the stored
        /// verdict and the replayed verdict were produced from different
        /// inputs.
        ///
        /// They remain perfectly valid for the BEFORE/AFTER code diff — both
        /// captures reconstruct the subject identically, so the comparison is
        /// still like-with-like. What they must not do is count toward
        /// "the store disagrees with the rules", which is a claim ABOUT the
        /// store. On the owner's project they were 46% of the apparent drift.
        let scoredAgainstUnreconstructableSubject: Bool

        var drifted: Bool { storedVerdict != finalVerdict }

        /// Drift that is genuinely a statement about the store: the verdict
        /// moved AND the comparison was like-with-like. This is the figure to
        /// quote; `drifted` alone over-reports.
        var driftedMeaningfully: Bool { drifted && !scoredAgainstUnreconstructableSubject }
        /// The first gate that stopped this record being a fact, or nil if none did.
        var blockingGate: GateResult? {
            finalGates.first { $0.outcome != .pass && $0.outcome != .skip }
        }
        /// Did the cross-record pass cause this, rather than a per-record gate?
        var demotedByExclusivity: Bool {
            preExclusivityVerdict == .fact && finalVerdict != .fact
        }
    }

    /// Re-score with the full diagnosis retained.
    static func diagnose(
        profileID: String, evidence: [EvidenceRecord],
        profile: Profile, snapshot: FamilyGraphSnapshot, homeChapmanCode: String
    ) -> [Detail] {
        guard !evidence.isEmpty else { return [] }

        let subject = ResearchSubject.fromProfile(
            profile, snapshot: snapshot, mode: .extend, homeChapmanCode: homeChapmanCode)

        // Stage 1 — the four gates, per record, in a stable order.
        let ordered = evidence.sorted { $0.sourceRecordID < $1.sourceRecordID }
        let scored = ordered.map {
            RecordScorer.classify(
                record: $0.record, subject: subject, searchType: $0.record.recordType)
        }
        // The same records under the type the row was FILED as, to measure the
        // replay's own searchType assumption rather than assume it away.
        let underFiledType = ordered.map {
            $0.record.recordType == $0.recordType
                ? nil
                : RecordScorer.classify(
                    record: $0.record, subject: subject, searchType: $0.recordType)
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
        // Applied rows are exempt from demotion, exactly as the live pipeline
        // exempts them — a replay that demoted an applied fact would report a
        // narrowing the app does not actually perform.
        let appliedIDs = Set(
            ordered.filter { $0.wasApplied(to: profile) }.map(\.sourceRecordID))
        let settled = Dictionary(
            RecordScorer.applyExclusivity(facts, ghosts: ghosts, appliedIDs: appliedIDs)
                .map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })

        // The probe fingerprint, read off the STORED gates: they record what
        // the scorer could see at the time. The subject-side cross-check
        // matters — a profile that genuinely has no given name (an unnamed
        // placeholder) produces the same gate reason from its OWN subject, and
        // its rows are real drift that must not be excused.
        let profileHasGivenName = !(profile.firstName ?? "")
            .trimmingCharacters(in: .whitespaces).isEmpty
        let profileHasBirthWindow = profile.birthDate?.earliest != nil
            || profile.birthDate?.latest != nil

        return zip(zip(ordered, scored), underFiledType).map { pair, filed in
            let (stored, fresh) = pair
            let final = settled[fresh.id] ?? fresh
            let storedSawNoGivenName = stored.gates.contains {
                $0.gate == .name && $0.reason.contains("subject given name unknown")
            }
            let storedSawNoBirthWindow = stored.gates.contains {
                $0.gate == .date && $0.reason == "insufficient date information"
            }
            let looksLikeProbeRow =
                stored.record.recordType == .death       // the probe asks for deaths only
                && storedSawNoGivenName && storedSawNoBirthWindow
                && (profileHasGivenName || profileHasBirthWindow)   // …but the profile has one
            return Detail(
                profileID: profileID,
                recordID: fresh.id,
                sourceID: stored.sourceID,
                intrinsicType: stored.record.recordType,
                filedType: stored.recordType,
                storedVerdict: stored.verdict,
                storedGates: stored.gates,
                userStatus: stored.userStatus,
                appliedAt: stored.appliedAt,
                scoredAt: stored.scoredAt,
                isEnrichment: stored.isEnrichment,
                preExclusivityVerdict: fresh.verdict,
                preExclusivityGates: fresh.gates,
                finalVerdict: final.verdict,
                finalGates: final.gates,
                filedTypeVerdict: filed?.verdict ?? fresh.verdict,
                scoredAgainstUnreconstructableSubject: looksLikeProbeRow)
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
        rows(from: diagnoseAll(in: db, snapshot: snapshot))
    }

    /// Re-score the whole tree with the full diagnosis retained.
    static func diagnoseAll(
        in db: ProjectDatabase, snapshot: FamilyGraphSnapshot
    ) -> [Detail] {
        let home = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? ""
        return snapshot.profiles.keys.sorted().flatMap { id -> [Detail] in
            guard let profile = snapshot.profiles[id],
                  let evidence = try? db.loadEvidenceForProfile(id)
            else { return [] }
            return diagnose(profileID: id, evidence: evidence,
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
