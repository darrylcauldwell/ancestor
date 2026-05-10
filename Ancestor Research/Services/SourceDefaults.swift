import Foundation

/// Pure helper that picks a sensible default `SourceOrigin` for a manual
/// entry based on the user's context (M16.5, DESIGN.md §7.5.9).
///
/// Without this, every manual entry defaults to `.manualMemory` regardless
/// of how the data is actually being captured — which weakens the source
/// audit trail. With it, transcribing a census defaults to `.manualRecord`,
/// adding a sibling can inherit from an existing sibling's source, etc.
nonisolated enum SourceDefaults {

    /// Pick a default source for a new profile or relationship based on
    /// the entry context. Census-mode short-circuits to `.manualRecord`.
    static func defaultSource(
        context: EntryContext,
        censusMode: Bool = false
    ) -> SourceOrigin {
        if censusMode { return .manualRecord }

        switch context {
        case .homePerson:
            return .manualMemory
        case .grandparent:
            return .manualMemory
        case .relativeOf(_, let primarySource):
            // If we know the existing relative's primary source AND it's not
            // a structured external import, inherit it. For external imports
            // (gedcom/wikitree) the manual default is more honest — the new
            // person isn't from that import.
            guard let source = primarySource, source.isManual else {
                return .manualMemory
            }
            return source
        case .sibling(_, let inherited):
            return inherited ?? .manualMemory
        case .unknown:
            return .manualMemory
        }
    }
}

/// Why is the user adding this person? Drives the source default and
/// (eventually) the source-attribution prompt.
nonisolated enum EntryContext: Sendable {
    /// Step 1 of the wizard — the user is themselves.
    case homePerson

    /// Adding a relative attached to an existing profile. The optional
    /// `primarySource` is the existing profile's first-listed source for
    /// any field; nil if unknown.
    case relativeOf(profileID: String, primarySource: SourceOrigin?)

    /// Adding via the sibling shortcut. The optional `inherited` is the
    /// existing sibling's source if we want the new sibling to match.
    case sibling(of: String, inherited: SourceOrigin?)

    /// Step 3a/3b of the wizard — grandparents typically come from a
    /// parent's memory. Caller may attach a free-text "from whom?" note.
    case grandparent

    /// Catch-all when no context is available.
    case unknown
}
