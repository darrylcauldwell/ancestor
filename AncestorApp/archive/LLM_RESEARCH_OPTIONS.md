# Research Coverage Gaps — Portfolio Weighing

**Status:** Decision-staging document. Not a spec.
**Date:** 2026-05-15
**Author context:** Drafted after a user session where researching themselves and then their mother separately surfaced wasted overlap (shared marriage cert, shared sibling birth certs). An earlier framing of this document treated "more LLM" as the decision; this version reframes around the concrete gaps the deterministic pipeline shows today, and asks the cheapest tier that closes each. The LLM piece is a tool, not the thing being decided.

---

## 1. What this document is

A gap inventory plus a per-gap argument about the cheapest tier that closes it. The output is a **portfolio of targeted moves** \u{2014} some deterministic, some MLX, possibly some Claude API \u{2014} chosen per gap, not wholesale. It is not a spec; it is a decision-staging doc that lets a follow-up spec pick the right unit of work with eyes open.

**Three things this document also commits to producing before any LLM work ships:**

1. A *cross-profile dedup* move, shipped first, regardless of the LLM answer. Cheapest and highest-leverage move in the inventory.
2. An *evaluation harness*: a small held-out set of known-difficult profiles with documented ground-truth facts, against which every coverage change is measured before/after. Without this, every option is "ship and hope."
3. An answered *stall-detection contract*: a precise definition of "the deterministic pipeline has stalled." Promoted from open question to gating decision because anything LLM-planner-shaped depends on it.

---

## 2. Context

### What\u{2019}s already wired

- `LocalInferenceService` (DeepSeek-R1 7B 4-bit via mlx-swift-lm). Used today by `ResearchInterpreter` and `NarrativeAssembler` for post-hoc reading and prose generation. Strips `<think>` chain-of-thought before returning. Roughly 7 GB resident; planning-class inference is ~10\u{2013}30 s per step on Apple Silicon.
- Field Researcher (Claude API). Already the tier-3 escalation for unstructured web evidence; goes through the Evidence Firewall (`pending_facts` \u{2192} hallucination checks \u{2192} scorer \u{2192} human review).
- Tiered-architecture rule (saved memory): deterministic \u{2192} local LLM \u{2192} API LLM, only route up at the wall.

### Constraints

- **Evidence Firewall** is law. No LLM (local or API) writes facts directly. Every output is a candidate that goes through the same scorer + human-review path.
- **Cluster context for the scorer is not free.** Today the scorer treats each profile independently; the same record cited against two profiles is two scoring runs, not one. Cross-profile dedup forces a real semantic decision: does a marriage cert count as one source corroborating two profiles, or as two independent sightings? (Answer: one source. ConvergenceEngine\u{2019}s lineage-grouping must be made cluster-aware.)
- **On-device resource cost is real.** A resident 7B model + planning loops competes with the editor for thermals, memory, and battery on a MacBook. "MLX is free per call" is wrong at the system level.

---

## 3. The gap inventory

What the deterministic pipeline misses today, observed or strongly suspected from session evidence:

| # | Gap | Concrete symptom |
|---|---|---|
| G1 | **Shared evidence not cross-applied across profiles** | User runs research on self, then on mother. Shared marriage cert is rediscovered, not propagated. |
| G2 | **Stall on no-result** | Source returns empty for the configured query; pipeline gives up rather than try a different angle. |
| G3 | **Phonetic / spelling variants not adaptively escalated** | `SearchStrictness` ladder exists (strict / loose / variant) but escalation is per-source-static, not response-driven. |
| G4 | **Ambiguous locations stall the cleanse step** | "Newport" matches 3 counties; the cleanse wizard surfaces the candidates but can\u{2019}t pick one from spouse/sibling context. |
| G5 | **Cross-cluster contradiction unresolved** | Cluster A claims born 1850; Cluster B claims 1855. No mechanism asks which is more plausible given the rest. |
| G6 | **Bare evidence not contextualised against family graph** | A single FreeBMD row with name+year+district passes scoring in isolation; never gets re-checked against known parents/siblings. |
| G7 | **Merge candidates missed for subtle cases** | `DiffEngine` catches obvious duplicates by exact-ish match. Same-person-different-spelling-different-region cases slip through. |
| G8 | **Narrative / interpretation thinness** | Shipped via `ResearchInterpreter` / `NarrativeAssembler`. Works as built. Adding more interpretation surfaces will not close coverage gaps \u{2014} this is a known limit of the surface, not an opportunity. |

