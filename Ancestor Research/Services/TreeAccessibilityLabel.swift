import Foundation

/// Pure helpers that build VoiceOver-friendly strings for tree-canvas nodes.
///
/// Canvas drawings are opaque to assistive tech, so M24 layers an accessibility
/// element over each visible profile. The label and hint built here are what
/// VoiceOver speaks for that element. Centralised so they remain testable
/// without spinning up SwiftUI.
nonisolated enum TreeAccessibilityLabel {

    /// Build the `accessibilityLabel` string for a tree node.
    ///
    /// Examples (with displayName "Mary Smith"):
    /// - both years: "Mary Smith, born 1842, died 1910, 5 of 7 facts"
    /// - birth only, living: "Mary Smith, born 1842, living, 3 of 7 facts"
    /// - birth only: "Mary Smith, born 1842, 4 of 7 facts"
    /// - no dates: "Mary Smith, 2 of 7 facts"
    /// - no name: "Unknown profile, 0 of 7 facts"
    static func nodeAccessibilityLabel(
        profile: Profile,
        completeness: ProfileCompleteness?
    ) -> String {
        var parts: [String] = []
        let name = profile.displayName.trimmingCharacters(in: .whitespaces)
        parts.append(name.isEmpty ? "Unknown profile" : name)

        if let by = profile.birthDate?.bestYear {
            parts.append("born \(by)")
        }
        if let dy = profile.deathDate?.bestYear {
            parts.append("died \(dy)")
        } else if let comp = completeness,
                  comp.potentiallyLiving,
                  profile.birthDate != nil {
            parts.append("living")
        }

        if let comp = completeness {
            parts.append("\(comp.score) of \(comp.maximum) facts")
        }

        return parts.joined(separator: ", ")
    }

    /// VoiceOver hint paired with `nodeAccessibilityLabel(...)`. Stable string
    /// describing what activating the node will do — kept short because hints
    /// are spoken after a brief pause.
    static let nodeAccessibilityHint: String =
        "Double tap to select. Press Space to inspect, Return to focus."
}
