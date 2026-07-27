import SwiftUI

/// Central registry of all available record sources.
@MainActor @Observable
final class SourceRegistry {
    private(set) var sources: [String: any RecordSource] = [:]

    /// Backing store for the enabled/disabled source preferences. Defaults to
    /// `.standard` — the app's real preferences, so production behaviour is
    /// unchanged. Tests inject a fresh ephemeral suite so a developer's
    /// disabled-source preference (e.g. a disabled FreeBMD, over its rate
    /// limits) never leaks into the test host and silently drops a source from
    /// dispatch. Replaces the former `@AppStorage`, which is hardwired to
    /// `.standard` and cannot be isolated. Keys are unchanged
    /// ("disabledSourceIDs" / "enabledLocalPluginIDs").
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // General sources are opt-OUT (default enabled). Explicit disable persists
    // under "disabledSourceIDs". Local plugins are opt-IN under
    // "enabledLocalPluginIDs" — retired by SOURCE_WEIGHTING Change 0; a persisted
    // enabled ID with no registered source is simply inert.
    private var disabledSourceIDs: Set<String> {
        get { Set((defaults.string(forKey: "disabledSourceIDs") ?? "").split(separator: ",").map(String.init)) }
        set { defaults.set(newValue.sorted().joined(separator: ","), forKey: "disabledSourceIDs") }
    }

    private var enabledLocalPluginIDs: Set<String> {
        get { Set((defaults.string(forKey: "enabledLocalPluginIDs") ?? "").split(separator: ",").map(String.init)) }
        set { defaults.set(newValue.sorted().joined(separator: ","), forKey: "enabledLocalPluginIDs") }
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
