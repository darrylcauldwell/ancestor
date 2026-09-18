import Foundation

/// An ARBITRARY source from any field on this profile — `sources` is a
/// dictionary, so `values.first` has no defined order and this can return a
/// different origin between runs. Callers treat it as a hint, never as
/// identity. (Making it deterministic is backlog `#CMT2`.) Used by
/// `SourceDefaults` so adding a relative of an existing person can
/// inherit that person's primary source rather than always defaulting
/// to `.manualMemory`.
nonisolated extension Profile {
    public var primarySource: SourceOrigin? {
        sources.values.first?.first?.origin
    }
}