That last row is included to retire the "more interpreter surfaces" framing. The existing surfaces work; that\u{2019}s precisely why scaling them won\u{2019}t move coverage.

---

## 4. Cheapest tier per gap

For each gap, the question is: what\u{2019}s the cheapest tier that plausibly closes it, and how would we measure that it did?

| # | Cheapest tier | Why | Eval metric |
|---|---|---|---|
| G1 | **Deterministic** | Query dedup + scoring shared evidence against multiple subjects is pure plumbing. No reasoning required. | % of cluster-internal evidence that requires only one source fetch instead of N. |
| G2 | **Deterministic first**, MLX second | Most stalls are answered by mechanically widening the year window, retrying with phonetic surname, or escalating scope. MLX-as-planner only earns its keep on truly creative moves the rules can\u{2019}t encode. | Held-out: out of N stalled profiles, how many additional `.fact` verdicts after adding deterministic escalation? After adding MLX planner on top? |
| G3 | **Deterministic** | Escalation logic is rule-shaped: "got zero `.fact`s at strict, retry at loose; got zero at loose, retry at variant". Already half-built; finish the loop. | Variant-tier hit rate on held-out vs. current static behaviour. |
| G4 | **Deterministic + structured context first**, MLX where context insufficient | Spouse\u{2019}s `birthLocationCode` is "DBY:Belper"? Then their "Newport" is almost certainly Derbyshire-adjacent. Graph traversal is cheap and explainable. | Resolution rate on a held-out set of "Newport"-shaped ambiguous-location findings, with and without graph-context resolver. |
| G5 | **MLX (planning-class)** | Genuinely a reasoning question: which cluster is more plausible given the rest of the tree? Cannot be expressed as a deterministic rule without enumerating every case. | Per-tree: count of contradictions surfaced and resolved with user agreement. |
| G6 | **Deterministic for the check**, MLX for the rationale | "Does this candidate birth year sit within the known parents\u{2019} fertility window?" is arithmetic. "Why is this candidate worse than the other one we found?" is prose. | Coverage-rate change on held-out, with and without family-graph plausibility gate. |
| G7 | Mixed | `DiffEngine` extension covers structurally-similar cases (deterministic). Subtle "John Caudwell, Ashbourne, 1845" \u{2248} "Jon Cauldwell, Wirksworth, 1845" is closer to MLX territory. | Merge-candidate suggestion precision and recall on a labelled set. |
| G8 | n/a \u{2014} retired | Existing interpreter surfaces work as built; no coverage upside in adding more. | n/a |

**Pattern that falls out:** the cheapest move for most gaps is deterministic. MLX earns its place on G5 (contradiction resolution) and G7 (subtle merges), and as a fallback escalation on G2 once deterministic moves are exhausted. The "options" of the previous draft dissolve into a portfolio.

---

## 5. The portfolio

Three buckets, ordered by what ships first.

### Bucket A \u{2014} ships first, regardless of any LLM decision

| Move | Gap | Tier | Effort | Eval |
|---|---|---|---|---|
| Cross-profile dedup: shared-evidence scoring + cluster-aware ConvergenceEngine | G1 | Deterministic | ~3\u{2013}5 sessions | "Same-source-counted-twice" rate before/after |
| Adaptive strictness escalation: rule-driven walk through strict\u{2192}loose\u{2192}variant on empty result | G2, G3 | Deterministic | ~2 sessions | Variant-tier hit rate before/after |
| Family-graph plausibility gate for solo candidates | G6 | Deterministic | ~2 sessions | False-positive `.fact` rate before/after |
| Graph-context resolver for ambiguous locations (use spouse / sibling `birthLocationCode`) | G4 | Deterministic | ~2 sessions | Newport-class resolution rate |
| **Eval harness**: 10\u{2013}20 held-out profiles with documented ground-truth fact set, plus a CLI runner that produces a single-number score per gap class | (all) | Tooling | ~2 sessions | n/a \u{2014} it *is* the eval |

