# Research Axes — Specification

**Status:** Draft (revision 2). No changes implemented yet.
**Scope:** SwiftUI `Ancestor Research` app (`/Users/darrylcauldwell/Development/ancestor/Ancestor Research/`)
**Date:** 2026-05-15
**Author context:** Drafted after the CWGC integration fix surfaced two recall gaps that share a common shape — search strictness needs to be a first-class axis, and geographic scope needs to be a hierarchy rather than a binary. The William Cauldwell case (no exact-spelling match in CWGC; soundex variants would surface candidates) demonstrated the need concretely. Revision 2 (this revision) tightens the contract with `RESEARCH_AND_CLEANSE_SPEC.md`, makes `RegionConfig` per-subject, adds acceptance criteria, and reconciles internal inconsistencies surfaced during review.

---

## 1. Problem statement

The research pipeline currently exposes two user-facing controls and one implicit one:

1. **Depth (`ResearchMode`)** — verify / extend / discover / all. Tunes iteration count, fact caps, and early-stop conditions. Same dispatcher, same sources.
2. **Scope (`ResearchScope`)** — `local | national`. Drives FreeBMD's district fan-out (12 Derbyshire districts vs ~620 UK districts). Other sources ignore it.
3. **Strictness** — implicit, hardcoded per source. CWGC uses `Tab=exact` unconditionally; FreeBMD uses its default (non-phonetic) flag.

Three compounding gaps:

1. **Scope is binary when it should be a hierarchy.** Genealogical research naturally escalates outward — parish first (where we have the most context), then registration district, then county, then adjacent counties (border ancestors), then national. The current `local | national` toggle collapses parish/district/county into "local" and treats adjacent-county searches as either skipped (local) or wasteful (national). Task #4.

2. **County adjacency has no representation.** A Derbyshire-born ancestor near the Nottinghamshire border is more likely to appear in NTT records than in YKS records, but the dispatcher has no notion of "adjacent". The data exists in human knowledge of UK geography but not in any file the app reads. Task #5.

3. **Strictness is hardcoded and inflexible.** CWGC's `Tab=exact` is correct for verifying a known ancestor and wrong for discovering a ghost-profile spelling variant. FreeBMD's default returns exact-surname matches and misses transcription variants. The pipeline cannot escalate from strict to loose when strict returns empty — the William Cauldwell case fails despite four plausible CALDWELL/CAUDWELL candidates being visible to anyone who broadens manually. Task #6.

A fourth gap, exposed by reviewing the above: **`RegionConfig` is Derbyshire-hardcoded** at `RegionConfig.derbyshire`. `ScoringRules.isLocalDistrict` calls into it without any subject context, so a Leicestershire-born subject's Leicestershire match scores as "non-local" while a Derbyshire match boosts. The two scope-hierarchy levels that mean anything per-subject (`.parish`, `.district`) are unimplementable until this is per-subject too. Task #5's adjacency lookup also has to take a subject's home county as input — there is no "adjacent" without a "where from".

Together, the four controls — depth, scope, strictness, home region — should orthogonally describe a research request. Currently three of them don't, and the fourth doesn't exist as data.

This spec **supersedes** `RESEARCH_AND_CLEANSE_SPEC.md`'s Change 1 iteration-based widening (home → national across pipeline iterations). The same recall problem is solved here by user-picked scope (monotonic per run) + strictness broadening on empty (one axis at a time). See §2.

---

## 2. Design decisions locked during planning

These are settled before implementation and are *not* open questions:

