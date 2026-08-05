# TEMPLATED_NARRATIVE_SOURCE_SPEC

## Problem

Free UK genealogy sites — memorial-inscription transcriptions, parish histories,
Online Parish Clerk (OPC) projects, GENUKI — are organised in their URLs by
**county Chapman code + parish** (`…/DBY/Youlgreave/…`, `…/big/eng/DBY/Youlgreave`).
They hold **discriminating** evidence a namesake-heavy BMD index cannot: death
dates, ages (→ birth years) and family groupings. But they are prose HTML with no
API, and "add one as a source" today means either a **bespoke connector per site**
(too much code) or a **whole-site crawl** — which most of these sites' terms
forbid ("may not copy… as a whole") and which hammers a volunteer server.

## Decision

A single **config-driven** mechanism. A source is a **URL template** with
placeholders — `{chapman}`, `{parish}`, `{surname}`, `{county}` — filled
**per-subject** from the Chapman code the pipeline already derives
(`ResearchSubject.homeChapmanCode`, with the project Home-county fallback) plus
the subject's resolved parish. We fetch **only the one local page on demand —
never the whole site**. Adding a site becomes a **config entry, not a connector**.

## Model

- **`TemplatedSourceConfig`** (Codable — bundleable and user-addable as JSON):
  `sourceID`, `displayName`, `urlTemplate`, `parishStyle`, `parser`,
  `termsSummary`, `attributionRequired`.
- **`TemplatedURLResolver.resolve(config, subject)` → `URL?`** — substitutes the
  placeholders; **returns nil if any placeholder cannot be filled** (a missing
  datum yields no query and no guess — never a URL with an empty segment).
- **`ParishSlugStyle`** — how the parish maps to the path (`concatenated`
  "SouthDarley", `hyphenated`, `asIs`). Per-site, because the schemes differ.
- **Parser is pluggable** — `.memorialInscription` (this site's stone format, see
  `MemorialInscriptionSource.parse`) or `.prose` (MLX extraction for freer pages
  such as GENUKI).

## Firewall (load-bearing)

Extracted **facts** (dates, ages, relationships) enter as **pending evidence** for
human review. The **verbatim transcription text is retained only for citation
display and is NEVER emitted by the Publisher** — respecting the common term "may
not be used in published family histories". Attribution (the source URL) is always
carried on the citation.

## ToS posture

Per-config `termsSummary`, verified against each site's **published** terms before
it ships (see `feedback_verify_source_terms_first`). The default posture for this
class of site: personal family-history research permitted; commercial sale,
publication in family histories, and whole-site copying forbidden; attribution
required; **one on-demand page per lookup — never a crawl**.

## Stages

- **Stage 0 — SHIPPED (`1afaf19`).** MI parser engine + wishful-thinking URL
  templating (`MemorialInscriptionSource`).
- **Stage 1 — THIS.** Generic `TemplatedSourceConfig` + `TemplatedURLResolver` +
  the ToS-verified wishful-thinking config, tested. Adding a site is now a config.
- **Stage 2 — DEFERRED.** Live `RecordSource` wiring — one on-demand fetch (reuse
  `ProseCorpusSource` retrieval, single-page + paced), parser dispatch, then
  firewall-gated pending evidence. `scopeHandling = .scoped` on the subject's
  Chapman code, so it participates only when a parish resolves.
- **Stage 3 — DEFERRED.** User-add UI (paste a template, pick a parser, verify
  terms) + additional bundled configs after verifying each site's URL scheme and
  terms: **GENUKI** (`genuki.org.uk/big/eng/{chapman}/{parish}`), county **OPC**
  projects, wishful-thinking's Census/Photograph collections.

## Invariants

- **One page per lookup — never a whole-site crawl.**
- **Never emit a URL with an unfilled placeholder** — a missing datum means no
  query, no guessed value.
- **Facts extractable; verbatim transcription never published.**
- **No hardcoded regions** — the Chapman code comes from the subject / project
  Home county, never Derbyshire-specific code.
