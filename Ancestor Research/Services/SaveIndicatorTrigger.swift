import Foundation

/// Predicate for the one-time "Your progress is saved automatically." toast
/// (DESIGN.md §7.5.15, M17.5). Shown after the user has performed a few
/// manual actions in a small manual project so they know nothing is lost
/// when they close the window — manual entry users in particular tend to
/// look for an explicit Save button.
///
/// Pure, no I/O — wired into `AppState` after each manual mutation and
/// unit-tested directly.
nonisolated enum SaveIndicatorTrigger {

    /// Fire the toast at the third recorded manual transaction. Anything
    /// less and the user might not yet have committed to using the app;
    /// anything more and we've waited too long.
    static let triggerThreshold: Int = 3

    /// Whether the toast should be surfaced *right now*.
    /// - `isSmallManualProject`: the project is in manual-guidance mode.
    /// - `hasShown`: the toast has already fired once for this user.
    /// - `transactionCount`: count of manual mutations in this project.
    static func shouldShow(
        isSmallManualProject: Bool,
        hasShown: Bool,
        transactionCount: Int
    ) -> Bool {
        isSmallManualProject
            && !hasShown
            && transactionCount >= triggerThreshold
    }
}
