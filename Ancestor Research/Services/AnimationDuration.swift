import Foundation

/// Pure helper for the reduce-motion duration logic.
///
/// The `accessibilityReduceMotion` environment value lives in SwiftUI, but the
/// arithmetic of "use 0 when reduce-motion is on, otherwise the requested
/// value" is pure and worth unit-testing in isolation. View code should pull
/// the environment flag and forward it here, rather than branching inline.
nonisolated enum AnimationDuration {
    /// Returns `0` (instant) when reduce-motion is on; otherwise the requested
    /// duration. Negative requests are clamped to zero — animation durations
    /// are non-negative by definition, and a negative value here almost
    /// certainly indicates a caller bug.
    static func duration(_ requested: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        return max(0, requested)
    }
}
