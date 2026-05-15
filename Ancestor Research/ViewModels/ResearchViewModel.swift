import Foundation
import os

/// Orchestrates per-profile research: trigger → pipeline → cluster review → accept.
@MainActor @Observable
final class ResearchViewModel {
    // Input
    var selectedProfile: Profile?
    var selectedMode: ResearchMode = .extend
    var selectedScope: ResearchScope = .local

    // Pipeline state
    var isResearching = false
    var currentResult: ResearchResult?
    var progressMessage: String?
    var sourceStatuses: [SourceStatus] = []
    /// Rolling buffer of the most recent activity events for the live feed.
    /// Capped at 30 entries so the UI scrolls cleanly without unbounded growth.
    var recentActivity: [String] = []
    private var activitySubscription: Task<Void, Never>?

    // Review state
    var clusterDecisions: [String: ClusterDecision] = [:]  // cluster.id → decision
    var proposedRelativeDecisions: [String: ClusterDecision] = [:]  // proposal.id → decision
    var isApplying = false
    var applyMessage: String?

    // Database reference for persistence
    var appDatabase: ProjectDatabase?

    // Error
    var errorMessage: String?

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ResearchVM")

    /// Status of each source during a research run.
    struct SourceStatus: Identifiable {
        let id: String
        let displayName: String
        var state: SourceState
        var resultCount: Int
        var reason: String?
    }

    enum SourceState: String {
        case pending, searching, complete, skipped, error
    }

    enum ClusterDecision: String {
        case accepted, rejected, deferred
    }

    // MARK: - Research Flow

