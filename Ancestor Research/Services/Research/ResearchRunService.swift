import Foundation
import os

/// Single construction path for research runs. Every entry point —
/// interactive UI runs (`ResearchViewModel`), whole-tree sweeps
/// (`WholeTreeResearchViewModel`), and MCP-requested watcher runs
/// (`RunRequestWatcher`) — builds its pipeline here, so run behaviour
/// cannot diverge by trigger (Phase 1 slice 6,
/// ARCHITECTURE_REVIEW_2026-07.md).
///
/// History note: before this existed each site hand-rolled construction,
/// and the watcher's copy omitted `rejectionLookup` — so MCP-triggered
/// runs did not honour user record discards across runs (the §3.6
/// guard). Exactly the divergence class this service exists to prevent.
@MainActor
enum ResearchRunService {

    struct Built {
        let pipeline: ResearchPipeline
        let sourceInfoMap: [String: SourceInfo]
    }

    /// Build the pipeline the one canonical way.
    ///
    /// `sourceInfoMap` may be passed in when the caller has already built
    /// it for UI purposes (source status cards); nil builds it here.
    static func makePipeline(
        registry: SourceRegistry,
        snapshot: FamilyGraphSnapshot,
        database: ProjectDatabase?,
        sourceInfoMap: [String: SourceInfo]? = nil,
        budgetTracker: SourceBudgetTracker? = nil
    ) -> Built {
        let map = sourceInfoMap ?? registry.buildSourceInfoMap()
        let dispatcher = SearchDispatcher(registry: registry, budgetTracker: budgetTracker)
        let pipeline = ResearchPipeline(
            dispatcher: dispatcher,
            snapshot: snapshot,
            sourceInfoMap: map,
            childEvidenceMMNLookup: ResearchPipeline.makeChildEvidenceMMNLookup(database: database),
            pendingFactWriter: ResearchPipeline.makePendingFactWriter(database: database),
            rejectionLookup: ResearchPipeline.makeRejectionLookup(database: database),
            userHypothesisLookup: ResearchPipeline.makeUserHypothesisLookup(database: database),
            negativeSearchKeyLoader: ResearchPipeline.makeNegativeSearchKeyLoader(database: database)
        )
        return Built(pipeline: pipeline, sourceInfoMap: map)
    }

    /// Build the per-source daily-budget tracker for a sustained run
    /// (ENGINE_FOUNDATION #Change5). Policies come from each registered
    /// source's declared `budgetPolicy`; the current request counts are
    /// rehydrated from `source_budget_state` so a budget spent before a
    /// restart is still spent after (§Change6). The persistence sink writes
    /// every counted request back to the same table. Returns nil when there
    /// is no database (nothing to persist to / restore from) — callers then
    /// run without budget tracking, exactly as before this Change.
    ///
    /// The tracker is shared across every run in the process (one quota per
    /// volunteer host, not per subject), so construct it ONCE per open
    /// project and thread the same instance into each `makePipeline` call.
    static func makeBudgetTracker(
        registry: SourceRegistry,
        database: ProjectDatabase?
    ) -> SourceBudgetTracker? {
        guard let database else { return nil }
        var policies: [String: SourceBudgetPolicy] = [:]
        for source in registry.allSources() {
            policies[source.sourceID] = source.budgetPolicy
        }
        let restored = (try? database.loadSourceBudgetWindows()) ?? []
        return SourceBudgetTracker(
            policies: policies,
            restoredWindows: restored,
            persist: { window in
                // Best-effort persistence; a failed single-row write must not
                // abort the run. The next counted request re-persists.
                try? database.saveSourceBudgetWindow(window)
            }
        )
    }

    // MARK: - Result persistence (Phase 1 slice 6b)

    /// What a persistence pass produced. `failures` must be surfaced by
    /// the caller (UI `errorMessage` or watcher log) — nothing in here
    /// fails silently.
    struct PersistOutcome {
        let runID: UUID?
        let finalisedLead: Lead?
        let failures: [ApplyEngine.WriteFailure]
    }

    /// Intentional per-caller differences, made explicit instead of
    /// living as drift between two copies:
    /// - `emitParentInferredLeads`: relationship-tagged leads from
    ///   supported `.parentInferred` hypotheses — the MCP `promote_lead`
    ///   gate needs them for autonomous expansion; the UI surfaces the
    ///   same hypotheses as proposal cards instead, so emitting them for
    ///   UI runs would double-surface.
    /// - `runPlaceholderWriteback`: ENGINE_FOUNDATION #Change2 thin→rich
    ///   enrichment, wanted on autonomous hops; UI runs leave it to the
    ///   human reviewing clusters.
    /// - `resultJSON`: the watcher's eval envelope
    ///   (SWIFT_MCP_EVAL_BACKEND_SPEC #Change3) stored on the run row.
    struct PersistOptions {
        var emitParentInferredLeads = false
        var runPlaceholderWriteback = false
        var resultJSON: String? = nil
    }

