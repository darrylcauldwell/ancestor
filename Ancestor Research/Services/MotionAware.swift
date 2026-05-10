import SwiftUI

/// Reduce-motion-aware animation modifier.
///
/// When the user has "Reduce motion" enabled in System Settings →
/// Accessibility, animations are dropped (set to `nil`) so movement is
/// instantaneous and won't trigger vestibular issues. This wraps the common
/// `.animation(_:value:)` pattern with the environment-driven gate so call
/// sites stay short and forget-proof.
///
/// Usage:
/// ```swift
/// someView.motionAware(.easeOut(duration: 0.15), value: popoverID)
/// ```
extension View {
    /// Apply an animation only when the user hasn't requested reduced motion.
    /// Wraps `.animation(_:value:)` with the environment-driven gate.
    /// Defaults to MainActor isolation (the project default) because the
    /// underlying `MotionAwareModifier` reads the SwiftUI environment.
    @ViewBuilder
    func motionAware<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionAwareModifier(animation: animation, value: value))
    }
}

@MainActor
private struct MotionAwareModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
