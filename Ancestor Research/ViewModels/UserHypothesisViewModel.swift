import Foundation
import Observation
import os

/// View-model for user-seeded hunches (Research pipeline,
/// Slice 4 — phase (b) Workbench UI + refuted/exhausted UX).
///
/// **This is the app-side seam the Workbench "Add a hunch" form drives
/// through, and the testable unit for Slice 4.** Submission delegates to
/// `HypothesisSeedService.submitSeed` (`requestedBy: "workbench"`) — the
/// SAME intake path the MCP `submit_hypothesis` tool uses, so validation
/// is not duplicated. Doctrine unchanged: a hunch never writes to the
/// tree; this VM only INSERTs a queued seed row and reads back the
/// engine-owned `research_hypotheses` verdicts.
///
/// The VM holds no long-lived hypothesis cache of its own beyond the
/// last `load(...)` — Workbench data is re-read on demand, matching the
/// `AppState.loadWorkbench()` pattern.
@MainActor
@Observable
final class UserHypothesisViewModel {

    private let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "UserHypothesisViewModel"
    )

    /// The open project database. Nil before a project is loaded — all
    /// operations become inert no-ops, never crashes.
    var database: ProjectDatabase?

    /// User-seeded hunches for the most recently loaded profile, already
    /// sorted for the surface: `.contradicted` first (the user
    /// asked a question; a refutation must not be buried), then
    /// `.supported`, `.inconclusive`; ties broken by most-recently
    /// tested. Populated by `load`; the view resets it to `[]` when no
    /// subject is selected. (Matches the AppState pattern of directly
    /// settable observable collections.)
    var hunches: [Hunch] = []

    /// One-shot feedback for the last submit, surfaced to the form.
    var lastSubmitResult: HypothesisSeedService.SubmitResult?
    var errorMessage: String?

    init(database: ProjectDatabase? = nil) {
        self.database = database
    }

    // MARK: - Presentation model

    /// A user hunch flattened for display: the raw hypothesis plus the
    /// derived verdict presentation and exhaustion flag. Pure
    /// value type so tests can assert the derived fields without a live
    /// database or SwiftUI.
    struct Hunch: Identifiable, Equatable, Sendable {
        let hypothesis: ResearchHypothesis
        var id: String { hypothesis.id }
        var verdict: ResearchHypothesis.Verdict { hypothesis.verdict }
        var reasoning: String { hypothesis.reasoning }
        var attempts: Int { hypothesis.attempts }
        var lastTestedAt: Date { hypothesis.lastTestedAt }
        var history: [ResearchHypothesis.Transition] { hypothesis.history }

        /// Human-facing verdict label ( vocabulary — the four
        /// user-visible states are supported / inconclusive / refuted /
        /// exhausted). "Refuted" is the user-facing word for
        /// `.contradicted`; "Exhausted" is an `.inconclusive` hunch whose
        /// ladder has no more levels to try.
        var statusLabel: String {
            switch verdict {
            case .supported: return "Supported"
            case .contradicted: return "Refuted"
            case .inconclusive: return isExhausted ? "Exhausted" : "Inconclusive"
            }
        }

        /// Ladder exhausted: every deficit level has been
        /// dispatched and none moved the verdict. Only meaningful for an
        /// unresolved (`.inconclusive`) hunch — a supported/refuted one
        /// has its answer regardless of remaining ladder budget.
        var isExhausted: Bool {
            verdict == .inconclusive
                && HypothesisEngine.isParentCandidatesExhausted(hypothesis)
        }

        /// The four hint fields, resolved from the typed payload for
        /// display. nil entries were never asserted.
        var fatherGiven: String? { payload?.fatherGiven }
        var fatherSurname: String? { payload?.fatherSurname }
        var motherGiven: String? { payload?.motherGiven }
        var motherMaidenSurname: String? { payload?.motherMaidenSurname }
        var marriageWindow: ClosedRange<Int>? { payload?.window }

        /// One-line "Bob Wheeldon × Sue" style summary of the asserted
        /// couple, for the card title.
        var coupleSummary: String {
            let father = [fatherGiven, fatherSurname]
                .compactMap { $0 }.joined(separator: " ")
            let mother = [motherGiven, motherMaidenSurname]
                .compactMap { $0 }.joined(separator: " ")
            switch (father.isEmpty, mother.isEmpty) {
            case (false, false): return "\(father) × \(mother)"
            case (false, true): return father
            case (true, false): return mother
            case (true, true): return "Parents (unnamed)"
            }
        }

        private struct Payload {
            let fatherGiven: String?
            let fatherSurname: String?
            let motherGiven: String?
            let motherMaidenSurname: String?
            let window: ClosedRange<Int>
        }

        private var payload: Payload? {
            guard case .parentCandidates(let fg, let fs, let mg, let mms, let w) = hypothesis.kind else {
                return nil
            }
            return Payload(
                fatherGiven: fg, fatherSurname: fs,
                motherGiven: mg, motherMaidenSurname: mms, window: w
            )
        }
    }

    // MARK: - Submit (phase b intake)

    /// Submit a hunch from the Workbench form. Delegates verbatim to the
    /// shared intake seam; on `.queued` the seed is materialised by the
    /// request watcher on its next poll. Returns the structured result so
    /// the caller can render "queued" vs a refusal reason. Refresh the
    /// list afterwards via `load` — the materialised verdict lands on the
    /// next watcher poll.
    @discardableResult
    func submit(
        profileID: String,
        hints: HypothesisSeedService.SeedHints
    ) -> HypothesisSeedService.SubmitResult? {
        guard let database else {
            errorMessage = "No project open."
            return nil
        }
        do {
            let result = try HypothesisSeedService.submitSeed(
                profileID: profileID,
                hints: hints,
                requestedBy: "workbench",
                db: database
            )
            lastSubmitResult = result
            switch result {
            case .queued(let seedID):
                logger.info("Workbench hunch queued: \(seedID)")
            case .refused(let reason):
                logger.info("Workbench hunch refused: \(reason.rawValue)")
            }
            return result
        } catch {
            errorMessage = "Could not save hunch: \(error.localizedDescription)"
            logger.error("submitSeed threw: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Load / list ( surface)

    /// Load the user-seeded hunches for `profileID` and sort them for the
    /// surface. Excludes user-rejected rows (they were dismissed;
    /// `loadHypotheses` filters them). Engine-origin hypotheses are
    /// filtered out — this surface is only the user's own hunches.
    func load(profileID: String) {
        guard let database else {
            hunches = []
            return
        }
        do {
            let all = try database.loadHypotheses(forProfile: profileID)
            hunches = Self.sortedForSurface(
                all.filter { $0.origin == .user }.map(Hunch.init)
            )
        } catch {
            errorMessage = "Could not load hunches: \(error.localizedDescription)"
            logger.error("loadHypotheses threw: \(error.localizedDescription)")
            hunches = []
        }
    }

    /// sort: `.contradicted` (refuted) hunches to the TOP so the
    /// user's answered-and-refuted question is never buried, then
    /// supported, then inconclusive; each group most-recently-tested
    /// first. Pure + static so tests can assert ordering directly.
    static func sortedForSurface(_ hunches: [Hunch]) -> [Hunch] {
        func rank(_ v: ResearchHypothesis.Verdict) -> Int {
            switch v {
            case .contradicted: return 0
            case .supported: return 1
            case .inconclusive: return 2
            }
        }
        return hunches.sorted { a, b in
            let ra = rank(a.verdict), rb = rank(b.verdict)
            if ra != rb { return ra < rb }
            return a.lastTestedAt > b.lastTestedAt
        }
    }

    /// The refuted (`.contradicted`) hunches — surfaced at the top of the
    /// Workbench Hunches section. Derived from the already-sorted `hunches`.
    var refutedHunches: [Hunch] { hunches.filter { $0.verdict == .contradicted } }

    /// The exhausted hunches — listed in their own section, kept rather
    /// than deleted. Nothing in the app revives one.
    var exhaustedHunches: [Hunch] { hunches.filter(\.isExhausted) }

    /// Active hunches still worth watching — neither refuted nor
    /// exhausted (supported and still-investigable inconclusive).
    var activeHunches: [Hunch] {
        hunches.filter { $0.verdict != .contradicted && !$0.isExhausted }
    }

    // MARK: - Dismiss

    /// Dismiss a hunch: flip `user_rejected = 1`. The verdict
    /// history is retained for audit — a tested-and-failed hunch is a
    /// research result worth keeping. Rejection memory then
    /// stops the engine re-dispatching it and intake refuses re-seeds.
    func dismiss(hunchID: String) {
        guard let database else { return }
        do {
            try database.rejectHypothesis(id: hunchID)
            hunches.removeAll { $0.id == hunchID }
            logger.info("Dismissed user hunch \(hunchID)")
        } catch {
            errorMessage = "Could not dismiss hunch: \(error.localizedDescription)"
            logger.error("rejectHypothesis threw: \(error.localizedDescription)")
        }
    }
}