This bucket directly addresses the user\u{2019}s stated frustration (G1), pulls in the easier coverage gains (G3, G4, G6), and produces the harness the rest of the document depends on.

### Bucket B \u{2014} gated on Bucket A landing

| Move | Gap | Tier | Effort | Gating decision |
|---|---|---|---|---|
| MLX-as-planner for residual stalls | G2 (residual) | MLX or Claude API | ~3\u{2013}5 sessions | Local vs API: see §6. Stall-detection contract: see §7. |
| MLX cross-cluster contradiction resolver | G5 | MLX | ~3 sessions | Worth doing only if held-out shows contradictions matter |
| Subtle-merge suggester | G7 | MLX | ~3 sessions | Worth doing only if `DiffEngine` extension leaves a real gap |

Each item is gated on the eval harness showing the gap is still real after Bucket A.

### Bucket C \u{2014} adjacent, not scoped here

- LLM hallucination guard for Field Researcher output. Defensive, doesn\u{2019}t affect coverage.
- LLM cleanse suggestions (explicitly deferred from `CLEANSE_WIZARD_SPEC` §7).
- Periodic tree-wide merge suggestion as a batch job.

Mention only \u{2014} not part of this decision.

---

## 6. The local-vs-API question for the planner

The tiered-architecture rule says "only route up when the cheaper tier hits the wall." For the planner case, the wall might be hit fast. The case has to be made explicitly, not assumed.

| Dimension | On-device MLX (DeepSeek-R1) | Claude API |
|---|---|---|
| **Per-call latency** | 10\u{2013}30 s for a planning-class prompt on Apple Silicon | 2\u{2013}5 s |
| **Throughput under thermal pressure** | Degrades under sustained load; MacBook fans, then throttles | Constant |
| **Per-call cost** | Free in $; not free in watts, memory, or user wait | ~$0.01\u{2013}0.05 per planning step (Sonnet 4 budget); negligible at planner-call frequency |
| **Privacy** | Strong \u{2014} no data leaves the device | Subject to API terms; project already permits for Field Researcher |
| **Offline use** | Works | Doesn\u{2019}t |
| **Deterministic cost ceiling** | Yes \u{2014} can\u{2019}t accidentally rack up a bill | No \u{2014} budget controls required (already in place for Field Researcher) |

**For the planner specifically:** planning calls are low-frequency (a handful per stalled profile), low-volume (small prompts, JSON outputs), and quality-sensitive (a bad plan wastes deterministic source calls). API per-call cost is negligible at this rate; latency advantage is substantial; quality of larger models on planning is real. The on-device argument leans hardest on privacy and offline \u{2014} both legitimate, but neither is unique to this project\u{2019}s threat model.

**Tentative conclusion:** for the planner case the API is probably the right tier. On-device MLX should be reserved for high-frequency, low-stakes tasks (G5 / G7 candidates, where the LLM is annotating not deciding) and as the fallback when offline. This conclusion needs the eval harness to verify before committing.

---

## 7. The stall-detection contract (gating decision)

Anything planner-shaped \u{2014} MLX or API \u{2014} needs a precise trigger. Without it, the planner has no entry point, no off-switch, and nothing to evaluate against. A short upstream investigation should resolve this before Bucket B starts.

Candidate definitions (pick one before any planner work):

1. **Zero-new-facts iteration**: an iteration of `ResearchPipeline.research` that adds no `.fact` and no `.lead` records to `ResearchState.confirmedFacts`. Stable, simple, observable.
2. **Confidence-floor stall**: the highest-confidence cluster after iteration N has a score below threshold T, where N and T are mode-dependent.
3. **Variant-exhaustion stall**: the dispatcher has walked strict \u{2192} loose \u{2192} variant for every applicable source and is still empty.

