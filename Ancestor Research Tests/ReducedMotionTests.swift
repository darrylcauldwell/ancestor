import Testing
@testable import Ancestor_Research

/// M24 — Tests for the reduce-motion duration helper.
///
/// SwiftUI environment-driven rendering is fragile to test directly, so we
/// confine the tests to the pure arithmetic helper. View call sites pull the
/// `accessibilityReduceMotion` environment value and forward it here.
struct ReducedMotionTests {
    @Test func animationDurationZeroWhenReduceMotionOn() {
        #expect(AnimationDuration.duration(0.35, reduceMotion: true) == 0)
        #expect(AnimationDuration.duration(1.5, reduceMotion: true) == 0)
        #expect(AnimationDuration.duration(0.0, reduceMotion: true) == 0)
    }

    @Test func animationDurationUnchangedWhenReduceMotionOff() {
        #expect(AnimationDuration.duration(0.35, reduceMotion: false) == 0.35)
        #expect(AnimationDuration.duration(1.5, reduceMotion: false) == 1.5)
        #expect(AnimationDuration.duration(0.15, reduceMotion: false) == 0.15)
    }

    @Test func animationDurationHandlesNegativeAndZeroRequests() {
        // Defensive: a negative request is almost certainly a caller bug, but
        // it must never propagate as a negative animation duration. Clamp to
        // zero in both modes.
        #expect(AnimationDuration.duration(-1.0, reduceMotion: false) == 0)
        #expect(AnimationDuration.duration(-0.001, reduceMotion: false) == 0)
        #expect(AnimationDuration.duration(-1.0, reduceMotion: true) == 0)
        #expect(AnimationDuration.duration(0.0, reduceMotion: false) == 0)
    }
}
