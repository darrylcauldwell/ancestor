import Foundation
import GRDB
import os

/// Watches `research_run_requests` for queued rows and fires the pipeline
/// against each. Closes the loop for the MCP `kick_off_research` tool —
/// external callers enqueue a row via SQLite, this watcher dequeues, runs
/// the deterministic pipeline, persists the result under the requested
/// profile, and writes back `status = completed` plus the `run_id` so the
/// caller can poll `get_run_status` to completion.
///
/// **Lifecycle.** Started by `AppState.openProject(_:)` once the database
/// is open and the snapshot is built; stopped by `closeProject()` so the
/// polling Task doesn't outlive its data source. Lives on the MainActor
/// because it reads `AppState.snapshot` and writes back through the same
/// `ProjectDatabase` the UI uses.
///
/// **Firewall.** The watcher only executes pipeline runs — it never
/// applies clusters, never accepts proposed relatives, never writes facts
/// into profile fields. The same human-in-the-loop boundary the Triage UI
/// enforces applies: the run record exists, evidence is persisted under
/// the requested profile, and the human reviews findings in the app.
@MainActor
final class RunRequestWatcher {
    private let appState: AppState
    private let registry: SourceRegistry
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "RunRequestWatcher")

    /// Polling cadence. 3s is short enough that MCP callers see queued
    /// runs start within a few seconds, long enough that the watcher
    /// doesn't burn CPU when the queue is idle.
    private let pollInterval: Duration = .seconds(3)

    private var pollingTask: Task<Void, Never>?

    init(appState: AppState, registry: SourceRegistry) {
        self.appState = appState
        self.registry = registry
    }

    /// Begin polling. Cheap to call repeatedly — re-starts the loop. Safe
    /// to call before the database is fully ready; each poll re-checks.
    func start() {
        stop()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop()
        }
    }

    /// Cancel the polling Task. Any in-flight pipeline run keeps going —
    /// cancellation only stops the next dequeue. (Mid-run cancellation
    /// would risk leaving requests stuck in `running` with no watcher to
    /// flip them back; better to let the in-flight run complete and write
    /// its result.)
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func pollOnce() async {
        guard let db = appState.currentDatabase else { return }
        guard let request = dequeueOne(db: db) else { return }
        logger.info("Dispatching research_run_request \(request.id): profile=\(request.profileID ?? "nil") lead=\(request.leadID ?? "nil") mode=\(request.mode) scope=\(request.scope)")
        await execute(request: request, db: db)
    }

    /// Pull the oldest queued row and atomically flip it to `running` so a
    /// concurrent caller (or a duplicate watcher) can't pick the same row.
    /// The SQLite update returns the modified row by id; if zero rows were
    /// affected we lost the race and skip.
    private func dequeueOne(db: ProjectDatabase) -> PendingRequest? {
        let snapshot: PendingRequest? = (try? db.dbQueue.write { dbConn -> PendingRequest? in
            guard let row = try Row.fetchOne(dbConn, sql: """
                SELECT id, profile_id, lead_id, mode, scope, auto_accept
                FROM research_run_requests
                WHERE status = 'queued'
                ORDER BY created_at ASC
                LIMIT 1
                """) else { return nil }
            let id: String = row["id"]
            // Atomic claim: only one watcher wins. `db.execute` returns
            // Void in GRDB — we don't need the affected-row count here
            // because the SELECT above ensures we only target rows
            // currently `'queued'`. A lost CAS race just means another
            // watcher picked the same row; that's the rare case in single-
            // process operation and the WHERE guard makes the UPDATE a
            // no-op rather than a corruption.
            try dbConn.execute(sql: """
                UPDATE research_run_requests
                SET status = 'running', started_at = ?
                WHERE id = ? AND status = 'queued'
                """, arguments: [Date(), id])
            return PendingRequest(
                id: id,
                profileID: row["profile_id"],
                leadID: row["lead_id"],
                mode: row["mode"],
                scope: row["scope"],
                autoAccept: row["auto_accept"] ?? "none"
            )
        }) ?? nil
        return snapshot
    }

    // MARK: - Execute

    private func execute(request: PendingRequest, db: ProjectDatabase) async {
        let mode = ResearchMode(rawValue: request.mode) ?? .extend
        let scope = ResearchScope(rawValue: request.scope) ?? .county
        let homeChapmanCode = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? "DBY"

        // Resolve subject. Profile takes precedence; either-or guaranteed
        // by the MCP tool but defensively handled here.
        let subject: ResearchSubject?
        var profileIDForPersistence: String? = nil
        var leadForFinalise: Lead? = nil

        if let profileID = request.profileID, !profileID.isEmpty {
            if let profile = appState.snapshot.profiles[profileID] {
                subject = ResearchSubject.fromProfile(
                    profile,
                    snapshot: appState.snapshot,
                    mode: mode,
                    homeChapmanCode: homeChapmanCode
                )
                profileIDForPersistence = profileID
            } else {
                markFailed(request.id, error: "profile \(profileID) not found in snapshot", db: db)
                return
            }
        } else if let leadID = request.leadID, !leadID.isEmpty {
            guard let lead = loadLead(id: leadID, db: db) else {
                markFailed(request.id, error: "lead \(leadID) not found", db: db)
                return
            }
            subject = ResearchSubject.fromLead(
                lead, mode: mode, homeChapmanCode: homeChapmanCode
            )
            leadForFinalise = lead
        } else {
            markFailed(request.id, error: "request has neither profile_id nor lead_id", db: db)
            return
        }

        guard let subject else {
            markFailed(request.id, error: "subject construction failed", db: db)
            return
        }

        let sourceInfoMap = registry.buildSourceInfoMap()
        let config = ResearchConfig.preset(for: mode).with(scope: scope)
        let dispatcher = SearchDispatcher(
            registry: registry,
            regionConfig: RegionConfig.derbyshire
        )
        let pipeline = ResearchPipeline(
            dispatcher: dispatcher,
            snapshot: appState.snapshot,
            sourceInfoMap: sourceInfoMap
        )

        // Diagnostic dispatch log — subscribe to the activity bus
        // before the pipeline starts, collect every per-source query
        // event, and surface them into the eval envelope's
        // `_dispatch_log` so a parity-disagreement investigation can
        // tell whether a search ever fired vs. fired and returned
        // nothing vs. fired and returned records that failed gates.
        // Bounded by `dispatchLogCap` to keep result_json size sane.
        let collector = DispatchLogCollector(cap: 500)
        let busStream = await ResearchActivityBus.shared.subscribe()
        let collectorTask = Task {
            for await event in busStream {
                await collector.record(event)
            }
        }

        let result = await pipeline.research(subject: subject, config: config)
        collectorTask.cancel()
        let dispatchLog = await collector.entries

        // Build a lead filter from the subject profile (when present)
        // so the persistence step can reject obviously-wrong
        // namesakes — alive-but-probate-record, far-off birth year,
        // etc. The filter is `nil` for lead-investigation runs (no
        // profile yet exists to filter against).
        let leadFilter: LeadFilter? = profileIDForPersistence
            .flatMap { appState.snapshot.profiles[$0] }
            .map(LeadFilter.deriving(from:))
        let runID = await persistResult(
            result: result,
            mode: mode,
            sourceInfoMap: sourceInfoMap,
            profileID: profileIDForPersistence,
            leadToFinalise: leadForFinalise,
            leadFilter: leadFilter,
            dispatchLog: dispatchLog,
            db: db
        )

        // Auto-accept of strongly-supported proposed relatives. Physically
        // absent from release builds via `#if AUTOMATION_AUTO_ACCEPT` — the
        // gating is a build flag, not a runtime check, so a release binary
        // is incapable of skipping human review even if the request row
        // carries auto_accept='confirmed'.
        //
        // Gate (tightened): a proposal auto-promotes only when at least
        // one cluster containing its evidence has hypothesis verdict
        // `.stronglySupported` AND the proposal has a resolved given name
        // (marriage enrichment narrowed the identity). Wide-window /
        // weakly-corroborated proposals stay manual until the
        // hypothesis-guided second pass adds corroborating records.
        #if AUTOMATION_AUTO_ACCEPT
        if request.autoAccept == "confirmed" {
            // Subject-identity precondition. Closes the Colin-Holmes failure
            // mode: when the subject has multiple plausible birth records and
            // no district anchor, the scorer treats several as facts and
            // downstream inference silently picks one. The resolver demands a
            // geographic hypothesis (own marriage location, children's birth
            // locations, etc.) uniquely identify ONE candidate birth before
            // any proposal is auto-promoted from this run.
            let identity = resolveSubjectIdentity(
                subject: subject,
                result: result,
                snapshot: appState.snapshot
            )
            if !identity.isResolved {
                logger.info("Auto-accept skipped: subject identity not resolved (\(String(describing: identity))) for request \(request.id)")
            } else {
                // T12-parent Phase 4: `result.proposedRelatives` was
                // deleted; project supported `.parentInferred` rows on
                // demand. Same shape as `ResearchViewModel.visibleProposedRelatives`.
                let projectedProposals: [ProposedRelative] = result.hypotheses
                    .filter { h in
                        guard case .parentInferred = h.kind else { return false }
                        return h.isDeterministicallySupported
                    }
                    .compactMap { h in
                        ResearchPipeline.projectParentInferredToProposal(
                            hypothesis: h,
                            allHypotheses: result.hypotheses,
                            scoredRecords: result.allScoredRecords,
                            subject: subject
                        )
                    }
                let promoted = autoAcceptStronglySupportedProposals(
                    proposals: projectedProposals,
                    clusters: result.clusters,
                    sourceInfoMap: sourceInfoMap,
                    db: db
                )
                if promoted > 0 {
                    logger.info("Auto-accept: promoted \(promoted) strongly-supported proposed relatives for request \(request.id)")
                    // Refresh snapshot so subsequent runs in the same recursion
                    // see the new ghost profiles + parent edges.
                    appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
                }
            }
        }
        #endif

        markCompleted(request.id, runID: runID, db: db)
        logger.info("Completed request \(request.id) → run \(runID ?? "<nil>")")
    }

    #if AUTOMATION_AUTO_ACCEPT
    /// Promote proposed relatives that have been *uniquely identified* by
    /// the deterministic pipeline — i.e. marriage enrichment has resolved
    /// the given name (the parent surname pair appears at a single BMD
    /// reference tuple, narrowing the identity) AND the originating birth
    /// record passed all four scoring gates.
    ///
    /// **Why not gate on cluster `.stronglySupported`?** That verdict
    /// requires multiple independent source lineages. FreeCen only covers
    /// 1841-1911 so for any ancestor born after 1911 there *is* no second
    /// lineage available — FreeBMD is the only structured source and the
    /// gate would never fire, blocking auto-promote for the 4 generations
    /// closest to a modern subject. The narrower signal we trust at scale
    /// is **identity uniqueness via marriage enrichment**: when the surname
    /// pair appears at exactly one (year, district, vol, page) tuple, that
    /// reference is itself near-independent confirmation. Cluster hypothesis
    /// verdicts stay as the surfacing signal in Triage; auto-promote uses
    /// this tighter proposal-level gate.
    private func autoAcceptStronglySupportedProposals(
        proposals: [ProposedRelative],
        clusters: [LifeCluster],
        sourceInfoMap: [String: SourceInfo],
        db: ProjectDatabase
    ) -> Int {
        _ = clusters         // Retained in signature so future second-pass
        _ = sourceInfoMap    // verdicts can re-introduce cluster-level gating.
        var promoted = 0
        for proposal in proposals {
            // Identity must be narrowed — given name resolved via marriage
            // enrichment. "Mother HOLMES" with no given name stays manual.
            guard let given = proposal.proposedGivenName, !given.isEmpty else { continue }
            // At least one record in the proposal's evidence must have
            // passed all four scoring gates. With marriage enrichment
            // matched, the proposal's evidence holds both the originating
            // birth record (subject's .fact) AND the cross-validating
            // marriage record. Either being .fact is sufficient given the
            // identity narrowing above.
            let hasFact = proposal.evidence.contains { $0.verdict == .fact }
            guard hasFact else { continue }
            // Skip if a parent with this surname + gender is already linked —
            // mirrors the "Already linked" UI suppression in cluster review.
            if case .parentOf(let subjectID) = proposal.relationship {
                let already = appState.snapshot.parentsOf(subjectID).contains { p in
                    p.gender == proposal.gender &&
                    (p.lastName ?? "").caseInsensitiveCompare(proposal.proposedSurname ?? "") == .orderedSame
                }
                if already { continue }
            }
            _ = try? db.acceptProposedRelative(proposal)
            promoted += 1
        }
        return promoted
    }

    /// Generates geographic hypotheses for the subject from family-graph
    /// signals and runs the identity resolver against this run's birth-fact
    /// records. Returns `.resolved` only when exactly one candidate birth
    /// passes the geographic filter; ambiguous or unresolved outcomes block
    /// auto-promote. Pure-ish — no DB writes, just a read of in-memory state.
    private func resolveSubjectIdentity(
        subject: ResearchSubject,
        result: ResearchResult,
        snapshot: FamilyGraphSnapshot
    ) -> SubjectIdentityResolution {
        guard let subjectID = subject.profileID else {
            return .unresolved(reason: "subject has no profileID")
        }
        let births = result.allScoredRecords.filter { scored in
            if case .birth = scored.record, scored.verdict == .fact { return true }
            return false
        }
        let hypotheses = GeographicHypothesisGenerator.inferDistricts(
            for: subjectID,
            snapshot: snapshot,
            eventYear: subject.birthYearFrom
        )
        return SubjectIdentityResolver.resolve(
            candidateBirthFacts: births,
            hypotheses: hypotheses
        )
    }
    #endif

    /// Mirror of `ResearchViewModel.runPipeline(...)`'s persistence block
    /// — kept here as a standalone path so the watcher doesn't depend on
    /// the UI view-model. Returns the new research_runs id when persistence
    /// runs (profile-keyed), nil for pure lead investigations.
    private func persistResult(
        result: ResearchResult,
        mode: ResearchMode,
        sourceInfoMap: [String: SourceInfo],
        profileID: String?,
        leadToFinalise: Lead?,
        leadFilter: LeadFilter?,
        dispatchLog: [DispatchLogCollector.Entry] = [],
        db: ProjectDatabase
    ) async -> String? {
        var savedRunID: UUID? = nil
        if let profileID {
            for scored in result.allScoredRecords {
                let citation = CitationRenderer.cite(scored.record)
                _ = try? db.saveEvidence(
                    profileID: profileID,
                    scored: scored,
                    citationFull: citation.full,
                    citationURL: citation.url
                )
            }
            // Spawn child leads from this run's scored leads + household
            // members, same as the UI path.
            let leadStore = LeadStore(db: db)
            Task.detached(priority: .utility) { [result, leadFilter] in
                for scored in result.leads {
                    // Filter obviously-wrong namesakes before they
                    // ever enter the leads table. See LeadFilter
                    // for the alive-vs-dead + precise-birth-year
                    // rules.
                    if let filter = leadFilter, !filter.accepts(scored) {
                        continue
                    }
                    _ = try? await leadStore.createFromScoredRecord(scored, profileID: profileID)
                }
                for member in result.householdMembers {
                    let censusYear = result.allScoredRecords
                        .compactMap { r -> Int? in
                            if case .census(let c) = r.record { return c.censusYear }
                            return nil
                        }.first ?? 1861
                    _ = try? await leadStore.createFromHouseholdMember(
                        member, profileID: profileID, censusYear: censusYear
                    )
                }
            }

            let runID = UUID()
            let searchedSources = Set(result.allScoredRecords.map(\.record.sourceID))
            let gps = GPSScorer.score(
                result: result,
                sourceInfoMap: sourceInfoMap,
                searchedSourceCount: searchedSources.count,
                totalSourceCount: registry.allSources().count
            )
            // Capture per-source throttle state at completion time so
            // the eval envelope can mark throttled-source runs distinct
            // from drift-source runs. A FreeBMD circuit-breaker trip
            // produces a "completed but empty" result that looks
            // identical to "we genuinely found nothing" without this.
            var throttledSources: [String] = []
            for src in registry.allSources() {
                if await src.isThrottled() {
                    throttledSources.append(src.sourceID)
                }
            }
            let resultJSON = Self.buildResultEnvelope(
                result: result,
                throttledSources: throttledSources,
                dispatchLog: dispatchLog
            )
            // Only claim `savedRunID = runID` when saveResearchRun
            // actually succeeded. Previously the `try?` swallowed
            // SQLite lock errors silently; the caller (markCompleted)
            // would then write that run_id into research_run_requests
            // even though no matching research_runs row existed. The
            // MCP get_research_result tool then 404'd on a run_id it
            // couldn't find — the harness saw `run_not_found` and
            // exploded. Surface the error and leave savedRunID nil
            // when the write failed so downstream stays consistent.
            do {
                try db.saveResearchRun(
                    id: runID,
                    profileID: profileID,
                    mode: mode,
                    startedAt: Date(),
                    completedAt: Date(),
                    factCount: result.confirmedFacts.count,
                    leadCount: result.leads.count,
                    clusterCount: result.clusters.count,
                    gpsScore: gps.score,
                    resultJSON: resultJSON
                )
                savedRunID = runID
            } catch {
                logger.error("saveResearchRun failed for profile \(profileID): \(error.localizedDescription)")
                // savedRunID stays nil — markCompleted will write a
                // completed status without a run_id, which the harness
                // treats as a pipeline failure rather than a phantom
                // success.
            }
        }
        if let lead = leadToFinalise {
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
        }
        return savedRunID?.uuidString
    }

    /// Serialize the §3 eval envelope into a JSON string for the
    /// `research_runs.result_json` column (SWIFT_MCP_EVAL_BACKEND_SPEC
    /// #Change3). Carries the three per-run verdicts plus the
    /// hypothesis / citation arrays the harness derives per-kind
    /// metrics from. Shape mirrors Python's `_state_to_envelope` in
    /// `eval/run_harness.py:197` so the §5.8 harness consumes either
    /// backend without branching.
    /// Envelope "kind" tag for a SourceRecord — finer-grained than
    /// `recordType`. `SourceRecord.recordType` collapses `.military`
    /// → `.death` for scoring purposes (the scorer's date and family
    /// gates treat military casualty records as death records). But
    /// the harness's per-kind metric distinguishes
    /// `military_service` (CWGC / war-grave evidence) from
    /// `death_disambiguation` (civil-registration death), and the
    /// Python pipeline emits `kind: "military"` for CWGC matches.
    /// Mirror that here so a CWGC-confirmed casualty satisfies both
    /// kinds — `_KIND_FACT_TYPES["military_service"]` is
    /// `{military, war_grave, cwgc}` and
    /// `_KIND_FACT_TYPES["death_disambiguation"]` already accepts
    /// `military` too.
    private static func envelopeKind(for record: SourceRecord) -> String {
        if case .military = record { return "military" }
        return record.recordType.rawValue
    }

    private static func buildResultEnvelope(
        result: ResearchResult,
        throttledSources: [String] = [],
        dispatchLog: [DispatchLogCollector.Entry] = []
    ) -> String {
        var supported: [[String: Any]] = []
        var citations: [String] = []
        for scored in result.confirmedFacts {
            let citation = CitationRenderer.cite(scored.record)
            let sourceStrings: [String] = {
                if let url = citation.url, !url.isEmpty {
                    return ["\(citation.sourceID): \(scored.summary) [\(url)]"]
                }
                return ["\(citation.sourceID): \(scored.summary)"]
            }()
            supported.append([
                "kind": envelopeKind(for: scored.record),
                "value": scored.summary,
                "sources": sourceStrings,
                "confidence": "confirmed",
            ])
            citations.append(contentsOf: sourceStrings)
        }

        // Contradicted = records the scorer ruled out via hard fails
        // (impossible verdict). Python's "rejected_records" carries a
        // record-summary + reason; Swift's gate machinery records
        // per-gate outcomes, so collapse the failed gates into one
        // reason string.
        let contradicted: [[String: Any]] = result.allScoredRecords
            .filter { $0.verdict == .impossible }
            .map { scored in
                let failed = scored.gates
                    .filter { $0.outcome == .fail || $0.outcome == .impossible }
                    .map { "\($0.gate.rawValue): \($0.reason)" }
                    .joined(separator: "; ")
                return [
                    "value": scored.summary,
                    "reason": failed.isEmpty ? "gate failure" : failed,
                ]
            }

        // Inconclusive = leads (records that scored as candidates but
        // didn't clear every gate). Python carries the gate reasons as
        // a list; mirror that.
        let inconclusive: [[String: Any]] = result.leads.map { scored in
            let reasons = scored.gates
                .filter { $0.outcome != .pass && $0.outcome != .skip }
                .map { $0.reason }
            return [
                "kind": envelopeKind(for: scored.record),
                "summary": scored.summary,
                "source": envelopeKind(for: scored.record),
                "reasons": reasons,
            ]
        }

        let dispatchLogPayload: [[String: Any]] = dispatchLog.map { entry in
            var row: [String: Any] = [
                "source":  entry.sourceID,
                "summary": entry.summary,
                "kind":    entry.kind.rawValue,
            ]
            if let n = entry.resultCount { row["results"] = n }
            if let r = entry.errorReason { row["error"] = r }
            return row
        }

        let payload: [String: Any] = [
            "supported_hypotheses":    supported,
            "contradicted_hypotheses": contradicted,
            "inconclusive_hypotheses": inconclusive,
            "discovered_citations":    citations,
            "parent_link_verdict":     result.parentLinkVerdict as Any,
            "identity_verdict":        result.identityVerdict as Any,
            "spouse_verdict":          result.spouseVerdict as Any,
            "_throttled":              throttledSources,
            "_dispatch_log":           dispatchLogPayload,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ),
        let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    // MARK: - Status writeback

    private func markCompleted(_ requestID: String, runID: String?, db: ProjectDatabase) {
        try? db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE research_run_requests
                SET status = 'completed', run_id = ?, completed_at = ?
                WHERE id = ?
                """, arguments: [runID, Date(), requestID])
        }
    }

    private func markFailed(_ requestID: String, error: String, db: ProjectDatabase) {
        logger.error("Request \(requestID) failed: \(error)")
        try? db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE research_run_requests
                SET status = 'failed', error = ?, completed_at = ?
                WHERE id = ?
                """, arguments: [error, Date(), requestID])
        }
    }

    private func loadLead(id: String, db: ProjectDatabase) -> Lead? {
        try? db.dbQueue.read { dbConn in
            guard let row = try Row.fetchOne(dbConn, sql: """
                SELECT id, profile_id, name, surname, given_name, birth_year, death_year,
                       relationship, source, status, evidence,
                       created_at, investigated_at, resolved_at, resolution
                FROM leads WHERE id = ?
                """, arguments: [id]) else { return nil }
            return Lead(
                id: row["id"],
                profileID: row["profile_id"] ?? "",
                name: row["name"] ?? "",
                surname: row["surname"],
                givenName: row["given_name"],
                birthYear: row["birth_year"],
                deathYear: row["death_year"],
                relationship: row["relationship"],
                source: LeadSource(rawValue: row["source"] ?? "") ?? .discovery,
                status: LeadStatus(rawValue: row["status"] ?? "new") ?? .new,
                evidence: row["evidence"] ?? "",
                createdAt: row["created_at"] ?? Date(),
                investigatedAt: row["investigated_at"],
                resolvedAt: row["resolved_at"],
                resolution: (row["resolution"] as String?).flatMap(LeadResolution.init(rawValue:))
            )
        }
    }
}

/// In-memory snapshot of a `research_run_requests` row picked up by the
/// watcher. Stripped to the fields needed to execute; status / timestamps
/// stay in the DB.
private struct PendingRequest {
    let id: String
    let profileID: String?
    let leadID: String?
    let mode: String
    let scope: String
    /// 'none' | 'confirmed'. When 'confirmed' AND the binary was compiled
    /// with the AUTOMATION_AUTO_ACCEPT flag, the watcher promotes
    /// .confirmed proposed relatives during the run. Release builds
    /// ignore the field entirely — the code path is `#if`-gated out.
    let autoAccept: String
}
