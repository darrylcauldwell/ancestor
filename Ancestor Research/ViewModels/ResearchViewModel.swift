import Foundation
import os

/// Orchestrates per-profile research: trigger → pipeline → cluster review → accept.
@MainActor @Observable
final class ResearchViewModel {
    // Input
    var selectedProfile: Profile?
    /// Lead currently being investigated, if any. Mutually exclusive with
    /// `selectedProfile` — the cluster review surface checks both so the
    /// header can show "Investigating: Jane Smith (lead)" without a profile
    /// in the tree. Set by `startResearch(lead:...)`, cleared by `reset()`.
    var selectedLead: Lead?
    var selectedMode: ResearchMode = .extend
    var selectedScope: ResearchScope = .county

    /// Display name of whatever's being researched — profile, lead, or
    /// neither. Triage surfaces use this rather than reaching into
    /// `selectedProfile?.displayName` so the lead case renders the lead's
    /// name without needing a synthetic Profile wrapper.
    var subjectDisplayName: String? {
        selectedProfile?.displayName ?? selectedLead?.name
    }

    // Pipeline state
    var isResearching = false
    var currentResult: ResearchResult?
    var progressMessage: String?
    var sourceStatuses: [SourceStatus] = []
    /// Rolling buffer of the most recent activity events for the live feed.
    /// Capped at 30 entries so the UI scrolls cleanly without unbounded growth.
    var recentActivity: [String] = []
    /// Per-source in-flight query count. Drives the source card's spinner →
    /// green-tick transition: the card stays on `.searching` until the count
    /// hits zero. Without this, sources that fan out (FreeBMD across
    /// districts, FreeCen across census years × chapman codes) would
    /// oscillate spinner↔tick as each individual query reports back.
    private var inFlightQueryCounts: [String: Int] = [:]
    private var activitySubscription: Task<Void, Never>?
    /// Owning reference for the outer research Task so the user can stop a run
    /// mid-flight via `cancelResearch()`. Set by the caller after `startResearch`
    /// kicks off; cleared when the run completes or is cancelled.
    var currentResearchTask: Task<Void, Never>?
    var wasCancelled = false

    // Review state
    var clusterDecisions: [String: ClusterDecision] = [:]  // cluster.id → decision
    var proposedRelativeDecisions: [String: ClusterDecision] = [:]  // proposal.id → decision
    /// Per-record overrides inside a cluster. Lets a user opt-in to applying
    /// a single record that didn't clear the gates (e.g. a `.lead` they've
    /// independently verified) or opt-out of one that did. The cluster-level
    /// Apply honours these decisions: forced records always apply, discarded
    /// records always skip, regardless of `wouldApply`. Key is `scored.id`.
    var recordDecisions: [String: ClusterDecision] = [:]
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

    /// Start research for a Lead — the unified entry point for "Investigate
    /// this lead" actions. Builds a `ResearchSubject` via the shared
    /// `ResearchSubject.fromLead` so the dispatcher searches for the lead's
    /// putative person, not the profile that generated the lead. Skips
    /// evidence persistence (no profile to attach to yet) but flips the
    /// lead's status to `.investigated` on completion so the Leads tab
    /// reflects the work.
    func startResearch(
        lead: Lead,
        snapshot: FamilyGraphSnapshot,
        registry: SourceRegistry
    ) async {
        selectedProfile = nil
        selectedLead = lead
        let homeChapmanCode = appDatabase
            .flatMap { try? $0.loadProjectMeta() }?
            .resolvedHomeChapmanCode ?? "DBY"
        let subject = ResearchSubject.fromLead(
            lead, mode: selectedMode, homeChapmanCode: homeChapmanCode
        )
        await runPipeline(
            subject: subject,
            snapshot: snapshot,
            registry: registry,
            persistProfileID: nil,
            leadToFinalise: lead
        )
    }

