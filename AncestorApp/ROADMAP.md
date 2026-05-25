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

## 2026-05-25 late — sustained enrichment run (operating model)

A multi-day operating mode emerging from the cross-day Discovery
artefact below: rather than Discover-only or Enrich-only sessions,
alternate **Discover wave → deep enrich on the promoted ring →
Discover next ring**, extending across days as a single sustained
pass rather than being bounded by the session clock.

### Why

Each Discovery hop compounds uncertainty from the parent profile.
Clusters #3 + #4 reverted (below) because Discovery ran off thin
profiles whose scorer signal was inadequate. The 4-gate scorer is
evidence-hungry; each extra source on a profile makes the next hop
safer.

The recursive shape is real: every enriched profile exposes more
enrichable profiles (children in census → spouses' parents in
marriage records → their siblings in baptism clusters). Nothing in
the engine caps expansion; the caps are operational and epistemic,
not architectural.

### Enrichment bar (per profile)

Minimum-anchor target before a profile can sponsor the next Discovery
hop:

- **Full BMD triangle** with GRO refs where civil reg covers lifespan
- **Every census in lifespan** that should exist (1841 → 1921 for
  English subjects); gaps are themselves evidence
- **Parish register** baptism / marriage / burial via FreeREG where
  civil reg is pre-1837 or sparse
- **Probate** if adult death post-1858
- **CWGC** if military-age death in war years
- **FindAGrave / burial** for location anchor
- **Children identified** from census + BMD — also what feeds the
  next Discovery wave

### What actually stops recursion (not wall-clock)

1. **Daily source budgets** — FreeBMD's daily quota is the ceiling;
   FreeCen / FamilySearch / CWGC each carry their own. Memory:
   `reference_freebmd_circuit_breaker.md`,
   `feedback_volunteer_sources_rate_limits.md`.
2. **Source coverage cliffs** — pre-1837 falls out of civil reg into
   patchy parish registers; convergence rates fall hard at that edge.
3. **Scorer attrition** — peripheral profiles have less corroboration;
   the 4-gate scorer naturally rejects more leads at the periphery,
   so expansion should taper itself.
4. **Personally diminishing returns** — 4th-cousin-twice-removed
   enrichment may clear gates but not inform anything worth knowing.

### Work needed to enable this mode

| # | Item | Size | Notes |
|---|---|---|---|
| 1 | Daily-budget awareness — engine pauses gracefully at quota and surfaces "resumes tomorrow" state, instead of circuit-breaking | M | Without this, a sustained run hits the breaker and ladders to 900s waits |
| 2 | Checkpoint/resume hardening for multi-day runs — snapshot already partial; verify it survives an overnight pause + process restart | S–M | Memory: `feedback_save_incrementally.md` |
| 3 | Scorer-attrition logging at the periphery — surface *where* expansion is tapering and why, so the brake is visible | S | Builds trust in confidence-based natural stopping |
| 4 | "Stop digging here" heuristic — bound expansion by collateral-line depth or distance-from-probands, so budget isn't burned on 5th cousins while core tree has gaps | M | Otherwise an unbounded run breadth-first explores territory the user doesn't care about |

### Backlog impact

