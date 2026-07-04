import Foundation

/// One hit returned from a cross-entity workbench search. Each case wraps
/// the underlying entity so callers can both render a list row and route
/// taps to the right detail view.
public nonisolated enum WorkbenchSearchResult: Identifiable, Sendable, Hashable {
    case note(WorkbenchNote)
    case question(OpenQuestion)
    case hypothesis(Hypothesis)
    case focusSet(FocusSet)

    /// Stable id so SwiftUI's ForEach/Identifiable doesn't fight us.
    /// Prefixed by kind so a note and a question with the same UUID — vanishingly
    /// rare but possible — don't collide.
    public var id: String {
        switch self {
        case .note(let n): return "note:\(n.id.uuidString)"
        case .question(let q): return "question:\(q.id.uuidString)"
        case .hypothesis(let h): return "hypothesis:\(h.id.uuidString)"
        case .focusSet(let f): return "focus:\(f.id.uuidString)"
        }
    }

    /// Result-type label used by the SearchView grouping.
    public var kindLabel: String {
        switch self {
        case .note: return "Notes"
        case .question: return "Questions"
        case .hypothesis: return "Hypotheses"
        case .focusSet: return "Focus sets"
        }
    }

    /// Sort order so the grouped list reads naturally — notes/questions/
    /// hypotheses lead, focus sets land at the bottom.
    public var groupOrder: Int {
        switch self {
        case .note: return 0
        case .question: return 1
        case .hypothesis: return 2
        case .focusSet: return 3
        }
    }

    /// SF Symbol shown next to the row.
    public var systemImage: String {
        switch self {
        case .note: return "note.text"
        case .question: return "questionmark.bubble"
        case .hypothesis: return "lightbulb"
        case .focusSet: return "scope"
        }
    }

    /// Headline shown on the row.
    public var title: String {
        switch self {
        case .note(let n): return n.tag.displayName
        case .question(let q): return q.text
        case .hypothesis(let h): return h.claimSummary
        case .focusSet(let f): return f.displayTitle
        }
    }

    /// Body text shown under the headline. May be empty.
    public var snippet: String {
        switch self {
        case .note(let n): return n.content
        case .question(let q): return q.triedSources ?? q.resolution ?? ""
        case .hypothesis(let h): return h.reasoning
        case .focusSet(let f):
            return "\(f.profileIDs.count) profile\(f.profileIDs.count == 1 ? "" : "s")"
        }
    }
}
