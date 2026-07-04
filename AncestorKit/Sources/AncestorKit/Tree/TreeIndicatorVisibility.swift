import Foundation

// MARK: - Indicator visibility (M16.11)

/// Pure helpers behind the "Show research indicators" Settings toggle.
/// Centralised so unit tests can verify each indicator type's gate
/// independently of the Canvas drawing code.
public nonisolated enum TreeIndicatorVisibility {
    /// Focus ring fires only when the profile is in the active focus set
    /// AND the user hasn't disabled research indicators.
    public static func focusRingVisible(
        nodeID: String,
        activeFocusSet: FocusSet?,
        showResearchIndicators: Bool
    ) -> Bool {
        guard showResearchIndicators else { return false }
        return activeFocusSet?.profileIDs.contains(nodeID) ?? false
    }

    /// Note dot fires only when there's at least one note AND the user
    /// hasn't disabled indicators.
    public static func noteVisible(hasNote: Bool, showResearchIndicators: Bool) -> Bool {
        showResearchIndicators && hasNote
    }

    /// Open-question marker — same rule as note dot.
    public static func questionVisible(hasOpenQuestion: Bool, showResearchIndicators: Bool) -> Bool {
        showResearchIndicators && hasOpenQuestion
    }

    /// Tentative-fact tilde — same rule.
    public static func tentativeVisible(hasTentativeFact: Bool, showResearchIndicators: Bool) -> Bool {
        showResearchIndicators && hasTentativeFact
    }
}
