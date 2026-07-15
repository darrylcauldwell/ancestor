import Foundation
import os

/// Reconstructs a reviewable `ResearchResult` from PERSISTED state — the
/// substrate an overnight watcher campaign (or any past run) leaves in the
/// database — so BulkReviewView / ClusterReviewView can review it without a
/// live pipeline session (CAMPAIGN_REVIEW_SPEC Change 5).
///
/// Sources of truth (all persisted):
///   evidence_records       → ScoredRecords (full fidelity post-v44: gates,
///                            summary, enrichment flag)
///   research_hypotheses    → proposals/banners
///   research_discrepancies → CL3 "conflicts with tree" badge (latest run)
///   negative_searches ∪ evidence source ids → searched-surface approximation
///   research_run_requests  → campaign windows (incl. failures)
///
/// Reconstruction semantics vs the original run (documented, deliberate):
///   • Clusters are re-derived by the SAME deterministic ClusteringEngine
///     over a canonical input order (source_record_id ascending — load order
///     is scored_at DESC, which is not reproducible). Cluster ids are
///     positional and remain session-scoped — decisions persist on record
///     ids / user_status only.
///   • The evidence set is the profile's cross-run UNION (latest verdict per
///     record), not one run's exact input — review sees everything known.
///   • Enrichment-tagged rows are excluded from clustering exactly as the
///     run excluded them (persisted is_enrichment, Change 2).
///   • User-discarded records stay IN the result (live-run parity — the UI
///     dims them via user_status).
@MainActor
enum CampaignReviewService {

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research", category: "CampaignReview")

    // MARK: - Per-profile reconstruction

    /// Rebuild a reviewable result for one profile from the database.
    /// Returns nil when the profile has no persisted evidence at all.
    static func reconstructResult(
        profileID: String,
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot
    ) -> ResearchResult? {
        guard let profile = snapshot.profiles[profileID] else { return nil }
        guard let evidence = try? db.loadEvidenceForProfile(profileID),
              !evidence.isEmpty else { return nil }

        // Canonical order — deterministic across reconstructions.
        let ordered = evidence.sorted { $0.sourceRecordID < $1.sourceRecordID }
        let scored = ordered.map(\.asScoredRecord)
        let enrichmentIDs = Set(ordered.filter(\.isEnrichment).map(\.sourceRecordID))

        // Cluster with the run's exclusion applied (pipeline parity:
        // ResearchPipeline filters enrichment records before clustering).
        let homeChapmanCode = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? ""
        let subject = ResearchSubject.fromProfile(
            profile, snapshot: snapshot, mode: .extend, homeChapmanCode: homeChapmanCode)
        let clusterInput = scored.filter { !enrichmentIDs.contains($0.id) }
        let clusters = ClusteringEngine.cluster(
            records: clusterInput,
            sourceInfoMap: [:],  // unused by cluster() since RESEARCH_CONFIDENCE Change 5
            homeChapmanCode: subject.homeChapmanCode
        )

        let hypotheses = (try? db.loadHypotheses(forProfile: profileID)) ?? []
        let discrepancies = (try? db.latestRunDiscrepancies(profileID: profileID)) ?? []

        // Searched-surface approximation for GPS criterion 1: persisted
        // genuine negatives ∪ sources that returned evidence. (The
        // whole-tree resume sentinel uses its own profileID, so it's
        // excluded by construction.)
        let negativeRows = (try? db.loadNegativeSearches(profileID: profileID)) ?? []
        var searchHistory: [SearchAttempt] = negativeRows.map {
            SearchAttempt(sourceID: $0.sourceID,
                          recordType: RecordType(rawValue: $0.recordType) ?? .birth,
                          searchKey: "(persisted negative)",
                          resultCount: 0, timestamp: $0.date)
        }
        let coveredSources = Set(negativeRows.map(\.sourceID))
        for sourceID in Set(ordered.map(\.sourceID)).subtracting(coveredSources).sorted() {
            searchHistory.append(SearchAttempt(
                sourceID: sourceID, recordType: .birth,
                searchKey: "(reconstructed from evidence)",
                resultCount: 1, timestamp: Date()))
        }

        return ResearchResult(
            confirmedFacts: scored.filter { $0.verdict == .fact },
            leads: scored.filter { $0.verdict == .lead },
            allScoredRecords: scored,
            clusters: clusters,
            discrepancies: discrepancies,
            householdMembers: [],
            searchHistory: searchHistory,
            hypotheses: hypotheses,
            enrichmentRecordIDs: enrichmentIDs
        )
    }

    // MARK: - Convergence badge matching

    /// The strongest PERSISTED convergence level among the fact values this
    /// cluster asserts — the per-finding badge datum (CAMPAIGN_REVIEW_SPEC
    /// Change 6). Matches the cluster's fact-verdict records' value keys
    /// (ConvergenceEngine.valueKey) against the profile's persisted
    /// evidence_convergence rows. nil when the cluster asserts no
    /// fact-verdict value or nothing persisted matches.
    nonisolated static func convergenceLevel(
        for cluster: LifeCluster,
        persisted: [ProjectDatabase.EvidenceConvergenceRow]
    ) -> ConvergenceLevel? {
        let clusterKeys = Set(
            cluster.records
                .filter { $0.verdict == .fact }
                .map { ConvergenceEngine.valueKey(for: $0.record) }
        )
        return persisted
            .filter { clusterKeys.contains($0.valueKey) }
            .map(\.level)
            .max()
    }

    // MARK: - Campaign enumeration

    /// One profile's campaign outcome — what a run window attempted.
    struct CampaignEntry: Identifiable, Sendable {
        var id: String { profileID }
        let profileID: String
        let requestCount: Int
        let completed: Int
        let failed: Int
        let lastError: String?
    }

    /// Enumerate the campaign window: which profiles were researched since
    /// `since`, including failures — the review surface shows what a
    /// campaign SKIPPED, not just what it found.
    static func campaignEntries(
        since: Date,
        db: ProjectDatabase
    ) -> [CampaignEntry] {
        let requests = (try? db.loadRunRequests(since: since)) ?? []
        var byProfile: [String: [ProjectDatabase.RunRequestRow]] = [:]
        for request in requests {
            guard let pid = request.profileID else { continue }  // lead runs reviewed via lead surfaces
            byProfile[pid, default: []].append(request)
        }
        return byProfile.map { pid, rows in
            CampaignEntry(
                profileID: pid,
                requestCount: rows.count,
                completed: rows.filter { $0.status == "completed" }.count,
                failed: rows.filter { $0.status == "failed" }.count,
                lastError: rows.first(where: { $0.error != nil })?.error
            )
        }
        .sorted { $0.profileID < $1.profileID }
    }
}
