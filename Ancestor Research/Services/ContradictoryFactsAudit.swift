import Foundation

/// DECISION_CORE_PAIR_SPEC follow-up — the tree-wide static twin of the
/// run-time exclusivity pass.
///
/// The pipeline's exclusivity pass only heals a profile when that profile is
/// re-researched; every profile not re-run since the decision-core rules
/// shipped can still hold mutually exclusive `fact` verdicts (the founding
/// specimens: Harry Marshall's 1999+2006 namesake probates, Mary E Land's two
/// marriages, Elizabeth Shaw's eleven births). This audit runs the SAME
/// deterministic rules (`RecordScorer.applyExclusivityAcrossStore` — slots,
/// registration-twin candidates, familyContext discriminator, ghost rivals)
/// over each profile's stored evidence with an empty batch, and reports the
/// facts the pass would demote. The one-click fix applies exactly those
/// demotions through `saveEvidence` (verdict-only; `user_status` and
/// `applied_at` preserved) — so Health and a re-research run always agree.
nonisolated struct ContradictoryFactsAudit {

    /// One demoted fact, shaped for display.
    struct DemotedFact: Identifiable, Sendable, Equatable {
        let sourceRecordID: String
        /// Human slot label ("death", "census 1891", "marriage").
        let slotLabel: String
        /// Best display line for the record — the stored citation when
        /// present, else the scorer summary.
        let detail: String
        /// The exclusivity reason the pass attached.
        let reason: String
        /// This record's content is ON THE TREE. The pass would still demote
        /// it, and the user needs to know that, but the one-click must not do
        /// it for them — see `Demotions.appliedHeldBack`.
        let isApplied: Bool
        var id: String { sourceRecordID }
    }

    /// What the pass would do, split by whether it is safe to do automatically.
    struct Demotions: Sendable {
        /// The pass would demote these and none is on the tree — the one-click
        /// may write them.
        let demotable: [ScoredRecord]
        /// The pass would demote these too, but their content is APPLIED to a
        /// profile. Demoting the evidence under an applied fact asserts the
        /// TREE is wrong, which is a genealogical judgement and the user's to
        /// make; a Health one-click that did it silently would leave a
        /// confirmed fact on the profile with its backing quietly reduced to a
        /// lead, days after the fact, with nothing linking the two. Reported,
        /// never written.
        let appliedHeldBack: [ScoredRecord]

        var all: [ScoredRecord] { demotable + appliedHeldBack }
        var isEmpty: Bool { demotable.isEmpty && appliedHeldBack.isEmpty }
    }

    /// A profile whose accepted facts contradict each other.
    struct Finding: Identifiable, Sendable, Equatable {
        let profileID: String
        let profileName: String
        let demotions: [DemotedFact]
        var id: String { profileID }

        /// Rows the one-click will NOT touch because they are on the tree.
        var appliedHeldBack: [DemotedFact] { demotions.filter(\.isApplied) }
        /// Rows the one-click will write.
        var demotable: [DemotedFact] { demotions.filter { !$0.isApplied } }

        /// Compact per-slot summary: "census 1891 ×3 · probate ×2".
        var slotSummary: String {
            var counts: [(label: String, count: Int)] = []
            for d in demotions {
                if let i = counts.firstIndex(where: { $0.label == d.slotLabel }) {
                    counts[i].count += 1
                } else {
                    counts.append((d.slotLabel, 1))
                }
            }
            return counts
                .map { $0.count == 1 ? $0.label : "\($0.label) ×\($0.count)" }
                .joined(separator: " · ")
        }
    }

    /// The stored fact rows the run-time pass would demote — with their
    /// appended `.exclusivity` gate, ready to re-persist. Empty when the
    /// store is internally consistent.
    /// `profile` is REQUIRED, with no default, on purpose. It is what
    /// `EvidenceRecord.wasApplied(to:)` needs for its citation-fingerprint
    /// fallback, and several apply paths (parent-unlock among them) land a
    /// record's facts WITHOUT stamping `applied_at` — so `appliedAt != nil`
    /// alone under-counts. A defaulted parameter is how the applied guard came
    /// to be missing here in the first place; making every call site name it
    /// forces the decision to be visible. Pass `nil` only when there genuinely
    /// is no profile in hand, and accept that the guard then degrades to the
    /// `applied_at` stamp.
    static func demotions(in evidence: [EvidenceRecord], profile: Profile?) -> Demotions {
        let facts = evidence
            .filter { $0.verdict == .fact && $0.userStatus != .discarded }
            .map(\.asScoredRecord)
        guard !facts.isEmpty else { return Demotions(demotable: [], appliedHeldBack: []) }
        // Ghost rivals: leads the pass previously demoted keep their slot
        // contested — a lone stored fact in a ghost-contested slot is the
        // flip-flop legacy state and demotes too. User-discarded rows never
        // block ("not them" resolves the contest) and never demote.
        let ghosts = evidence
            .filter { $0.verdict == .lead && $0.userStatus != .discarded }
            .map(\.asScoredRecord)
            .filter(RecordScorer.isExclusivityGhost)
        // Deliberately UNEXEMPTED (`appliedIDs` left empty). The pipeline
        // exempts applied rows from demotion so a run cannot take back the
        // user's decision — but this audit's job is to REPORT, and an applied
        // fact that contradicts another is exactly what the user needs told.
        // The split below is what keeps the one-click from acting on it.
        let demoted = RecordScorer.applyExclusivityAcrossStore(
            batch: [], storedFacts: facts, storedGhosts: ghosts
        ).demotedStored

        // The guard. The exclusivity verdict is unchanged — what changes is
        // who is allowed to act on it.
        let appliedIDs = Set(
            evidence.filter { $0.wasApplied(to: profile) }.map(\.sourceRecordID))
        return Demotions(
            demotable: demoted.filter { !appliedIDs.contains($0.id) },
            appliedHeldBack: demoted.filter { appliedIDs.contains($0.id) })
    }

    /// Display-shaped finding for one profile; nil when consistent.
    ///
    /// Applied rows ARE reported — the contradiction is real and the user must
    /// see it — but they carry `isApplied` so the surface can say plainly that
    /// the one-click will not touch them.
    static func finding(
        profileID: String, profileName: String, evidence: [EvidenceRecord],
        profile: Profile?
    ) -> Finding? {
        let demoted = demotions(in: evidence, profile: profile)
        guard !demoted.isEmpty else { return nil }
        let heldBackIDs = Set(demoted.appliedHeldBack.map(\.id))
        let rowByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.sourceRecordID, $0) })
        let rows = demoted.all.map { rec in
            DemotedFact(
                sourceRecordID: rec.id,
                slotLabel: slotLabel(for: rec.record),
                detail: rowByID[rec.id]?.citationFull
                    ?? (rec.summary.isEmpty ? rec.record.recordType.rawValue : rec.summary),
                reason: rec.gates.last { $0.gate == .exclusivity }?.reason
                    ?? "competing candidates",
                isApplied: heldBackIDs.contains(rec.id))
        }
        return Finding(profileID: profileID, profileName: profileName, demotions: rows)
    }

    /// "census-1891" → "census 1891"; non-slot records fall back to type.
    static func slotLabel(for record: SourceRecord) -> String {
        guard let slot = RecordScorer.exclusivitySlot(for: record) else {
            return record.recordType.rawValue
        }
        return slot.replacingOccurrences(of: "-", with: " ")
    }
}