    /// THE result-persistence path — previously two hand-maintained
    /// copies (`ResearchViewModel.runPipeline`'s block and
    /// `RunRequestWatcher.persistResult`, self-described as its
    /// "mirror") which had drifted: the watcher never upserted
    /// hypotheses, spawned leads in a detached fire-and-forget task
    /// (racing the run-completion write and the eval envelope), and
    /// `try?`-swallowed every error.
    ///
    /// Evidence rows, hypothesis upserts, child leads, and the run
    /// record are profile-keyed; lead-investigation runs (nil
    /// `profileID`) skip those and only flip the investigated lead's
    /// status. Per-item failures are collected, never aborting the
    /// remaining writes — matching the UI path's long-standing
    /// behaviour.
    static func persist(
        result: ResearchResult,
        mode: ResearchMode,
        sourceInfoMap: [String: SourceInfo],
        registry: SourceRegistry,
        snapshot: FamilyGraphSnapshot,
        profileID: String?,
        leadToFinalise: Lead?,
        options: PersistOptions = PersistOptions(),
        db: ProjectDatabase
    ) async -> PersistOutcome {
        var failures: [ApplyEngine.WriteFailure] = []
        var savedRunID: UUID? = nil

        if let profileID {
            // Run id generated up front so evidence rows carry their run
            // linkage (CAMPAIGN_REVIEW_SPEC Change 2) — the same id the
            // research_runs row is saved under below.
            let runID = UUID()

            // Evidence rows + citations — persisted with the FULL scorer
            // output (gates + summary) and the run's enrichment tag so a DB
            // reconstruction can rebuild the exact ScoredRecords and apply
            // the same clustering exclusion the run did.
            var saved = 0
            for scored in result.allScoredRecords {
                let citation = CitationRenderer.cite(scored.record)
                do {
                    try db.saveEvidence(
                        profileID: profileID,
                        scored: scored,
                        citationFull: citation.full,
                        citationURL: citation.url,
                        isEnrichment: result.enrichmentRecordIDs.contains(scored.record.id),
                        runID: runID.uuidString
                    )
                    saved += 1
                } catch {
                    failures.append(.init(what: "Save evidence \(scored.record.id)", error: error))
                }
            }
            logger.info("Persisted \(saved)/\(result.allScoredRecords.count) evidence records for \(profileID)")

            // CAMPAIGN_REVIEW_SPEC Change 3 — persist the evidence chain's
            // convergence per asserted fact value. Upsert per
            // (profile, value_key): the level upgrades as independent
            // lineages accumulate across runs; a level DROP (registry/tier
            // changes) is recorded rather than suppressed — the table is an
            // audit trail of the chain's current strength, not a ratchet.
            // Fact-verdict records only (leads must not inflate the chain,
            // DS-24), witness-collapsed inside scoreValueGroups (DS-03).
            let factRecords = result.confirmedFacts.map(\.record)
            if !factRecords.isEmpty {
                let groups = ConvergenceEngine.scoreValueGroups(
                    records: factRecords, sourceInfoMap: sourceInfoMap
                )
                do {
                    try db.upsertEvidenceConvergence(profileID: profileID, groups: groups)
                } catch {
                    failures.append(.init(what: "Persist evidence convergence", error: error))
                }
            }

            // T12-sibling Phase 1: persist pipeline-generated hypotheses
            // alongside evidence. Upsert preserves created_at and the
            // user_rejected flag across re-runs (V2 spec §4.3).
            if !result.hypotheses.isEmpty {
                do {
                    try db.upsertHypotheses(result.hypotheses)
                    logger.info("Persisted \(result.hypotheses.count) hypotheses for \(profileID)")
                } catch {
                    failures.append(.init(what: "Persist hypotheses", error: error))
                }
            }

            // Child leads. Profile-aware lead filter rejects death-shaped
            // records for living profiles and namesake leads outside the
            // precise-birth-year window (LeadFilter rules). Inline await —
            // the old watcher copy ran this detached, so run completion
            // could be recorded before the leads existed.
            let leadStore = LeadStore(db: db)
            let leadFilter = snapshot.profiles[profileID].map(LeadFilter.deriving(from:))
            for scored in result.leads {
                if let filter = leadFilter, !filter.accepts(scored) {
                    continue
                }
                do { _ = try await leadStore.createFromScoredRecord(scored, profileID: profileID) }
                catch { failures.append(.init(what: "Save lead", error: error)) }
            }
            for member in result.householdMembers {
                let censusYear = result.allScoredRecords
                    .compactMap { r -> Int? in
                        if case .census(let c) = r.record { return c.censusYear }
                        return nil
                    }.first ?? 1861
                do { _ = try await leadStore.createFromHouseholdMember(member, profileID: profileID, censusYear: censusYear) }
                catch { failures.append(.init(what: "Save household lead", error: error)) }
            }

            // Relationship-tagged leads for supported `.parentInferred`
            // hypotheses — carries the kin context `promote_lead`'s gate
            // requires (watcher runs only; see PersistOptions).
            if options.emitParentInferredLeads {
                for hypothesis in result.hypotheses {
                    guard case .parentInferred = hypothesis.kind else { continue }
                    guard hypothesis.verdict == .supported else { continue }
                    do { _ = try await leadStore.createFromParentInferredHypothesis(hypothesis) }
                    catch { failures.append(.init(what: "Save parent-inferred lead", error: error)) }
                }
            }

            // Thin-placeholder write-back (ENGINE_FOUNDATION #Change2).
            // `apply` is idempotent (re-checks density before writing).
            if options.runPlaceholderWriteback {
                let extracted: [(givenName: String?, birthYear: Int?)] = result.allScoredRecords
                    .filter { $0.verdict != .impossible }
                    .map { scored in
                        (
                            givenName: scored.record.common.givenName,
                            birthYear: PlaceholderWriteback.extractBirthYear(from: scored.record)
                        )
                    }
                if let proposal = PlaceholderWriteback.propose(from: extracted) {
                    do { _ = try PlaceholderWriteback.apply(proposal: proposal, profileID: profileID, db: db) }
                    catch { failures.append(.init(what: "Placeholder write-back", error: error)) }
                }
            }

            // Run record. `savedRunID` is claimed only when the write
            // succeeded — a swallowed SQLite lock error here used to leave
            // research_run_requests pointing at a run row that didn't
            // exist, and MCP get_research_result 404'd on it.
            // T1-01 piece 5 + T1-04 — persist genuine negatives at the
            // per-WIRE-query grain. Only (source, recordType) pairs whose
            // every main-loop query answered cleanly with zero records
            // (and with no record in hand from any other flow) are
            // recorded; errors, blocks, throttles, and truncated pages
            // leave no negative. Each distinct clean-negative query is
            // stored keyed by its `QueryCache.cacheKey` (search_params),
            // so a later run's cross-run reader
            // (`NegativeSearchCache`, T1-04) can suppress the identical
            // re-fire within its freshness window. Suppressed replays
            // from THIS run carry `isCleanNegative == false` and so are
            // excluded — the absence is already on disk; only its
            // `searched_at` is refreshed by the UPSERT above. Coexists
            // with the whole-tree resume-state rows, which live under
            // profile_id "__whole_tree__" with NULL-shaped JSON params.
            let negativeKeys = NegativeSearchAggregator.genuineNegativeKeys(
                outcomes: result.searchOutcomes,
                scoredRecords: result.allScoredRecords
            )
            for negative in negativeKeys {
                do {
                    try db.saveNegativeSearch(
                        profileID: profileID,
                        sourceID: negative.sourceID,
                        recordType: negative.recordType.rawValue,
                        params: negative.queryKey,
                        resultKind: "zero",
                        hitCount: 0
                    )
                } catch {
                    failures.append(.init(what: "Save negative search", error: error))
                }
            }

            // T1-01 / FT-23 — outcome-aware accounting: sources that only
            // errored / were blocked / returned truncated pages no longer
            // count toward "reasonably exhaustive search".
            let searchedSources = GPSScorer.searchedSourceIDs(for: result)
            // CL3 — criterion 4 reads the dispute ledger + value-candidate
            // hypotheses; loaded best-effort (a read failure degrades to
            // the no-context defaults, never blocks the run save).
            let disputeRows: [DisputeRow] =
                (try? db.allDisputes(profileID: profileID)) ?? []
            let hypotheses = (try? db.loadHypotheses(forProfile: profileID)) ?? []
            let inconclusiveCandidates = hypotheses
                .filter { $0.kind.discriminator == "birthYearCandidate" && $0.verdict == .inconclusive }
                .count
            let availableIDs = Set(registry.allSources().map(\.sourceID))
            let subjectProfile = snapshot.profiles[profileID]
            let relevantIDs = GPSScorer.relevantSourceIDs(
                birthYear: subjectProfile?.birthDate?.bestYear,
                deathYear: subjectProfile?.deathDate?.bestYear,
                gender: subjectProfile?.gender,
                available: availableIDs)
            let gps = GPSScorer.score(
                result: result,
                sourceInfoMap: sourceInfoMap,
                searchedSourceIDs: searchedSources,
                totalSourceCount: availableIDs.count,
                relevantSourceIDs: relevantIDs,
                openDisputes: disputeRows.filter(\.isOpen),
                resolvedDisputes: disputeRows.filter { !$0.isOpen },
                inconclusiveValueCandidateCount: inconclusiveCandidates
            )
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
                    resultJSON: options.resultJSON ?? ""
                )
                savedRunID = runID
                // CL3 T-B — run discrepancies stop dead-ending: persist
                // with run linkage, and grade-≥-conflict rows (already
                // fact-grade by detectDiscrepancies' filter) also open a
                // dispute so the conflict is signal, not just data.
                do {
                    try db.insertRunDiscrepancies(
                        profileID: profileID, runID: runID.uuidString,
                        discrepancies: result.discrepancies)
                    for d in result.discrepancies where d.severity >= .conflict {
                        let conflict = Self.disputeConflict(for: d, profileID: profileID)
                        _ = try db.upsertDispute(
                            profileID: profileID, conflict: conflict,
                            adjudication: DisputeResolver.adjudicate(conflict))
                    }
                } catch {
                    failures.append(.init(what: "Persist run discrepancies", error: error))
                }
            } catch {
                failures.append(.init(what: "Save research run", error: error))
            }
        }

        // Lead path: flip status to .investigated so the Leads tab
        // reflects that this lead has been searched.
        var finalisedLead: Lead? = nil
        if let lead = leadToFinalise {
            let updated = Lead(
                id: lead.id, profileID: lead.profileID,
                name: lead.name, surname: lead.surname, givenName: lead.givenName,
                birthYear: lead.birthYear, deathYear: lead.deathYear,
                ageAtDeath: lead.ageAtDeath, place: lead.place,
                relationship: lead.relationship, source: lead.source,
                status: .investigated, evidence: lead.evidence,
                createdAt: lead.createdAt,
                investigatedAt: Date(),
                resolvedAt: lead.resolvedAt, resolution: lead.resolution
            )
            do {
                // upsertLead — saveLead (INSERT OR IGNORE) never lands this
                // flip for a lead already in the DB, which is every lead
                // reaching this path (CAMPAIGN_REVIEW_SPEC Change 1).
                try db.upsertLead(updated)
                finalisedLead = updated
            } catch {
                failures.append(.init(what: "Update lead status", error: error))
            }
        }

        // #CPC-Change2 — post-persist corroboration pass scoped to this
        // profile's spouse edges: fires at the exact moment the SECOND
        // spouse's run lands, so a freshly-persisted marriage lead meets
        // its counterpart without waiting for the next project open.
        // Best-effort like every non-essential persist step.
        do {
            _ = try CorroborationSweep.run(
                db: db, snapshot: snapshot, limitToProfileID: profileID)
        } catch {
            failures.append(.init(what: "Corroboration sweep", error: error))
        }

        return PersistOutcome(runID: savedRunID, finalisedLead: finalisedLead, failures: failures)
    }

    /// CL3 T-B — a ≥ .conflict run discrepancy expressed as a dispute-
    /// producing conflict (`detected_by='runSweep'`). Field keys map onto
    /// the apply-path identities so the run-time and apply-time producers
    /// join the same open dispute rather than opening rivals.
    nonisolated static func disputeConflict(
        for d: ResearchDiscrepancy, profileID: String
    ) -> DetectedConflict {
        let fieldKey: String = switch d.field {
        case "birthYear": ProfileField.birthDate.rawValue
        case "deathYear": ProfileField.deathDate.rawValue
        default: d.field
        }
        return DetectedConflict(
            kind: .fieldValue,
            profileID: profileID,
            field: fieldKey,
            reason: .valueMismatch,
            severity: d.severity,
            competingSources: [
                FieldSource(origin: SourceOrigin(identifier: "tree"), raw: d.existingValue, addedAt: Date()),
                FieldSource(origin: SourceOrigin(identifier: d.sourceID), raw: d.sourceValue, addedAt: Date()),
            ],
            evidenceJSON: nil,
            reasoning: "Run discrepancy (\(d.field)): tree says '\(d.existingValue)', \(d.sourceID) says '\(d.sourceValue)'. \(d.reasoning)",
            detectedBy: .runSweep
        )
    }

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "RunService")
}
