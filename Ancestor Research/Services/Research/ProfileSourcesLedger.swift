import Foundation
import AncestorKit

/// PROFILE_SOURCES_LEDGER_SPEC Change 2 — the read-only per-profile evidence
/// ledger: the records a user has kept for a person (accepted facts / saved
/// leads), read straight from `evidence_records` with **no research run**. This
/// is what closes the "applied facts show only as field values; you must re-run
/// research to re-see the records" gap.
///
/// Pure over the DB read — the view renders `entries`; a later change adds the
/// per-entry removal action on top of the same list.
enum ProfileSourcesLedger {

    /// One kept record, display-ready.
    struct Entry: Identifiable, Sendable, Equatable {
        /// The source record id — stable, and the handle a later removal change
        /// uses to reject the record.
        let id: String
        let sourceID: String
        let recordType: RecordType
        let verdict: RecordVerdict
        /// Full citation (falls back to the scorer summary if none was rendered).
        let citation: String
        let citationURL: String?
        /// What this record lands on the profile ("birth date Dec 1883",
        /// "birth place Belper") — the SAME `absorptionPlan` the write path
        /// executes, so the ledger can't claim a fact the apply didn't write.
        let establishes: [String]
    }

    /// The kept records backing a profile, ordered deterministically (record
    /// type, then id). "Kept" = `savedAsLead` — the status both the apply path
    /// and "Save as lead" write; discarded/unreviewed rows are excluded.
    static func entries(for profileID: String, db: ProjectDatabase) throws -> [Entry] {
        try db.loadEvidenceForProfile(profileID)
            .filter { $0.userStatus == .savedAsLead }
            .map { rec in
                Entry(
                    id: rec.sourceRecordID,
                    sourceID: rec.sourceID,
                    recordType: rec.recordType,
                    verdict: rec.verdict,
                    citation: (rec.citationFull?.isEmpty == false ? rec.citationFull! : rec.summary),
                    citationURL: rec.citationURL,
                    establishes: rec.record.absorptionPlan(profileID: profileID).compactMap(\.reviewLabel))
            }
            .sorted { ($0.recordType.rawValue, $0.id) < ($1.recordType.rawValue, $1.id) }
    }
}