All eight foundation items (scorer tightening, dedup, write-back,
attrition logging, daily-budget awareness, checkpoint hardening,
stop-digging heuristic, §14.B.1 re-check) moved to
`AncestorApp/ENGINE_FOUNDATION_SPEC.md` as #Change1–#Change8.
Commits reference those change numbers. The four output-surface /
coverage-extension specs (`PROSE_CORPUS` Phase B,
`FAMILYSEARCH_SOURCE` content surface, `SOURCE_MEDIA`, `KINSHIP`
#Change3–5) plus `RESEARCH_PIPELINE_SPEC` Part II are deferred
until the foundation ships. See each spec's header for the deferral
note.

## 2026-05-25 — cross-day session wrap

Two-day arc covering parity re-validation, cluster outcomes, and
the empirical proof of Discovery Onboarding as a viable product
shape. Calendar-day-2 picked up after a sleep break during a
discovery run that completed gen-2 expansion overnight.

### Parity outcome

Full-corpus swift-mcp re-run after reverting clusters #3 + #4
(commits `40b0d2f` + `edf15ed`): **HEADLINE 38 supported vs target
31** — best result yet, post-revert. Cluster wins kept and
empirically validated end-to-end:

- **Cluster #1** — Elizabeth birth + marriage close; Catherine birth
  no longer drifts. Held.
- **Cluster #2** — Ernest marriage closes at Ashbourne Q1 1915 as
  predicted. Held.
- **Cluster #3** — reverted. Tier-2 narrowing broke John pair +
  Mabel parent_link in exchange for Catherine + Stephen over-claim
  fix. Net trade-off was bad. Catherine + Stephen still drift; a
  cleaner sparsity guard is the redo.
- **Cluster #4** — reverted. Geography tightening hit cross-county
  Lydia + Ernest death as side-effects. Outlier handling is a real
  problem but the within-county-locality rule was too coarse.

### Discovery Onboarding — architecture proven

The Discovery Onboarding architecture was sketched and iteratively
validated by building each missing piece in code:

| Piece | Commit | Status |
|---|---|---|
| `promote_lead` MCP tool (lead → profile + edge) | `aece608` | shipped |
| `LeadStore.createFromParentInferredHypothesis` emitter | `736de34` | shipped |
| Watcher wires emitter into pipeline result | `20da37f` | shipped |
| Driver `is_promotable` accepts nil given_name for parent-inferred | `09f5aec` | shipped |
| Watcher refreshes snapshot on miss (gen-2+ unblocker) | `07cbba6` | shipped |
| `promote_lead` estimates parent's birth-year from child's | `14e69a3` | shipped |
| Python driver, populator, seed extractor | `ca00756` | shipped |

The autonomous chain — `kick_off_research → emit parentInferred lead
→ promote_lead → enqueue → repeat` — now runs end-to-end without
human intervention. Validated by growing the Cauldwell Discovery
project from 15 seed profiles to **87 profiles in one cross-day
run**: 15 starter-7 + Lily + Claire's tree → 72 auto-promoted
ancestors via `@FR_…@` profile IDs.

### Empirical findings (the real value)

The 87-profile artefact exposes the next round of problems that
weren't surfaceable without running it:

1. **Scorer-on-thin-profiles is too permissive.** Final tally:
   16,299 facts, 10,855 leads, 2,888 impossible across 27,054
   evidence rows. For a known-good seed (Ernest) the engine
   produces ~17 focused matches; for a surname-only placeholder
   (Darryl's mother HOLMES) it produces ~3,000 candidates, most
   landing `.fact` because the name + date gates pass any
   `HOLMES` born 1926-56. Tightening the 4-gate scorer when
   subject lacks given-name + precise birth-year is the next
   spec'd change.

2. **No dedup-on-promote.** Darryl's mother was already in the
   tree as Jennifer Holmes (@I50100815@), yet `promote_lead`
   created a new HOLMES placeholder (@FR_2F7D…@). A search-tree-
   for-match step before INSERT would prevent duplicates.

3. **Generation-3 needs sharper data.** Round-1 promotion gave
   placeholders only surname + estimated date window. Round-2
   research had to do too much disambiguation. Idea: after the
   first round of research on the FR profile, the engine likely
   identifies a single best-candidate record — use that record's
   given-name to update the placeholder before continuing the
   BFS.

4. **All record types fire.** Aggregate evidence covers birth,
   death, marriage, census, probate, burial, parish, and military
   (CWGC) — every category in the spec. Sibling discovery via
   FreeBMD MMN only fires on subjects with full data; FR
   placeholders skip it.

### Open work, ordered by leverage

Foundation work — scorer tightening, dedup, write-back, attrition
logging, daily-budget awareness, checkpoint hardening, stop-digging
heuristic, §14.B.1 re-check — now lives in
`AncestorApp/ENGINE_FOUNDATION_SPEC.md` as #Change1–#Change8.

Remaining items not in that spec:

- **Re-attempts of clusters #3 + #4** with the lessons learned —
  scoped narrower (sparsity guard only for known-sparse subjects;
  geography outlier only for explicitly-flagged cases). Parity work,
  parallel to foundation.
- **Discovery Onboarding wizard UX** once the foundation ships.

### Session metric

15 commits in 24h of clock time, 5.8× tree growth in the
empirical run, two corpus clusters survived re-validation, two
reverted with clear redo plans.

## 2026-05-25 evening — all four clusters fixed (pending validation)

The morning's parity report localised the 15 disagreements into
four actionable clusters. All four shipped before EOD; full-corpus
re-validation deferred to 2026-05-26 (one full-corpus pass per
session — see memory `feedback_volunteer_sources_rate_limits.md`).

| Cluster | Subjects | Commits | Status |
|---|---|---|---|
| #1 — female pre-marriage maiden axis | Elizabeth (4 cells), Catherine birth | `0b75b5f` dispatcher + `514ad20` scorer | shipped; Elizabeth-only smoke confirms birth+marriage close (2 of 4 cells) |
| #2 — wife maiden for male marriage | Ernest marriage (1 cell) | `6bc5c5e` (cherry-picked from worktree) | shipped; predicted close on Ernest's Ashbourne Q1 1915 |
| #3 — parent-link sparsity guard | Catherine + Stephen parent_link (2 cells) | `b68a29b` | shipped; tier-2 token gathering narrowed to FreeCen only (Python parity) |
| #4 — geography outlier within-county | George Bowden (3 cells) | `ea6d07d` | shipped; new birthLocality + districtCoversParish; CWGC carve-out preserved |

**Combined predicted impact (next parity run):**
- Closures: Elizabeth × 2 (birth, marriage), Ernest marriage, Catherine parent_link, Stephen parent_link, George × 3 (birth/death/marriage at minimum stay below `supported`). ≈ 8 cells.
- Risks to monitor: Robert parent_link must remain supported (cluster #3 test pins this); Robert CWGC military must stay supported (cluster #4 test pins this); no regression on Mabel parent_link / John pair.

**Carry-over for future sessions (out of scope this round):**
- Elizabeth death — cross-county to Wales (Risca, Monmouthshire); needs cross-county / cross-country geo handling.
- Elizabeth spouse — `supported_via_matched_page` requires FreeBMD matched-page feature (Epic 3, not shipped).
- George birth — `supported_with_year_correction` verdict-shape edge case; Swift currently `inconclusive`.

**Workflow note:** clusters #2/#3/#4 were tackled in parallel via three worktree-isolated subagents. #3 + #4 landed on main directly (their worktree base diverged); #2's worktree commit was cherry-picked. Full test suite (1359/1360 passing, 1 skipped) post-merge confirms the four fixes coexist cleanly. Validation still requires a single live full-corpus harness run.

**Anchor commits today (evening):**
- `0b75b5f` — surnamesToProbe pre-marriage maiden axis (dispatcher)
- `514ad20` — checkName maiden axis acceptance (scorer)
- `b68a29b` — VerdictEmitter tier-2 scoped to FreeCen
- `ea6d07d` — geography gate within-county locality check
- `6bc5c5e` — wife maiden surname plumbing through FamilyContext.spouseFatherSurname

## 2026-05-25 update — clean parity re-run, drift reshuffled

Yesterday's 26 commits validated end-to-end against a fresh
swift-mcp + python full-corpus pass. Headline unchanged
(31/46 = 67% agreement, 15 disagreements) but the **composition
moved significantly**:

- Reports: `eval/PARITY_REPORT_2026-05-25.md` (vs `…2026-05-24.md`)
- Swift run: `eval/runs/2026-05-24T19-43-36.json` (18:02 wall)
- Python run: `eval/runs/2026-05-24T19-56-44.json` (10:35 wall)

**Closed cells (8)** — drift cells that disagreed yesterday and
now agree:

| Subject | Kind | Closure source |
|---|---|---|
| Robert Cauldwell  | death_disambiguation     | 2423f35 (Ashbourne alias / married-surname) |
| Robert Cauldwell  | marriage_disambiguation  | 2423f35 |
| Robert Cauldwell  | military_service         | 2423f35 (CWGC carve-out + per-type tolerance) |
| Robert Cauldwell  | parent_link              | 297a6f3 (household-token widening) |
| Ernest Cauldwell  | parent_link              | 297a6f3 |
| Catherine H. Bown | death_disambiguation     | 73e05d1 (Ashbourne alias) |
| Lydia Kenworthy   | death_disambiguation     | (cross-county handling — was on the watchlist; closes naturally) |
| Mabel cluster     | marriage_disambiguation  | e003628 (maiden-surname probe) |

Headline stays at 15 because **8 new disagreements appeared**:

- **3 cells where Swift is now better than Python** (Python
  regression candidates, not Swift drift): John pair parent_link,
  Mabel parent_link, Elizabeth parent_link.
- **2 over-claims from yesterday's parent_link widening**
  (commit `297a6f3` was too aggressive for sparse subjects):
  Catherine parent_link, Stephen parent_link — both `supported`
  where corpus expects `inconclusive`.
- **3 new visible cells** that were both-inconclusive yesterday
  but now have Python finding records Swift misses: Elizabeth
  marriage (`supported_via_matched_page`), and the Sarah/Charles
  `out_of_scope` markers from commit `518f8ed` reading as
  disagreements when Swift confirms.

### Remaining drift, grouped by root cause

Dispatch-log evidence (now surfaced in the parity report) localises
the 15 remaining disagreements into 4 actionable clusters:

1. **Female-subject pre-marriage search uses married surname**
   (Elizabeth Cauldwell, 4 cells: birth, death, marriage, parent_link).
   Every Swift query is `Elizabeth Beighton` (her twin married
   surname) — including the birth probe `1842–1846` for a child
   born as Cauldwell. Yesterday's `e003628` fixed maiden-surname
   probing for `marriage_disambiguation`; the same logic needs
   to extend to all **pre-marriage record types** (birth, early
   census, baptism) when subject is female. Python uses maiden,
   so this closes 4 cells in one extension. See memory
   `wikitree_married_surname_convention.md`.

2. **Wife's maiden surname for male marriage searches**
   (Ernest Cauldwell, 1 cell: marriage). FreeBMD marriage probes
   all fire as `Cauldwell × Cauldwell` (wife indexed under
   married name in twin). The real record is `Cauldwell × Ward`
   at Ashbourne Q1 1915 vol 7b p977. Ashbourne IS in the
   district list — the search dispatches correctly, just with
   the wrong bride surname. Symmetric to `e003628` but on the
   groom side: needs derive-wife-maiden-from-children's-BMD.

3. **Parent-link widening over-eager on sparse subjects**
   (Catherine, Stephen, 2 cells). `297a6f3` widened household
   tokens + FreeCen enrichment to recover Robert/Ernest. It now
   over-claims for subjects whose corpus expects `inconclusive`.
   Needs a sparsity guard — possibly minimum-evidence threshold
   before emitting `supported` on parent_link.

4. **Geography gate too lenient on out-of-scope records**
   (George Bowden, 3 cells: birth, death, marriage). George's
   corpus marks him as a `geographic_outlier` born outside
   Derbyshire. Swift confirms Glossop/Basford/Ilkeston death
   and Bakewell marriage hits anyway. Gate should soft-fail when
   record locality is geographically disjoint from the home-county
   scope for an outlier subject.

Plus 3 cells where Swift is right and Python is wrong (cluster #5,
deprioritised — investigate only if a Python regression is later
suspected to hide a shared bug): John pair / Mabel / Elizabeth
parent_link.

### Today's session — read-only validation, no commits

This session only ran the validation pass + this ROADMAP update.
No code changes. The four clusters above are queued for an
attended coding session — each is M-sized at most, all four are
plausible single-session work.

**Network footprint stayed inside the safe envelope:** Lily warmup
(15s) → sample-3 (3:55) → full corpus swift-mcp (18:02) → full
corpus python (10:35). No circuit-breaker trips, no orphan MCP
processes left. FreeBMD probe pre-flight returned 200/0.38s; same
holds at session end.

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