| Decision | Choice | Rationale |
|---|---|---|
| Number of user-facing axes | **Two** — depth and scope | Strictness derives from depth; a third knob is noise |
| Strictness ↔ depth mapping | **Verify** = strict only; **Extend** = strict, broaden once on empty; **Discover** = loose first, escalate to variant on empty; **All** = every tier deduped | Mirrors how a human researcher actually escalates |
| Lead-score authorship | **Scorer owns it, search layer doesn't** | A loose-mode hit with a perfect date+parish match should beat a strict-mode hit with a 10-year date gap |
| Scope hierarchy levels | parish → district → county → adjacent counties → national | Five levels match available data (parish list, district codes, chapman codes, adjacency table, FreeBMDDistrictCatalogue) |
| Adjacency data shape | **Static JSON file** `county-adjacency.json`, hand-curated, indexed by chapman code | Adjacency is geographic fact, not derivable; ~120 lines for UK + Ireland |
| Adjacency hop depth | **Single-hop only.** Adjacent set does not transitively include neighbours-of-neighbours | Two-hop is rare in practice; deferred until query-volume budget proves the gap |
| Border-town flag | **Derived at lookup time**, not stored | Avoid maintaining a third location field; a parish is "border" iff its district sits in a county whose adjacency entry is non-empty *and* the parish's recorded location_code matches a border-county district |
| Strictness implementation surface | **Per-source flag in `RecordQuery`**, sources may ignore | Some sources (Wirksworth, FindAGrave) have no strict/loose distinction |
| Empty-then-broaden detection | **Dispatcher**, not source | Keeps sources as dumb pipes (per existing comment at `SearchDispatcher.swift:5`) |
| Default-scope derivation | **Depth-only:** verify→.district, extend→.county, discover→.adjacent, all→.national. Single 4-row table, profile completeness ignored | Avoids a 2-input precedence rule; user can override per-run from the sheet |
| Backwards compatibility | **No** — `ResearchScope` enum is breaking-restructured (2 cases → 5 cases) | Single in-repo consumer; clean rewrite is cheaper than alias-with-deprecation |
| `.parish` behaviour on parish-unsupported sources | **Skip entirely** (return zero queries). Do not silently widen to `.district` | The user picking `.parish` is asking for a tight constraint; silent widening violates that |
| Relationship to RESEARCH_AND_CLEANSE Change 1 | **This spec supersedes** that change's home→national iteration widening. Scope is monotonic per run; only strictness broadens on empty | Two widening mechanisms across the same pipeline create undefined interactions |
| Home-region data source | **`Project.homeChapmanCode: String?`** — project-scoped, derived from home-person anchor at project creation. Legacy projects open with `nil`; call sites fall through to `"DBY"` | Per-project, not per-subject — most projects research one family, one region |
| `RegionConfig` per-subject vs per-project | **Per-subject parameterisation** via `forChapmanCode:` factory functions on `RegionConfig`; constants live on (because the data lives there), but every call site passes the subject's home Chapman code through. `ScoringRules.isLocalDistrict(_:forHomeChapman:)` makes the scorer per-subject too | Avoids singleton swap; per-subject is correct, per-project is the source from which it's threaded |

---

## 2.5 Prerequisites and ordering with `RESEARCH_AND_CLEANSE_SPEC.md`

`RESEARCH_AND_CLEANSE_SPEC.md` (prior spec) is still partially in-flight. Its Change 3 (parent inference) shipped in commit `a63a436`. Its Change 1 (national FreeBMD with home-region weighting) and Change 2 (`Profile.birthLocationCode` + gazetteer typeahead) are listed as "awaiting implementation."

Interactions:

- **Prior spec's Change 1 is superseded by this spec.** Do not implement the iteration-based home→national widening. Update the prior spec's status when this spec's Change 6 ships.
- **Prior spec's Change 2 (Profile.birthLocationCode + gazetteer) is a hard prerequisite for this spec's Change 3.** `.parish` and `.district` scope levels only mean something when the subject has a structured location code. Until prior-Change-2 ships, this spec's Change 3 must silently fall through `.parish` and `.district` to `.county` for any profile lacking a structured code. This is acceptable as a transitional state, but every commit reference to this spec's Change 3 must note the dependency.

Recommended ordering across both specs:

