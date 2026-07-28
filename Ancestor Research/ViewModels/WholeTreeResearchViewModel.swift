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

    /// Backfill mode (FREEBMD_CITATION_BACKFILL_SPEC Change 4): a scoped,
    /// auto-continuing sweep of the citation-flagged profiles. It finds links,
    /// not facts, so the no-facts streak-stop must not apply. Defaults off —
    /// "Research All" is unchanged.
    var isBackfill = false
    var autoContinueReview = false
    /// Set when a profile's research hit a real server throttle (429 →
    /// SearchAvailability.throttled). Halts the whole run — trust the live 429,
    /// don't keep hammering a parked source (owner direction 2026-07-28).
    var hitThrottle = false

    // Current research
    var currentResult: ResearchResult?
    var waitingForReview = false

    // Error
    var errorMessage: String?

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "WholeTree")
    private var startTime: Date?

    // MARK: - Queue Building

    /// Build a priority-sorted queue of profiles to research.
    /// Priority: least complete first, skip already-complete profiles. Per-source
    /// coverage is enforced by the dispatcher — profiles outside any source's
    /// declared range simply return zero results rather than being pre-excluded.
    /// `restrictedTo` (non-nil) scopes the queue to a specific set of profile
    /// ids — the FreeBMD citation backfill (FREEBMD_CITATION_BACKFILL_SPEC
    /// Change 4) passes the audit-flagged profiles and takes them all,
    /// regardless of completeness. nil keeps the default "every incomplete
    /// profile, least-complete first" behaviour.
    func buildQueue(snapshot: FamilyGraphSnapshot, restrictedTo: Set<String>? = nil) {
        profileQueue = snapshot.profiles.values
            .filter { profile in
                if let restrictedTo { return restrictedTo.contains(profile.id) }
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
        database: ProjectDatabase?,
        restrictedTo: Set<String>? = nil,
        autoContinue: Bool = false
    ) async {
        isBackfill = restrictedTo != nil
        autoContinueReview = autoContinue
        buildQueue(snapshot: snapshot, restrictedTo: restrictedTo)
        guard !profileQueue.isEmpty else {
            errorMessage = isBackfill ? "No FreeBMD links to backfill." : "No incomplete profiles to research."
            return
        }
        // A scoped backfill takes the whole flagged set (bounded by its own
        // count), not the default 20-profile cap; the time limit + cancel stay
        // as the safety net, and the pipeline's per-source breaker throttles
        // FreeBMD so this never hammers the volunteer servers.
        if isBackfill { maxProfiles = profileQueue.count }

        isRunning = true
        isCancelled = false
        profilesCompleted = 0
        totalFacts = 0
        consecutiveNoFacts = 0
        hitThrottle = false
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

            // Project fallback only; fromProfile's derivation chain prefers
            // the profile's own birth location and only uses this when the
            // profile is location-less.
            let homeChapmanCode = (try? database?.loadProjectMeta())?
                .resolvedHomeChapmanCode ?? ""
            let subject = ResearchSubject.fromProfile(profile, snapshot: snapshot, mode: .extend, homeChapmanCode: homeChapmanCode)
            let config = ResearchConfig.extend

            let built = ResearchRunService.makePipeline(
                registry: registry,
                snapshot: snapshot,
                database: database
            )
            let pipeline = built.pipeline

            let result = await pipeline.research(subject: subject, config: config)
            currentResult = result

            // Run-level throttle-stop (owner direction 2026-07-28): when the
            // server actually pushes back (a real 429 → SearchAvailability
            // .throttled), stop the WHOLE run rather than churn the rest of the
            // queue against a source that's now parked. Trust the live signal,
            // not a guessed quota. `shouldStop` reads this after this profile.
            if result.searchOutcomes.contains(where: { $0.outcome.availability == .throttled }) {
                hitThrottle = true
            }

            let newFacts = result.confirmedFacts.count
            totalFacts += newFacts

            if newFacts == 0 {
                consecutiveNoFacts += 1
            } else {
                consecutiveNoFacts = 0
            }

            // CAMPAIGN_REVIEW_SPEC Change 4 — whole-tree runs persist through
            // the SAME single path as UI and watcher runs. Previously this
            // loop called the pipeline directly and persisted nothing but
            // unfiltered scored-record leads: no evidence rows, no run
            // record, no hypotheses, no discrepancies — an overnight
            // "Research All" campaign left nothing reviewable on disk, and
            // its ClusterReviewView hand-off applied against evidence rows
            // that were never saved. persist() also creates the
            // LeadFilter-gated leads, replacing the direct LeadStore path.
            if let db = database {
                _ = await ResearchRunService.persist(
                    result: result,
                    mode: .extend,
                    sourceInfoMap: built.sourceInfoMap,
                    registry: registry,
                    snapshot: snapshot,
                    profileID: profile.id,
                    leadToFinalise: nil,
                    db: db
                )
            }

            profilesCompleted += 1

            // Pause for user review if there are clusters to review — but a
            // backfill sweep auto-continues (it's unattended maintenance; new
            // clusters still land in Triage as usual).
            if !result.clusters.isEmpty && !autoContinueReview {
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
        if hitThrottle { return true }
        if profilesCompleted >= maxProfiles { return true }
        // Backfill finds links, not facts — the no-facts streak must not cut it
        // short before it has walked the whole flagged set.
        if !isBackfill && consecutiveNoFacts >= noFactsStreakLimit { return true }
        if let start = startTime, Date().timeIntervalSince(start) > Double(timeLimitMinutes * 60) { return true }
        return false
    }

    var stopReason: String? {
        if isCancelled { return "Cancelled by user" }
        if hitThrottle { return "FreeBMD throttled (429) — stopped to respect the server; resume when it clears." }
        if profilesCompleted >= maxProfiles { return "Max profiles reached (\(maxProfiles))" }
        if !isBackfill && consecutiveNoFacts >= noFactsStreakLimit { return "No new facts for \(noFactsStreakLimit) consecutive profiles" }
        if let start = startTime, Date().timeIntervalSince(start) > Double(timeLimitMinutes * 60) { return "Time limit reached (\(timeLimitMinutes) min)" }
        return nil
    }

    var progressSummary: String {
        "\(profilesCompleted)/\(profileQueue.count) profiles, \(totalFacts) facts"
    }

    // MARK: - Resume Persistence

    /// Save current position for resume after app restart.
    func saveProgress(to db: ProjectDatabase?) {
        guard let db else { return }
        let state: [String: Any] = [
            "currentIndex": currentIndex,
            "profilesCompleted": profilesCompleted,
            "totalFacts": totalFacts,
            "profileIDs": profileQueue.map(\.id),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            try? db.saveNegativeSearch(
                profileID: "__whole_tree__",
                sourceID: "resume_state",
                recordType: "whole_tree",
                params: json
            )
        }
    }

    /// Try to restore progress from a previous run.
    func restoreProgress(from db: ProjectDatabase?, snapshot: FamilyGraphSnapshot) -> Bool {
        guard let db else { return false }
        let searches = (try? db.loadNegativeSearches(profileID: "__whole_tree__")) ?? []
        guard searches.first(where: { $0.sourceID == "resume_state" }) != nil else { return false }

        // Resume state is stored as search params JSON — this is a pragmatic reuse
        // of the negative_searches table. A dedicated table could be added in a future migration.
        return false // Placeholder — full restore requires deserializing profile queue
    }
}
