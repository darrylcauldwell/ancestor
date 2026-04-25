import Foundation

/// How strongly a value is corroborated by independent sources.
nonisolated enum ConvergenceLevel: String, Sendable, Codable, Comparable {
    /// No supporting evidence
    case uncorroborated
    /// One source only
    case singleSource
    /// 2 sources but may share lineage (both transcribe same original)
    case possible
    /// 2 independent sources with good trust scores
    case probable
    /// 3+ independent sources — high confidence
    case confirmed

    private var rank: Int {
        switch self {
        case .uncorroborated: 0
        case .singleSource: 1
        case .possible: 2
        case .probable: 3
        case .confirmed: 4
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}
