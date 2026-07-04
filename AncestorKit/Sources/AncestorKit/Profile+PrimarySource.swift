import Foundation

/// First-listed source across any field on a profile. Used by
/// `SourceDefaults` so adding a relative of an existing person can
/// inherit that person's primary source rather than always defaulting
/// to `.manualMemory`.
nonisolated extension Profile {
    public var primarySource: SourceOrigin? {
        sources.values.first?.first?.origin
    }
}
