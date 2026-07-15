import Foundation

/// User-facing review status for a piece of evidence. Distinct from the
/// scorer's `RecordVerdict` — that says "the algorithm thinks this is a match";
/// this says "the user has acted on this record". Persisted on
/// `evidence_records.user_status` (migration v16) so decisions survive re-runs.
///
/// Lifecycle: every newly-saved evidence row starts `.unreviewed`. The user
/// either marks it `.savedAsLead` (which also creates a Lead row pointing at
/// the evidence) or `.discarded` (which suppresses the record from future
/// cluster reviews and proposed-relative lists). Both can be reverted back to
/// `.unreviewed` — that's the "mutable status flag" promise.
nonisolated enum UserReviewStatus: String, Codable, Sendable, CaseIterable {
    case unreviewed
    case savedAsLead = "saved_as_lead"
    case discarded
}

/// A persisted snapshot of a single SourceRecord that the pipeline saw for a profile.
///
/// Captures the full raw record (typed fields + rawFields, JSON-encoded) plus the
/// verdict the scorer assigned. The point is to never throw away a source response —
/// every field a source returned for this person stays queryable forever.
///
/// Profile typed fields (birthDate, birthLocation, etc.) are derived projections
/// from this evidence; the evidence is the ground truth.
nonisolated struct EvidenceRecord: Sendable, Identifiable {
    /// Composite id: "<profileID>|<sourceRecordID>". Stable across re-runs so
    /// re-scoring the same record overwrites in place rather than duplicating.
    let id: String
    let profileID: String
    let sourceID: String
    let sourceRecordID: String
    let recordType: RecordType
    let verdict: RecordVerdict
    let record: SourceRecord            // decoded from record_json
    let citationFull: String?
    let citationURL: String?
    let scoredAt: Date
    /// User decision on this record. Defaults `.unreviewed` for newly-saved
    /// evidence; mutated via `ProjectDatabase.updateEvidenceUserStatus(...)`.
    /// Preserved across re-runs by `saveEvidence` (only the scorer-side
    /// columns get overwritten on conflict).
    let userStatus: UserReviewStatus

    // CAMPAIGN_REVIEW_SPEC Change 2 — the persisted evidence chain carries
    // the FULL scorer output, so a DB reconstruction is a complete
    // ScoredRecord, not a gates-less shadow. Legacy (pre-v44) rows decode
    // as gates=[] / summary="" / isEnrichment=false.

    /// Per-gate outcomes the scorer assigned (name/date/geography/family).
    let gates: [GateResult]
    /// Scorer's one-line summary of the record.
    let summary: String
    /// True when the run tagged this record as hypothesis-enrichment
    /// (parents' marriages, sibling probes) — excluded from candidate-life
    /// clustering, mirrored here so a re-cluster over persisted evidence
    /// applies the same exclusion.
    let isEnrichment: Bool
    /// research_runs.id of the run that last scored this row.
    let lastRunID: String?

    init(
        id: String, profileID: String, sourceID: String, sourceRecordID: String,
        recordType: RecordType, verdict: RecordVerdict, record: SourceRecord,
        citationFull: String?, citationURL: String?, scoredAt: Date,
        userStatus: UserReviewStatus,
        gates: [GateResult] = [], summary: String = "",
        isEnrichment: Bool = false, lastRunID: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.sourceID = sourceID
        self.sourceRecordID = sourceRecordID
        self.recordType = recordType
        self.verdict = verdict
        self.record = record
        self.citationFull = citationFull
        self.citationURL = citationURL
        self.scoredAt = scoredAt
        self.userStatus = userStatus
        self.gates = gates
        self.summary = summary
        self.isEnrichment = isEnrichment
        self.lastRunID = lastRunID
    }

    /// Reconstruct the scorer's view of this row — the input shape
    /// ClusteringEngine and the review surfaces consume.
    var asScoredRecord: ScoredRecord {
        ScoredRecord(id: sourceRecordID, record: record, verdict: verdict,
                     gates: gates, summary: summary)
    }

    static func compositeID(profileID: String, sourceRecordID: String) -> String {
        "\(profileID)|\(sourceRecordID)"
    }
}
