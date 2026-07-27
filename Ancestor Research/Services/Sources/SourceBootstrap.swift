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

    // Tier 2: CSRF token (session per search batch)
    registry.register(FreeBMDSource())
    registry.register(FreeCenSource())
    // FreeREG is DELIBERATELY NOT registered (2026-07-27, owner decision): its
    // terms forbid programmatic searching ("front-end programs strictly
    // forbidden", permission pending ADR-008), so the app must not scrape it.
    // Its rich baptism records (which name both parents) stay reachable via the
    // human-permitted route — the "Search FreeREG" link-out on the profile
    // (SharedProfileLayout). The `freereg` source ID is retained in the trust-tier
    // registry for existing FreeREG citations. FreeREGSource.swift is kept for
    // reference / possible re-enable if Free UK Genealogy grants permission.

    // FamilySearch historical records over the official OAuth Platform API
    // (owner 2026-07-21: records ARE granted at our Beta tier — live-verified,
    // ~21k hits for a real subject — so the pivot's "records are walled"
    // premise was empirically false). Search + score in memory; persistence is
    // §16 pointer-only (ARKs + our verdicts, never record content/images).
    // Beta (non-production) only until production certification.
    registry.register(FamilySearchSource())

    // Tier 4: User-added prose corpora (parish records, local-history sites).
    // Failure to resolve Application Support is non-fatal — the user just
    // loses prose-corpus retrieval for this launch, structured sources
    // continue to work. See PROSE_CORPUS_SPEC.md §6, §9.
    if let proseSource = try? ProseCorpusSource.makeForProduction() {
        registry.register(proseSource)
    }
}