1. This spec's Change 1 (per-subject RegionConfig).
2. This spec's Change 2 (county adjacency data).
3. Prior spec's Change 2 (structured location codes + gazetteer). This is the heavy data-model change; doing it before this spec's Change 3 lets `.parish`/`.district` mean what they say from day one.
4. This spec's Change 3 onwards.

---

## 3. Three axes — locked semantics

### 3.1 Depth (`ResearchMode`) — unchanged behaviour, expanded role

| Mode | Iteration / fact-cap behaviour (existing) | Strictness ladder (new) |
|---|---|---|
| `verify` | Stops early when known facts corroborated | Strict only. Never broadens. |
| `extend` | Standard iterations, fills missing facts | Strict first. On empty per-source, broaden once to loose. |
| `discover` | Most iterations, no early stop | Start at `.loose`. On empty per-source, escalate to `.variant`. Strict is **not** run. |
| `all` | Maximum iterations, highest fact cap | Run every tier (strict + loose + variant) in parallel, dedupe across the union. |

### 3.2 Scope (`ResearchScope`) — replace binary with hierarchy

Old:
```swift
enum ResearchScope { case local, national }
```

New:
```swift
enum ResearchScope: Comparable {
    case parish        // queries only the subject's home parish
    case district      // home parish's registration district
    case county        // all districts in the home county (current "local")
    case adjacent      // home county + counties bordering it (single hop)
    case national      // all UK districts (current "national")
}
```

Order is widening. `parish ≤ district ≤ county ≤ adjacent ≤ national`. The dispatcher uses this for FreeBMD/FreeCen/FreeREG district fan-out and ignores it for inherently-national sources (CWGC, FindAGrave, Probate). Wirksworth is parish-locked: it returns results only when scope is `.parish` and the subject's home parish matches Wirksworth's coverage, otherwise it returns zero queries.

