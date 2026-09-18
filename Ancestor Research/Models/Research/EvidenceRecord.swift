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

    /// v56 — when the apply ACTION ran for this record (nil = never applied,
    /// or applied before v56 existed; Remove clears it). `.savedAsLead` alone
    /// is NOT an apply: the "Save as lead" review action stamps the same
    /// status without writing anything.
    let appliedAt: Date?

    // Campaign review Change 2 — the persisted evidence chain carries
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
        userStatus: UserReviewStatus, appliedAt: Date? = nil,
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
        self.appliedAt = appliedAt
        self.gates = gates
        self.summary = summary
        self.isEnrichment = isEnrichment
        self.lastRunID = lastRunID
    }

    /// Whether the apply ACTION actually ran for this record. v56's
    /// `applied_at` is the truth; rows applied BEFORE v56 (the column has no
    /// backfill) are recognised by the apply's fingerprint — every applied
    /// field carries the record's citation, so its URL (or its citation text,
    /// access-date trimmed) appears among the profile's field sources. A
    /// record merely kept via "Save as lead" matches neither. (Owner dogfood
    /// 2026-07-31: Mary Ellen Thompson's saved-as-lead census rendered a
    /// green "Applied" while her Birth stayed empty — `.savedAsLead` alone
    /// must never read as applied.)
    func wasApplied(to profile: Profile?) -> Bool {
        if userStatus == .discarded { return false }   // the user rejected it
        if appliedAt != nil { return true }
        // Citation-fingerprint fallback: a confirmed fact on the profile that
        // cites THIS record is proof the apply ran — whatever the userStatus.
        // Previously this required `.savedAsLead`, but apply paths like
        // parent-unlock land a census's facts + life event WITHOUT stamping the
        // evidence, so a wrongly-applied census showed "Apply" (not "Remove") in
        // the ledger and couldn't be undone (owner report 2026-08-06: George
        // Herbert Brooks's Coleorton namesake census).
        guard let profile else { return false }
        let trimmedFull = Self.trimAccessDate(citationFull)
        for sources in profile.sources.values {
            for source in sources {
                guard let citation = source.citation else { continue }
                if let url = citationURL, !url.isEmpty, citation.url == url { return true }
                if let full = trimmedFull, !full.isEmpty,
                   Self.trimAccessDate(citation.notes) == full { return true }
            }
        }
        return false
    }

    /// "…; accessed 30 Jul 2026." → "…" — the only part of a citation that
    /// differs between the apply-time copy and a later re-scrape.
    static func trimAccessDate(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.range(of: "; accessed").map { String(s[..<$0.lowerBound]) } ?? s
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
