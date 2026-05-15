import SwiftUI

/// Central registry of all available record sources.
@MainActor @Observable
final class SourceRegistry {
    private(set) var sources: [String: any RecordSource] = [:]

    // General sources are opt-OUT (default enabled). Explicit disable persists here.
    @ObservationIgnored
    @AppStorage("disabledSourceIDs") private var disabledSourceIDsRaw: String = ""

    // Local plugins are opt-IN (default disabled). Explicit enable persists here.
    // Default contains "wirksworth" so the previously-bundled local plugin remains
    // available to existing trees without the user having to re-enable it.
    @ObservationIgnored
    @AppStorage("enabledLocalPluginIDs") private var enabledLocalPluginIDsRaw: String = "wirksworth"

    private var disabledSourceIDs: Set<String> {
        get { Set(disabledSourceIDsRaw.split(separator: ",").map(String.init)) }
        set { disabledSourceIDsRaw = newValue.sorted().joined(separator: ",") }
    }

    private var enabledLocalPluginIDs: Set<String> {
        get { Set(enabledLocalPluginIDsRaw.split(separator: ",").map(String.init)) }
        set { enabledLocalPluginIDsRaw = newValue.sorted().joined(separator: ",") }
    }

    func register(_ source: any RecordSource) {
        sources[source.sourceID] = source
    }

    func setEnabled(sourceID: String, enabled: Bool) {
        guard let source = sources[sourceID] else { return }
        switch source.kind {
        case .general:
            var disabled = disabledSourceIDs
            if enabled { disabled.remove(sourceID) } else { disabled.insert(sourceID) }
            disabledSourceIDs = disabled
        case .localPlugin:
            var enabledSet = enabledLocalPluginIDs
            if enabled { enabledSet.insert(sourceID) } else { enabledSet.remove(sourceID) }
            enabledLocalPluginIDs = enabledSet
        }
    }

    func source(for id: String) -> (any RecordSource)? {
        sources[id]
    }

    /// Enabled sources that provide the given record type, optionally filtered by region.
    ///
    /// The region filter is **permissive**: false positives produce empty queries
    /// (cheap); false negatives silently exclude whole sources (the bug we used
    /// to have where `.englandAndWales != .county("Derbyshire")` killed every
    /// UK source for any county-tagged profile). Region overlap uses
    /// `Region.overlaps(_:)`, which knows the hierarchy.
    func enabledSources(for recordType: RecordType, region: Region? = nil) -> [any RecordSource] {
        sources.values.filter { source in
            guard isEnabled(source.sourceID) else { return false }
            guard source.recordTypes.contains(recordType) else { return false }
            // No subject region — no filter
            guard let region else { return true }
            // No declared coverage — assume worldwide
            if source.coverageRegions.isEmpty { return true }
            return source.coverageRegions.contains(where: { $0.overlaps(region) })
        }
    }

    /// All enabled sources.
    func enabledSources() -> [any RecordSource] {
        sources.values.filter { isEnabled($0.sourceID) }
    }

    /// All sources including disabled (for Settings UI).
    func allSources() -> [any RecordSource] {
        Array(sources.values)
    }

    func isEnabled(_ sourceID: String) -> Bool {
        guard let source = sources[sourceID] else { return false }
        switch source.kind {
        case .general:    return !disabledSourceIDs.contains(sourceID)
        case .localPlugin: return enabledLocalPluginIDs.contains(sourceID)
        }
    }

    /// Group sources by data lineage — used by convergence engine.
    func sourcesByLineage() -> [SourceLineage: [any RecordSource]] {
        Dictionary(grouping: Array(sources.values), by: \.dataLineage)
    }
}
