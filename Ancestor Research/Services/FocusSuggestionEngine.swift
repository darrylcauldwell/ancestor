import Foundation

/// Surface profiles the user has touched recently as candidates for a
/// focus set (DESIGN.md §7.7.2). Drives the "Quick add" row in the focus
/// composer — suggestions are never auto-added, the user taps to accept.
///
/// Pure logic, nonisolated — no DB access. Callers pass the full
/// transaction list and we filter by completion timestamp.
nonisolated enum FocusSuggestionEngine {

    /// Profile IDs touched by transactions completed within the last
    /// `windowMinutes`, deduplicated and ordered most-recent first.
    ///
    /// "Touched" means a profile mentioned by any of the transaction's
    /// associated kinds — adds, family additions, edits, soft-deletes,
    /// dispute resolutions. Pure structural housekeeping (importGEDCOM,
    /// refreshWikiTree, undo, addRelationship/removeRelationship, manualEdit
    /// without an attached profile in the kind itself) is excluded because
    /// `TransactionKind` doesn't carry the profile ID for those cases —
    /// the underlying `field_changes` rows do, but pulling them in would
    /// require DB access. The current heuristic catches the common
    /// "user is actively working on these people" pattern.
    static func suggestRecentlyActive(
        transactions: [Transaction],
        windowMinutes: Int = 30,
        referenceDate: Date = Date()
    ) -> [String] {
        let windowSeconds = TimeInterval(windowMinutes * 60)
        let cutoff = referenceDate.addingTimeInterval(-windowSeconds)

        // Most-recent-first iteration — guarantees the dedup keeps the
        // freshest occurrence of each profile ID.
        let recent = transactions
            .filter { $0.completedAt >= cutoff && $0.completedAt <= referenceDate }
            .sorted { $0.completedAt > $1.completedAt }

        var seen = Set<String>()
        var ordered: [String] = []
        for transaction in recent {
            for profileID in profileIDs(from: transaction.kind) where !seen.contains(profileID) {
                seen.insert(profileID)
                ordered.append(profileID)
            }
        }
        return ordered
    }

    /// Pull profile IDs out of a `TransactionKind`. Returns an empty array
    /// for kinds that don't carry profile IDs in the kind itself.
    private static func profileIDs(from kind: TransactionKind) -> [String] {
        switch kind {
        case .addProfile(let profileID):
            return [profileID]
        case .addFamily(let profileIDs):
            return profileIDs
        case .softDelete(let profileIDs):
            return profileIDs
        case .resolveDispute(_, let profileID):
            return [profileID]
        case .importGEDCOM,
             .refreshWikiTree,
             .addRelationship,
             .removeRelationship,
             .manualEdit,
             .undo:
            return []
        }
    }
}