    /// Start research for a profile.
    func startResearch(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        registry: SourceRegistry
    ) async {
        selectedProfile = profile
        selectedLead = nil
        let homeChapmanCode = appDatabase
            .flatMap { try? $0.loadProjectMeta() }?
            .resolvedHomeChapmanCode ?? "DBY"
        let subject = ResearchSubject.fromProfile(
            profile, snapshot: snapshot, mode: selectedMode, homeChapmanCode: homeChapmanCode
        )
        await runPipeline(
            subject: subject,
            snapshot: snapshot,
            registry: registry,
            persistProfileID: profile.id,
            leadToFinalise: nil
        )
    }

    /// Shared inner pipeline driver. Sets up the live-activity subscription,
    /// runs the pipeline, populates `currentResult`, and routes post-pipeline
    /// persistence based on the caller. Profile callers pass `persistProfileID`
    /// so evidence rows, child leads, and the run-record land under that
    /// profile. Lead callers pass `leadToFinalise` so the lead's status flips
    /// to `.investigated` on completion; evidence persistence is skipped
    /// because there's no profile to attach it to until the lead is promoted.
    private func runPipeline(
        subject: ResearchSubject,
        snapshot: FamilyGraphSnapshot,
        registry: SourceRegistry,
        persistProfileID: String?,
        leadToFinalise: Lead?
    ) async {
        isResearching = true
        wasCancelled = false
        currentResult = nil
        clusterDecisions = [:]
        proposedRelativeDecisions = [:]
        recordDecisions = [:]
        recentActivity = []
        inFlightQueryCounts = [:]
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

        let sourceInfoMap = registry.buildSourceInfoMap()

        // Show source eligibility
        sourceStatuses = registry.allSources().map { source in
            SourceStatus(
                id: source.sourceID,
                displayName: source.displayName,
                state: registry.isEnabled(source.sourceID) ? .pending : .skipped,
                resultCount: 0,
                reason: registry.isEnabled(source.sourceID) ? nil : "disabled"
            )
        }

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

        updateSourceStatuses(from: result)
        logger.info("Research complete: \(result.clusters.count) clusters, \(result.confirmedFacts.count) facts, \(result.leads.count) leads")

        // Persistence is profile-keyed: evidence rows + child leads +
        // run-record all need a profileID. Lead-investigation runs skip
        // these blocks and instead update the lead's own status below.
        if let profileID = persistProfileID, let db = appDatabase {
            var saved = 0
            for scored in result.allScoredRecords {
                let citation = CitationRenderer.cite(scored.record)
                do {
                    try db.saveEvidence(
                        profileID: profileID,
                        scored: scored,
                        citationFull: citation.full,
                        citationURL: citation.url
                    )
                    saved += 1
                } catch {
                    logger.warning("Failed to save evidence for \(scored.record.id): \(error.localizedDescription)")
                }
            }
            logger.info("Persisted \(saved)/\(result.allScoredRecords.count) evidence records for \(subject.displayName)")

            let leadStore = LeadStore(db: db)
            for scored in result.leads {
                _ = try? await leadStore.createFromScoredRecord(scored, profileID: profileID)
            }
            for member in result.householdMembers {
                let censusYear = result.allScoredRecords
                    .compactMap { r -> Int? in
                        if case .census(let c) = r.record { return c.censusYear }
                        return nil
                    }.first ?? 1861
                _ = try? await leadStore.createFromHouseholdMember(member, profileID: profileID, censusYear: censusYear)
            }

            let searchedSources = Set(result.allScoredRecords.map(\.record.sourceID))
            let gps = GPSScorer.score(
                result: result,
                sourceInfoMap: sourceInfoMap,
                searchedSourceCount: searchedSources.count,
                totalSourceCount: registry.allSources().count
            )
            try? db.saveResearchRun(
                id: UUID(),
                profileID: profileID,
                mode: selectedMode,
                startedAt: Date(),
                completedAt: Date(),
                factCount: result.confirmedFacts.count,
                leadCount: result.leads.count,
                clusterCount: result.clusters.count,
                gpsScore: gps.score
            )
        }

        // Lead path: flip status to .investigated so the Leads tab reflects
        // that this lead has been searched. Evidence stays in memory on the
        // VM (visible in Triage) until the user promotes the lead.
        if let lead = leadToFinalise, let db = appDatabase {
            let updated = Lead(
                id: lead.id, profileID: lead.profileID,
                name: lead.name, surname: lead.surname, givenName: lead.givenName,
                birthYear: lead.birthYear, deathYear: lead.deathYear,
                relationship: lead.relationship, source: lead.source,
                status: .investigated, evidence: lead.evidence,
                createdAt: lead.createdAt,
                investigatedAt: Date(),
                resolvedAt: lead.resolvedAt, resolution: lead.resolution
            )
            try? db.saveLead(updated)
            selectedLead = updated
        }
    }