    /// Start research for a profile.
    func startResearch(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        registry: SourceRegistry
    ) async {
        selectedProfile = profile
        isResearching = true
        currentResult = nil
        clusterDecisions = [:]
        proposedRelativeDecisions = [:]
        recentActivity = []
        errorMessage = nil
        progressMessage = "Preparing research..."

        // Subscribe to live activity events so the UI can show per-source spinners
        // and a recent-activity feed. Cancelled at the end of the run.
        //
        // IMPORTANT: subscribe() must complete BEFORE the pipeline kicks off,
        // otherwise the source's earliest `sourceQueryStarted` events fire
        // into the bus before our continuation is registered and they are
        // silently dropped — which is what produced the empty Activity feed
        // for fast Discover runs.
        activitySubscription?.cancel()
        let stream = await ResearchActivityBus.shared.subscribe()
        activitySubscription = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                self.applyActivityEvent(event)
            }
        }

        // Build source info map
        let sourceInfoMap = registry.buildSourceInfoMap()

        // Build subject from profile
        let subject = ResearchSubject.fromProfile(profile, snapshot: snapshot, mode: selectedMode)

        // Show source eligibility
        sourceStatuses = registry.allSources().map { source in
            return SourceStatus(
                id: source.sourceID,
                displayName: source.displayName,
                state: registry.isEnabled(source.sourceID) ? .pending : .skipped,
                resultCount: 0,
                reason: registry.isEnabled(source.sourceID) ? nil : "disabled"
            )
        }

        // Choose config based on mode + scope
        let config = ResearchConfig.preset(for: selectedMode).with(scope: selectedScope)

        progressMessage = "Searching \(subject.displayName)..."

        let dispatcher = SearchDispatcher(
            registry: registry,
            regionConfig: RegionConfig.derbyshire
        )
        let pipeline = ResearchPipeline(
            dispatcher: dispatcher,
            snapshot: snapshot,
            sourceInfoMap: sourceInfoMap
        )

        let result = await pipeline.research(subject: subject, config: config)

        currentResult = result
        isResearching = false
        progressMessage = nil
        activitySubscription?.cancel()
        activitySubscription = nil

        // Update source statuses from results
        updateSourceStatuses(from: result)

        logger.info("Research complete: \(result.clusters.count) clusters, \(result.confirmedFacts.count) facts, \(result.leads.count) leads")

        // Persist every scored record as evidence. Lossless capture of typed +
        // raw fields per source response. Idempotent on (profile, source-record-id),
        // so re-running research overwrites the same row rather than duplicating.
        if let db = appDatabase {
            var saved = 0
            for scored in result.allScoredRecords {
                let citation = CitationRenderer.cite(scored.record)
                do {
                    try db.saveEvidence(
                        profileID: profile.id,
                        scored: scored,
                        citationFull: citation.full,
                        citationURL: citation.url
                    )
                    saved += 1
                } catch {
                    logger.warning("Failed to save evidence for \(scored.record.id): \(error.localizedDescription)")
                }
            }
            logger.info("Persisted \(saved)/\(result.allScoredRecords.count) evidence records for \(profile.displayName)")
        }

        // Create leads from scored leads and household discoveries
        if let db = appDatabase {
            let leadStore = LeadStore(db: db)
            for scored in result.leads {
                _ = try? await leadStore.createFromScoredRecord(scored, profileID: profile.id)
            }
            for member in result.householdMembers {
                let censusYear = result.allScoredRecords
                    .compactMap { r -> Int? in
                        if case .census(let c) = r.record { return c.censusYear }
                        return nil
                    }.first ?? 1861
                _ = try? await leadStore.createFromHouseholdMember(member, profileID: profile.id, censusYear: censusYear)
            }
        }

        // Persist the research run
        if let db = appDatabase {
            let searchedSources = Set(result.allScoredRecords.map(\.record.sourceID))
            let gps = GPSScorer.score(
                result: result,
                sourceInfoMap: sourceInfoMap,
                searchedSourceCount: searchedSources.count,
                totalSourceCount: registry.allSources().count
            )
            try? db.saveResearchRun(
                id: UUID(),
                profileID: profile.id,
                mode: selectedMode,
                startedAt: Date(),
                completedAt: Date(),
                factCount: result.confirmedFacts.count,
                leadCount: result.leads.count,
                clusterCount: result.clusters.count,
                gpsScore: gps.score
            )
        }
    }

    /// Translate an activity event into UI state — per-source spinner + activity feed.
    /// Source status flips to `.searching` on start, back to a result-count display
    /// on completion, and to `.error` on failure.
    private func applyActivityEvent(_ event: ResearchActivityEvent) {
        // Append to the rolling activity feed (cap at 30 entries — newest at top).
        recentActivity.insert(event.description, at: 0)
        if recentActivity.count > 30 { recentActivity.removeLast(recentActivity.count - 30) }

        // Update per-source status card.
        switch event {
        case .sourceQueryStarted(let sourceID, _):
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }) {
                sourceStatuses[idx].state = .searching
                sourceStatuses[idx].reason = nil
            }
        case .sourceQueryCompleted(let sourceID, _, let count):
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }) {
                sourceStatuses[idx].state = .complete
                sourceStatuses[idx].resultCount += count
            }
        case .sourceError(let sourceID, _, let reason):
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }) {
                sourceStatuses[idx].state = .error
                sourceStatuses[idx].reason = reason
            }
        case .pipelineStage:
            // Pipeline stages don't bind to a single source; only the feed shows them.
            break
        }
    }

    private func updateSourceStatuses(from result: ResearchResult) {
        var sourceCounts: [String: Int] = [:]
        for record in result.allScoredRecords {
            sourceCounts[record.record.sourceID, default: 0] += 1
        }
        for i in sourceStatuses.indices {
            let count = sourceCounts[sourceStatuses[i].id] ?? 0
            sourceStatuses[i].resultCount = count
            if sourceStatuses[i].state != .skipped {
                sourceStatuses[i].state = .complete
                if count == 0 {
                    sourceStatuses[i].reason = "no results"
                }
            }
        }
    }

    // MARK: - Cluster Decisions

    /// Mark every record in this cluster as `saved_as_lead` and project
    /// each record onto the profile as a `LifeEvent`. Replaces the old
    /// in-memory "accepted" marker — the decision now travels with the
    /// evidence row itself so the user can come back to it after restarting
    /// the app, and re-running research won't reset the flag.
    ///
    /// Task #53 — the projection is the on-ramp from research results into
    /// the tree. Each constituent `SourceRecord` that maps to a LifeEvent
    /// (burial, military, probate, census, parish baptism/burial — not
    /// birth/death/marriage which live elsewhere) becomes a row in
    /// `life_events`. The LifeEvent.id is deterministic in (profileID,
    /// sourceRecordID), so re-clicking "Save as lead" on the same cluster
    /// is idempotent via `addLifeEventIfAbsent`.
    func acceptCluster(_ cluster: LifeCluster) {
        clusterDecisions[cluster.id] = .accepted
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        let ids = cluster.records.map(\.record.id)
        try? db.updateEvidenceUserStatus(profileID: profileID, sourceRecordIDs: ids, status: .savedAsLead)
        for scored in cluster.records {
            if let event = scored.record.projectToLifeEvent(profileID: profileID) {
                _ = try? db.addLifeEventIfAbsent(event)
            }
        }
    }

    /// Mark every record in this cluster as `discarded`. Both the new column
    /// and the legacy `record_rejections` table get written: rejections is
    /// still consulted by `loadRejections` (which now unions both views), so
    /// older projects without `user_status` populated keep working.
    func rejectCluster(_ cluster: LifeCluster) {
        clusterDecisions[cluster.id] = .rejected
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        let ids = cluster.records.map(\.record.id)
        try? db.updateEvidenceUserStatus(profileID: profileID, sourceRecordIDs: ids, status: .discarded)
        for record in cluster.records {
            try? db.saveRejection(profileID: profileID, recordID: record.id)
        }
    }

    /// Unwind a previous Save-as-lead / Discard decision on every record in
    /// the cluster. The legacy `record_rejections` row is NOT removed (it
    /// would require a DELETE migration and the union-read in `loadRejections`
    /// makes the active state authoritative anyway) — discarded rows can
    /// re-appear if they're flipped back to `unreviewed` here.
    func resetCluster(_ cluster: LifeCluster) {
        clusterDecisions.removeValue(forKey: cluster.id)
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        let ids = cluster.records.map(\.record.id)
        try? db.updateEvidenceUserStatus(profileID: profileID, sourceRecordIDs: ids, status: .unreviewed)
    }

    func deferCluster(_ cluster: LifeCluster) {
        clusterDecisions[cluster.id] = .deferred
    }

    /// Source-record IDs the user has manually overridden via the
    /// rejected-records section in cluster review. Tracked here so the row
    /// flips visibly from "Save as lead anyway" → "Saved as lead" the
    /// moment the user clicks; without it, `userStatusForRecord` reads the
    /// DB on each render but SwiftUI has no @Observable signal to know to
    /// re-render and the click looked like a no-op.
    var overriddenRecordIDs: Set<String> = []

    /// Live lookup for a single record's `user_status` so the cluster-review
    /// rejected-records section can disable its "Save as lead anyway" button
    /// once the user has acted. Returns `.unreviewed` if the row isn't yet
    /// persisted (the projection only runs after Save as lead).
    func userStatusForRecord(_ sourceRecordID: String) -> UserReviewStatus {
        // Fast path — the user just clicked Override in this session.
        // Reading `overriddenRecordIDs` here is what re-renders the row.
        if overriddenRecordIDs.contains(sourceRecordID) {
            return .savedAsLead
        }
        guard let db = appDatabase, let profileID = selectedProfile?.id else {
            return .unreviewed
        }
        let id = EvidenceRecord.compositeID(profileID: profileID, sourceRecordID: sourceRecordID)
        guard let event = (try? db.loadEvidenceForProfile(profileID))?.first(where: { $0.id == id }) else {
            return .unreviewed
        }
        return event.userStatus
    }

    /// Override the scorer's `.impossible` verdict — mark the single record
    /// as `saved_as_lead` and run the same `projectToLifeEvent` path that
    /// `acceptCluster` uses for normal clusters (Task #53). Gives the user
    /// final say when the subject's profile is too sparse for the scorer.
    func overrideRejection(_ scored: ScoredRecord) {
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        try? db.updateEvidenceUserStatus(
            profileID: profileID,
            sourceRecordIDs: [scored.record.id],
            status: .savedAsLead
        )
        if let event = scored.record.projectToLifeEvent(profileID: profileID) {
            _ = try? db.addLifeEventIfAbsent(event)
        }
        // Flip the observable signal so SwiftUI re-renders the row.
        overriddenRecordIDs.insert(scored.record.id)
    }

    // MARK: - Proposed Relative Decisions

    /// Filter proposals by previously-persisted rejections for the subject.
    /// Called after research completes so old rejections suppress the same proposal.
    func visibleProposedRelatives() -> [ProposedRelative] {
        guard let result = currentResult else { return [] }
        guard let db = appDatabase, let profileID = selectedProfile?.id else {
            return result.proposedRelatives
        }
        let rejected = (try? db.loadRejections(profileID: profileID)) ?? []
        return result.proposedRelatives.filter { !rejected.contains($0.id) }
    }

    /// Accept a proposed relative: create a ghost Profile + parent-of Relationship in one atomic transaction.
    /// Refreshes the AppState snapshot so the new relative shows up in the tree.
    func acceptProposedRelative(_ proposal: ProposedRelative, into appState: AppState) {
        guard let db = appState.currentDatabase else {
            errorMessage = "No project open"
            return
        }
        guard case .parentOf(let subjectID) = proposal.relationship else {
            errorMessage = "Only parent-of proposals are supported"
            return
        }

        let ghostID = UUID().uuidString
        let ghost = makeGhostProfile(id: ghostID, from: proposal)

        let role: ParentRole = switch proposal.gender {
        case .male: .father
        case .female: .mother
        default: .unspecified
        }

        let parentEdge = Relationship(
            id: UUID(),
            from: ghostID,
            to: subjectID,
            type: .parent,
            role: role,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )

        do {
            _ = try db.addFamily(
                profiles: [ghost],
                relationships: [parentEdge],
                source: .freebmd
            )
            appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
            proposedRelativeDecisions[proposal.id] = .accepted
        } catch {
            errorMessage = "Failed to create relative: \(error.localizedDescription)"
        }
    }

    /// Reject a proposed relative: persist the proposal id so it will not reappear
    /// on subsequent research runs for the same subject.
    func rejectProposedRelative(_ proposal: ProposedRelative) {
        proposedRelativeDecisions[proposal.id] = .rejected
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        try? db.saveRejection(profileID: profileID, recordID: proposal.id)
    }

    private func makeGhostProfile(id: String, from proposal: ProposedRelative) -> Profile {
        let birthDate: GenealogicalDate?
        switch (proposal.birthYearLow, proposal.birthYearHigh) {
        case let (lo?, hi?):
            birthDate = GenealogicalDate(parsing: "BET \(lo) AND \(hi)")
        case let (lo?, nil):
            birthDate = GenealogicalDate(parsing: "AFT \(lo)")
        case let (nil, hi?):
            birthDate = GenealogicalDate(parsing: "BEF \(hi)")
        case (nil, nil):
            birthDate = nil
        }

        return Profile(
            id: id,
            externalIDs: [:],
            firstName: proposal.proposedGivenName,
            lastName: proposal.proposedSurname,
            gender: proposal.gender,
            attributes: PersonAttributes(
                nameStatus: proposal.proposedGivenName == nil ? .placeholder : .known,
                lifeStatus: .normal,
                privacy: .normal
            ),
            birthDate: birthDate,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    var acceptedClusters: [LifeCluster] {
        currentResult?.clusters.filter { clusterDecisions[$0.id] == .accepted } ?? []
    }

    var pendingDecisions: Int {
        guard let result = currentResult else { return 0 }
        return result.clusters.count - clusterDecisions.count
    }

    var hasAcceptedClusters: Bool {
        !acceptedClusters.isEmpty
    }

    // MARK: - Apply Results

    /// Apply accepted clusters to the tree.
    /// Returns the fields that were updated.
    func applyAccepted(to appState: AppState) -> Int {
        guard let profile = selectedProfile else { return 0 }
        guard appState.currentDatabase != nil else { return 0 }

        isApplying = true
        applyMessage = "Applying research results..."
        var fieldsUpdated = 0

        for cluster in acceptedClusters {
            for scored in cluster.records where scored.verdict == .fact {
                switch scored.record {
                case .birth(let r):
                    if profile.birthDate == nil, r.birthYear != nil { fieldsUpdated += 1 }
                    if profile.birthLocation == nil, (r.birthPlace ?? r.district) != nil { fieldsUpdated += 1 }
                case .death(let r):
                    if profile.deathDate == nil, r.deathYear != nil { fieldsUpdated += 1 }
                    if profile.deathLocation == nil, (r.deathPlace ?? r.district) != nil { fieldsUpdated += 1 }
                case .marriage:
                    fieldsUpdated += 1
                default:
                    break
                }
            }
        }

        isApplying = false
        applyMessage = nil
        return fieldsUpdated
    }

    /// Re-run the current research session at a different scope.
    /// Used by the No-Candidates empty-state "Search nationally" button —
    /// keeps the same profile + mode but widens the scope.
    func restart(
        withScope scope: ResearchScope,
        snapshot: FamilyGraphSnapshot,
        registry: SourceRegistry
    ) async {
        guard let profile = selectedProfile else { return }
        selectedScope = scope
        await startResearch(profile: profile, snapshot: snapshot, registry: registry)
    }

    /// Reset for a new research session.
    func reset() {
        selectedProfile = nil
        currentResult = nil
        clusterDecisions = [:]
        proposedRelativeDecisions = [:]
        sourceStatuses = []
        progressMessage = nil
        errorMessage = nil
        isResearching = false
    }
}
