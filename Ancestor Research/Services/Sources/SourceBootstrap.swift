import Foundation

/// Register all available record sources.
/// Called once at app launch. Each source is an independent actor or struct.
/// Adding a new source: create its file in Services/Sources/, then add one line here.
@MainActor
func bootstrapSources(registry: SourceRegistry) {
    // Tier 1: Stateless (no auth, no session)
    registry.register(CWGCSource())
    registry.register(FindAGraveSource())
    registry.register(ProbateSource())
    registry.register(WirksworthSource())

    // Tier 2: CSRF token (session per search batch)
    registry.register(FreeBMDSource())
    registry.register(FreeCenSource())
    registry.register(FreeREGSource())

    // Future sources — uncomment when implemented:
    // registry.register(FamilySearchSource())  // Only when OAuth is available
}
