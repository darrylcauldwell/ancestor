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
    // FreeREG is registered under the SAME ADR-008 §Decision-2 interim-use
    // posture as its two identical-terms siblings FreeBMD/FreeCEN (all three
    // are one charity, Free UK Genealogy, under the same "front end programs…
    // strictly forbidden" terms). Owner decision 2026-07-29: this is a personal
    // research assistant streamlining a single researcher's access — tiny
    // request volumes, conservative pacing (1s) + a daily cap, every record
    // linked back to the transcribers' site, no bulk replication — so FreeREG
    // gathers data on the same interim footing as FreeBMD/FreeCEN while the
    // Free UK Genealogy permission request is pending, rather than being the
    // odd source held to a stricter link-only posture. Its rich baptism records
    // (which name BOTH parents) are a first-class research channel. The manual
    // "Search FreeREG" link-out on the profile stays as a complementary route.
    // (Reverses the 2026-07-27 link-only retirement, restoring free-trio parity.)
    registry.register(FreeREGSource())

    // Memorial inscriptions (Wishful Thinking), Chapman-templated: one on-demand
    // parish page per lookup, never a crawl (TEMPLATED_NARRATIVE_SOURCE_SPEC).
    // Terms permit personal research; the firewall keeps verbatim prose out of
    // the Publisher. Only fires when a subject resolves to a parish + county.
    registry.register(MemorialInscriptionRecordSource())

    // FamilySearch is deliberately NOT registered as a record source.
    // Owner decision 2026-08-07, confirmed by FamilySearch Developer Support
    // (2026-08-05): historical-records collection access is permanently
    // unavailable to third-party applications through the API — not a beta
    // limitation, not a certifiable tier — for legal reasons (what a third
    // party may display vs what FamilySearch may). The Beta "records ARE
    // granted / ~21k hits" result that once justified registering it here was a
    // beta-data mirage; production returns nothing (every `p_…` persona ARK
    // 404s on the production host). FamilySearch's sanctioned role for us is a
    // Family Tree READ/WRITE integration (the write leg + OAuth stay), never a
    // records tap. The record engine stands on the six free sources above.
    // `FamilySearchSource` and its parser remain in the tree only as reused
    // internals (GEDCOM X decode); nothing wires them into the pipeline.

    // Tier 4: User-added prose corpora (parish records, local-history sites).
    // Failure to resolve Application Support is non-fatal — the user just
    // loses prose-corpus retrieval for this launch, structured sources
    // continue to work. See PROSE_CORPUS_SPEC.md §6, §9.
    if let proseSource = try? ProseCorpusSource.makeForProduction() {
        registry.register(proseSource)
    }
}
