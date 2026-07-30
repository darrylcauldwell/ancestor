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
        var id: String { sourceRecordID }
    }

    /// A profile whose accepted facts contradict each other.
    struct Finding: Identifiable, Sendable, Equatable {
        let profileID: String
        let profileName: String
        let demotions: [DemotedFact]
        var id: String { profileID }

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
    static func demotions(in evidence: [EvidenceRecord]) -> [ScoredRecord] {
        let facts = evidence
            .filter { $0.verdict == .fact && $0.userStatus != .discarded }
            .map(\.asScoredRecord)
        guard !facts.isEmpty else { return [] }
        // Ghost rivals: leads the pass previously demoted keep their slot
        // contested — a lone stored fact in a ghost-contested slot is the
        // flip-flop legacy state and demotes too. User-discarded rows never
        // block ("not them" resolves the contest) and never demote.
        let ghosts = evidence
            .filter { $0.verdict == .lead && $0.userStatus != .discarded }
            .map(\.asScoredRecord)
            .filter(RecordScorer.isExclusivityGhost)
        return RecordScorer.applyExclusivityAcrossStore(
            batch: [], storedFacts: facts, storedGhosts: ghosts
        ).demotedStored
    }

    /// Display-shaped finding for one profile; nil when consistent.
    static func finding(
        profileID: String, profileName: String, evidence: [EvidenceRecord]
    ) -> Finding? {
        let demoted = demotions(in: evidence)
        guard !demoted.isEmpty else { return nil }
        let rowByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.sourceRecordID, $0) })
        let rows = demoted.map { rec in
            DemotedFact(
                sourceRecordID: rec.id,
                slotLabel: slotLabel(for: rec.record),
                detail: rowByID[rec.id]?.citationFull
                    ?? (rec.summary.isEmpty ? rec.record.recordType.rawValue : rec.summary),
                reason: rec.gates.last { $0.gate == .exclusivity }?.reason
                    ?? "competing candidates")
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
