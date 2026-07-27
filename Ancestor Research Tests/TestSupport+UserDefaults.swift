import Foundation

extension UserDefaults {
    /// A fresh, empty `UserDefaults` suite for hermetic tests. Registry-driven
    /// tests build a `SourceRegistry(defaults: .ephemeralSuite())` so the
    /// developer's real app preferences — in particular a disabled `freebmd`
    /// (over FreeBMD's rate limits) persisted in `disabledSourceIDs` — never
    /// leak into the test host and silently drop a source from dispatch.
    /// Root cause of the machine-specific ScopeContract/StagedPipeline reds; see
    /// reference_main_red_change5_tests. Each call returns an independent suite,
    /// so tests that toggle enablement can't interfere under parallel execution.
    static func ephemeralSuite() -> UserDefaults {
        let name = "dev.dreamfold.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
