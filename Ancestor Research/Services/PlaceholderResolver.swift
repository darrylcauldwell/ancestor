import Foundation

/// Detects placeholder profiles (those created via the sibling shortcut, or
/// otherwise marked `NameStatus.placeholder`) so the UI can prompt the user
/// to replace them with real entries when the information becomes available.
nonisolated enum PlaceholderResolver {

    /// One placeholder along with its resolution context.
    struct Suggestion: Sendable, Identifiable {
        var id: String { placeholderID }
        let placeholderID: String
        /// Profiles whose only link to this placeholder is via parent edges —
        /// they'd benefit if the placeholder were replaced with a real person.
        let affectedChildIDs: [String]
    }

    /// Find all placeholder profiles in the snapshot and the children that
    /// would be re-parented if each placeholder is replaced.
    static func placeholders(in snapshot: FamilyGraphSnapshot) -> [Suggestion] {
        snapshot.profiles.values
            .filter { $0.resolvedAttributes.nameStatus == .placeholder }
            .map { profile in
                let children = snapshot.childrenOf(profile.id).map(\.id)
                return Suggestion(placeholderID: profile.id, affectedChildIDs: children)
            }
            .sorted { $0.placeholderID < $1.placeholderID }
    }

    /// Returns the placeholder relevant to a given anchor profile, if any.
    /// Used when the user adds real parents — we look up whether the anchor
    /// already has a placeholder parent, and if so suggest replacing it.
    static func placeholderParent(of anchorID: String, in snapshot: FamilyGraphSnapshot) -> String? {
        for parent in snapshot.parentsOf(anchorID) {
            if parent.resolvedAttributes.nameStatus == .placeholder {
                return parent.id
            }
        }
        return nil
    }
}
