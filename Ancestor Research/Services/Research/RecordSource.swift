import Foundation

/// Whether a source is broadly applicable or hyper-local.
///
/// - `general`: bundled with the core app, useful to any UK researcher.
///   Default-enabled. May expose a local/national scope axis.
/// - `localPlugin`: niche source covering a small geographic area or
///   narrow record type (e.g. Wirksworth Genealogy Project). Default-disabled.
///   Users opt in only when their tree intersects the source's area.
///   Always-local by definition — the scope axis does not apply.
///
/// Distinct from `SourceCategory` in `SourceTierRegistry.swift`, which
/// classifies citation provenance (official archive, volunteer transcription,
/// etc). This type classifies distribution model (bundled-general vs plugin).
nonisolated enum SourceKind: String, Codable, Sendable {
    case general
    case localPlugin
}

/// The single protocol all sources conform to.
/// Not actor-bound — stateless sources are structs, stateful sources are actors.
/// Both are Sendable.
protocol RecordSource: Sendable {
    nonisolated var sourceID: String { get }
    nonisolated var displayName: String { get }
    nonisolated var recordTypes: Set<RecordType> { get }
    nonisolated var coverageYearRange: ClosedRange<Int>? { get }
    nonisolated var coverageRegions: Set<Region> { get }
    nonisolated var dataLineage: SourceLineage { get }
    nonisolated var trustTier: SourceTrustTier { get }
    nonisolated var evidenceDirectness: EvidenceDirectness { get }
    nonisolated var tosStatus: SourceToSStatus { get }
    nonisolated var kind: SourceKind { get }
    /// Long-form "what is this source" name for Settings UI. The
    /// short canonical `displayName` is what citations and activity-feed
    /// summaries use; `descriptiveName` is for educating the user about
    /// what an acronym actually covers. Defaults to `displayName`.
    nonisolated var descriptiveName: String { get }

    func search(_ query: RecordQuery) async -> SourceQueryResult
}

extension RecordSource {
    /// Default kind — most sources are general-purpose. Local plugins override.
    nonisolated var kind: SourceKind { .general }

    /// Default descriptive name = canonical display name. Sources whose
    /// canonical name is an acronym (CWGC, FreeBMD, FreeCen, FreeREG)
    /// override to spell it out for the Settings list.
    nonisolated var descriptiveName: String { displayName }
}

/// Sources that can fetch full detail for a specific record.
protocol DetailFetchingSource: RecordSource {
    func fetchDetail(recordID: String) async -> SourceQueryResult
}

/// Sources that accept external credentials.
protocol AuthenticatingSource: RecordSource {
    nonisolated var credentialLabel: String { get }
    func setCredential(_ value: String) async
    func clearCredentials() async
}
