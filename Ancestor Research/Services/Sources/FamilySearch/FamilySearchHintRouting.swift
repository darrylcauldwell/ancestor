import Foundation
import AncestorKit

/// Routes FamilySearch hint-derived `SourceRecord`s through the deterministic
/// scorer and buckets them into a `ResearchResult` for
/// `ResearchRunService.persist` (S6b — the agreed scorer-routed design).
///
/// The FS match confidence (`rawFields["fsMatchScore"]`) is INERT to the
/// scorer: `RecordScorer.classify` reads only the name/date/geography/
/// familyContext gates, never `fsMatchScore` — so §18 holds by construction, and
/// a hint that FamilySearch's ML attached to the *wrong* same-name tree person
/// simply scores `.impossible`/`.lead` on the real subject's gates and is
/// filtered/flagged there. That deterministic net is the whole point of routing
/// hints through the scorer rather than minting leads from FS's opinion.
///
/// Records are tagged `enrichmentRecordIDs` so persistence flags the evidence
/// rows (and a DB re-cluster applies the same exclusion). Dedup against records
/// search is automatic: both paths key evidence on `"<profileID>|<persona.id>"`.
nonisolated enum FamilySearchHintRouting {

    static func route(records: [SourceRecord], subject: ResearchSubject) -> ResearchResult {
        let scored = records.map {
            RecordScorer.classify(record: $0, subject: subject, searchType: $0.recordType)
        }
        return ResearchResult(
            confirmedFacts: scored.filter { $0.verdict == .fact },
            leads: scored.filter { $0.verdict == .lead },
            allScoredRecords: scored,
            clusters: [],
            discrepancies: [],
            householdMembers: [],
            searchHistory: [],
            enrichmentRecordIDs: Set(scored.map(\.id)))
    }
}
