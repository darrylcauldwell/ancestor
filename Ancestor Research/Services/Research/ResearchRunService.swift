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
        sourceInfoMap: [String: SourceInfo]? = nil
    ) -> Built {
        let map = sourceInfoMap ?? registry.buildSourceInfoMap()
        let dispatcher = SearchDispatcher(registry: registry)
        let pipeline = ResearchPipeline(
            dispatcher: dispatcher,
            snapshot: snapshot,
            sourceInfoMap: map,
            childEvidenceMMNLookup: ResearchPipeline.makeChildEvidenceMMNLookup(database: database),
            pendingFactWriter: ResearchPipeline.makePendingFactWriter(database: database),
            rejectionLookup: ResearchPipeline.makeRejectionLookup(database: database)
        )
        return Built(pipeline: pipeline, sourceInfoMap: map)
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
            // Evidence rows + citations.
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
                    failures.append(.init(what: "Save evidence \(scored.record.id)", error: error))
                }
            }
            logger.info("Persisted \(saved)/\(result.allScoredRecords.count) evidence records for \(profileID)")

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
            let runID = UUID()
            let searchedSources = Set(result.allScoredRecords.map(\.record.sourceID))
            let gps = GPSScorer.score(
                result: result,
                sourceInfoMap: sourceInfoMap,
                searchedSourceCount: searchedSources.count,
                totalSourceCount: registry.allSources().count
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
                relationship: lead.relationship, source: lead.source,
                status: .investigated, evidence: lead.evidence,
                createdAt: lead.createdAt,
                investigatedAt: Date(),
                resolvedAt: lead.resolvedAt, resolution: lead.resolution
            )
            do {
                try db.saveLead(updated)
                finalisedLead = updated
            } catch {
                failures.append(.init(what: "Update lead status", error: error))
            }
        }

        return PersistOutcome(runID: savedRunID, finalisedLead: finalisedLead, failures: failures)
    }

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "RunService")
}