**Fallback when subject lacks a structured location code:** If `subject.birthLocationCode == nil` (true for every profile until prior spec's Change 2 ships), the dispatcher silently treats `.parish` and `.district` as `.county` and uses `Project.homeChapmanCode` (or `"DBY"` if that is also `nil`) for district lookup. Logged at debug level so it's traceable in development without spamming production.

### 3.3 Strictness — new internal axis

```swift
enum SearchStrictness: Comparable {
    case strict      // exact name match, default for most sources
    case loose       // server-side fuzzy / phonetic if supported
    case variant     // soundex / hand-listed spelling variants
}
```

Internal — not exposed in `ResearchConfigSheet`. Derived from `ResearchMode` at dispatch time. **§7's per-source table is the authoritative spec for which sources support which tiers.** Sources that only support `.strict` treat any value as strict (see §7 column behaviour). No protocol-witness machinery; the table is the contract.

---

## 4. ResearchConfigSheet UX changes

Current (`ResearchConfigSheet.swift:38-68`):
- Depth: segmented picker, 4 options (verify/extend/discover/all)
- Scope: segmented picker, 2 options (Local / National)

New:
- Depth: unchanged.
- Scope: **5-option `Picker` with `.menu` style.** Segmented is too wide for 5 options on a 420-pt sheet.
- **Default scope = function of depth only** (per §2 decisions table):

  | Depth | Default scope |
  |---|---|
  | verify | `.district` |
  | extend | `.county` |
  | discover | `.adjacent` |
  | all | `.national` |

  Profile completeness no longer factors into the default — too many failure modes from a 2-input precedence rule. The user adjusts per-run from the sheet if the default doesn't fit.

- Description footer copy updated to explain both axes — including the strictness implication of the chosen depth (e.g. "Discover broadens to spelling variants if exact matches return empty").
- `estimatedDuration` lookup table grows from 2×4 = 8 entries to 5×4 = 20 entries. Honest ranges:

  | | parish | district | county | adjacent | national |
  |---|---|---|---|---|---|
  | verify | 5–15 s | 10–30 s | 30 s–1 min | 1–3 min | 3–8 min |
  | extend | 10–30 s | 30 s–1 min | 1–2 min | 2–5 min | 5–12 min |
  | discover | 15–45 s | 1–2 min | 2–4 min | 3–8 min | 5–15 min |
  | all | 30 s–1 min | 2–4 min | 3–6 min | **5–12 min** | **8–20 min** |

  The bottom-right two cells are bolded as a warning to the user — `.all × .adjacent` and `.all × .national` are the genuine "throw everything at it" runs and will not finish in under 5 minutes.

---

## 5. SearchDispatcher contract changes

### 5.1 Input

`RecordQuery` gains:
```swift
var strictness: SearchStrictness = .strict
```

`SearchDispatcher.dispatch(...)` gains:
```swift
mode: ResearchMode  // was implicit, now drives strictness
```

### 5.2 Internal flow

For each (source, recordType, scope-fanned-out query):

1. Build strict-tier queries.
2. Dispatch all strict queries in parallel.
3. **If `mode == .verify`**: return results as-is, no broadening.
4. **If `mode == .extend`**: for any source that returned `.results([])`, rebuild that source's query with `strictness = .loose` and dispatch a second pass for those sources only.
5. **If `mode == .discover`**: skip strict tier; build at `.loose`. For any source returning `.results([])`, rebuild at `.variant`.
6. **If `mode == .all`**: build at all three tiers in parallel, dedupe across them at the end (existing `deduplicate(...)` already handles `(sourceID, recordID)` pairs).

The existing taskgroup-per-source structure is preserved — strictness just rebuilds queries.

### 5.3 Geographic fan-out

`buildQueries(source:subject:recordType:scope:)` switches on `scope`:

- `.parish` — single query per parish-supporting source (FreeREG, FreeCen, Wirksworth where parish matches its coverage). **Parish-unsupported sources (FreeBMD, CWGC, Probate, FindAGrave) return zero queries** — they do not silently widen.
- `.district` — single query for the home parish's registration district. Sources that don't expose a district axis (FreeREG, FreeCen) widen to `.county` for those sources only.
- `.county` — current `.local` behaviour: all districts in `RegionConfig.districts(forChapmanCode: subject.homeChapmanCode)`.
- `.adjacent` — county districts + every district in counties returned by `RegionConfig.adjacentCounties(subject.homeChapmanCode)`. Single hop only.
- `.national` — current `.national` behaviour.

Wirksworth's coverage check stays unchanged at the source level — it ignores anything ≥ `.district`.

---

## 6. County adjacency data shape

File: `Ancestor Research/Resources/Regions/county-adjacency.json`

Structure:
```json
{
  "DBY": ["NTT", "STS", "CHS", "YKS", "LEI", "WAR"],
  "NTT": ["DBY", "YKS", "LIN", "LEI"],
  ...
}
```

Indexed by Chapman code (already used elsewhere — `uk-chapman-codes.json`). Values are arrays of adjacent Chapman codes. Coverage: 39 English counties + 13 Welsh + 33 Scottish + 32 Irish (pre-1922 boundaries). ~120 entries total.

Adjacency is **single-hop** and **symmetric**: if `A` lists `B`, `B` must list `A`. Test enforces both invariants.

API:
```swift
extension RegionConfig {
    func adjacentCounties(_ code: String) -> [String]
}
```

Sources for the data:
- English: pre-1974 ceremonial county boundaries (more useful for genealogy than post-1974 admin areas)
- Welsh: traditional counties (Anglesey, Brecknock, etc. — pre-1996)
- Scottish: pre-1975 counties (Aberdeen through Wigtown)
- Irish: pre-1922 counties (32 total, including the 6 that became NI)

Hand-curated; spot-checked against Ordnance Survey traditional-counties map. JSON file ships as a bundle resource; loaded once at app start; no migration concerns.

---

## 7. Per-source strictness implementation

| Source | `.strict` | `.loose` | `.variant` |
|---|---|---|---|
| CWGC | `Tab=exact` + Forename | no `Tab` param (server soundex) | **falls back to `.loose`** (no useful variant axis distinct from server soundex) |
| FreeBMD | default flags | `Phonetic=true` | one query per surname in `surname-variants.json` |
| FreeREG | exact surname | phonetic match | one query per variant |
| FreeCen | exact | phonetic | one query per variant |
| FindAGrave | exact | falls back to `.strict` | falls back to `.strict` |
| Probate | exact | falls back to `.strict` | falls back to `.strict` |
| Wirksworth | exact | falls back to `.strict` | falls back to `.strict` |

For sources whose `.loose` or `.variant` cell says "falls back to `.strict`", the dispatcher treats the source as already-at-max — no second-pass broadening attempt for that source.

Variant dictionary: `Ancestor Research/Resources/surname-variants.json`, indexed by canonical (lowercased) surname. Initially populated with the surnames currently in the user's tree (~30 entries), hand-curated. Lookup falls back to `[surname]` (single-element array — no variants) if no entry. Sources that don't support `.variant` skip the lookup entirely.

---

## 8. Implementation order — numbered Changes with acceptance criteria

Each Change is one commit, referenced as `#Change1` etc. in the commit message.

### Change 1 — Per-subject RegionConfig

- `RegionConfig.districts(forChapmanCode:)` factory: returns the district map for that county. Returns `[:]` for unknown codes (logged at warn).
- `Project.homeChapmanCode: String?` field; derives at project creation from the home-person anchor's birth location if structured; otherwise `nil`. v21 migration adds the column with `NULL` default.
- `ScoringRules.isLocalDistrict(_:forHomeChapman:)` and call sites (`ScoringRules.swift:391/396/401/406` or current equivalents) thread the subject's home Chapman code through. Behaviour-preserving when caller passes `"DBY"`.
- `RegionConfig.derbyshire` constant stays as data, but no production call site reads from it directly — they all go through the factory.

**Acceptance criteria:**
- **AC1.1** `RegionConfig.districts(forChapmanCode: "DBY")` returns the current Derbyshire district map. Unit test asserts dictionary equality with the existing constant.
- **AC1.2** `ScoringRules.isLocalDistrict("Leicester", forHomeChapman: "LEI")` returns `true`. `ScoringRules.isLocalDistrict("Leicester", forHomeChapman: "DBY")` returns `false`. Test covers both directions.
- **AC1.3** `Project.homeChapmanCode` column exists after v21 migration; legacy projects open with `NULL`; new projects with a structured home-person birth location populate it at creation.
- **AC1.4** Researching a profile in a non-Derbyshire project produces scoring decisions that match the project's home chapman code, not Derbyshire. Integration test with a synthetic Leicestershire project.

### Change 2 — County adjacency data + lookup

- Add `Ancestor Research/Resources/Regions/county-adjacency.json` with hand-curated adjacency map (~120 entries).
- Add `RegionConfig.adjacentCounties(_:)` lookup with bundled-JSON loader (mirrors `UKChapmanCodes.swift` pattern).
- **No behaviour change** — pure data + API addition. Ships green; can be reviewed in isolation.

**Acceptance criteria:**
- **AC2.1** `county-adjacency.json` ships with all 117 traditional UK + Ireland counties: 39 English, 13 Welsh, 33 Scottish, 32 Irish. Schema-validated at load.
- **AC2.2** Adjacency is symmetric: for every `A→B` entry, `B→A` exists. Verified by a single test iterating all entries.
- **AC2.3** Spot checks: `adjacentCounties("DBY")` includes `"NTT"`, `"STS"`, `"CHS"`. `adjacentCounties("KEN")` includes `"SRY"`, `"SSX"`, `"ESS"`. `adjacentCounties("ZZZ")` returns `[]` and logs at warn.

### Change 3 — ResearchScope hierarchy (depends on prior spec's Change 2)

- Replace `enum ResearchScope { case local, national }` with the 5-case hierarchy from §3.2.
- Update `SearchDispatcher.buildQueries(...)` to switch on all five.
- Migrate every `scope: .local` / `scope: .national` call site (audit: `ResearchViewModel`, `WholeTreeResearchViewModel`, `ResearchConfigSheet`, `ContentView`, any tests).
- `ResearchConfigSheet` picker stays binary (`Local` → `.county`, `National` → `.national`) for this Change — UI catches up in Change 7.
- **Transitional behaviour while prior spec's Change 2 is unimplemented:** `.parish` and `.district` silently widen to `.county` for any subject whose `birthLocationCode` is `nil`, using `Project.homeChapmanCode ?? "DBY"`.

**Acceptance criteria:**
- **AC3.1** `ResearchScope` has exactly 5 cases ordered `parish < district < county < adjacent < national`.
- **AC3.2** Dispatcher fan-out test: `.county` for a Derbyshire subject produces N queries where N = `regionConfig.districts(forChapmanCode: "DBY").count`. `.adjacent` produces N + sum of adjacent county district counts.
- **AC3.3** Parish-unsupported sources (FreeBMD, CWGC, Probate, FindAGrave) return zero queries when scope is `.parish`. Test asserts this for each.
- **AC3.4** For a subject with `birthLocationCode == nil`, `.parish` and `.district` produce the same query set as `.county`. Test logs the transitional-widening message at debug.

### Change 4 — SearchStrictness type + RecordQuery field

- Add `enum SearchStrictness` to `Models/Research/`.
- Add `strictness: SearchStrictness = .strict` to `RecordQuery`.
- `SearchDispatcher.dispatch(...)` gains `mode: ResearchMode` parameter; computes the strict-only tier and passes through (no broadening yet — Change 6 wires that).
- All sources ignore the new field initially.
- **No behaviour change** beyond the new type being available.

**Acceptance criteria:**
- **AC4.1** `SearchStrictness` exists with three cases, conforms to `Comparable`, ordered `strict < loose < variant`.
- **AC4.2** `RecordQuery.strictness` defaults to `.strict`. Existing `RecordQuery` constructors compile without modification.
- **AC4.3** `SearchDispatcher.dispatch(...)` accepts a `mode:` parameter. All current call sites pass `subject.mode` (or `.extend` if not yet available).
- **AC4.4** Pipeline integration test: a research run with `mode: .extend` produces the same record set as before this Change. Strict no-op proof.

### Change 5 — Per-source strictness handling

- CWGC, FreeBMD, FreeREG, FreeCen consume `query.strictness` per §7 table.
- Add `Ancestor Research/Resources/surname-variants.json` (≥30 surnames, seeded from the user's tree).
- Sources without broader tiers (Probate, Wirksworth, FindAGrave) treat any strictness value as `.strict`.

**Acceptance criteria:**
- **AC5.1** `surname-variants.json` ships with ≥30 entries. JSON schema-validated at load.
- **AC5.2** CWGC with `.loose` issues a request without the `Tab` parameter. CWGC with `.variant` falls back to `.loose` (no separate API call). Asserted via `FixtureHTTPClient`.
- **AC5.3** FreeBMD with `.loose` sets `Phonetic=true` in the form body. FreeBMD with `.variant` fans out N+1 queries where N is the number of variants for the surname.
- **AC5.4** Probate, Wirksworth, FindAGrave produce identical request bytes for `.strict`, `.loose`, `.variant`. Asserted via `FixtureHTTPClient`.

### Change 6 — Empty-then-broaden in dispatcher

- `SearchDispatcher.dispatch(...)` implements the §5.2 flow:
  - `verify`: strict only.
  - `extend`: detect zero-result sources, re-dispatch at `.loose`, merge.
  - `discover`: start at `.loose`; on empty, escalate to `.variant`.
  - `all`: parallel fan-out at every tier, dedupe.
- Activity bus events get a `strictness` field on **every** event (so the activity feed can colour-code or label by tier). Surfaced in `ResearchProgressView` activity feed lines.

**Acceptance criteria:**
- **AC6.1** Mode `.verify` issues only `.strict` queries. No second-pass observable in `ResearchActivityBus`. Asserted via event capture.
- **AC6.2** Mode `.extend` against a source mocked to return `[]` at `.strict` issues exactly one second-pass query at `.loose` for that source. Sources that returned non-empty at `.strict` do not get a second pass.
- **AC6.3** Mode `.discover` issues no `.strict` queries. Sources mocked to return `[]` at `.loose` receive a `.variant` follow-up.
- **AC6.4** Mode `.all` issues all three tiers in parallel. Final result set has no duplicate `(sourceID, recordID)` pairs.
- **AC6.5** **Motivating end-to-end:** A research run on a synthetic profile `{firstName: "William", lastName: "Cauldwell", birthYear: 1882, deathLocation: "Ypres"}` in `.discover` mode surfaces ≥2 CALDWELL/CAUDWELL military candidates from CWGC in the cluster review. Integration test with live `SourceHTTPClient` (network test, gated by a flag — opt-in for CI).

### Change 7 — ResearchConfigSheet 5-level scope picker

- Replace segmented `Local/National` Picker with a 5-option `.menu` picker.
- Update `estimatedDuration` lookup table (5×4 = 20 entries) with honest ranges per §4.
- `defaultScope(for: ResearchMode)` derives initial selection from depth only (per §4 table).
- Description footer updated to explain strictness implications of the chosen depth.

**Acceptance criteria:**
- **AC7.1** Scope picker shows exactly 5 options in `.menu` style. Visual snapshot test against a known good frame.
- **AC7.2** `defaultScope(for: .verify) == .district`. `defaultScope(for: .extend) == .county`. `defaultScope(for: .discover) == .adjacent`. `defaultScope(for: .all) == .national`. Unit test for each.
- **AC7.3** `estimatedDuration(mode:scope:)` returns a value for every one of the 20 (mode, scope) pairs. `(.all, .national)` returns the 8–20 min string.
- **AC7.4** Description footer text changes when the depth selection changes — verified by a single snapshot test toggling depth across the four modes.

---

## 9. Out of scope

- **Multi-region support beyond home county + adjacent.** A user with ancestors in multiple unrelated counties (e.g. Derbyshire + Cornwall) doesn't get an explicit multi-home-region option. Use `.national` for that case.
- **Two-hop adjacency.** Neighbours-of-neighbours not surfaced. Revisit if recall gaps prove the need.
- **Cross-border (Scotland ↔ England) adjacency.** Scottish and English counties don't share the same recording systems. Adjacency is within-country only.
- **Adjacency-based scoring weights.** The scorer continues to use `RegionConfig.isLocalDistrict(_:forHomeChapman:)` (post-Change-1) for "home vs away" weighting. A future change could grade adjacent-county hits between home-county and distant — out of scope here.
- **Variant dictionary auto-population.** The 30-surname seed is hand-curated. A future tool could mine the user's GEDCOM for surname transcription variants — out of scope.
- **Per-tier UI signals on result rows.** Beyond the activity-feed `strictness` field, individual records don't carry a "found at which tier" badge in the cluster review. Reasonable future addition; not required for first ship.
- **Per-subject home region.** A subject whose `birthLocationCode` puts them in a different county than the project's home-person uses the **project's** Chapman code for dispatch and scoring. Per-subject overriding is deferred.

---

## 10. Open questions

- **Q1** Should `.adjacent` scope also fan out FreeREG/FreeCen by adjacent-county parishes, or only FreeBMD by adjacent-county districts? **Default:** all three; revisit if query volume becomes a problem.
- **Q2** Does `surname-variants.json` need a UI surface for the user to add their own variants? **Default:** no for first ship — file is editable from disk if needed.
