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
    /// User opt-in for prose extraction. Defaults to off because the
    /// phase is a ~20-minute MLX workload that produces zero hits on
    /// most cross-region subjects (Wirksworth corpus + Belper subject
    /// = nothing useful). Set by `ContentView` from `ResearchRequest`
    /// before each `startResearch` call.
    var runProseExtraction: Bool = false

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
    /// Top-K prose-corpus candidates for the current run. Populated
    /// after the structured pipeline completes (see `runPipeline`).
    /// Empty when no prose corpora are registered or when the subject
    /// has no surname. Surfaced inline beside the structured results;
    /// the activity log already shows the search itself via the
    /// `ProseCorpusSource` events. P6 adds MLX extraction over this
    /// list for `.discover`/`.all` modes.
    var proseCandidates: [ProseCandidate] = []
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

    /// Phase timestamps for the dev-build dual-clock display in
    /// `ResearchProgressView`. The iteration loop has its own latency
    /// budget (~5 min); the optional prose-extraction phase that only
    /// runs in `.discover`/`.all` is multi-minute MLX work with its
    /// own budget (~20 min). Showing both separately stops the user
    /// being misled by a single combined clock that's red because
    /// prose extraction ran, not because the iteration loop was slow.
    var iterationPhaseStart: Date?
    var iterationPhaseEnd: Date?
    var prosePhaseStart: Date?
    var prosePhaseEnd: Date?

    // Review state
    var clusterDecisions: [String: ClusterDecision] = [:]  // cluster.id → decision
    var proposedRelativeDecisions: [String: ClusterDecision] = [:]  // proposal.id → decision
    /// User decision on each sibling proposal — same accept / reject contract
    /// as proposed relatives, keyed by `SiblingProposal.id`. Persisted via the
    /// shared rejection store so rejected siblings don't reappear on re-runs.
    var siblingDecisions: [String: ClusterDecision] = [:]
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

    // MARK: - Persistence error surfacing

    /// Run a persistence operation whose failure used to be `try?`-swallowed.
    /// A failed write must never look like success (the accept-flow bug
    /// class): failures are logged and surfaced via `errorMessage`.
    /// Returns nil on failure so call sites keep their optional flow.
    @discardableResult
    private func persist<T>(_ what: String, _ op: () throws -> T) -> T? {
        do {
            return try op()
        } catch {
            logger.error("\(what) failed: \(error.localizedDescription)")
            errorMessage = "\(what) failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Async variant of `persist(_:_:)`.
    @discardableResult
    private func persist<T>(_ what: String, _ op: () async throws -> T) async -> T? {
        do {
            return try await op()
        } catch {
            logger.error("\(what) failed: \(error.localizedDescription)")
            errorMessage = "\(what) failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Surface `ApplyEngine` write failures through the same log +
    /// `errorMessage` channel as `persist(_:_:)`.
    private func report(_ failures: [ApplyEngine.WriteFailure]) {
        for f in failures {
            logger.error("\(f.what) failed: \(f.error.localizedDescription)")
            errorMessage = "\(f.what) failed: \(f.error.localizedDescription)"
        }
    }

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

    // MARK: - AI Gate

    /// Surfaced when the user kicks off research but the reasoning model
    /// isn't loaded. ContentView observes this and presents an alert with
    /// "Open Settings" / "Run Without AI" / "Cancel". Cleared by the
    /// matching action handlers.
    var aiGate: AIGate?

    struct AIGate: Identifiable {
        let id = UUID()
        /// True when the safetensors are already in the sandbox model dir
        /// — loading is the only step. False when a download is also needed.
        let modelOnDisk: Bool
        /// Display name of the user's selected reasoning model, for the
        /// alert message.
        let modelDisplayName: String
        /// Replays `startResearch` with `bypassAICheck = true` so the
        /// pipeline runs without MLX.
        let proceed: () async -> Void
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
        registry: SourceRegistry,
        bypassAICheck: Bool = false
    ) async {
        if !bypassAICheck, await shouldGateOnMissingAI(
            retry: { [weak self] in
                await self?.startResearch(
                    lead: lead, snapshot: snapshot, registry: registry,
                    bypassAICheck: true
                )
            }
        ) { return }

        selectedProfile = nil
        selectedLead = lead
        // Project-level fallback; "" when unset. fromLead has no
        // profile-derivation path (leads aren't on the tree yet) so this
        // is the only chapman source for the subject.
        let homeChapmanCode = appDatabase
            .flatMap { try? $0.loadProjectMeta() }?
            .resolvedHomeChapmanCode ?? ""
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

    /// Start research for a profile. `focus` (when set) narrows the
    /// dispatched record types to the focus's set — see
    /// RESEARCH_PIPELINE_SPEC §11.4.
    func startResearch(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        registry: SourceRegistry,
        focus: ResearchFocus? = nil,
        bypassAICheck: Bool = false
    ) async {
        if !bypassAICheck, await shouldGateOnMissingAI(
            retry: { [weak self] in
                await self?.startResearch(
                    profile: profile, snapshot: snapshot, registry: registry,
                    focus: focus, bypassAICheck: true
                )
            }
        ) { return }

        selectedProfile = profile
        selectedLead = nil
        // Project-level fallback; "" when unset. fromProfile's derivation
        // chain prefers the profile's own birthLocationCode/birthLocation
        // over this fallback, so non-DBY profiles in a project with a
        // chapman setting still get correctly anchored to their own home.
        let homeChapmanCode = appDatabase
            .flatMap { try? $0.loadProjectMeta() }?
            .resolvedHomeChapmanCode ?? ""
        let subject = ResearchSubject.fromProfile(
            profile,
            snapshot: snapshot,
            mode: selectedMode,
            focus: focus,
            homeChapmanCode: homeChapmanCode
        )
        await runPipeline(
            subject: subject,
            snapshot: snapshot,
            registry: registry,
            persistProfileID: profile.id,
            leadToFinalise: nil
        )
    }

    /// If the reasoning model isn't loaded, populate `aiGate` so the view
    /// can present a "Load model first?" alert, and return `true` to tell
    /// the caller to bail out. Otherwise returns `false`.
    ///
    /// The closure passed as `retry` re-invokes `startResearch` with
    /// `bypassAICheck = true`, which the alert's "Run Without AI" button
    /// triggers.
    private func shouldGateOnMissingAI(retry: @escaping () async -> Void) async -> Bool {
        if await LocalInferenceService.shared.isAvailable { return false }
        let raw = UserDefaults.standard.string(forKey: "reasoningModelChoice")
            ?? ReasoningModel.default.rawValue
        let model = ReasoningModel(rawValue: raw) ?? .default
        let onDisk = LocalInferenceService.shared.onDiskBytes(for: model) > 1_000_000_000
        self.aiGate = AIGate(
            modelOnDisk: onDisk,
            modelDisplayName: model.displayName,
            proceed: retry
        )
        return true
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
        siblingDecisions = [:]
        recordDecisions = [:]
        recentActivity = []
        inFlightQueryCounts = [:]
        proseCandidates = []
        errorMessage = nil
        progressMessage = "Preparing research..."
        iterationPhaseStart = Date()
        iterationPhaseEnd = nil
        prosePhaseStart = nil
        prosePhaseEnd = nil

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

        // Synthetic "sources" for MLX activity. Same status-card UX so
        // the user can watch Level-2 / prose-extractor progress instead
        // of guessing at the long quiet phases. Pre-seeded as .pending;
        // the same `sourceQueryStarted/Completed` events that drive the
        // real sources update these.
        sourceStatuses.append(SourceStatus(
            id: "mlx-strategist",
            displayName: "Level-2 Strategist (AI)",
            state: .pending, resultCount: 0, reason: nil
        ))
        if (selectedMode == .discover || selectedMode == .all || selectedMode == .adaptive), runProseExtraction {
            sourceStatuses.append(SourceStatus(
                id: "mlx-prose",
                displayName: "Prose Extraction (AI)",
                state: .pending, resultCount: 0, reason: nil
            ))
        }

        let config = ResearchConfig.preset(for: selectedMode).with(scope: selectedScope)
        progressMessage = "Searching \(subject.displayName)..."

        let pipeline = ResearchRunService.makePipeline(
            registry: registry,
            snapshot: snapshot,
            database: appDatabase,
            sourceInfoMap: sourceInfoMap
        ).pipeline

        let result = await pipeline.research(subject: subject, config: config)
        iterationPhaseEnd = Date()

        // Prose-corpus retrieval — fan out the subject across every
        // registered prose corpus and store the top-K candidates for
        // the UI. Runs after the structured pipeline so its activity
        // events land at the end of the live feed; the existing
        // `activitySubscription` is still alive, so the user sees
        // "Prose corpora Cauldwell — searching… → 5 results".
        //
        // K-per-mode mirrors spec §9.3: verify/extend keep the
        // shortlist small (no MLX cost yet), discover widens to 5
        // and `.all` to 8.
        proseCandidates = await fetchProseCandidates(subject: subject, registry: registry, mode: selectedMode)

        // Prose-corpus MLX extraction (P6, spec §11) — only fires in
        // `.discover` / `.all` modes. Reads each candidate's body
        // from disk, runs the local reasoning model, routes
        // extracted facts through `pending_facts` and narratives
        // through `narrative_findings`. Profile-keyed; lead-only
        // runs (no profileID) skip this just like they skip
        // structured evidence persistence above.
        if (selectedMode == .discover || selectedMode == .all || selectedMode == .adaptive),
           runProseExtraction,
           let profileID = persistProfileID,
           let db = appDatabase,
           !proseCandidates.isEmpty {
            prosePhaseStart = Date()
            await runProseExtraction(
                candidates: proseCandidates,
                subject: subject,
                profileID: profileID,
                registry: registry,
                db: db
            )
            prosePhaseEnd = Date()
        }

        currentResult = result
        isResearching = false
        progressMessage = nil
        activitySubscription?.cancel()
        activitySubscription = nil

        updateSourceStatuses(from: result)
        logger.info("Research complete: \(result.clusters.count) clusters, \(result.confirmedFacts.count) facts, \(result.leads.count) leads")

        // Phase 1 slice 6b: THE shared persistence path. Evidence rows +
        // hypotheses + child leads + run-record are profile-keyed; lead-
        // investigation runs skip them (evidence stays in memory on the VM,
        // visible in Triage, until the user promotes the lead) and only
        // flip the investigated lead's status.
        if let db = appDatabase {
            let outcome = await ResearchRunService.persist(
                result: result,
                mode: selectedMode,
                sourceInfoMap: sourceInfoMap,
                registry: registry,
                snapshot: snapshot,
                profileID: persistProfileID,
                leadToFinalise: leadToFinalise,
                db: db
            )
            report(outcome.failures)
            if let updated = outcome.finalisedLead {
                selectedLead = updated
            }
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
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }),
               sourceStatuses[idx].state != .error {
                // .error is sticky: a later query starting (next record
                // type / strictness tier / stage) must not wipe it.
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
        case .sourceSkipped(let sourceID, let reason):
            // Informational, not a failure — the source card shows the
            // dedicated .skipped state with the reason, distinct from
            // .error (SOURCE_WEIGHTING Change 2).
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }),
               sourceStatuses[idx].state != .error {
                sourceStatuses[idx].state = .skipped
                sourceStatuses[idx].reason = reason
            }
        case .pipelineStage:
            // Pipeline stages don't bind to a single source; only the feed shows them.
            break
        case .scorerAttrition:
            // Aggregate stat across all sources; feed-only, no per-source state change.
            break
        case .dailyBudgetExhausted(let sourceID, let resumeAt):
            // The source's daily quota is spent — surface it on the status
            // card as a paused/error state so the user sees WHY it stopped
            // producing results, distinct from a transient failure
            // (#Change5). Sticky like an error until the run ends.
            if let idx = sourceStatuses.firstIndex(where: { $0.id == sourceID }) {
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                sourceStatuses[idx].state = .error
                sourceStatuses[idx].reason = "Daily budget spent — resumes \(fmt.string(from: resumeAt))"
            }
        }
    }

    // MARK: - Prose-corpus retrieval

    /// Fan a subject out across every registered prose corpus and
    /// return the top-K candidates. Returns an empty array when no
    /// `ProseCorpusSource` is registered (e.g. Application Support
    /// was unreachable at bootstrap), when the subject has no
    /// surname (the SQL's INNER JOIN gate), or when no corpora are
    /// registered. Never throws — per-corpus errors are logged
    /// inside `ProseCorpusSource` and the rest of the dispatch
    /// continues.
    private func fetchProseCandidates(
        subject: ResearchSubject,
        registry: SourceRegistry,
        mode: ResearchMode
    ) async -> [ProseCandidate] {
        guard let proseSource = registry.source(for: "prose-corpus") as? ProseCorpusSource else {
            return []
        }
        guard registry.isEnabled("prose-corpus") else { return [] }
        guard let surname = subject.surname, !surname.isEmpty else { return [] }

        let query = Self.buildProseQuery(subject: subject, surname: surname)
        let limit = Self.proseCorpusLimit(for: mode)
        return await proseSource.searchCandidates(query: query, limit: limit)
    }

    /// K-per-mode mapping per PROSE_CORPUS_SPEC.md §9.3. Verify and
    /// extend keep the shortlist small; discover widens to 5; .all
    /// runs through 8.
    nonisolated static func proseCorpusLimit(for mode: ResearchMode) -> Int {
        switch mode {
        case .verify:   return 3
        case .extend:   return 3
        case .discover: return 5
        case .all:      return 8
        case .adaptive: return 5   // discover-grade shortlist for the one action
        }
    }

    /// Run MLX-driven prose-corpus extraction for the top-K
    /// candidates and persist the resulting facts/narratives. Failure
    /// per candidate is swallowed (logged) — the UI just shows the
    /// candidates that did produce output. Re-entrant: the
    /// `EvidenceFirewall.idempotencyKey` ensures duplicate rows
    /// across runs are silently dropped by the INSERT OR IGNORE
    /// path.
    private func runProseExtraction(
        candidates: [ProseCandidate],
        subject: ResearchSubject,
        profileID: String,
        registry: SourceRegistry,
        db: ProjectDatabase
    ) async {
        guard let proseSource = registry.source(for: "prose-corpus") as? ProseCorpusSource else {
            return
        }
        // Only attempt extraction when the local reasoning model is
        // loaded — calling reasonJSON without a loaded model returns
        // nil per LocalInferenceService, but the user benefits from
        // an honest activity-feed line instead of N quiet no-ops.
        let modelReady = await LocalInferenceService.shared.isAvailable
        guard modelReady else {
            await ResearchActivityBus.shared.publish(
                .pipelineStage(message: "Prose extraction skipped — local reasoning model not loaded.")
            )
            return
        }
        let extractor = ProseCorpusExtractor(llm: DefaultProseExtractionLLM())
        await ResearchActivityBus.shared.publish(
            .pipelineStage(message: "Extracting facts from \(candidates.count) prose page\(candidates.count == 1 ? "" : "s")…")
        )
        var savedFacts = 0
        var savedNarratives = 0
        for candidate in candidates {
            guard let page = await proseSource.loadPageBody(forCandidate: candidate) else {
                logger.warning("Prose extractor skipping missing page \(candidate.id)")
                continue
            }
            // Per-page started/completed events for the "Prose Extraction
            // (AI)" card. Each prose body is a multi-second MLX call;
            // surfacing each one keeps the spinner card honest rather
            // than masking 5-10 minutes of MLX behind one stage event.
            let pageLabel = (candidate.title ?? "").isEmpty
                ? candidate.id
                : (candidate.title ?? candidate.id)
            await ResearchActivityBus.shared.publish(
                .sourceQueryStarted(
                    sourceID: "mlx-prose",
                    summary: "Prose: \(pageLabel)"
                )
            )
            let result = await extractor.extract(
                candidate: candidate,
                body: page.body,
                subject: subject,
                profileID: profileID
            )
            for fact in result.facts {
                do { try db.savePendingFact(fact); savedFacts += 1 }
                catch { logger.warning("Failed to save prose pending fact \(fact.id): \(error.localizedDescription)") }
            }
            for narrative in result.narratives {
                do { try db.saveNarrativeFinding(narrative); savedNarratives += 1 }
                catch { logger.warning("Failed to save prose narrative \(narrative.id): \(error.localizedDescription)") }
            }
            await ResearchActivityBus.shared.publish(
                .sourceQueryCompleted(
                    sourceID: "mlx-prose",
                    summary: "Prose: \(pageLabel)",
                    resultCount: result.facts.count + result.narratives.count
                )
            )
        }
        await ResearchActivityBus.shared.publish(
            .pipelineStage(message: "Prose extraction complete — \(savedFacts) fact\(savedFacts == 1 ? "" : "s"), \(savedNarratives) narrative\(savedNarratives == 1 ? "" : "s") for review.")
        )
    }

    /// Build a single `RecordQuery` for the prose source. The prose
    /// source ignores `recordType` (its result isn't record-typed
    /// in the structured sense) and `sourceParams`; what matters is
    /// surname, given name, year range, and region. We use the
    /// widest plausible year window — birth-year floor to death-year
    /// ceiling, with a `birth + 95` fallback when the death window
    /// is unknown — so a corpus page that talks about the subject
    /// at any point in their life still scores.
    nonisolated static func buildProseQuery(subject: ResearchSubject, surname: String) -> RecordQuery {
        let yearFrom: Int? = subject.birthYearFrom
        let yearTo: Int?
        if let dt = subject.deathYearTo {
            yearTo = dt
        } else if let dt = subject.deathYearFrom {
            yearTo = dt + 2
        } else if let bt = subject.birthYearTo {
            yearTo = bt + 95
        } else if let bf = subject.birthYearFrom {
            yearTo = bf + 95
        } else {
            yearTo = nil
        }
        return RecordQuery(
            surname: surname,
            givenName: subject.givenName,
            recordType: .pedigree,
            yearFrom: yearFrom,
            yearTo: yearTo,
            gender: subject.gender,
            region: subject.region,
            sourceParams: .generic
        )
    }

    private func updateSourceStatuses(from result: ResearchResult) {
        var sourceCounts: [String: Int] = [:]
        for record in result.allScoredRecords {
            sourceCounts[record.record.sourceID, default: 0] += 1
        }
        for i in sourceStatuses.indices {
            let count = sourceCounts[sourceStatuses[i].id] ?? 0
            sourceStatuses[i].resultCount = count
            // Errors are sticky through settling too — a source that
            // failed (e.g. FamilySearch session expired) must never end
            // the run wearing a green tick with "no results" (live find:
            // Harry Marshall run, 2026-07-15).
            if sourceStatuses[i].state != .skipped && sourceStatuses[i].state != .error {
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
        let kept = recordsAfterDiscardVeto(cluster, profileID: profileID, db: db)
        let ids = kept.map(\.record.id)
        persist("Save evidence status") { try db.updateEvidenceUserStatus(profileID: profileID, sourceRecordIDs: ids, status: .savedAsLead) }
        for scored in kept {
            for event in scored.record.projectToLifeEvents(profileID: profileID) {
                persist("Save life event") { try db.addLifeEventIfAbsent(event) }
            }
        }
    }

    /// Prior-session adjudications are ground truth — `recordDecisions` is
    /// session-scoped, so a record discarded in an EARLIER session has no
    /// entry there. Both cluster-level accept paths filter through this so
    /// a discard is never resurrected (applied, projected to a LifeEvent,
    /// or flipped to saved_as_lead) by a later cluster action. An explicit
    /// accept THIS session wins — the user actively overrode the discard.
    private func recordsAfterDiscardVeto(
        _ cluster: LifeCluster, profileID: String, db: ProjectDatabase
    ) -> [ScoredRecord] {
        let priorDiscards = (try? db.loadRejections(profileID: profileID)) ?? []
        return cluster.records.filter { scored in
            switch recordDecisions[scored.id] {
            case .accepted: return true
            case .rejected: return false
            default: return !priorDiscards.contains(scored.record.id)
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
        let kept = recordsAfterDiscardVeto(cluster, profileID: profile.id, db: db)
        persist("Save evidence status") { try db.updateEvidenceUserStatus(profileID: profile.id, sourceRecordIDs: kept.map(\.record.id), status: .savedAsLead) }

        for scored in kept {
            // Per-record overrides win over gate predicate: explicitly
            // accepted → force apply; otherwise the `wouldApply` gate
            // decides. Session-rejected and prior-session-discarded
            // records were already removed by the veto above.
            if recordDecisions[scored.id] != .accepted {
                guard RecordScorer.wouldApply(scored) else { continue }
            }

            report(ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: appState.snapshot, db: db))
            // Non-BMD records (census/burial/probate/parish) still get a LifeEvent
            // — same path acceptCluster takes. BMD records return none here; a
            // census fans out into census + occupation + residence events.
            for event in scored.record.projectToLifeEvents(profileID: profile.id) {
                persist("Save life event") { try db.addLifeEventIfAbsent(event) }
            }
        }

        if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
            appState.snapshot = snap
        }
        // CONFLICT_LAYER_SPEC CL2 (T-C trigger): post-apply-batch sweep —
        // conflicts introduced by this batch surface immediately.
        appState.runConflictSweep(force: true)
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
        persist("Save evidence status") {
            try db.updateEvidenceUserStatus(
                profileID: profile.id,
                sourceRecordIDs: [scored.record.id],
                status: .savedAsLead
            )
        }
        report(ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: appState.snapshot, db: db))
        for event in scored.record.projectToLifeEvents(profileID: profile.id) {
            persist("Save life event") { try db.addLifeEventIfAbsent(event) }
        }
        if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
            appState.snapshot = snap
        }
    }

    /// Discard a single record from a cluster — marks `user_status = discarded`
    /// and persists a rejection. Subsequent research runs won't re-surface it.
    /// Cluster-level Apply skips this record even if `wouldApply` would
    /// otherwise pick it up.
    func discardRecord(_ scored: ScoredRecord) {
        recordDecisions[scored.id] = .rejected
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        persist("Save discard status") {
            try db.updateEvidenceUserStatus(
                profileID: profileID,
                sourceRecordIDs: [scored.record.id],
                status: .discarded
            )
        }
        persist("Save rejection") { try db.saveRejection(profileID: profileID, recordID: scored.record.id) }
    }

    /// Clear a per-record decision so it falls back to the cluster's
    /// `wouldApply` gate behaviour and stops appearing as overridden.
    func resetRecordDecision(_ scored: ScoredRecord) {
        recordDecisions.removeValue(forKey: scored.id)
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        persist("Reset record status") {
            try db.updateEvidenceUserStatus(
                profileID: profileID,
                sourceRecordIDs: [scored.record.id],
                status: .unreviewed
            )
        }
        // Discard writes user_status AND a record_rejections row — clear
        // both, or the restored record stays suppressed in future runs.
        persist("Clear rejection") {
            try db.deleteRejection(profileID: profileID, recordID: scored.record.id)
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
        persist("Save discard status") { try db.updateEvidenceUserStatus(profileID: profileID, sourceRecordIDs: ids, status: .discarded) }
        for record in cluster.records {
            persist("Save rejection") { try db.saveRejection(profileID: profileID, recordID: record.id) }
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
        persist("Reset record status") { try db.updateEvidenceUserStatus(profileID: profileID, sourceRecordIDs: ids, status: .unreviewed) }
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
        persist("Save evidence status") {
            try db.updateEvidenceUserStatus(
                profileID: profileID,
                sourceRecordIDs: [scored.record.id],
                status: .savedAsLead
            )
        }
        for event in scored.record.projectToLifeEvents(profileID: profileID) {
            persist("Save life event") { try db.addLifeEventIfAbsent(event) }
        }
        // Flip the observable signal so SwiftUI re-renders the row.
        overriddenRecordIDs.insert(scored.record.id)
    }

    // MARK: - Proposed Relative Decisions

    /// Filter proposals by previously-persisted rejections for the subject.
    /// Called after research completes so old rejections suppress the same proposal.
    ///
    /// **V2 spec T12-parent Phase 3**: source of truth is now
    /// `result.hypotheses` (filtered to `.parentInferred` /
    /// `isDeterministicallySupported`), projected via the pipeline's
    /// helper on demand — given names and ambiguous marriages come
    /// from the post-reconciliation hypothesis state. The legacy
    /// `result.proposedRelatives` field still exists and is still
    /// populated; Phase 4 deletes it.
    func visibleProposedRelatives(snapshot: FamilyGraphSnapshot) -> [ProposedRelative] {
        guard let result = currentResult else { return [] }
        let supportedParentHypotheses = result.hypotheses.filter { h in
            guard case .parentInferred = h.kind else { return false }
            return h.isDeterministicallySupported
        }
        let subjectForProjection: ResearchSubject? = {
            guard let profile = selectedProfile else { return nil }
            return ResearchSubject(
                profileID: profile.id,
                surname: profile.lastName,
                givenName: profile.firstName,
                middleName: profile.middleName,
                birthYearFrom: profile.birthDate?.earliest,
                birthYearTo: profile.birthDate?.latest,
                deathYearFrom: profile.deathDate?.earliest,
                deathYearTo: profile.deathDate?.latest,
                gender: profile.gender,
                region: nil,
                mode: .extend,
                familyContext: nil,
                // Projection-time subject — only used downstream by the
                // pure projector which doesn't consult chapman, so leave
                // unset rather than fabricating a Derbyshire anchor.
                homeChapmanCode: ""
            )
        }()
        guard let subject = subjectForProjection else { return [] }
        let proposals = supportedParentHypotheses.compactMap { h in
            ResearchPipeline.projectParentInferredToProposal(
                hypothesis: h,
                allHypotheses: result.hypotheses,
                scoredRecords: result.allScoredRecords,
                subject: subject
            )
        }
        _ = snapshot   // not used directly — projection is snapshot-free
        guard let db = appDatabase, let profileID = selectedProfile?.id else {
            return proposals
        }
        let rejected = Self.loadRejectionsLogged(db: db, profileID: profileID, logger: logger)
        return proposals.filter { !rejected.contains($0.id) }
    }

    /// Read-path helper: rejection loads can run during view rendering,
    /// so failures log (no `errorMessage` mutation mid-render) and fall
    /// back to unfiltered — previously-rejected items resurfacing is
    /// visible, not silent data loss.
    nonisolated private static func loadRejectionsLogged(
        db: ProjectDatabase, profileID: String, logger: Logger
    ) -> Set<String> {
        do {
            return try db.loadRejections(profileID: profileID)
        } catch {
            logger.error("Load rejections failed — proposals shown unfiltered: \(error.localizedDescription)")
            return []
        }
    }

    /// Accept a proposed relative: create a ghost Profile + parent-of
    /// Relationship in one atomic transaction. When the proposal matches
    /// an existing profile (per `ProposalDedup`), link the existing
    /// profile to the subject instead of creating a duplicate ghost —
    /// re-running research and re-accepting the same proposal is now
    /// a no-op rather than a duplicate-creator.
    func acceptProposedRelative(_ proposal: ProposedRelative, into appState: AppState) {
        guard let db = appState.currentDatabase else {
            errorMessage = "No project open"
            return
        }
        guard case .parentOf(let subjectID) = proposal.relationship else {
            errorMessage = "Unsupported proposal relationship"
            return
        }
        do {
            var failures: [ApplyEngine.WriteFailure] = []
            _ = try ApplyEngine.acceptParentProposal(
                proposal,
                subjectID: subjectID,
                snapshot: appState.snapshot,
                db: db,
                failures: &failures
            )
            report(failures)
            if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
                appState.snapshot = snap
            }
            proposedRelativeDecisions[proposal.id] = .accepted

            // Retire the blank placeholder parent the sibling shortcut left
            // on the subject, replacing it with this real parent and moving
            // any shared siblings across — instead of stacking a 3rd/4th
            // parent behind hidden blanks (owner report 2026-07-15).
            if let newParent = appState.snapshot.parentsOf(subjectID).first(where: { p in
                p.gender == proposal.gender &&
                (p.lastName ?? "").caseInsensitiveCompare(proposal.proposedSurname ?? "") == .orderedSame
            }) {
                let role: ParentRole = proposal.gender == .female
                    ? .mother : (proposal.gender == .male ? .father : .unspecified)
                appState.reconcilePlaceholderParent(
                    childID: subjectID, realParentID: newParent.id, role: role)
            }

            // Slice 11 — when both parents are now linked AND a supported
            // .parentMarriage hypothesis exists for the pair, materialise
            // the spouse edge with marriage date/location from the cited
            // BMD record. Idempotent: no-op if the spouse edge already
            // exists. The materialisation only runs after the accept has
            // refreshed the snapshot, so the just-accepted parent is in
            // the graph.
            if let result = currentResult {
                persist("Materialise parents' spouse edge") {
                    try db.ensureSpouseEdgeForParents(
                        ofSubject: subjectID,
                        hypotheses: result.hypotheses,
                        scoredRecords: result.allScoredRecords,
                        snapshot: appState.snapshot
                    )
                }
                if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
                    appState.snapshot = snap
                }
            }
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
            if persist("Apply parent given name", {
                try db.editProfile(
                    profileID: parent.id,
                    changes: [(.firstName, nil, given.capitalized)],
                    dateChanges: [],
                    source: origin
                )
            }) != nil {
                written += 1
            }
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
                let dateCandidate = ApplyEngine.bmdDate(year: m.marriageYear, quarter: m.quarter, exact: m.marriageDate)
                let locationCandidate = m.marriagePlace ?? m.district
                if persist("Record marriage on spouse edge", {
                    try db.fillRelationshipMarriage(
                        relationshipID: edge.id,
                        candidateDate: dateCandidate,
                        candidateLocation: locationCandidate
                    )
                }) != nil {
                    written += 1
                }
            default:
                break
            }
        }

        if written > 0 {
            if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
                appState.snapshot = snap
            }
            proposedRelativeDecisions[proposal.id] = .accepted
        }
        return written
    }

    /// Reject a proposed relative: persist the proposal id so it will not reappear
    /// on subsequent research runs for the same subject.
    func rejectProposedRelative(_ proposal: ProposedRelative) {
        proposedRelativeDecisions[proposal.id] = .rejected
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        persist("Save rejection") { try db.saveRejection(profileID: profileID, recordID: proposal.id) }
    }

    // MARK: - Sibling Proposal Decisions

    /// Sibling proposals from the most recent run, filtered by previously-
    /// persisted rejections so re-runs don't keep re-surfacing siblings the
    /// user has dismissed. Same pattern as `visibleProposedRelatives`.
    ///
    /// **V2 spec T12-sibling (Phase 4 complete)**: source of truth is
    /// `result.hypotheses` (filtered to `.siblingExists` /
    /// `isDeterministicallySupported`), projected via the pipeline's
    /// helper on demand. The legacy `result.proposedSiblings` field has
    /// been deleted; this method is the only surface that builds
    /// `SiblingProposal`s for the accept / reject UI.
    func visibleSiblings(snapshot: FamilyGraphSnapshot) -> [SiblingProposal] {
        guard let result = currentResult else { return [] }
        let supportedSiblingHypotheses = result.hypotheses.filter { h in
            guard case .siblingExists = h.kind else { return false }
            return h.isDeterministicallySupported
        }
        let proposals = supportedSiblingHypotheses.flatMap { h in
            ResearchPipeline.projectSiblingExistsToProposals(
                hypothesis: h,
                scoredRecords: result.allScoredRecords,
                snapshot: snapshot
            )
        }
        guard let db = appDatabase, let profileID = selectedProfile?.id else {
            return proposals
        }
        let rejected = Self.loadRejectionsLogged(db: db, profileID: profileID, logger: logger)
        return proposals.filter { !rejected.contains($0.id) }
    }

    /// Accept a sibling proposal: create a ghost Profile and wire it to
    /// BOTH parent profiles in one atomic transaction. When the proposal
    /// matches an existing profile (per `ProposalDedup`), link the
    /// existing profile to the proposal's parents instead of creating
    /// a duplicate ghost — re-running sibling discovery and re-accepting
    /// the same candidate is now a no-op rather than a duplicate-creator.
    /// The George Brooks × 2 / Hilda Brooks × 2 bug pattern.
    func acceptSibling(_ proposal: SiblingProposal, into appState: AppState) {
        guard let db = appState.currentDatabase else {
            errorMessage = "No project open"
            return
        }
        do {
            let candidates = Array(appState.snapshot.profiles.values)
            switch ProposalDedup.decide(
                query: ProposalDedup.Query(siblingProposal: proposal),
                candidates: candidates
            ) {
            case .matched(let existingID):
                try ensureBothParentEdges(
                    onExistingProfile: existingID,
                    fatherID: proposal.fatherID,
                    motherID: proposal.motherID,
                    in: appState.snapshot,
                    db: db
                )
            case .noMatch, .multipleMatches:
                _ = try db.acceptSiblingProposal(proposal)
            }
            if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
                appState.snapshot = snap
            }
            siblingDecisions[proposal.id] = .accepted
        } catch {
            errorMessage = "Failed to create sibling: \(error.localizedDescription)"
        }
    }

    /// Add father and mother edges onto an existing profile, only
    /// inserting edges that aren't already there. Idempotent.
    private func ensureBothParentEdges(
        onExistingProfile childID: String,
        fatherID: String,
        motherID: String,
        in snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws {
        let existingParents = Set(snapshot.parentsOf(childID).map(\.id))
        for (parentID, role) in [(fatherID, ParentRole.father), (motherID, .mother)] {
            guard !existingParents.contains(parentID) else { continue }
            let edge = Relationship(
                id: UUID(),
                from: parentID,
                to: childID,
                type: .parent,
                role: role,
                subtype: .biological,
                marriageDate: nil,
                marriageLocation: nil,
                divorceDate: nil
            )
            _ = try db.addRelationshipIfAbsent(edge)
        }
    }

    /// Accept a `.supported` `.birthYearCandidate` hypothesis (slice 5 of
    /// `project_multi_hypothesis_birth_year_plan`). Writes the chosen year
    /// to `Profile.birthDate`, reusing the matching `Profile.sources[.birthDate]`
    /// entry's `raw` + `origin` so provenance is preserved (e.g. the
    /// freebmd "Dec 1883" source becomes the canonical attestation
    /// rather than a generic "1883").
    ///
    /// The directional-overwrite rule (`shouldOverwriteDateField`)
    /// deliberately refuses to choose between same-span precise values
    /// — disambiguation is the multi-hypothesis pivot's job, and this
    /// IS that pivot. So this method bypasses the policy and writes
    /// unconditionally when the user accepts a `.supported` hypothesis.
    ///
    /// No-op when:
    ///   • hypothesis is not `.birthYearCandidate` kind
    ///   • verdict is not `.supported` (or is model-assisted)
    ///   • no current project DB is open
    ///   • profile referenced by the hypothesis doesn't exist
    func acceptBirthYearCandidate(
        _ hypothesis: ResearchHypothesis,
        into appState: AppState
    ) {
        guard let db = appState.currentDatabase else {
            errorMessage = "No project open"
            return
        }
        do {
            try ApplyEngine.applyBirthYearCandidate(
                hypothesis, snapshot: appState.snapshot, db: db
            )
            if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
                appState.snapshot = snap
            }
        } catch ApplyEngine.ApplyBirthYearCandidateError.notSupported,
                ApplyEngine.ApplyBirthYearCandidateError.wrongKind {
            // Defensive guards — UI shouldn't expose Accept for these,
            // but log silently if it does. No user-visible error.
            return
        } catch ApplyEngine.ApplyBirthYearCandidateError.profileMissing(let id) {
            errorMessage = "Profile \(id) not found in current snapshot"
        } catch {
            errorMessage = "Failed to apply birth year: \(error.localizedDescription)"
        }
    }

    /// CL5 — accept a death-year candidate: writes the date, resolves the
    /// linked dispute, and contradicts the group's rivals in one action.
    func acceptDeathYearCandidate(
        _ hypothesis: ResearchHypothesis,
        into appState: AppState
    ) {
        guard let db = appState.currentDatabase else {
            errorMessage = "No project open"
            return
        }
        do {
            try ApplyEngine.applyDeathYearCandidate(
                hypothesis, snapshot: appState.snapshot, db: db
            )
            if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
                appState.snapshot = snap
            }
        } catch ApplyEngine.ApplyBirthYearCandidateError.notSupported,
                ApplyEngine.ApplyBirthYearCandidateError.wrongKind {
            return
        } catch ApplyEngine.ApplyBirthYearCandidateError.profileMissing(let id) {
            errorMessage = "Profile \(id) not found in current snapshot"
        } catch {
            errorMessage = "Failed to apply death year: \(error.localizedDescription)"
        }
    }

    /// Reject a sibling proposal: persist the proposal id so it won't reappear
    /// on subsequent research runs for the same subject.
    func rejectSibling(_ proposal: SiblingProposal) {
        siblingDecisions[proposal.id] = .rejected
        guard let db = appDatabase, let profileID = selectedProfile?.id else { return }
        persist("Save rejection") { try db.saveRejection(profileID: profileID, recordID: proposal.id) }
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
        if let snap = persist("Refresh tree snapshot", { try db.buildSnapshot() }) {
            appState.snapshot = snap
        }

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
            // T1-01 / FT-23 — outcome-aware searched-source accounting.
            let searchedSources = GPSScorer.searchedSourceIDs(for: result)
            let gps = GPSScorer.score(
                result: result,
                sourceInfoMap: [:],
                searchedSourceCount: searchedSources.count,
                totalSourceCount: max(searchedSources.count, 1)
            )
            persist("Save research run") {
                try db.saveResearchRun(
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
        siblingDecisions = [:]
        recordDecisions = [:]
        sourceStatuses = []
        progressMessage = nil
        errorMessage = nil
        isResearching = false
    }
}
