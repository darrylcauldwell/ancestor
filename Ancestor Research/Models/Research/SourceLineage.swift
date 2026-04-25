import Foundation

/// Where a source's data comes from — used by the convergence engine
/// to determine whether two sources agreeing is independent corroboration.
/// Two FreeBMD entries from different districts are the SAME lineage
/// (both transcribe GRO indexes). FreeBMD + FamilySearch are DIFFERENT lineages.
nonisolated enum SourceLineage: Hashable, Codable, Sendable {
    /// Direct transcription of a known primary source (e.g., FreeBMD → GRO indexes)
    case independentTranscription(of: String)
    /// Community-edited with mixed provenance (FamilySearch, Find a Grave)
    case communityEdited
    /// Official primary record (CWGC casualties, government registers)
    case primaryRecord
    /// Derived from other known sources
    case derivedFrom(Set<String>)
}
