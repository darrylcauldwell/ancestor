# DOSSIER_SPEC — The Investigation Dossier (T9 redesign)

**Status: Proposed — awaiting review (drafted 2026-07-13 from a three-design competition; small-model-first won 9/9/9).** Commits will reference `#T9-Change1`…`#T9-Change6`.

**Governing invariants:**

- **(a) Pure deterministic projection.** The dossier is a render of rows that already exist — fully useful with NO model loaded. Every statement carries ≥1 provenance ref resolving to a live row. The dossier is never persisted as evidence, never cited, never fed back into scoring.
- **(b) Selection-not-generation.** MLX never generates load-bearing content; it only selects and ranks within deterministically enumerated options, and every dispatched probe payload is **path-invariant** — byte-identical whichever path (model or deterministic fallback) chose it. Companion set contract ⟨A3⟩: the set of seedable challenges with the model ON is always a subset of the deterministic detector's set.
- **(c) A challenge is a SEARCH DIRECTIVE, never data.** Epic 13 doctrine (§5.15) inherited wholesale: no writes to tree tables from seed/probe/grade, no-self-confirmation, rejection memory, caps.
- **(d) Faithful confidence.** `ConfidenceVocabulary` ⟨A5⟩ is the *only* source of confidence language in the dossier, and it narrates the deterministic verdicts verbatim — a `.probable` cluster is never described as established, by construction.

**What this is:** the pre-commit **decision dossier** for one subject — what we know, what conflicts, what's honestly missing, what's being investigated — plus a **bounded adversarial challenge loop**: a deterministic weakness detector whose surviving challenge points become visible open questions and, on an explicit human gesture, typed search directives riding the shipped hypothesis machinery. The model smooths phrasing and ranks doubts; the rules find the weaknesses, build the probes, and grade the evidence.

**What this is not:** NOT the PROSE_CORPUS bio synthesis — that is *post-commit* biography over accepted facts at publish time; this is the *pre-commit* decision document over the full evidence state (disputes, negatives, hypotheses — things a bio must never contain). Same grounding machinery (built here, in AncestorKit, for PROSE_CORPUS to consume later), different moment. NOT an autonomous research agent — the human gesture gates every dispatch ⟨A8⟩. **This spec supersedes the old narrow T9** ("§5.5 T9 — MLX free-text disambiguation pass", `RESEARCH_PIPELINE_SPEC.md:2367`): `disambiguateIdentity` is never built, the §5.5.1 θ-threshold machinery (`:2393`) is dissolved, and RESEARCH_PIPELINE_SPEC's T9 entry should gain a supersession note pointing here.

**Provenance:** three competing designs (ledger-first / loop-first / small-model-first) judged by three lenses (invariant-fit, buildability, user-value). Small-model-first won all three at 9/10 and is adopted wholesale as the base architecture. The judges' consolidated graft list (12 amendments from the two donor designs) is folded in below, marked **⟨An⟩**; where a graft conflicts with the base, the graft wins. All file/line references verified against the working tree 2026-07-13; refs that had drifted in the competition text are corrected here (Appendix A note).

---

## 1. Reframing — what T9 becomes

Old T9 (§5.5): MLX picks a preferred candidate when `SubjectIdentityResolver` returns `.ambiguous`, gated by a user-agreement threshold θ. **Superseded, not built.** The redesign removes the model-breaks-ties pathway entirely: residual ambiguity is *rendered* (D5 candidate comparison) and *attacked* (adversarial directives that gather discriminating evidence); the rules then decide on the new evidence. No model output ever reaches `SubjectIdentityResolver` — strictly stronger than §5.5.1's "ship with θ pinned at always-reject". The shipped `compareCandidates` prose (`ResearchInterpreter.swift:260`) is absorbed as D5's renderer.

```
A. DOSSIER      deterministic skeleton from rows   → MLX smooths phrasing only
B. CHALLENGE    deterministic weakness detector    → MLX selects+phrases within
                pre-builds complete directives        a closed option set
C. HYPOTHESES   surviving challenges = typed search directives, origin
                .modelAdversarial, staged through user_hypothesis_seeds ⟨A9⟩,
                riding the SHIPPED Epic-13 framework unchanged
D. STEERING     human reads, dismisses, and DISPATCHES ⟨A8⟩ — the dossier
                itself never writes tree data
```

**The bounded loop.** One cycle = assemble → detect (fingerprint-deduped ⟨A1⟩) → optionally MLX-rank → render as open questions → human "Run this check" ⟨A8⟩ → probe under shipped budgets → evidence lands through the normal scorer → challenge statuses recompute (`answered`/`deferred`) ⟨A1,A4⟩ → skeleton hash changes → re-render. The loop is **closed by the human, not by a controller**: iteration emerges from pass → gesture → evidence → re-pass, bounded by per-pass and per-subject caps, fingerprint dedup, and `SourceBudgetTracker`. Termination is narrated in the D7 footer ⟨A2⟩: *"stopped: dry"* (nothing survived dedup), *"challenge cap"*, or *"FreeBMD budget paused — resumes next session"*.

---

## 2. Decision log