    /// Stop a running research pipeline mid-flight. Cancels the outer task —
    /// Swift structured concurrency propagates the signal to in-flight URLSession
    /// requests and any cancellation-aware sub-tasks. Sources that have already
    /// returned keep their results visible; in-flight sources flip to a
    /// `cancelled` reason on their status card.
    func cancelResearch() {
        guard isResearching else { return }
        wasCancelled = true
        currentResearchTask?.cancel()
        activitySubscription?.cancel()
        activitySubscription = nil
        isResearching = false
        progressMessage = "Cancelled"
        // Any source still showing `.searching` won't get a completion event —
        // mark them cancelled so the UI stops spinning.
        for index in sourceStatuses.indices where sourceStatuses[index].state == .searching {
            sourceStatuses[index].state = .skipped
            sourceStatuses[index].reason = "cancelled"
        }
    }

    /// Translate an activity event into UI state — per-source spinner + activity feed.
    /// Source status flips to `.searching` on start, back to a result-count display
    /// on completion, and to `.error` on failure. Internal (not private) so tests
    /// can drive activity-event sequences without subscribing to the bus.
    func applyActivityEvent(_ event: ResearchActivityEvent) {
        // Append to the rolling activity feed (cap at 30 entries — newest at top).
        recentActivity.insert(event.description, at: 0)
        if recentActivity.count > 30 { recentActivity.removeLast(recentActivity.count - 30) }

        // Update per-source status card. A source's "spinner → green-tick"
        // transition only fires when its in-flight query count drops to zero,
        // so multi-query sources (FreeBMD fanning across districts, FreeCen
        // across census years × chapman codes) stay on the spinner for the
        // full batch rather than oscillating spinner↔tick per query.
        switch event {
        case .sourceQueryStarted(let sourceID, _, _):
            inFlightQueryCounts[sourceID, default: 0] += 1
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }) {
                sourceStatuses[idx].state = .searching
                sourceStatuses[idx].reason = nil
            }
        case .sourceQueryCompleted(let sourceID, _, let count, _):
            inFlightQueryCounts[sourceID] = max((inFlightQueryCounts[sourceID] ?? 1) - 1, 0)
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }) {
                sourceStatuses[idx].resultCount += count
                // Only flip to complete when no more queries are in flight
                // AND the source hasn't already errored in this batch (error
                // is sticky — a later success shouldn't paper over an earlier
                // failure). While the count is still positive, the spinner
                // stays — THIS particular query finished, but the source as
                // a whole isn't done yet.
                let stillInFlight = (inFlightQueryCounts[sourceID] ?? 0) > 0
                if !stillInFlight && sourceStatuses[idx].state != .error {
                    sourceStatuses[idx].state = .complete
                }
            }
        case .sourceError(let sourceID, _, let reason, _):
            inFlightQueryCounts[sourceID] = max((inFlightQueryCounts[sourceID] ?? 1) - 1, 0)
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }) {
                // Errors are sticky — once a source hits an error, the
                // .error state persists even if subsequent queries succeed.
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

    /// Apply a `.confirmed` cluster to the subject's profile. Differs from
    /// `acceptCluster` ("Save as lead") by also writing each fact record's
    /// data into the matching profile fields and attaching the record as a
    /// citation source.
    ///
    /// Overwrite rule: never replace an existing field value (see memory
    /// `feedback_check_before_overwrite.md` — BMD year-only data is often
    /// less precise than what the user entered manually). When the column is
    /// already populated, the record is recorded via `recordAlternativeFact`
    /// so the citation lands in `field_sources` while the column value stays.
    func applyCluster(_ cluster: LifeCluster, into appState: AppState) {
        clusterDecisions[cluster.id] = .accepted
        guard let db = appState.currentDatabase, let profile = selectedProfile else { return }
        let ids = cluster.records.map(\.record.id)
        try? db.updateEvidenceUserStatus(profileID: profile.id, sourceRecordIDs: ids, status: .savedAsLead)

        for scored in cluster.records {
            // Per-record overrides win over gate predicate.
            //  • Explicitly accepted → force apply
            //  • Explicitly rejected → skip
            //  • Otherwise            → fall back to `wouldApply` gate
            switch recordDecisions[scored.id] {
            case .accepted:
                break                              // force apply below
            case .rejected:
                continue                           // user said no
            default:
                guard Self.wouldApply(scored) else { continue }
            }

            applyFactToSubject(scored, profile: profile, snapshot: appState.snapshot, db: db)
            // Non-BMD records (census/burial/probate/parish) still get a LifeEvent
            // — same path acceptCluster takes. BMD records return nil here.
            if let event = scored.record.projectToLifeEvent(profileID: profile.id) {
                _ = try? db.addLifeEventIfAbsent(event)
            }
        }

        appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
    }

    // MARK: - Per-record overrides (Task #35)

    /// Force-apply a single record from a cluster — bypasses the
    /// `wouldApply` gate so a manually-verified lead can still land. Writes
    /// the record's data to the profile (overwrite-safe, fills nil fields
    /// only), creates a LifeEvent where applicable, and marks the record's
    /// `user_status = savedAsLead`. Records the decision so cluster-level
    /// Apply honours the override too.
    func applyRecord(_ scored: ScoredRecord, into appState: AppState) {
        recordDecisions[scored.id] = .accepted
        guard let db = appState.currentDatabase, let profile = selectedProfile else { return }
        try? db.updateEvidenceUserStatus(
            profileID: profile.id,
            sourceRecordIDs: [scored.record.id],
            status: .savedAsLead
        )
        applyFactToSubject(scored, profile: profile, snapshot: appState.snapshot, db: db)
        if let event = scored.record.projectToLifeEvent(profileID: profile.id) {
            _ = try? db.addLifeEventIfAbsent(event)
        }
        appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
    }

    /// Discard a single record from a cluster — marks `user_status = discarded`
    /// and persists a rejection. Subsequent research runs won't re-surface it.
    /// Cluster-level Apply skips this record even if `wouldApply` would
    /// otherwise pick it up.
    func discardRecord(_ scored: ScoredRecord) {
        recordDecisions[scored.id] = .rejected
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        try? db.updateEvidenceUserStatus(
            profileID: profileID,
            sourceRecordIDs: [scored.record.id],
            status: .discarded
        )
        try? db.saveRejection(profileID: profileID, recordID: scored.record.id)
    }

    /// Clear a per-record decision so it falls back to the cluster's
    /// `wouldApply` gate behaviour and stops appearing as overridden.
    func resetRecordDecision(_ scored: ScoredRecord) {
        recordDecisions.removeValue(forKey: scored.id)
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        try? db.updateEvidenceUserStatus(
            profileID: profileID,
            sourceRecordIDs: [scored.record.id],
            status: .unreviewed
        )
    }

    /// True when the record is a marriage AND the scorer's `familyContext`
    /// gate passed because the record's spouse matches the subject's known
    /// spouse. Used to bypass the `verdict == .fact` filter in `applyCluster`
    /// for the subject-marriage-to-existing-spouse-edge case where FreeBMD
    /// transcription gaps demote an otherwise-correct match to `.lead`.
    nonisolated static func recognisesKnownSpouse(_ scored: ScoredRecord) -> Bool {
        guard case .marriage = scored.record else { return false }
        return scored.gates.contains { $0.gate == .familyContext && $0.outcome == .pass }
    }

    /// Single source of truth for "would `applyCluster` write this record?".
    /// Cluster review reads this to surface a per-record badge and to count
    /// the Apply button label. Mirrors exactly the predicate inside
    /// `applyCluster`'s loop — if you change one, change both.
    nonisolated static func wouldApply(_ scored: ScoredRecord) -> Bool {
        scored.verdict == .fact || recognisesKnownSpouse(scored)
    }

    private func applyFactToSubject(_ scored: ScoredRecord, profile: Profile, snapshot: FamilyGraphSnapshot, db: ProjectDatabase) {
        let origin = SourceOrigin(identifier: scored.record.sourceID)
        switch scored.record {
        case .birth(let r):
            let dateCandidate = Self.bmdDate(year: r.birthYear, quarter: r.quarter, exact: r.birthDate)
            applyDateField(.birthDate, existing: profile.birthDate, candidate: dateCandidate, profileID: profile.id, origin: origin, db: db)
            applyStringField(.birthLocation, existing: profile.birthLocation, candidate: r.birthPlace ?? r.district, profileID: profile.id, origin: origin, db: db)
        case .death(let r):
            let dateCandidate = Self.bmdDate(year: r.deathYear, quarter: r.quarter, exact: r.deathDate)
            applyDateField(.deathDate, existing: profile.deathDate, candidate: dateCandidate, profileID: profile.id, origin: origin, db: db)
            applyStringField(.deathLocation, existing: profile.deathLocation, candidate: r.deathPlace ?? r.district, profileID: profile.id, origin: origin, db: db)
        case .marriage(let m):
            applyMarriageToSubjectSpouseEdge(m, profileID: profile.id, snapshot: snapshot, db: db)
        case .pedigree, .census, .burial, .military, .probate, .parish:
            // Non-BMD types fall through to the LifeEvent projection path in applyCluster.
            break
        }
    }

    /// Apply a subject-side marriage record to the spouse edge between this
    /// subject and the matching spouse profile. Match is by surname (the
    /// `Spouse` field in BMD post-1912 marriage rows carries the spouse's
    /// surname). Marriage data is written only into nil columns via
    /// `fillRelationshipMarriage` — existing values the user typed manually
    /// are never overwritten (`Check Before Overwrite` rule).
    private func applyMarriageToSubjectSpouseEdge(
        _ m: MarriageRecord,
        profileID: String,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) {
        guard let recordSpouseRaw = m.spouseName?.trimmingCharacters(in: .whitespaces),
              !recordSpouseRaw.isEmpty else { return }
        // BMD spouse field is normally just a surname (post-1912 marriages).
        // Defensive split: pick the trailing token in case it's "GIVEN SURNAME".
        let recordSpouseSurname = (recordSpouseRaw.split(separator: " ").last.map(String.init)
            ?? recordSpouseRaw).uppercased()

        let spouseEdges = snapshot.relationships.filter { rel in
            rel.type == .spouse && (rel.from == profileID || rel.to == profileID)
        }
        let matched = spouseEdges.first { rel in
            let otherID = rel.from == profileID ? rel.to : rel.from
            guard let other = snapshot.profiles[otherID] else { return false }
            return (other.lastName ?? "").uppercased() == recordSpouseSurname
        }
        guard let edge = matched else { return }

        let dateCandidate = Self.bmdDate(year: m.marriageYear, quarter: m.quarter, exact: m.marriageDate)
        let locationCandidate = m.marriagePlace ?? m.district
        _ = try? db.fillRelationshipMarriage(
            relationshipID: edge.id,
            candidateDate: dateCandidate,
            candidateLocation: locationCandidate
        )
    }

    private func applyDateField(
        _ field: ProfileField,
        existing: GenealogicalDate?,
        candidate: GenealogicalDate?,
        profileID: String,
        origin: SourceOrigin,
        db: ProjectDatabase
    ) {
        guard let candidate else { return }
        if existing == nil {
            _ = try? db.editProfile(profileID: profileID, changes: [], dateChanges: [(field, nil, candidate)], source: origin)
        } else {
            _ = try? db.recordAlternativeFact(profileID: profileID, field: field, rawValue: candidate.original, source: origin)
        }
    }

    private func applyStringField(
        _ field: ProfileField,
        existing: String?,
        candidate: String?,
        profileID: String,
        origin: SourceOrigin,
        db: ProjectDatabase
    ) {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return }
        if (existing ?? "").isEmpty {
            _ = try? db.editProfile(profileID: profileID, changes: [(field, nil, trimmed)], dateChanges: [], source: origin)
        } else {
            _ = try? db.recordAlternativeFact(profileID: profileID, field: field, rawValue: trimmed, source: origin)
        }
    }

    /// Build a `GenealogicalDate` from a BMD record's year + quarter. BMD
    /// quarters are labelled by the END month ("Mar quarter" = Jan–Mar);
    /// year-granularity storage means we keep that nuance in the original
    /// string ("Mar 1976") rather than in earliest/latest.
    private static func bmdDate(year: Int?, quarter: String?, exact: String?) -> GenealogicalDate? {
        if let exact = exact?.trimmingCharacters(in: .whitespaces), !exact.isEmpty {
            return GenealogicalDate(parsing: exact)
        }
        guard let year else { return nil }
        if let q = quarter?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            return GenealogicalDate(parsing: "\(q) \(year)")
        }
        return GenealogicalDate(parsing: String(year))
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
        do {
            _ = try db.acceptProposedRelative(proposal)
            appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
            proposedRelativeDecisions[proposal.id] = .accepted
        } catch {
            errorMessage = "Failed to create relative: \(error.localizedDescription)"
        }
    }

    /// Apply enrichment data from an already-linked proposed relative onto
    /// the linked parent (and the parent-pair spouse edge). Mirrors the
    /// cluster `applyCluster` flow: fill missing values, attach citations,
    /// never overwrite. Use cases:
    ///   - Marriage enrichment populated `proposedGivenName` but the user's
    ///     linked parent had no first name → write the given name.
    ///   - Cross-validating marriage record in `proposal.evidence[1...]`
    ///     → fill marriage_date / marriage_location on the spouse edge
    ///       between this parent and the other linked parent of the subject.
    /// Returns the number of fields actually written so the UI can surface
    /// a "nothing to apply" toast when everything is already populated.
    @discardableResult
    func applyProposedRelative(_ proposal: ProposedRelative, into appState: AppState) -> Int {
        guard case .parentOf(let subjectID) = proposal.relationship,
              let db = appState.currentDatabase else { return 0 }
        let parents = appState.snapshot.parentsOf(subjectID)
        guard let parent = parents.first(where: { p in
            p.gender == proposal.gender &&
            (p.lastName ?? "").caseInsensitiveCompare(proposal.proposedSurname ?? "") == .orderedSame
        }) else { return 0 }

        var written = 0

        // Given name: only fill if the linked parent has nothing today.
        if (parent.firstName ?? "").isEmpty,
           let given = proposal.proposedGivenName?.trimmingCharacters(in: .whitespaces),
           !given.isEmpty {
            let origin = SourceOrigin(identifier: proposal.evidence.first?.record.sourceID ?? "freebmd")
            _ = try? db.editProfile(
                profileID: parent.id,
                changes: [(.firstName, nil, given.capitalized)],
                dateChanges: [],
                source: origin
            )
            written += 1
        }

        // Cross-validating records (evidence after the originating birth).
        // Today only marriage enrichment produces these; future enrichment
        // types fall through and are recorded as citation-only via the
        // existing recordAlternativeFact path.
        let otherParent = parents.first { $0.id != parent.id }
        for scored in proposal.evidence.dropFirst() {
            switch scored.record {
            case .marriage(let m):
                guard let otherParent else { break }
                let edge = appState.snapshot.relationships.first { rel in
                    rel.type == .spouse &&
                    ((rel.from == parent.id && rel.to == otherParent.id) ||
                     (rel.from == otherParent.id && rel.to == parent.id))
                }
                guard let edge else { break }
                let dateCandidate = Self.bmdDate(year: m.marriageYear, quarter: m.quarter, exact: m.marriageDate)
                let locationCandidate = m.marriagePlace ?? m.district
                _ = try? db.fillRelationshipMarriage(
                    relationshipID: edge.id,
                    candidateDate: dateCandidate,
                    candidateLocation: locationCandidate
                )
                written += 1
            default:
                break
            }
        }

        if written > 0 {
            appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
            proposedRelativeDecisions[proposal.id] = .accepted
        }
        return written
    }

    /// Reject a proposed relative: persist the proposal id so it will not reappear
    /// on subsequent research runs for the same subject.
    func rejectProposedRelative(_ proposal: ProposedRelative) {
        proposedRelativeDecisions[proposal.id] = .rejected
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        try? db.saveRejection(profileID: profileID, recordID: proposal.id)
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

    /// Promote the lead currently in `selectedLead` into a ghost Profile,
    /// then persist the in-memory `currentResult` evidence under it. Closes
    /// the loop opened by `startResearch(lead:)` — without promotion, lead-
    /// investigation findings live only in memory and the Triage Apply
    /// buttons have no profile target. After promotion the ghost becomes
    /// `selectedProfile`, so the same cluster cards (no re-fetch) act on
    /// the new node like a regular profile-based research result.
    @discardableResult
    func promoteLeadToProfile(into appState: AppState) -> String? {
        guard let lead = selectedLead,
              let db = appState.currentDatabase else { return nil }

        let ghostID: String
        do {
            ghostID = try db.promoteLeadToProfile(lead)
        } catch {
            errorMessage = "Failed to promote lead: \(error.localizedDescription)"
            return nil
        }

        // Refresh snapshot so the new ghost is reachable for downstream
        // operations (apply paths look it up by ID).
        appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot

        // Persist the in-memory research result under the new profile. Same
        // shape as the profile-research path's persistence block, just
        // delayed until promotion. Lead-derived runs never write evidence
        // up-front because there's no profile to attach to.
        if let result = currentResult {
            var saved = 0
            for scored in result.allScoredRecords {
                let citation = CitationRenderer.cite(scored.record)
                do {
                    try db.saveEvidence(
                        profileID: ghostID,
                        scored: scored,
                        citationFull: citation.full,
                        citationURL: citation.url
                    )
                    saved += 1
                } catch {
                    logger.warning("Failed to save evidence post-promotion for \(scored.record.id): \(error.localizedDescription)")
                }
            }
            logger.info("Promotion persisted \(saved)/\(result.allScoredRecords.count) evidence records under \(ghostID)")

            // Run-record for the GPS scorer / research-log surfaces.
            let registrySources = result.allScoredRecords.map(\.record.sourceID)
            let gps = GPSScorer.score(
                result: result,
                sourceInfoMap: [:],
                searchedSourceCount: Set(registrySources).count,
                totalSourceCount: max(Set(registrySources).count, 1)
            )
            try? db.saveResearchRun(
                id: UUID(),
                profileID: ghostID,
                mode: selectedMode,
                startedAt: Date(),
                completedAt: Date(),
                factCount: result.confirmedFacts.count,
                leadCount: result.leads.count,
                clusterCount: result.clusters.count,
                gpsScore: gps.score
            )
        }

        // Hand subject identity over to the new ghost so Triage's apply
        // paths (which key off `selectedProfile`) now have a real target.
        selectedProfile = appState.snapshot.profiles[ghostID]
        selectedLead = nil
        return ghostID
    }

    /// Reset for a new research session.
    func reset() {
        selectedProfile = nil
        selectedLead = nil
        currentResult = nil
        clusterDecisions = [:]
        proposedRelativeDecisions = [:]
        recordDecisions = [:]
        sourceStatuses = []
        progressMessage = nil
        errorMessage = nil
        isResearching = false
    }
}
