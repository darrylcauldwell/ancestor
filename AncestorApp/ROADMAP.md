# Roadmap — closing the spec backlog

**Status:** Living document (2026-05-23). Compiled from a sweep across
all `AncestorApp/*_SPEC.md` files. Each epic ties to one or more
existing specs; this doc only sequences and sizes, it does not invent
new design.

**Sizing:**
- **S** — one commit, ~1 hour.
- **M** — a few commits, ~half-day session.
- **L** — multi-session, day or more each.

**Convention:** every commit lands on `main` referencing the spec
change number it implements (e.g. `feat: kinship #Change4 — …`). No
GitHub issues opened for in-flight epic work — the spec is the plan.

## 2026-05-24 update — parity drift work in progress

Epic 1 closed (commits `849f35e`, `6072646`, `e4ed36c`,
`19290c2`). 31/46 cells agree (67%). Today's drift-closure session
closed 2 more cells (Robert + Ernest parent_link, commit `297a6f3`)
via household-token widening + FreeCen detail enrichment.

Full-corpus re-validation deferred to 2026-05-25 — FreeBMD's
circuit breaker tripped after a cap=5 enrichment run (~3h, burned
the day's rate budget). See `feedback_volunteer_sources_rate_limits.md`
+ `reference_freebmd_circuit_breaker.md` in memory. Today's
infrastructure fixes (WAL, watcher tightening, harness retry,
warmup probe, throttle surfacing) all land but stay unvalidated
end-to-end until tomorrow's clean run.

**Tomorrow's first action:** confirm FreeBMD is responsive
(single-subject `--only "@I50100727@"` smoke), then
`python eval/run_harness.py --backend swift-mcp --db-path …`. The
warmup probe (Lily) will abort early if the watcher is wedged.

**Once parity re-runs cleanly,** the parity gap should be much
smaller than yesterday's 15 disagreements. Today's commits close
(expected):
- Robert parent_link + military_service + death (CWGC carve-out
  + per-type tolerance + married-surname acceptance, commit 2423f35)
- Ernest parent_link (verdict-emitter widening, commit 297a6f3)
- Catherine death (Ashbourne alias, commit 73e05d1)
- Catherine + Mabel marriage (maiden-surname probe, commit e003628)
- Sarah + Charles cells removed entirely (corpus out_of_scope,
  commit 518f8ed)

**Remaining drift to investigate** if parity still shows it:
- **Ernest marriage** — directly confirmed Ernest × Sarah Ward
  marriage exists at FreeBMD Q1 1915 Ashbourne vol 7b p977.
  Ashbourne IS in DBY's district list so Swift's home-county
  dispatcher SHOULD include it. But Ernest's evidence_records
  show ZERO FreeBMD marriage records — the search either didn't
  run or returned 0 inexplicably. Need Swift runtime logging /
  ActivityBus trace to localise.
- **Lydia death** (cross-county handling).
- **Elizabeth birth + death** (Pattern A, unknown cause).
- **George Bowden** (Pattern C — Swift over-claims out-of-scope
  records; geography gate too lenient).

## Dependency graph

```
        SWIFT_MCP_EVAL_BACKEND #Change4-9   [Epic 1]
                       │
                       ▼ (parity signal feeds priorities)
   ┌───────────────────┼───────────────────┬───────────────────┐
   │                   │                   │                   │
KINSHIP             FS §9.1             T7 stall            PROSE Phase B
#Change3-8          gaps                gate                bio synthesis
[Epic 2]            [Epic 3]            [Epic 4]            [Epic 6]
   │                                       │
   ▼                                       ▼
KINSHIP #Change9                       T8 + T9 MLX
Swift port [Epic 9]                    [Epic 5]
                                           │
                                           ▼
                                       T31 retuning [Epic 7]

Independent epics:  SOURCE_MEDIA [Epic 8]
                    FS §9.2-9.3 [Epic 10]
                    PROSE Phase C [Epic 11]
                    T23 [Epic 12]
```

## Epic 1 — Close the eval loop (SWIFT_MCP_EVAL #Change4–9) [M]

Today's commit `c9fae87` shipped the Swift half (#Change1–3). Finish
the harness end so Python ↔ Swift parity is measurable.

- **#Change4 (S):** `get_research_result(run_id)` MCP tool in
  `FieldResearcherMCP/` — reads `research_runs.result_json`, returns
  the §3 envelope shape. Errors when run isn't complete.
- **#Change5 + #Change6 + #Change7 (M):** `_swift_mcp_pipeline_call`
  in `eval/run_harness.py`, `--backend swift-mcp` choice (currently
  `python|mock` at `run_harness.py:617`), and `--db-path` flag
  (defaults to `$ANCESTOR_EVAL_DB` then `~/Library/Application
  Support/AncestorResearchEval/test-corpus.sqlite`).
- **#Change8 (S):** smoke-run Ernest end-to-end with `--backend
  swift-mcp`, commit message documents the envelope.
- **#Change9 (S):** parity report — both backends across the 12-subject
  corpus, side-by-side per-kind agreement table.

**Why first:** highest leverage and smallest unknowns. Unlocks the
parity signal that should drive prioritisation for every other epic.

## Epic 2 — Kinship engine (KINSHIP #Change3–8) [L]

Natural progression from today's `find_children` (#Change2).

- **#Change3 (S):** lift `find_spouses` out of
  `_expand_post_marriage_searches`. Return *all* spouses (covers
  remarriage, widowhood) with per-spouse evidence.
- **#Change4 (M):** `discover_kin(subject, depth_up, depth_down)`
  walker + `KinshipGraph` type per §5. Default caps `depth_up=3`,
  `depth_down=3`, `max_nodes=200`.
- **#Change5 (M):** `verify_relationship(a, b, claimed)` primitive
  + structured-relationship parser (`nth_cousin_mth_removed`,
  `aunt_or_uncle`, etc.).
- **#Change6 (S):** corpus YAML extensions — `expected_relatives` +
  `expected_verifications` blocks for Ernest, Robert, Mabel cluster.
- **#Change7 (S):** harness `--mode discovery|verification`. New
  metrics: kin-discovery recall, kin-discovery precision,
  verification accuracy.
- **#Change8 (S):** living-person guard extension — Lily's
  `expected_relatives` block declaring parents only.

## Epic 3 — FamilySearch first-cut completion (§9.1) [S + optional M]

Closes the partially-shipped epic. Today the source is registered
(`SourceBootstrap.swift:22`) and the search path works, but three
spec items remain.

- **S:** add `placeARK: String?`, `collectionCompleteness: Double?`,
  `volatilityScore: Double?` to `RecordCommon`.
- **S:** migration adding `result_kind` + `hit_count` to
  `negative_searches` (§6.6 caching).
- **S:** document the two probe outcomes (does `q.recordType=Birth`
  restrict; collection-filter param name) inline in
  `FamilySearchSource.swift`.
- **Optional M:** FamilySearch fallback for pre-1912 marriage spouse
  extraction — pivots the abandoned FreeBMD matched-page idea to FS's
  `Couple` relationship (FS index ties spouses by record, not by
  page). Reusable across every pre-1912 woman whose tree lacks a
  populated spouse profile.

## Epic 4 — T7 stall-gate completion [M]

Implement condition (a) of the §7.4 two-condition stall gate.
Requires defining the `deficitQuery` contract on
`SearchDispatcher` — RESEARCH_PIPELINE_SPEC §5.3 lists this as the
documented partial. **Blocks Epic 5 (T8).**

## Epic 5 — MLX bolt-ons (T8 + T9) [L each]

Local-only (no third-party API). Both target the post-loop phase.

- **T8 (L):** MLX next-search suggestion for weak verdicts. Depends
  on Epic 4 (deficit-query contract).
- **T9 (L):** MLX free-text disambiguation pass. Independent of T8;
  `ResearchInterpreter.disambiguateIdentity(candidates:state:)`.

Each needs: prompt design, golden test fixtures, integration into
the post-loop phase, and verdict-emission accounting.

## Epic 6 — Bio synthesis (PROSE_CORPUS Phase B) [L]

Phase A is shipped (10 files under `Services/Corpus/`,
`ProseCorpusSource: RecordSource` registered). Phase B is the bio
pipeline AC-S1–S5 + AC-E1–E3.

- **Stage A (S):** deterministic base layer — facts → skeleton
  paragraphs.
- **Stage B (S):** context retrieval — wire `ProseCorpusSource.search`
  into the bio pipeline.
- **Stage C (L):** MLX synthesis with strict zero-hallucination
  prompts. The hard part.
- **Stage D (M):** verification pass — every sentence backed by a
  `pending_facts` row or `narrative_findings` entry.
- **Bio rendering + regen (M):** inline citation markers, inspector
  cards (Part X), staleness detection + user-edit preservation
  (Part XI).

## Epic 7 — T31 empirical ladder retuning [M]

Depends on Epic 1 (harness mature), Epic 4 (T7 complete), Epic 5
(T8/T9 shipped). Pure analysis + threshold tuning.

## Epic 8 — SOURCE_MEDIA first-cut (§7) [M, then L]

Entire spec is paper-only today.

- **Decision (S):** Option A (extend `attachments`) vs Option B
  (new `source_media` table). Spec leans B.
- **M:** `source_media` schema migration + `SourceMediaCandidate`
  model + Find a Grave headstone extractor as first source.
- **L:** extend to CWGC + FamilySearch (`RectangleRegion` from
  `sourceQualifier`). Blob-cache vs URL-only decision (§8) along
  the way.

## Epic 9 — KINSHIP #Change9 Swift port [L]

Faithful port of #Change1–5 to Swift once Python primitives are
stable (per `feedback_port_from_python.md`). Verify with
`compare_*.py`.

## Epic 10 — FamilySearch §9.2 + §9.3 [M, then L]

- **§9.2 (M):** ARK lookup endpoint, bio-citation matcher with
  ARK-deterministic path, collection metadata caching → trust-tier
  refinement.
- **§9.3 (L):** OAuth transport (post-App-Store-approval),
  non-biological relationships, place authority enrichment, new
  `RecordType` cases driven by first-cut data.

## Epic 11 — PROSE_CORPUS Phase C [M]

Cluster-driven candidate URL discovery (PROSE_CORPUS_SPEC §19).
Optional harness feature.

## Epic 12 — T23 Sample Tree tour [M]

Out of architectural scope per RESEARCH_PIPELINE_SPEC §5.6. First-
launch UI tour. Defer until everything else lands.

---

## Suggested first three sessions

1. **Epic 1** — close the eval loop. Biggest information gain,
   smallest unknowns. Tells us where Swift drifts from Python.
2. **Epic 3** — close FS first-cut gaps. Three small additions, no
   dependencies, tidies a partial epic.
3. **Epic 2 #Change3 + #Change4** — `find_spouses` + `discover_kin`.
   Natural continuation of today's kinship work.

After those three: parity-measured Swift backend, complete FS first
cut, and a kinship discovery primitive landed.

## Tracking

This roadmap is not authoritative on design — the per-spec change
lists are. When an epic ships, update its line above to "shipped
(commit `<sha>`)" or strike it through. When a new gap is discovered,
add it as a new epic and update the dependency graph.
