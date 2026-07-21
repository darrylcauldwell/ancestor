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
    registry.register(FreeREGSource())

    // FamilySearch is NOT registered as a records source (owner pivot
    // 2026-07-21): the free direct sources cover UK vital-record data, so FS
    // is not a data tap. Its value is enrichment/hints + document-image
    // POINTERS via the Tree API, designed fresh against the OAuth foundation
    // in Services/Sources/FamilySearchAuth/FamilySearchOAuth.swift. The old
    // cookie records plugin was deleted (recoverable from git history).

    // Tier 4: User-added prose corpora (parish records, local-history sites).
    // Failure to resolve Application Support is non-fatal — the user just
    // loses prose-corpus retrieval for this launch, structured sources
    // continue to work. See PROSE_CORPUS_SPEC.md §6, §9.
    if let proseSource = try? ProseCorpusSource.makeForProduction() {
        registry.register(proseSource)
    }
}
