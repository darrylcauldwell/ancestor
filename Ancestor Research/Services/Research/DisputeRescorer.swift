import Foundation
import os
import AncestorKit

/// EV35 (2026-08-26) — resolving a dispute must re-score the records its
/// openness was holding back.
///
/// `RecordScorer.contestedPremise` demotes a record from `.impossible` to a
/// reviewable `.lead` while its premise field is under an open dispute. That
/// demotion is frozen into `evidence_records` at scoring time, so once the
/// user rules the dispute the record keeps sitting in "Researched — not
/// applied" until an unrelated research run happens to re-fetch and re-stomp
/// it. This performs that same deterministic re-stomp on the spot.
///
/// Purely local — the records are already persisted, so no network, no source
/// re-fetch, no volunteer-source load. The re-score itself is
/// `ScoreReplay.diagnose`: the SAME two-stage replay (four gates, then the
/// cross-record exclusivity pass with the live pipeline's applied exemption)
/// the drift harness uses, so the rules cannot fork into a second copy.
///
/// Only the WRITE is scoped. `ScoreReplay` is explicit that a replay row is
/// not the stored verdict and may differ for reasons that have nothing to do
/// with this dispute (the profile edited since, an unreconstructable probe
/// subject, a filed-vs-intrinsic searchType artefact). Persisting the whole
/// replay on a dispute click would silently re-verdict unrelated rows, so the
/// write is confined to rows whose stored date gate names THIS field as the
/// disputed premise. Everything else the replay decides stays diagnosis.
///
/// Applied rows are re-scored like any other, deliberately: this is the same
/// re-stomp a research run performs, and a run does not exempt applied rows
/// from the GATE pass (`saveEvidence` overwrites `verdict` regardless of
/// `applied_at`). The exclusivity pass's applied exemption still holds —
/// `ScoreReplay` passes `appliedIDs` through — and `ProfileSourcesLedger`
/// ranks `.applied` above the verdict, so an applied record does not fall out
/// of the Applied bucket.
nonisolated enum DisputeRescorer {

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research", category: "DisputeRescorer")

    /// Re-score and re-persist the stored evidence a now-settled dispute on
    /// `field` was holding back. Returns the number of rows rewritten.
    ///
    /// `snapshot` MUST be rebuilt after the resolution write — the subject is
    /// derived from it, and a stale snapshot still carries the open dispute
    /// (and, for an `.accepted` resolution, the old canonical value).
    @discardableResult
    static func rescoreAfterResolution(
        profileID: String,
        field: ProfileField,
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot
    ) -> Int {
        guard let profile = snapshot.profiles[profileID],
              let evidence = try? db.loadEvidenceForProfile(profileID),
              !evidence.isEmpty else { return 0 }

        // The rows this dispute demoted, identified from the PERSISTED gates.
        let held = Set(
            evidence
                .filter { RecordScorer.heldByOpenDispute($0.gates, field: field) }
                .map(\.sourceRecordID))
        guard !held.isEmpty else { return 0 }

        let home = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? ""
        let details = ScoreReplay.diagnose(
            profileID: profileID, evidence: evidence,
            profile: profile, snapshot: snapshot, homeChapmanCode: home)
        let rowByID = Dictionary(
            evidence.map { ($0.sourceRecordID, $0) }, uniquingKeysWith: { a, _ in a })

        var rewritten = 0
        for detail in details where held.contains(detail.recordID) {
            guard let row = rowByID[detail.recordID] else { continue }
            // Gates as well as verdict: a record that stays a lead for a NEW
            // reason must lose the stale "which is itself disputed" prose the
            // user is reading. `GateResult` is not Equatable, hence by hand.
            let unchanged = detail.finalVerdict == row.verdict
                && detail.finalGates.count == row.gates.count
                && zip(detail.finalGates, row.gates).allSatisfy {
                    $0.gate == $1.gate && $0.outcome == $1.outcome && $0.reason == $1.reason
                }
            guard !unchanged else { continue }
            do {
                // `summary` is a pure function of (record, searchType) — the
                // dispute cannot move it — so the stored one is carried over
                // rather than recomputed. `runID: row.lastRunID` preserves the
                // run linkage the default-nil parameter would otherwise NULL.
                try db.saveEvidence(
                    profileID: profileID,
                    scored: ScoredRecord(
                        id: row.sourceRecordID,
                        record: row.record,
                        verdict: detail.finalVerdict,
                        gates: detail.finalGates,
                        summary: row.summary),
                    citationFull: row.citationFull,
                    citationURL: row.citationURL,
                    isEnrichment: row.isEnrichment,
                    runID: row.lastRunID)
                rewritten += 1
            } catch {
                logger.error("""
                    Re-score write failed for \(row.sourceRecordID, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        if rewritten > 0 {
            logger.info("""
                Dispute on \(field.rawValue, privacy: .public) settled — re-scored \
                \(rewritten, privacy: .public) held record(s) for \(profileID, privacy: .public)
                """)
        }
        return rewritten
    }
}
