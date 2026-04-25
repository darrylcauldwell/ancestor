import Foundation

/// How directly a source's evidence relates to the original event.
/// A birth certificate is primary (recorded at the event).
/// A census age is secondary (reported years later by someone who may not know).
/// A Find a Grave entry is derivative (compiled from other sources).
///
/// Three derivative sources agreeing is weaker than one primary source.
/// The convergence engine uses this to cap confidence levels.
nonisolated enum EvidenceDirectness: Int, Codable, Sendable, Comparable {
    /// Recorded contemporaneously by someone with direct knowledge
    /// (parish register at a baptism, death certificate by a registrar)
    case primary = 3

    /// Recorded by someone reporting indirect knowledge
    /// (census age reported by household head, FreeBMD index transcribed from GRO)
    case directTranscription = 2

    /// Compiled or summarised without seeing the primary record
    /// (Find a Grave volunteer entries, FamilySearch user submissions)
    case derivative = 1

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
