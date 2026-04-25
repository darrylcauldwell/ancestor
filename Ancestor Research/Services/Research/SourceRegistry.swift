import SwiftUI

/// Central registry of all available record sources.
@MainActor @Observable
final class SourceRegistry {
    private(set) var sources: [String: any RecordSource] = [:]

    @ObservationIgnored
    @AppStorage("disabledSourceIDs") private var disabledSourceIDsRaw: String = ""

    private var disabledSourceIDs: Set<String> {
        get { Set(disabledSourceIDsRaw.split(separator: ",").map(String.init)) }
        set { disabledSourceIDsRaw = newValue.sorted().joined(separator: ",") }
    }

    func register(_ source: any RecordSource) {
        sources[source.sourceID] = source
    }

    func setEnabled(sourceID: String, enabled: Bool) {
        var disabled = disabledSourceIDs
        if enabled { disabled.remove(sourceID) } else { disabled.insert(sourceID) }
        disabledSourceIDs = disabled
    }

    func source(for id: String) -> (any RecordSource)? {
        sources[id]
    }

    /// Enabled sources that provide the given record type, optionally filtered by region.
    func enabledSources(for recordType: RecordType, region: Region? = nil) -> [any RecordSource] {
        sources.values.filter { source in
            !disabledSourceIDs.contains(source.sourceID)
            && source.recordTypes.contains(recordType)
            && (region == nil || source.coverageRegions.isEmpty || source.coverageRegions.contains(region!))
        }
    }

    /// All enabled sources.
    func enabledSources() -> [any RecordSource] {
        sources.values.filter { !disabledSourceIDs.contains($0.sourceID) }
    }

    /// All sources including disabled (for Settings UI).
    func allSources() -> [any RecordSource] {
        Array(sources.values)
    }

    func isEnabled(_ sourceID: String) -> Bool {
        !disabledSourceIDs.contains(sourceID)
    }

    /// Group sources by data lineage — used by convergence engine.
    func sourcesByLineage() -> [SourceLineage: [any RecordSource]] {
        Dictionary(grouping: Array(sources.values), by: \.dataLineage)
    }
}
