# Source Weighting — staged dispatch, free-sources-first

**Status: SHIPPED 2026-07-15 — one deferred residue (Change 6).** The staged-dispatch
design (free-sources-first, FS on-miss), the scope contract + per-source pins, the visible
skip/miss-test semantics, the one-research-action UX, and the Sourcing report all shipped
2026-07-15 and are verified in code. See `ROADMAP.md` #7 and git history
(`63259a9`, `b99ce47`, `72de503`, `07914e4`, `d07a0c5`, `88d526a`, `1931d59`, `cd78eea`,
`7d3bf10`) for what landed; the live-verification thread lives in ROADMAP #7. Everything
below is the sole unbuilt residue.

## Change 6 — FreeCEN place scoping (FT-13) — DEFERRED, gated on ADR-008

FreeCEN currently widens `.parish`/`.district` scope to `.county` because `FreeCenParams`
has no parish field — the freecen2 `place_ids[]` capability was noted and deferred as FT-13
(`SearchDispatcher.swift:927–928`). With Scope now the app's ONLY fan-out control (Depth
retired), silent widening undermines the picker's honesty. Fold FT-13 in: extend
`FreeCenParams` with place scoping, resolve place ids from the subject's parish/district via
the freecen2 API's place search, and honour `.parish`/`.district` natively. Keep FT-11's
birth-county axis behaviour at `.adjacent`/`.national` unchanged.

**Constraints:** capability must be built from freecen2's PUBLISHED API surface
(`feedback_verify_source_terms_first` — fetch and cite the docs, no trial-and-error probing),
and it ships behind the **ADR-008 resolution** (Free UK Genealogy programmatic-access
permission) like all Free UK Genealogy traffic.

**Acceptance:** a parish-scope run emits FreeCEN queries carrying place scoping; county-scope
queries are byte-identical to today's.

**Size:** M. **Deps:** ADR-008 resolution + freecen2 published-API docs. **Order:** after
ADR-008 clears; independent of Media/Clustering.
