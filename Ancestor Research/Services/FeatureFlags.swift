import Foundation

/// Compile-time feature flags. Today this only gates the Field Researcher
/// (Claude API integration). Using a flag rather than a runtime toggle so
/// App Store archives can ship without any reference to api.anthropic.com,
/// the API-key entry UI, or the Field Researcher service code.
///
/// The flag direction is **negative** by default — `FIELD_RESEARCHER_DISABLED`
/// is set only when archiving for the App Store. Existing Debug, TestFlight,
/// and CI builds compile unchanged.
///
/// To produce an App-Store-clean archive:
///   xcodebuild archive ... \
///     SWIFT_ACTIVE_COMPILATION_CONDITIONS="FIELD_RESEARCHER_DISABLED"
///
/// Or add `FIELD_RESEARCHER_DISABLED` to a dedicated archive scheme's
/// active compilation conditions.
nonisolated enum FeatureFlags {

    /// `true` when the Field Researcher (Claude API) feature is compiled in.
    /// `false` for App Store archives. UI call sites either read this flag
    /// (when only the section is hidden) or use `#if` directly (when the
    /// referenced types must not be compiled at all).
    static let fieldResearcherEnabled: Bool = {
#if FIELD_RESEARCHER_DISABLED
        return false
#else
        return true
#endif
    }()
}
