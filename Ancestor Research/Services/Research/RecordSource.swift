import Foundation

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

    func search(_ query: RecordQuery) async -> SourceQueryResult
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
