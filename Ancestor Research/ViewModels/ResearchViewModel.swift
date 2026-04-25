import Foundation
import os

/// Orchestrates per-profile research: trigger → pipeline → cluster review → accept.
@MainActor @Observable
final class ResearchViewModel {
    // Input
    var selectedProfile: Profile?
    var selectedMode: ResearchMode = .extend

    // Pipeline state
    var isResearching = false
    var currentResult: ResearchResult?
    var progressMessage: String?
    var sourceStatuses: [SourceStatus] = []

    // Review state
    var clusterDecisions: [String: ClusterDecision] = [:]  // cluster.id → decision
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
        errorMessage = nil
        progressMessage = "Preparing research..."

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

        // Choose config based on mode
        let config: ResearchConfig
        switch selectedMode {
        case .verify: config = .verify
        case .extend: config = .extend
        case .discover: config = .discover
        }

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

        // Update source statuses from results
        updateSourceStatuses(from: result)

        logger.info("Research complete: \(result.clusters.count) clusters, \(result.confirmedFacts.count) facts, \(result.leads.count) leads")

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

    func acceptCluster(_ cluster: LifeCluster) {
        clusterDecisions[cluster.id] = .accepted
    }

    func rejectCluster(_ cluster: LifeCluster) {
        clusterDecisions[cluster.id] = .rejected
        // Persist rejections for all records in the cluster
        if let db = appDatabase, let profileID = selectedProfile?.id {
            for record in cluster.records {
                try? db.saveRejection(profileID: profileID, recordID: record.id)
            }
        }
    }

    func deferCluster(_ cluster: LifeCluster) {
        clusterDecisions[cluster.id] = .deferred
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

    /// Reset for a new research session.
    func reset() {
        selectedProfile = nil
        currentResult = nil
        clusterDecisions = [:]
        sourceStatuses = []
        progressMessage = nil
        errorMessage = nil
        isResearching = false
    }
}
