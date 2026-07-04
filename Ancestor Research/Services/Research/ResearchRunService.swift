import Foundation

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
}
