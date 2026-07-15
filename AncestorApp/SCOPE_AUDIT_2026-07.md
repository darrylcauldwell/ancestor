# Scope Audit — does the Scope picker control fan-out per source?

**2026-07-15.** Requested by Darryl ("check it works as we think it should for each data
source") while deciding that Scope becomes the app's ONLY fan-out control
(SOURCE_WEIGHTING_SPEC). Method: one tracer per source following the scope parameter from
`SearchDispatcher.buildQueries` into outbound query construction, every claimed deviation
adversarially verified against the code (workflow `wf_d9661310-d6d`, 39 agents; raw trace
tables in the session transcript). Contract audited: *narrower scope must never produce
broader/more queries; unsupported granularity must widen deliberately+visibly or skip with a
visible record — never silently ignore scope.*

## Verdict per source

| Source | parish | district | county | adjacent | national | Scope honoured? |
|---|---|---|---|---|---|---|
| FreeBMD | zero queries (deliberate, tested, disclosed in UI) | widens→county (commented, tested) | 1 countyid query | home+neighbours, umbrella-expanded (9 for DBY) | 1 all-districts query | **Yes** (best in class) |
| FreeCEN | widens→county (FT-13 deferred → now spec'd) | widens→county | residence axis, home code | **birth-axis swap** (FT-11): 1 query, birth=home, residence unfiltered | same axis swap; empty-home → real ~90-code sweep | **Mostly** (documented widenings) |
| FreeREG | home-county only | home-county only | home-county only | home+neighbours (**umbrella codes NOT expanded**) | ~70 codes | **Yes, with defects** |
| CWGC | national always | national always | national always | national always | national | By design (war graves) — rationale not co-located, untested |
| FindAGrave | **identical at all 5 levels** (county/deathLocation-pinned) | same | same | same | same — the pin never lifts | **No** — and docs contradict each other |
| Probate | national always (registry-catchment logic is scorer-side) | same | same | same | same | By design, documented; untested |
| Wirksworth | ignores scope (3-layer documented localPlugin) | — | — | — | — | Moot — being retired (spec Change 0) |
| FamilySearch | **scope never read — global reach, all 5 levels identical** | same | same | same | same | **NO — confirmed broken-severity** |

## Confirmed findings (20; most-severe first)

1. **[broken] FamilySearch ignores scope entirely.** The dispatcher's familysearch branch
   never reads `scope`; queries carry only PROFILE-derived soft place axes (home county as
   `q.*LikePlace` re-ranks — soft, never server-side filters). A parish-scope run and a
   national-scope run emit byte-identical FS queries. On the only global-reach source this
   is the direct mechanism behind remote-namesake haystacks (Barbara Ayre, Northumberland).
   Related (verified, gated on OAuth pagination #Change5): only page 1 (100 results) is ever
   fetched, so a true record demoted below rank 100 by the home-county soft axes is
   unreachable at ANY scope.
2. **[surprising] FS adjacent scope never widens to bordering counties** — soft axes carry
   the home code only; RegionConfig adjacency is unused for FS.
3. **[surprising] Empty home Chapman code silently zeroes the free trio below national.**
   FreeBMD (district/county/adjacent), FreeCEN (adjacent — degenerate dead fallback, comment
   corrected `3e52edd`), FreeREG (every scope below national): zero queries, no log, no
   negative-search/skip record. Reads as "never searched" instead of "cannot scope without
   an anchor". (FreeBMD logs a warning only for non-empty UNKNOWN chapmans.)
4. **[surprising] FreeREG's parish param is dead.** `FreeREGParams.parish` (and
   `registerType`) never reach the wire; the MLX strategist's parish narrowing silently
   no-ops (acknowledged only as a cache-key note, QueryCache.swift:236-237). Same class:
   **Wirksworth `parishHint` dead** (moot on retirement).
5. **[surprising] Silent scope-ignore is the dispatcher's DEFAULT for any future source** —
   the `default:` branch never consults scope, so a newly registered source inherits
   scope-invariance with no per-source comment, test, or flag.
6. **[surprising] Doc-vs-doc contradiction:** `ResearchScope`'s own header says non-covering
   sources should "return zero queries" at parish; the dispatcher header says CWGC/FAG/
   Probate/Wirksworth "ignore scope". FindAGrave's actual behaviour matches neither reading
   cleanly (county-pinned at every level — not "inherently national" either).
7. **[cosmetic] FreeREG umbrella adjacency codes not expanded** (YKS passed verbatim,
   duplicate WRY/YKS coverage) — FreeBMD/FreeCEN expand, FreeREG doesn't.
8. **[cosmetic] Test-pin gaps:** no test pins scope behaviour for CWGC, FindAGrave, Probate,
   or FamilySearch; FreeREG's per-scope fan-out (1/1/1/8/56 for DBY) unpinned; CWGC
   monotonicity holds only by construction. FT-04's comment rationale for excluding FreeREG
   from escalation is factually wrong. CWGC/Probate deliberate-widening rationale not
   co-located with their branches. Wirksworth year-window params unused (moot).

## Refuted as deliberate-and-documented (kept for the record)

FreeBMD parish-skip visibility (disclosed in UI copy + tested); FT-04 county→national
auto-escalation on clean-empty (spec-prescribed, CONNECTOR_AUDIT FT-04); FreeBMD
adjacent-emits-9-queries-vs-national-1 (query-count inversion, reach still monotonic);
FreeCEN FT-11 birth-axis swap incl. adjacent≡national for home-known subjects (deliberate,
but see UI-copy nit: the Scope help text doesn't mention census axis semantics — and the
border-born ancestor case is worth revisiting in the weighting build); Probate scope-ignore
(catchment logic is scorer-side); Wirksworth region-gate exclusion (uniform eligibility
gating).

## Disposition

All confirmed findings are INPUTS to `SOURCE_WEIGHTING_SPEC` (staged dispatch rebuilds this
exact dispatcher surface): FS place-axis hardening + scope participation belong to Stage-4
design; empty-anchor visible-skip joins the miss-test/searched-surface work; dead params
removed with FT-13; per-source scope test pins become acceptance criteria. No hot fixes made
during the audit beyond the `3e52edd` comment correction.
