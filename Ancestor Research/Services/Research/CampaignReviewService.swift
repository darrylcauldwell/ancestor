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

    /// Leads to review in the window — gathered across the WHOLE STORE, not
    /// through `campaignEntries`.
    ///
    /// This deliberately does not go via run requests, and it lives here, next
    /// to `campaignEntries`, so the difference is visible. Triage used to
    /// collect leads inside its loop over campaign entries; because that list
    /// is built purely from `research_run_requests`, every lead created without
    /// a run was structurally invisible — MCP `submit_lead`, household
    /// absorption and manual entry all create leads with no request, and the
    /// entries loop additionally skips any profile whose result cannot be
    /// reconstructed, dropping that profile's leads with it. The owner's report
    /// (2026-08-21): two children found in a 1901 census, submitted over MCP,
    /// absent from Triage and reachable only by knowing which profile to open.
    ///
    /// A lead is a finding in its own right and does not need a run to justify
    /// showing it.
    ///
    /// `investigating` (pipeline in flight) and `promoted` (already a profile)
    /// are excluded — neither is awaiting a decision.
    static func campaignLeads(
        since: Date, db: ProjectDatabase
    ) -> (leads: [Lead], dismissed: [Lead]) {
        let window = ((try? db.loadLeads()) ?? []).filter { $0.createdAt >= since }
        return (
            leads: window.filter { $0.status == .new || $0.status == .investigated },
            dismissed: window.filter { $0.status == .dismissed }
        )
    }

    /// The add-to-tree action a lead warrants, or nil for "Research first".
    ///
    /// The distinction is whether the lead ASSERTS A PERSON or merely offers a
    /// record candidate. A lead built from a scored record — "George H LAND,
    /// Dec 1866, Rotherham" — carries no `relationship`: it is one index row
    /// out of a namesake-dense set, and adding it blind is how the removed
    /// Promote button minted fake identity profiles. A lead that names a kin
    /// role is a different claim: somebody enumerated this person standing in
    /// that relation to someone already on the tree. A census household is the
    /// archetype — the enumerator wrote them down, so their existence is not
    /// in question, only their dates and later life.
    ///
    /// The node promoted is a `nameStatus.placeholder` with provenance recorded
    /// as an origin note rather than a fabricated citation, so it is visibly a
    /// research node throughout. That is the safety valve that made "Add as
    /// mother/father" acceptable, and it holds identically here.
    ///
    /// SIBLING is deliberately excluded. There is no sibling edge in this model
    /// — siblings are implied by shared parents — so promoting one would have
    /// to guess which parents to attach it to, and `relationshipEdge` returns
    /// nil for it, which would strand the new node with no edge at all.
    enum AddAction: Equatable {
        case parent(role: String)   // "mother" / "father"
        case child
        case spouse

        /// Button label — reads from the perspective of the profile the lead
        /// sits under ("Add as child" on the father's row).
        var label: String {
            switch self {
            case .parent(let role): "Add as \(role)"
            case .child: "Add as child"
            case .spouse: "Add as spouse"
            }
        }
    }

    static func addAction(for lead: Lead) -> AddAction? {
        if let role = parentRole(lead) { return .parent(role: role) }
        switch lead.relationship?.lowercased() {
        case "child": return .child
        case "spouse": return .spouse
        default: return nil     // no kin claim → Research first
        }
    }

    /// "mother"/"father" for a parent-inference lead, else nil. A parent role
    /// is the only one where a surname alone identifies the person — you have
    /// at most one mother and one father.
    static func parentRole(_ lead: Lead) -> String? {
        switch lead.relationship?.lowercased() {
        case "mother": "mother"
        case "father": "father"
        default: nil
        }
    }

    /// Identity key for collapsing leads into one review row.
    ///
    /// Parent-inference leads key on (profile, role, surname) — one per
    /// surname by nature. Everything else keys on (profile, surname, given,
    /// year), so "Ida L Land 1885" arriving from three records collapses while
    /// a different year stays separate.
    ///
    /// The role branch is gated on PARENT roles specifically. It used to fire
    /// for any non-empty `relationship`, and "one per surname" is true of a
    /// mother but false of a CHILD or a sibling — they share a surname by
    /// definition. Every child-of-X lead therefore collapsed into a single row:
    /// Lilian A Land (b. ~1893) and George W Land (b. ~1898), both children of
    /// George Land in the 1901 Wirksworth census, showed as one row badged
    /// "2 records" with Lilian invisible inside it (owner report 2026-08-21).
    /// Two different people are not one finding.
    static func leadGroupKey(_ lead: Lead) -> String {
        if let role = parentRole(lead) {
            return "rel|\(lead.profileID)|\(role)|\((lead.surname ?? lead.name).uppercased())"
        }
        let surname = (lead.surname ?? "").uppercased()
        let given = (lead.givenName ?? "").uppercased()
        let year = lead.birthYear.map(String.init) ?? lead.deathYear.map(String.init) ?? "?"
        return "id|\(lead.profileID)|\(surname)|\(given)|\(year)"
    }
}
