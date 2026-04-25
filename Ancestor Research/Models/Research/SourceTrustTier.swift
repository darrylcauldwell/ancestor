import Foundation

/// How much to trust a source's data — affects convergence scoring
/// and discrepancy severity.
nonisolated enum SourceTrustTier: Int, Codable, Sendable, Comparable {
    /// Volunteer-contributed, mixed quality (FamilySearch user submissions, Find a Grave)
    case community = 1
    /// Systematic transcription of primary sources (FreeBMD, FreeCen, FreeREG)
    case transcription = 2
    /// Official primary records (CWGC, government registers)
    case primary = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
