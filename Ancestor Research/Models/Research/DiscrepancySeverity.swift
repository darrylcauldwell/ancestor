import Foundation

/// How serious a discrepancy between a source and the tree is.
nonisolated enum DiscrepancySeverity: String, Sendable, Codable, Comparable {
    /// No actual discrepancy
    case none
    /// Trivial difference (census birthplace varies between enumerations)
    case note
    /// More precise version of existing value ("1834" → "15 Mar 1834")
    case refinement
    /// Genuine disagreement, unclear which is right
    case conflict
    /// Existing value is almost certainly wrong (primary source disagrees significantly)
    case correction

    private var rank: Int {
        switch self {
        case .none: 0
        case .note: 1
        case .refinement: 2
        case .conflict: 3
        case .correction: 4
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}
