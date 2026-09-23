import Foundation

/// Where a source's data comes from — used by the convergence engine to decide
/// whether two sources agreeing is independent corroboration or the same
/// original counted twice.
///
/// Two FreeBMD entries from different districts are the SAME lineage: both
/// transcribe the GRO indexes, so they corroborate each other no more than one
/// does alone. Independence requires transcribing DIFFERENT originals.
public nonisolated enum SourceLineage: Hashable, Codable, Sendable {
    /// Direct transcription of a named primary source (e.g. FreeBMD → GRO indexes).
    /// Two sources carrying the same name are parallel transcriptions, not
    /// independent witnesses.
    case independentTranscription(of: String)
    /// A transcription whose original we cannot name — an aggregator spanning
    /// many collections, where the record at hand may transcribe the GRO
    /// indexes, a parish register, a census, or something else entirely.
    ///
    /// Deliberately NOT counted toward independent corroboration: we cannot
    /// show it is distinct from any other transcription, and claiming
    /// independence we cannot demonstrate is how a cluster reaches the
    /// auto-promote gate on one original counted twice. Under-counting costs
    /// throughput; over-counting writes wrong genealogy unattended.
    case unattributedTranscription
    /// Community-edited with mixed provenance (Find a Grave)
    case communityEdited
    /// Official primary record (CWGC casualties, government registers)
    case primaryRecord
    /// Derived from other known sources
    case derivedFrom(Set<String>)
}