1. **T9 pivots from tie-breaker to render-and-refute.** Model output never reaches the resolver; the θ discipline transfers to a measurable adversarial-agreement metric with a deterministic-only kill switch (§10).
2. **Selection-not-generation, by construction.** The detector pre-builds *complete* `HypothesisKind` payloads; MLX picks from a numbered list and phrases ≤240-char rationales. Path-invariance (dispatched payloads byte-identical across paths) and membership invariance ⟨A3⟩ (seedable-with-model ⊆ detector set) are both acceptance-tested. This is the reliable envelope of a 4B local model — the winning design's core, kept whole.
3. **Skeleton is the product.** The deterministic dossier ships first and remains the always-available fallback; smoothing is the second-to-last change. Verification failures *drop to skeleton, never soften* (PROSE_CORPUS rule adopted now).
4. **Transport through the shipped staging table ⟨A9⟩ — grafts win over base.** Adversarial seeds go through `user_hypothesis_seeds` (v32, `ProjectDatabase.swift:998`) with `requested_by = 'adversarialLoop'` and the challenge fingerprint in the payload — **never direct `HypothesisEngine` emission**. This inherits §5.15.2 validation and refusal codes for free (incl. `previouslyRejected`, `HypothesisSeedService.swift:49`), keeps the engine sole owner of `research_hypotheses`, and preserves a full audit trail of what the loop asked for and why. `requested_by` is TEXT with no CHECK constraint ('mcp' | 'workbench' today) — the new value needs no migration.
5. **Default dispatch posture ⟨A8⟩ — grafts win over base.** `.modelAdversarial` rows **never dispatch** until an explicit human gesture — "Run this check" (one row) or "Run checks now" (the subject's open batch). The gesture confers batch-scoped user intent, riding the same `origin == .user` unconditional-dispatch predicate Epic 13's E4 established in `ResearchPipeline` (mirroring the §5.11 investigate gesture, `RESEARCH_PIPELINE_SPEC.md:2666`). Until then the rows are *visible open questions*. The base design's rides-the-T7-stall-gate posture is rejected: model speculation never spends volunteer-source budget without a human in the loop.
6. **Durable challenge memory ⟨A1⟩.** New `challenge_points` table keyed by deterministic fingerprint with status lifecycle `openQuestion | seeded | probing | answered | dismissed | deferred`. A **dismissed challenge is never re-raised** (the challenge-level `user_rejected`); **`answered` is recomputed automatically** when evidence lands (a W1 single-witness challenge flips when a second independent witness arrives — the researcher sees challenges get resolved). `deferred(budget)` is first-class ⟨A4⟩: a probe hitting a paused source defers visibly and resumes next session, never silently dropped.
7. **Grade-at-materialisation ⟨A7⟩ — a new step, not existing behaviour.** `HypothesisSeedService` materialisation (`HypothesisSeedService.swift:243`) today updates seed status only; grading waits for the next pipeline flow. This spec adds an immediate deterministic grade against already-held evidence at materialisation for `adversarialLoop` rows: a hypothesis the tree already contradicts lands `.contradicted` instantly, at zero wire cost, and is never probed.
8. **No-self-confirmation at the witness level.** A directive spawned to corroborate fact F carries `excludedWitnesses` = F's current WitnessKeys, recomputed via `WitnessIdentity.key(for:)` (`WitnessIdentity.swift:59`) at grade time — keys never persisted (CONFLICT_LAYER §2.6 honoured). Another transcription of the same GRO line cannot corroborate itself.
9. **`ConfidenceVocabulary` is a single named component ⟨A5⟩** (AncestorKit, beside the grounding types): the exhaustive enum→phrase table for `matchQuality` / `ConvergenceLevel` / hypothesis verdicts / dispute states. Smoothing verification enforces «verbatim confidence phrase» containment (protected phrases must appear byte-identical or the section falls back), digit protection ⟨A11⟩ (a smoothed sentence whose digits differ from its skeleton source is rejected), and a banned lexicon ("proves", "certainly", "undoubtedly", "must have").
10. **One new kind, `.censusPresence(year:district:)`** — through the sanctioned Decision-1 typed-kind path. It is the workhorse directive (W1/W4/W5/W7) and simultaneously lands the deferred census-gap re-probe roadmap item (memory: `project_census_gap_reprobe_deferred`).
11. **Third origin `.modelAdversarial`.** `Origin` (`ResearchHypothesis.swift:40-43`, TEXT-backed, decode-defaulted — no migration) gains the case Epic 13's Decision E1 anticipated. `isModelAssisted` (`:89`) is `true` only when an MLX pick selected the row, `false` on the deterministic-fallback path; verdicts are always `isModelAssisted = false` — grading never has model input.
12. **Honest process narration.** D7 provenance footer ⟨A2⟩; per-section empty states distinguishing *no rows recorded* from *searched and nothing found* ⟨A12⟩; cap-reached behaviour states what was dropped (over-cap directives render display-only with an explicit note, never vanish). No autonomous `InvestigationLoopController`, no parallel budget layer, no coverage-matrix substrate — the loop-first design's machinery is rejected; its honesty features are kept.

---

## 3. Conceptual model

```
GroundedSentence = (text, refs: [ProvenanceRef]); a sentence with an empty ref
                   set cannot be constructed. ProvenanceRef = typed row ref:
                   .fieldSource(id) | .dispute(id) | .hypothesis(id) |
                   .negativeSearch(id) | .lifeEvent(id) | .challenge(fingerprint) |
                   .gpsCriterion(n) | .cluster(id) | .evidenceRecord(id) |
                   .relationship(id)

Dossier          = header + D1–D7 sections of GroundedSentences. A projection,
                   never data: recomputed from rows, cached only as display prose.

ChallengePoint   = one deterministic weakness finding:
                   (fingerprint, kind W1–W9, severity, refute-framed statement,
                    refs, directives: [CandidateDirective])
                   fingerprint = hash(kind, profileID, normalised params) — the
                   challenge equivalent of identityKey.

CandidateDirective = a FULLY-BUILT, engine-checkable HypothesisKind payload +
                   deterministic rationale template + excludedWitnesses refs.
                   The model can select it; nothing can reshape it.

Challenge lifecycle ⟨A1,A4⟩:
   openQuestion ──(human gesture / seed)──▶ seeded ──▶ probing ──▶ answered
        │                                     │            │
        └──▶ dismissed (TERMINAL —            └────────────┴──▶ deferred(budget)
             fingerprint never re-raised)                       (resumes next
   answered/deferred recomputed at every assembly;               session)
   a challenge whose trigger predicate no longer fires → answered(byRowRef).
```

---

## 4. Components

| Component | File | Responsibility |
|---|---|---|
| `GroundedSentence` / `ProvenanceRef` / `GroundedProseVerifier` / `ConfidenceVocabulary` ⟨A5⟩ | NEW `AncestorKit/Sources/AncestorKit/Research/GroundedProse.swift` | Grounding types, the zero-hallucination gate for smoothed text (§7.2), the only confidence-language table. In AncestorKit so PROSE_CORPUS bio synthesis reuses them later. |
| `DossierAssembler` | NEW `Ancestor Research/Services/Research/DossierAssembler.swift` | Pure, nonisolated, unit-testable (same posture as `ConflictDetector`). `(rows) → Dossier`. Zero writes, zero model calls. |
| `ChallengePointDetector` | NEW `Ancestor Research/Services/Research/ChallengePointDetector.swift` | Deterministic weakness catalogue W1–W9 (§6) with pre-built directives; fingerprint dedup against `challenge_points`. Pure except the challenge-point store. |
| `DossierInterpreter` | NEW `Ancestor Research/Services/Research/DossierInterpreter.swift` | The **only** MLX surface: Pass B selection (§7.1), Pass A smoothing (§7.2). Sibling of `ResearchInterpreter`; same defensive-parse idiom as `parseFocusedQuery` (`ResearchInterpreter.swift:182`), JSON via `LocalInferenceService.reasonJSON` (`LocalInferenceService.swift:357` — the base design's `extractJSONDictionary` does not exist; corrected). Model-absent (`isAvailable`, `:111`) or invalid output → deterministic result, identical shape. |
| Emission path ⟨A9⟩ | `HypothesisSeedService.swift` (+ `ResearchHypothesis.swift`, `HypothesisEngine.swift`) | Challenge → staged seed (`requested_by='adversarialLoop'`, fingerprint in payload) → §5.15.2 validation → materialise with `origin = .modelAdversarial` → **grade-at-materialisation** ⟨A7⟩. Caps §4.5. |
| `HypothesisEngine+CensusPresence` | NEW `Ancestor Research/Services/Research/HypothesisEngine+CensusPresence.swift` | Generator/grader/deficit ladder for the one new kind, wired into the three central switches (`HypothesisEngine.swift:73/:106` + the deficit switch) exactly like the 8 existing `HypothesisEngine+*.swift` extensions. |
| `DossierView` | NEW `Ancestor Research/Views/Dossier/DossierView.swift` + `DossierComponents.swift` | Render sections; provenance refs as tappable anchors; steering actions delegate to existing flows only. `AppTypography` tokens; files <300 lines. |
| MCP read surface | `FieldResearcherMCP/Sources/MCPServer.swift` | `ancestor://profile/{id}/dossier` resource — deterministic skeleton as JSON. Read-only, model-free (the server never runs MLX); Evidence Firewall untouched. |

### 4.1 Assembler inputs (all existing, one new fetch helper)

`allDisputes(profileID:)` (`ProjectDatabase.swift:3732` — the CONFLICT_LAYER §4.8.6 contract: `reasoning`, per-rung `ladder_trace`, `witness_summary` verbatim); `field_sources`; `research_hypotheses` (+ `candidateGroupID`, `ResearchHypothesis.swift:75`; `Transition` history `:48-60`); `negative_searches` via **new** `negativeSearches(profileID:)` fetch helper (table v1 `ProjectDatabase.swift:195`; index `idx_negative_searches_profile` exists at `:220`; no helper exists today); `SearchOutcome` honesty envelope (`RecordTypes.swift:956` — `truncated` `:966`, `suppressed` `:979`, availability cases `.ok/.error/.throttled/.blocked/.requiresAuth` `:918-943`, **`isCleanNegative`** `:1032` — exact name, base's `countsAsCleanNegative` corrected); GPS criterion reasons (`GPSScorer.swift` — c1 `:101`, c2 `:121`, c3 `:146`, c4 `:181` with open-dispute enumeration, c5 `:244`; competition text's `:95–:184` had drifted); `ConvergenceEngine.scoreValueGroups` (`:173`); `WitnessIdentity.key(for:)` (`:59`) + `independentWitnessCount` (`WitnessIdentity.swift:172`, surfaced on `SourcingStrength`, `EvidenceConfidence.swift:66`); `life_events`; `research_discrepancies` (`run_id` since v41, `ProjectDatabase.swift:1308-1310`); `challenge_points` (§8).

### 4.2 Refresh lifecycle

Assembly is a cheap pure read: recompute on view appear and after run completion. Staleness is detected by **skeleton content hash** comparison ⟨A6⟩ — not by an event-token scheme (the base design's `ResearchActivityBus` invalidation events do not exist; the bus carries source/pipeline telemetry only — corrected). Existing bus events (`sourceQueryCompleted`, `pipelineStage`, `dailyBudgetExhausted`) may opportunistically trigger a recompute; correctness never depends on them. Smoothed prose is cached keyed `(profile_id, skeleton_hash, section)` (§8): hash change invalidates, the skeleton shows immediately, re-smoothing runs in background — MLX runs once per distinct ledger state.

### 4.3 Surfaces

(a) Profile page — "Investigation Dossier" entry in `SharedProfileLayout`, sibling of the shipped Disputes (`:184-230`) and Conflicts (`:237`) sections (base's `:165-186` had drifted); (b) `ClusterReviewView` — per-candidate dossier absorbs the "Compare candidates" action; (c) Workbench — dossier link beside `HypothesesView`. One view, three doors.

### 4.4 Steering (D)

Existing flows only: *dismiss challenge* (fingerprint → `dismissed`, terminal ⟨A1⟩); *dismiss hypothesis* (`user_rejected = 1`, rejection memory); *Run this check / Run checks now* ⟨A8⟩ (batch-scoped user-intent dispatch, §2.5); *investigate further* (§5.11 gesture → next deficit level); *accept proposals* via the shipped ⟨G12⟩ proposed-resolution banners and choose-one cards. `DossierView` calls existing `AppState`/`ResearchViewModel` actions; it introduces **no new write path** to tree data.

### 4.5 Bounds and memory

- ≤ 3 new `.modelAdversarial` seeds per pass; ≤ 5 open per subject. At cap the detector still runs; over-cap directives render display-only with a "cap reached — N dropped" note ⟨A12⟩.
- Fingerprint dedup ⟨A1⟩ upstream (never re-raise dismissed/open fingerprints) + `identityKey` collision upsert (`ResearchHypothesis.swift:338`) + `previouslyRejected` intake refusal downstream — three independent layers, re-running a pass is idempotent.
- Probes share the run's source budget; `SourceBudgetTracker.isPaused` (`SourceBudgetTracker.swift:82`) → challenge status `deferred(budget)` ⟨A4⟩, resumed next session; no wire calls outside a run/gesture context. `ExpansionPolicy` bounds consumed unmodified. Volunteer-source etiquette (FreeBMD daily budget) holds by construction.
- W2/W3 challenge kinds are *prioritisations of existing rows* — they never create hypotheses and don't count against caps.

---

## 5. The dossier — section contract

Every sentence is a `GroundedSentence`; a sentence with an empty ref set is a bug and is never emitted. Each section renders an **honest empty state** ⟨A12⟩ distinguishing *no rows recorded* ("No negative searches recorded — absence here means *not yet searched*") from *searched and nothing found* (clean-negative-backed).

**D0 — Header.** Subject, primary cluster `matchQuality`, one line per GPS criterion using the criterion `reason` strings **verbatim** (rewritten for honesty in CL3 — they enumerate open disputes). Refs: GPS criterion index + cluster ID.

**D1 — What we know.** Per accepted fact: value, `independentWitnessCount` (recomputed WitnessKeys — never "3 sources" for one GRO line transcribed thrice), best tier + directness, per-ValueGroup convergence. Template family generalises `deterministicEvidenceSummary` (`ResearchInterpreter.swift:19`): *"Birth year 1883 is established by 2 independent witnesses (GRO index; census enumeration). Convergence: probable."* Confidence phrases come only from `ConfidenceVocabulary` — narrated exactly at the computed verdict.

**D2 — What conflicts.** A render of `allDisputes(profileID:)`, open first (severity desc): `reasoning` verbatim, per-value `witness_summary` weighing, resolved rows with rule ID + one-line `ladder_trace` digest (*"Resolved by R2a — CWGC primary over community memorial"*). Deferred/dismissed collapsed. The stored strings ARE the text; MLX may paraphrase them, the verbatim string remains the fallback and one tap away.

**D3 — What's missing.** Three honesty classes, never conflated: (a) *searched and absent* — only `isCleanNegative` rows ("FreeBMD death index 1900–1910, searched 2026-06-30: no match"), suppressed cross-run negatives shown with their suppression provenance; (b) *partial answer — not evidence of absence* — `truncated`, `.throttled`, `.blocked`, `.requiresAuth` outcomes, explicitly labelled; a gap is **never** synthesised from truncation; (c) *structural gaps* — gap-finder predicates (the same ones `compare_gaps.py` checks) + in-scope census years with neither a record nor a clean negative.

**D4 — What's being investigated.** Hypothesis rows grouped by `candidateGroupID` (choose-one groups render as one comparison, mirroring ⟨G5⟩): kind, verdict, `reasoning` verbatim, attempts/ladder level, origin badge (engine / user / model-adversarial), verdict-history one-liner. Contradicted user hunches keep their §5.15.8 prominence.

**D5 — Candidate comparison** (only when ≥2 clusters ≥ `.probable`, or resolver ambiguity): side-by-side deterministic table of the discriminating fields (where the clusters' ValueGroups diverge), each cell reffed. Old T9's territory lands here — as rendering plus challenge fodder (W5), never as a model verdict.

**D6 — Challenges.** `challenge_points` render: refute-framed statement, status badge, linked hypothesis verdict, model-or-template rationale (provenance-stamped), dismissed collapsed (revivable — a tested-and-dismissed challenge is a research result), deferred with the pause reason ⟨A4⟩, over-cap items with the drop note ⟨A12⟩.

**D7 — Provenance footer ⟨A2⟩.** Generated-at; skeleton content hash; per-section row counts; narration mode (*"deterministic"* or *"smoothed by Qwen3.5-4B — verified"*); and the loop termination reason (*"stopped: dry"* / *"challenge cap (3 seeded, 2 shown unseeded)"* / *"FreeBMD budget paused — resumes next session"* / *"no challenge pass run yet"*).

**Grounding rules (normative):** (1) every sentence ≥1 ref resolving to a live row; (2) verbatim-string doctrine — dispute `reasoning`/`ladder_trace`, GPS reasons, hypothesis `reasoning` are quoted or truncated, never re-worded deterministically; (3) confidence terms only via `ConfidenceVocabulary`; (4) numbers/years/names must originate in the reffed rows — structurally in the assembler (templates only interpolate row fields), re-checked by `GroundedProseVerifier` on any MLX output; (5) the dossier is a projection, never a source.

---

## 6. The challenge scaffold — deterministic classes

`ChallengePointDetector.detect(profile:, dossier:) -> [ChallengePoint]` — pure; the honesty envelope is consulted inside every trigger predicate (truncated/blocked/throttled never counts as searched, so absence-shaped challenges fire only where the absence is real).

| ID | Trigger (all deterministic) | Directive(s) pre-built |
|---|---|---|
| **W1** | Accepted fact with `independentWitnessCount == 1` | Corroborate via a *different archive class*: birthDate → `.censusPresence(firstCensusYear ≥ birth)`; deathDate → `.burialAtParish` (`ResearchHypothesis.swift:310`, existing kind) |
| **W2** | Open `fieldValue` dispute on a date field | **No new row** — priority-bump the CL5 candidate group (link, don't mint) |
| **W3** | Hypothesis `.inconclusive` with linkage-unproven reasoning | **No new row** — priority bump to its next ladder level |
| **W4** | In-scope census year Y, `birth < Y < death`, no accepted census record, no clean negative | `.censusPresence(Y, district)` — lands the deferred census-gap re-probe feature |
| **W5** | ≥2 rival clusters `matchQuality ≥ .confirmed`, disjoint anchors (GPS-c4 predicate reused) | Discriminator probe: `.censusPresence` in the diverging year/place; date rivalries → W2 path |
| **W6** | Marriage edge with spouse-side single witness, or census marital status widowed/remarried with no matching marriage record | `.subjectSpouseMarriage` re-probe / `.secondMarriage` (`:313`) — delivers CL6's deferred F4b affordance as a by-product |
| **W7** | >10-year gap between consecutive accepted life events with zero coverage | `.censusPresence` for census years inside the gap |
| **W8** ⟨A10⟩ | `.expectedRecordAbsent` — a **clean negative** where the timeline says a record should exist (death in scope, death index cleanly searched across the expected decade, no hit) | Adjacent record-class probe: probate / `.burialAtParish` / window-widened re-probe within `ExpansionPolicy` bounds. The one place a clean negative is itself the weakness signal |
| **W9** ⟨A10⟩ | `.modelAssistedVerdict` — any `isModelAssisted` verdict (`:89`) in the subject's evidence chain | No directive — a transparency line linking to the underlying hypothesis; the model's earlier involvement is automatically a challengeable weakness |

**Fingerprints and lifecycle ⟨A1⟩:** stable ID (e.g. `"W4:census:1901"`); dedup against `challenge_points` — a `dismissed` fingerprint is never re-raised; `answered` recomputed at every assembly (trigger predicate no longer fires → status flips with the answering row ref); `deferred(budget)` ⟨A4⟩ set when the directive's source `isPaused`, re-queued on next session start if unpaused.

**Deterministic fallback ranking** (used verbatim when MLX is absent or its output invalid): severity desc → W2 → W5 → W1/W6 (death, birth, marriage) → W8 → W4/W7 chronological → W9. Top-N emitted with template rationales. **Identical output shape to the MLX path.**

---

## 7. MLX prompt contracts (4B-calibrated; both via `DossierInterpreter`)

### 7.1 Pass B — adversarial selection

The model **selects and phrases; it never invents an option.** Input ≤ ~1,800 tokens (digest, not full dossier); bounded output.

```
SYSTEM: You are an adversarial genealogy reviewer. Find the strongest reasons
this identification could be WRONG. You may ONLY choose from the numbered
challenge options provided. Output JSON: {"picks":[{"id":"<option id>",
"rationale":"<one sentence>"}]}. At most {N} picks. No other keys.
If no option is worth pursuing, output {"picks":[]}.

USER: SUBJECT: {name}, b.{year} {district}. CONFIDENCE: {matchQuality}.
ACCEPTED FACTS: {per-fact lines: value · witnesses · tiers}
OPEN CONFLICTS: {dispute reason strings, verbatim, truncated}
OPTIONS:
[W4:census:1901] No 1901 census record and the year was never cleanly
searched. Directive: FreeCen 1901, SMITH Mary, Belper.
…
```

**Validation (any failure → deterministic fallback for the whole pass):** JSON via `reasonJSON`; pick IDs ⊆ offered set; ≤ N, deduped; rationale ≤ 240 chars; entity cross-check — every 4-digit year and capitalised proper noun in a rationale must appear in the prompt input (the `parseFocusedQuery` lifespan-guard idiom generalised). Surviving picks keep the model rationale (row stamped `isModelAssisted = true`); rejected/absent → template rationale, `false`. **The directives dispatched are identical either way** — MLX affects ordering and phrasing only (path invariance), and can never seed outside the detector's set (membership invariance ⟨A3⟩, acceptance-tested as an explicit subset contract). An explicit `{"picks":[]}` is respected as the model's give-up signal, but the top deterministic challenge points still render in D6 display-only — model silence has no suppressive power over information.

### 7.2 Pass A — dossier smoothing

Per-section (inputs ≤ ~600 tokens), optional, second-to-last change:

```
SYSTEM: Rewrite the numbered sentences as one flowing paragraph. You must not
add, remove, or alter any fact, name, date, place, or number. Confidence
phrases marked «…» must appear exactly as written. Keep each sentence's tag
[S1]…[Sn] attached to the clause it supports. Output only the paragraph.
USER: [S1] Birth year 1883 «established by» 2 independent witnesses… [S2] …
```

**`GroundedProseVerifier` (deterministic; shared with future bio synthesis):**
1. **Ref subset + completeness** — every output tag ∈ input tags; every input tag present (nothing silently dropped).
2. **Entity cross-check** — all 4-digit numbers, title-case tokens ≥3 chars, and confidence words in the output appear in the input.
3. **Digit protection ⟨A11⟩** — a sentence whose digits differ from its skeleton source is rejected.
4. **«Verbatim confidence phrase» containment ⟨A5⟩** — every protected phrase appears byte-identical, or the section is rejected (catches `probable → probably genuine`, which the entity check alone would pass).
5. **Banned lexicon ⟨A11⟩** — "proves", "certainly", "undoubtedly", "must have" (permanent unit-tested list on `ConfidenceVocabulary`).
6. **Length** — ≤ 1.5× input chars.

Any failure → that section renders the skeleton (drop, never soften; fallback is per-section, never per-dossier). Skeleton text stays one tap away even when smoothing succeeds. **Cache ⟨A6⟩:** `dossier_cache` keyed `(profile_id, skeleton_hash, section)` — MLX runs once per distinct ledger state; hash change invalidates; skeleton shows until re-smoothed.

---

## 8. Schema — migration `v42_dossier` (single migration; ships with #T9-Change2)

Current head is `v41_conflict_layer` (`ProjectDatabase.swift:1262`), so v42 is next.

```sql
CREATE TABLE challenge_points (                     -- ⟨A1⟩
    fingerprint TEXT PRIMARY KEY,                   -- hash(kind, profile_id, normalised params)
    profile_id TEXT NOT NULL,
    kind TEXT NOT NULL,                             -- 'W1'..'W9'
    status TEXT NOT NULL,                           -- openQuestion|seeded|probing|answered|dismissed|deferred
    severity TEXT,
    seeded_hypothesis_id TEXT,
    rationale TEXT,                                 -- template or verified model rationale
    detail_json TEXT,                               -- typed params, row refs, model_id when
                                                    -- model-picked, deferral reason ⟨A4⟩
    created_at DATETIME NOT NULL,
    status_changed_at DATETIME
);
CREATE INDEX idx_challenge_points_profile ON challenge_points(profile_id, status);

CREATE TABLE dossier_cache (                        -- ⟨A6⟩ display cache, discardable,
    profile_id TEXT NOT NULL,                       -- never evidence, never published
    skeleton_hash TEXT NOT NULL,
    section_id TEXT NOT NULL,
    smoothed_json TEXT NOT NULL,                    -- verified sentences only
    model_id TEXT NOT NULL,
    created_at DATETIME NOT NULL,
    PRIMARY KEY (profile_id, skeleton_hash, section_id)
);
```

**No-migration notes:** `Origin` gains `'modelAdversarial'` (TEXT-backed, decode-defaulted); `user_hypothesis_seeds.requested_by` gains `'adversarialLoop'` (TEXT, no CHECK constraint — verified); seed payload JSON gains optional `challenge_fingerprint` ⟨A9⟩. The dossier itself is never persisted. No changes to the Evidence Firewall write surface, no new writable MCP tables.

---

## 9. Changes

Each independently shippable, gated by `xcodebuild test`. Ordering is load-bearing: skeleton before detector before emission before any MLX — the first two gates are pure additive reads.

### Change 1 — deterministic dossier + surfaces (M)

**Scope:** `GroundedProse.swift` (types + `ConfidenceVocabulary` ⟨A5⟩; verifier stub); `DossierAssembler` D0–D5 + D7 footer ⟨A2⟩ (narration mode "deterministic"; termination "no challenge pass run yet"); `negativeSearches(profileID:)` fetch helper; `DossierView` + three entry points; honest empty states ⟨A12⟩; MCP dossier resource.

**Acceptance criteria:** (1) model-absent machine renders every section; (2) every sentence carries ≥1 ref resolving to a live row (test walks all refs); (3) D2 strings byte-match `DisputeRow` `reasoning`/rule IDs; (4) D3 never lists a truncated/blocked outcome as a gap (fixture with `truncated: true`), and empty-state copy distinguishes no-rows from clean-negative ⟨A12⟩; (5) John-1840/41 fixture renders D5 with both clusters; George Brooks fixture renders its candidate group from rows; (6) MCP resource returns the same skeleton; `FieldResearcherMCP` `swift build` green; (7) zero DB writes during assembly (DB-diff); (8) D7 footer carries hash + per-section counts.

**Blast radius:** new files, one `ProjectDatabase` fetch helper, `MCPServer.swift` read resource, `SharedProfileLayout` entry. Zero behaviour change anywhere.

### Change 2 — challenge detector + durable memory (M)

**Scope:** v42 migration (§8); `ChallengePointDetector` W1–W9 (⟨A10⟩ classes included) with pre-built directives; fingerprint lifecycle ⟨A1⟩ (dismiss gesture; `answered` recompute at assembly); D6 render display-only; deterministic ranking; cap-note rendering ⟨A12⟩. No emission, no MLX.

**Acceptance criteria:** (1) each W-class has a fixture producing exactly its point with correct refs; (2) W4 fires only when no clean negative exists AND not merely truncated (both directions); (3) W8 fires only on an `isCleanNegative` row in the expected window ⟨A10⟩; (4) W9 fires on an `isModelAssisted` verdict in the chain ⟨A10⟩; (5) W2/W3 produce priority markers, never rows; (6) a dismissed fingerprint is never re-raised across passes ⟨A1⟩; (7) a W1 flips to `answered` when a second independent witness lands (status-recompute test) ⟨A1⟩; (8) detector writes nothing outside `challenge_points`; ranking matches the normative fallback order.

**Blast radius:** migration, new detector file, `DossierView` D6, challenge-point store in `ProjectDatabase`. No hypothesis, dispatch, or scorer surface touched.

### Change 3 — emission + steering, deterministic end-to-end (L)

**Scope:** `Origin.modelAdversarial`; `.censusPresence(year:district:)` kind + `HypothesisEngine+CensusPresence` (generator/grader/deficit; grading uses `isCleanNegative`, asymmetric verdicts — clean exhaustive negative → `.inconclusive`, **never** `.contradicted`); staging transport ⟨A9⟩ (`requested_by='adversarialLoop'`, fingerprint in payload, §5.15.2 validation incl. `previouslyRejected`); watcher materialisation maps origin + **grade-at-materialisation** ⟨A7⟩; caps + over-cap display ⟨A12⟩; `excludedWitnesses` no-self-confirmation; "Run this check"/"Run checks now" dispatch gesture ⟨A8⟩ (batch-scoped `origin == .user`-equivalent carve-out); `deferred(budget)` ⟨A4⟩ via `SourceBudgetTracker.isPaused` + next-session resume.

**Acceptance criteria:** (1) end-to-end: challenge → seed row → materialised hypothesis `origin='modelAdversarial'`, `isModelAssisted=false`, correct `identityKey` → immediate deterministic grade; a tree-contradicted seed lands `.contradicted` with zero dispatches ⟨A7⟩; (2) DB-diff: seed+materialise+grade writes nothing to `profiles`/`relationships`/`life_events`/`citations` (§5.15.11 test reused); (3) **no dispatch without the gesture**: a research run completes with open adversarial rows and `searchHistory` is unchanged; the gesture dispatches exactly that batch ⟨A8⟩; (4) same-WitnessKey evidence cannot flip `.supported` (GRO-retranscription fixture); (5) `.censusPresence` clean negative grades `.inconclusive`, never `.contradicted`; (6) paused source → challenge `deferred`, footer names it, resumes next session ⟨A4⟩; (7) `previouslyRejected` refusal blocks re-seeding of a dismissed hypothesis; a dismissed *challenge* never reaches intake at all ⟨A1⟩; (8) 6th open seed refused at compile → display-only with cap note ⟨A12⟩; (9) old-JSON hypothesis decode passes (Codable-additive).

**Blast radius:** `ResearchHypothesis.swift` (Origin case + kind), `HypothesisEngine.swift` (3 switch arms) + new extension file, `HypothesisSeedService.swift` (new requester value + grade-at-materialisation step), dispatch-flag plumbing in `ResearchPipeline`/`SearchDispatcher` call path (`dispatchOne`, `SearchDispatcher.swift:157`), `DossierView` actions. The heaviest gate — the deterministic pillar must be whole before any MLX.

### Change 4 — MLX Pass B: adversarial selection (S)

**Scope:** `DossierInterpreter.selectChallenges` prompt + closed-schema validation + entity cross-check + whole-pass fallback; `isModelAssisted=true` stamping on model-picked rows; pick provenance into `challenge_points.detail_json` (the eval log home — no new table).

**Acceptance criteria:** (1) crafted garbage (bad JSON, foreign IDs, over-cap, hallucinated year in rationale) each falls back to deterministic ranking, output shape identical; (2) `{"picks":[]}` respected — D6 still renders deterministic points display-only; (3) model-absent path bit-identical to Change 3; (4) **path invariance**: dispatched directive payloads byte-equal regardless of which path ranked them; (5) **membership invariance ⟨A3⟩**: property test asserts seedable-with-model ⊆ detector set over the fixture corpus.

**Blast radius:** new interpreter methods, `LocalInferenceService` call sites, detector→interpreter seam. No schema, no dispatch semantics.

### Change 5 — MLX Pass A: smoothing + verifier + cache (S)

**Scope:** per-section smoothing; `GroundedProseVerifier` full checks (§7.2, incl. digit protection ⟨A11⟩, «confidence» containment ⟨A5⟩, banned lexicon); `dossier_cache` ⟨A6⟩; D7 narration mode flips to "smoothed by <model> — verified".

**Acceptance criteria:** (1) six rejection fixtures — added year, dropped tag, novel proper noun, altered «confidence phrase», digit drift, 1.6× length — each falls back to skeleton per-section; (2) banned-word output rejected ⟨A11⟩; (3) accepted smoothing preserves all tags, entities, and protected phrases; (4) cache hit skips inference; hash change invalidates and shows skeleton until re-smoothed ⟨A6⟩; (5) model-absent renders skeleton with no UI difference beyond phrasing; footer states the mode ⟨A2⟩.

**Blast radius:** interpreter, verifier, cache table I/O, `DossierView` mode badge. Nothing load-bearing — deletable without loss of function.

### Change 6 — lifecycle + eval (S)

**Scope:** once-per-run auto challenge pass (opt-in, default on, debounced — **detection and rendering only**, dispatch stays gesture-gated ⟨A8⟩); hash-based staleness + post-run refresh; deferred-challenge resume on session start ⟨A4⟩; research-summary line ("2 challenges raised on George Brooks"); harness agreement-rate report + deterministic-only kill-switch flag (§10).

**Acceptance criteria:** (1) dossier refreshes after run-complete/dispute-resolve/accept without relaunch; (2) exactly one auto pass per completed run, and it dispatches nothing; (3) a deferred challenge re-queues when its source unpauses next session; (4) harness emits agreement rate over the §5.8 eval corpus; (5) full suite green (`BackupServiceTests`/`staticServicesAreThreadSafe` flakes isolation-cleared per memory).

**Blast radius:** run-completion hook, session-start hook, harness reporting. No new write paths.

---

## 10. Eval discipline (replaces §5.5.1 θ)

Per-pass provenance lives in `challenge_points` (`detail_json`: options offered, model-vs-fallback pick, `model_id`); user actions are the status transitions themselves. Metric: **adversarial agreement rate** = investigated ÷ (investigated + dismissed) over the §5.8 harness corpus. Pass B ships enabled because the fallback is identical-shape (the spiritual successor of "θ pinned at always-reject" — but the feature works day one); if agreement on the 20–30-profile tier falls below 50%, Pass B drops to deterministic-only by default flag. Pass A has no metric — it is presentation only and verifier-gated.

---

## 11. Non-goals (explicit)

1. **No API/cloud model tier** — local MLX only (in-app Claude tier removed pre-App-Store). The provider seam is nonetheless deliberate: everything model-facing routes through `DossierInterpreter`'s selection/smoothing contracts, so a future BYO-key frontier tier (decision-gated: privacy consent + living-people redaction on outbound prompts) would slot behind the same cage without design change — better selections and prose, same invariants. Explored 2026-07-13; all identified frontier benefits remain live candidates (prose-fact extraction feeding the firewall, a tier-2 challenger, whole-tree direction, better narration) — dev-side judging/build assistance is simply the first mover because it needs no product changes. The user-facing tier is undecided, not deprioritised.
2. **No model-decided anything**: verdicts, dispute resolution, cluster merges, resolver input, tier assertion (trust stays URL-derived), §14.3 auto-approval changes. `disambiguateIdentity` and the §5.5.1 threshold: never built, formally retired.
3. **No free-generation hypothesis kinds and no parameter synthesis by the model** — it selects pre-built payloads only; window-tweaking is out of scope (the ledger-first design's model-composed axes were the judged-fatal flaw; not adopted).
4. **No autonomous dispatch** — no T7-stall-gate riding for model-origin rows ⟨A8⟩, no loop controller, no iteration budgets, no batch adversarial sweeps, no whole-tree passes; subject-scoped only.
5. **No dossier persistence as evidence/citation**; never published to viewers; not in the CloudKit snapshot; `dossier_cache` is discardable display prose.
6. **No NL hunch parsing** (Epic 13 phase (c) — separate pass, now unblocked to reuse `DossierInterpreter`'s validation idioms).
7. **No location value-candidate kinds** (CONFLICT_LAYER §7 ceiling stands) and no new dispute producers — D2 is a pure consumer of `allDisputes`.
8. **No new MCP write surface** — the dossier resource is read-only and model-free; external hunches keep using `submit_hypothesis`; the Evidence Firewall (`pending_facts` + `leads`) is untouched.
9. **No `.parentCandidates` seeding by this loop** — its user-seeded-only contract (`ResearchHypothesis.swift:283-298`, case at `:299`) is inviolate; adversarial identity work links to the engine-origin `.parentIdentityCandidate` machinery instead.

---

## 12. Python-parity note

**None — no Python counterpart.** The dossier, challenge scaffold, hypothesis framework, and MLX surfaces are Swift-first territory (`feedback_swift_is_what_ships`); Python has no dispute persistence, no hypothesis rows, and no local model. Where the dossier *reuses* ported predicates it must not fork them: D3's structural gaps use the same gap-finder predicates `compare_gaps.py` checks. The twin/GEDCOM interchange formats carry no dossier or challenge data, so `compare_twins.py` / `compare_gaps.py` must stay green throughout as the no-op proof — run them at every gate.

---

## Appendix A — integration-point map (verified against the working tree 2026-07-13)

| Surface | Location |
|---|---|
| v41 migration head (v42 goes after) | `Ancestor Research/Services/ProjectDatabase.swift:1262` |
| `DisputeRow` / `openDisputes` / `allDisputes` | `ProjectDatabase.swift:3492` / `:3697` / `:3732` |
| `negative_searches` (v1) / profile index / *(new helper needed)* | `ProjectDatabase.swift:195` / `:220` |
| `user_hypothesis_seeds` (v32) / `requested_by` TEXT | `ProjectDatabase.swift:998` / `:1008` |
| `research_discrepancies.run_id` (v41) | `ProjectDatabase.swift:1308-1310` |
| `HypothesisSeedService` refusals (`previouslyRejected`) / materialise | `Services/Research/HypothesisSeedService.swift:38-58` (`:49`) / `:243` |
| `ResearchInterpreter`: summary / focused-query / parse / compare / census years | `Services/Research/ResearchInterpreter.swift:19/:145/:182/:260/:332` |
| `LocalInferenceService`: shared / isAvailable / reason / reasonJSON | `Services/Research/LocalInferenceService.swift:97/:111/:305/:357` |
| `SourceBudgetTracker.isPaused` | `Services/Research/SourceBudgetTracker.swift:82` |
| `SearchOutcome` / `truncated` / `suppressed` / availability / `isCleanNegative` | `AncestorKit/.../Research/RecordTypes.swift:956/:966/:979/:918-943/:1032` |
| GPS criteria 1–5 | `Services/Research/GPSScorer.swift:101/:121/:146/:181/:244` |
| `Origin` / `candidateGroupID` / `isModelAssisted` / kinds / `identityKey` | `AncestorKit/.../Research/ResearchHypothesis.swift:40-43/:75/:89/:193-313/:338` |
| `.birthYearCandidate` / `.deathYearCandidate` / `.parentIdentityCandidate` / `.parentCandidates` / `.burialAtParish` / `.secondMarriage` | `ResearchHypothesis.swift:266/:273/:281/:299/:310/:313` |
| `HypothesisEngine` central switches (+8 existing kind extensions) | `Services/Research/HypothesisEngine.swift:73/:106` + deficit switch |
| ParentCandidates no-self-confirmation | `Services/Research/HypothesisEngine+ParentCandidates.swift:123/:642` |
| `SearchDispatcher.dispatchOne` / `FocusedQuery` | `Services/Research/SearchDispatcher.swift:157` / `Models/Research/FocusedQuery.swift` |
| `WitnessIdentity.key(for:)` / `independentWitnessCount` / `scoreValueGroups` | `AncestorKit/.../Research/WitnessIdentity.swift:59/:172` / `ConvergenceEngine.swift:173` |
| `SharedProfileLayout` Disputes / Conflicts sections | `Views/Profile/SharedProfileLayout.swift:184-230` / `:237` |
| `ResearchActivityBus` (telemetry events only — not an invalidation bus) | `Services/Research/ResearchActivityBus.swift` |
| RESEARCH_PIPELINE_SPEC: T7 §5.3 / T8 §5.4 / T9 §5.5 (+§5.5.1 θ) / §5.11 / §5.15 | `RESEARCH_PIPELINE_SPEC.md:2201/:2260/:2367 (:2393)/:2666/:3436` |
| New files | `AncestorKit/.../Research/GroundedProse.swift`, `Services/Research/DossierAssembler.swift`, `ChallengePointDetector.swift`, `DossierInterpreter.swift`, `HypothesisEngine+CensusPresence.swift`, `Views/Dossier/DossierView.swift` |

*Evidence base: three-design competition output (small-model-first base + twelve-graft consolidated review, 2026-07-13); code citations verified against the working tree 2026-07-13. Corrections applied to competition-text claims: `extractJSONDictionary` does not exist (→ `reasonJSON`); GPSScorer criteria and `SharedProfileLayout` section lines drifted; `HypothesisKind` starts `:193` and `.parentCandidates` contract sits at `:283-299`; the seed watcher does not grade at materialisation today (⟨A7⟩ is new work); `ResearchActivityBus` has no run/dispute/accept events (invalidation redesigned around skeleton hashes ⟨A6⟩); the clean-negative predicate is `isCleanNegative`; `requested_by` needs no migration to accept `'adversarialLoop'`.*