Option 1 is the cleanest signal but the most permissive (will fire often). Option 3 is the strictest but most useful (fires only when deterministic rules are genuinely out of ideas). Likely answer: **a combination** \u{2014} fire the planner when the dispatcher hits variant-exhaustion *and* the result set is empty or below threshold. But the choice has to be made, defended, and made visible to the user as a UI signal ("Pipeline ran out of ideas. Try a reasoning step?").

This is upstream of the Bucket B decision, not parallel.

---

## 8. Cluster-aware scoring (an honest call-out)

Cross-profile dedup (G1, in Bucket A) is not a "deterministic plumbing" task as cleanly as it sounds. The Convergence Engine groups records by lineage and scores corroboration. Shared evidence used to confirm facts on *two* profiles is a single source that the current scorer would naively count twice unless made cluster-aware.

The contract change: a `ResearchCluster` (couple, family, or selected set) becomes a first-class scoring unit. When the same `SourceRecord` is part of evidence for two profiles in the cluster, it counts once in the convergence score but contributes to both profiles\u{2019} fact sets. The shared relationship is itself the linking evidence.

This is a real semantic question \u{2014} not a footnote. A short design pass on the scorer contract should land before the cross-profile dedup move ships, even though the dedup itself is "deterministic plumbing."

---

## 9. Evaluation harness (what shipping looks like)

Cheap and concrete:

- **Corpus**: ~15 profiles drawn from the user\u{2019}s real tree, hand-curated as "known difficult." Each profile has a documented "ground truth" set of facts that *should* be discoverable (and a documented "should be left empty" set for hallucination guardrails).
- **Runner**: a CLI scheme target that invokes `ResearchPipeline.research(...)` against each profile in the corpus with current code, captures the resulting `ResearchResult.confirmedFacts`, and diffs against ground truth.
- **Metrics, per gap class**: precision (proportion of `.fact` verdicts that match ground truth), recall (proportion of ground-truth facts that surfaced as `.fact`), and contradiction count.
- **Reporting**: one number per gap class per run, printed at the end. CI for the eval is optional; a manual `swift run eval` is enough to start.

Without this, no decision in §5 can be defended. With it, each move ships with a before/after delta and a rollback condition.

---

## 10. Decisions to make before any spec

Promoted from "open questions":

1. **Stall-detection contract** (§7). Gates Bucket B.
2. **Cluster-aware scoring contract** (§8). Gates the cross-profile dedup move in Bucket A.
3. **Eval-harness corpus selection.** Whose tree, which profiles, who curates ground truth.
4. **Local vs API for the planner** (§6). Default: API. Needs explicit sign-off.

Genuinely still open:

5. Family-cluster UX boundary \u{2014} couple? couple+children? free-form selection? Only matters once Bucket A is shipped and the question becomes interactive instead of background.
6. Resource policy for any on-device MLX work that does ship \u{2014} thermal/battery thresholds at which to defer or downgrade.

---

## 11. Net recommendation

Ship Bucket A first, in order:

1. Eval harness (so every subsequent move has a defensible delta).
2. Cluster-aware scoring contract (design pass + scorer/ConvergenceEngine update).
3. Cross-profile dedup move on top of the new scoring contract.
4. The remaining Bucket A deterministic moves (G2/G3 escalation, G4 graph-context resolver, G6 plausibility gate), each with eval delta in its commit message.

Then \u{2014} not before \u{2014} answer the stall-detection contract and the local-vs-API question, and decide which of Bucket B\u{2019}s LLM moves still earns its place given what the harness shows.

This is the move regardless of how the LLM piece ultimately lands. The LLM work then gets to compete for the residual gaps with real evidence behind the choice, instead of being picked on prior intuition.

---

*End of weighing. Next: a small design pass on the scoring contract, then a Bucket A spec.*
