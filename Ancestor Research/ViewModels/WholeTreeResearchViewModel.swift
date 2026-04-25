import Foundation
import os

/// Orchestrates whole-tree research — loops per-profile pipeline over a priority-sorted queue.
/// Same per-profile cluster review, one at a time. No new bulk UI.
@MainActor @Observable
final class WholeTreeResearchViewModel {
    // Queue
    var profileQueue: [Profile] = []
    var currentIndex: Int = 0
    var currentProfile: Profile?

    // Progress
    var isRunning = false
    var isCancelled = false
    var profilesCompleted: Int = 0
    var totalFacts: Int = 0
    var consecutiveNoFacts: Int = 0

    // Config
    var maxProfiles: Int = 20
    var timeLimitMinutes: Int = 30
    var noFactsStreakLimit: Int = 3

    // Current research
    var currentResult: ResearchResult?
    var waitingForReview = false

    // Error
    var errorMessage: String?

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "WholeTree")
    private var startTime: Date?

    // MARK: - Queue Building

    /// Build a priority-sorted queue of profiles to research.
    /// Priority: least complete first, skip post-1930 births and already-complete profiles.
    func buildQueue(snapshot: FamilyGraphSnapshot) {
        profileQueue = snapshot.profiles.values
            .filter { profile in
                // Skip unsearchable (born after 1930)
                if let birthYear = profile.birthDate?.earliest, birthYear > 1930 { return false }
                // Skip fully complete profiles
                let comp = snapshot.completeness(for: profile.id)
                return comp.score < comp.maximum
            }
            .sorted { a, b in
                let ca = snapshot.completeness(for: a.id)
                let cb = snapshot.completeness(for: b.id)
                return ca.score < cb.score  // Least complete first
            }
        currentIndex = 0
    }

    // MARK: - Research Loop

    /// Start whole-tree research. Processes one profile at a time.
    func start(
        snapshot: FamilyGraphSnapshot,
        registry: SourceRegistry,
        database: ProjectDatabase?
    ) async {
        buildQueue(snapshot: snapshot)
        guard !profileQueue.isEmpty else {
            errorMessage = "No incomplete profiles to research."
            return
        }

        isRunning = true
        isCancelled = false
        profilesCompleted = 0
        totalFacts = 0
        consecutiveNoFacts = 0
        startTime = Date()
        currentResult = nil
        waitingForReview = false

        let queueCount = self.profileQueue.count
        logger.info("Whole-tree research started: \(queueCount) profiles queued")

        while self.currentIndex < self.profileQueue.count && !self.shouldStop {
            let profile = self.profileQueue[self.currentIndex]
            self.currentProfile = profile

            let idx = self.currentIndex + 1
            logger.info("Researching \(idx)/\(queueCount): \(profile.displayName)")

            let sourceInfoMap = registry.buildSourceInfoMap()
            let subject = ResearchSubject.fromProfile(profile, snapshot: snapshot, mode: .extend)
            let config = ResearchConfig.extend

            let dispatcher = SearchDispatcher(registry: registry, regionConfig: RegionConfig.derbyshire)
            let pipeline = ResearchPipeline(dispatcher: dispatcher, snapshot: snapshot, sourceInfoMap: sourceInfoMap)

            let result = await pipeline.research(subject: subject, config: config)
            currentResult = result

            let newFacts = result.confirmedFacts.count
            totalFacts += newFacts

            if newFacts == 0 {
                consecutiveNoFacts += 1
            } else {
                consecutiveNoFacts = 0
            }

            // Create leads from this profile's research
            if let db = database {
                let leadStore = LeadStore(db: db)
                for scored in result.leads {
                    _ = try? await leadStore.createFromScoredRecord(scored, profileID: profile.id)
                }
            }

            profilesCompleted += 1

            // Pause for user review if there are clusters to review
            if !result.clusters.isEmpty {
                waitingForReview = true
                // Wait until user continues
                while waitingForReview && !isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }

            if shouldStop { break }
            currentIndex += 1
        }

        isRunning = false
        currentProfile = nil
        let completed = self.profilesCompleted
        let facts = self.totalFacts
        logger.info("Whole-tree research complete: \(completed) profiles, \(facts) facts")
    }

    /// Continue to next profile after reviewing current results.
    func continueToNext() {
        waitingForReview = false
        currentResult = nil
    }

    /// Cancel the research loop.
    func cancel() {
        isCancelled = true
        waitingForReview = false
    }

    // MARK: - Stop Conditions

    private var shouldStop: Bool {
        if isCancelled { return true }
        if Task.isCancelled { return true }
        if profilesCompleted >= maxProfiles { return true }
        if consecutiveNoFacts >= noFactsStreakLimit { return true }
        if let start = startTime, Date().timeIntervalSince(start) > Double(timeLimitMinutes * 60) { return true }
        return false
    }

    var stopReason: String? {
        if isCancelled { return "Cancelled by user" }
        if profilesCompleted >= maxProfiles { return "Max profiles reached (\(maxProfiles))" }
        if consecutiveNoFacts >= noFactsStreakLimit { return "No new facts for \(noFactsStreakLimit) consecutive profiles" }
        if let start = startTime, Date().timeIntervalSince(start) > Double(timeLimitMinutes * 60) { return "Time limit reached (\(timeLimitMinutes) min)" }
        return nil
    }

    var progressSummary: String {
        "\(profilesCompleted)/\(profileQueue.count) profiles, \(totalFacts) facts"
    }
}
