# LEAD DISCOVERY — Clustering as a Discovery Engine

**Status:** Design / accepted-direction (2026-07-16). Not started. Design-before-implement per owner decision.
**One line:** Repurpose clustering from a per-subject *evidence-acceptance* aid into a corpus-level *discovery* engine that turns the noisy lead pool into a small, prioritised set of hypothesised people, links, and families — routed through the existing hypothesis + firewall machinery for human review.

---

## 1. Problem & thesis

Clustering today runs **inside** the per-subject research pipeline. Given a known subject, it groups that subject's candidate records into distinct "lives" so acceptance doesn't smear a namesake's facts onto the profile. That is a **defensive guard**, not the acceptance decision (the 4-gate scorer + convergence engine make the accept), and it can actively *harm* acceptance — the Ernest Cauldwell case over-merged an infant death (1886, age 0) with a 1915 marriage, producing contradictory facts the writer then (correctly) refused to apply, while the cluster badge misleadingly read "Applied".

The higher-leverage use of clustering is the inverse: **bottom-up discovery over the accumulated lead pool.** Take records that individually look unconnected and find the groups that cohere into a life, a family, or a bridge between two existing people — "more than the sum of the parts." This grows the tree instead of confirming a node.

**Thesis:** acceptance-clustering is the weaker fit (keep it, but as a hardened namesake guard); **discovery-clustering is the pivot** and the logic isn't there yet.

---

## 2. Two clustering roles (make the split explicit)

| | **Job A — Disambiguation (current)** | **Job B — Discovery (new)** |
|---|---|---|
| Entry point | A known subject's candidate records | The whole *orphan* lead pool (no anchor) |
| Question | "Which of these same-name records are *my* Ernest?" | "Do these unconnected leads cohere into someone/something new?" |
| Output | Accept / reject records onto the subject | **Hypotheses** (possible person / link / family) |
| Failure if wrong | Contradictory facts on a real profile | Noise in a review queue (recoverable) |
| Decision maker | Scorer + convergence (clustering is a guard) | Deterministic blocking + constraints; human confirms |

The two share a common core (group records into lives under identity constraints). The engine can be **one thing with two drivers**; the constraints (§7) benefit both.

---

## 3. What discovery produces (emergent-findings taxonomy)

An emergent cluster is never evidence itself — it is a **prioritised hypothesis**. Concrete forms:

1. **Candidate new person** — a coherent cluster of orphan leads (birth + census + marriage that lock together) → a person not in the tree.
2. **Candidate link** — a cluster whose records touch two existing profiles → a proposed relationship between them.
3. **Family from context** — a census household inside a cluster → siblings/parents to add.
4. **Corroboration** — weak-alone leads that cohere → higher confidence a fact is real (fuel for the convergence engine).

**What makes a candidate *valuable* vs a random namesake: tree-proximity.** Every lead carries provenance — the subject whose research generated it. A cluster of leads that all originated in the Cauldwell branch, cohering into a person, is a *likely Cauldwell relative*. A cluster of 1850 strangers who merely share a surname is not. **Origin-subject proximity is a first-class blocking feature**, not an afterthought — it ties discovery back to the existing tree.

---

## 4. Value chain: how a cluster becomes evidence

The payoff is not "the cluster gives you a fact." It is **3,752 undifferentiated leads → a dozen high-value things to actually chase.** Noise pool → prioritised worklist. The chain:

```
orphan leads  →  deterministic blocking + constraints  →  emergent cluster
             →  hypothesis (person / link / family)  →  [firewall + human review]
             →  research subject  OR  proposed relationship
             →  normal pipeline  →  real evidence
```

The cluster seeds a **T11/T12 hypothesis** — the same machinery already built for user-seeded hypotheses, but *seeded by discovery* instead of by the user. Confirmed hypotheses become research subjects (which produce evidence through the normal pipeline) or confirmable relationships (structural evidence).

---

## 5. Architecture

Four layers, deterministic-first:

**5.1 Deterministic blocking (does the heavy lifting).**
Collapse the O(n²) pool into small candidate buckets with cheap, traceable keys: normalised surname, birth-decade, Chapman county, event type, and **origin-subject proximity**. Thousands of leads → many tiny buckets. Fast, reproducible, auditable. AI never sees the whole pool.

**5.2 Identity constraints (the "when in doubt, split" enforcement).** See §7. Shared with acceptance-clustering; includes the **death-caps-lifespan** fix so the Ernest failure cannot recur.

**5.3 AI boundary — bounded, never the clusterer.**
The instinct "AI is good at finding patterns in a large unstructured pool" is right *only* in the embeddings sense, not the "hand the LLM the whole pool" sense (which is non-deterministic, hallucination-prone, and doesn't fit a 4B local model).
- **Embeddings (per-lead, cheap, scalable):** each lead's text → a semantic-fingerprint vector via a small MLX embedding model. Deterministic *math* (cosine similarity) then clusters the vectors — the model produces *features*, not decisions. This catches fuzzy matches ("Ernest CAULDWELL, Turnditch" ≈ "Ernest Cauldwell, Ward") that no hand-written rule spells out. Reproducible given a fixed model + input.
- **Adjudication (borderline pairs only):** where deterministic keys + embeddings are genuinely uncertain, the generative model gives a probabilistic same-person judgment — as a **proposal**, gated by the deterministic layer. It never auto-merges.
- **Narration:** cluster summaries ("looks like a person born ~1887 in Turnditch who married a Ward") and relationship extraction from household prose — the local model's existing strengths.

**5.4 Hypothesis emission + review.**
Emergent clusters → T11/T12 hypotheses → Evidence Firewall → a review surface in **Triage** ("N possible people / M possible links from your leads"), each a card with its constituent leads, the AI narrative, and the proposed action. **No auto-apply.** Dismissed clusters feed the cross-run negative cache so they don't re-surface.

---

## 6. Determinism & the sandwich (invariant preserved)

"AI proposes, rules + human decide" holds for discovery exactly as for acceptance:
- Deterministic blocking + constraints **form** the groups (reproducible, auditable).
- Embeddings are per-item **features**, not merge decisions; deterministic similarity does the grouping.
- AI adjudicates/narrates but **never commits** — output is a hypothesis, gated and human-reviewed.
- Nothing writes to profiles without passing the firewall.

Deterministic scale; AI judgment at the boundary.

---

## 7. Identity constraints (the deterministic core, shared)

Hard rules that split rather than merge on doubt:
- **Death caps the lifespan.** A death record sets `lifespanEnd = deathYear` (small margin), never expands it. A death **with age** bounds birth (`birth ≈ deathYear − age`); an infant death collapses to ~one year. **Reject any record dated after a cluster's death** — you cannot marry or appear in a census after dying. *(This is also a standalone quality fix for acceptance-clustering — worth shipping first; see §9.)*
- **One life-defining event per person** — at most one birth, one death per cluster; a second implies a split.
- **Age/date consistency** — a census age must agree with the cluster's birth window; disagreement splits.
- **Geography sanity** — Chapman-county coherence (already `SourceTierRegistry`/config-derived; no hardcoded regions).
- **Prefer over-split** — a wrong merge corrupts; a wrong split just means two review cards instead of one.

---

## 8. Risks & failure modes

| Risk | Mitigation |
|---|---|
| Over-merge (the Ernest failure at scale) | §7 constraints, death-caps-lifespan, over-split bias |
| Noise flood (a wall of "maybe-people") | **Precision-first** — few confident clusters beat many speculative ones; recall grows later |
| AI hallucination | AI is adjudicator/narrator, never decider; deterministic gate + firewall |
| Non-determinism | Deterministic clustering over fixed embeddings; reproducible |
| Performance (thousands of leads) | Blocking shrinks the problem before any similarity/AI work |
| False confidence | Firewall + human review; nothing auto-applies |
| Solution-looking-for-a-problem | **Phase 0 empirical probe** on the real pool as the go/no-go |

---

## 9. Staged plan (each phase has an explicit gate)

- **Phase 0 — Empirical probe (diagnostic only).** Run deterministic blocking (no AI, no new UX) over this tree's real ~3,752 leads. Emit a report: how many coherent clusters (size ≥ 2–3, consistent identity), with a manual-inspection sample. **Gate:** do coherent people/links visibly emerge? If yes, proceed; if it's mush, we learned it cheaply. *This is the go/no-go for the whole pivot.*

  **Phase 0 RESULT (2026-07-16, tree `3B0473D4`, `LeadDiscoveryEngine.report`):** 5,409 leads → 1,735 clusters, **568 surfaceable** (≥2), 4,242 leads in surfaceable clusters, 294 multi-event-kind, 22 multi-source. **GO on the concept** — clusters carrying a birth year are plausible single people (`Mary Ann WARD b~1875` all Burton; `Elizabeth WALLACE b~1872` 1871–73), and half of surfaceable clusters span ≥2 event kinds (the "sum > parts" signal). **But one blocking flaw must be fixed before Phase 1:** leads with **no birth year** (deaths/burials/marriages carry none) fall into a single `(surname, decade=nil)` block and chain-merge on name alone → giant false clusters (`George WARD` = 273 different men; `MARY E WARD` = 195, death-ages 75/76/94; `HARRY MARSHALL` = 65 across three services). Root cause: the discriminators that would split them — **age-at-death → implied birth year**, and **district/place** — live only in the free-text `evidence` string, not as structured `Lead` fields. **Required before Phase 1:** structure age-at-death + place on `Lead` (preferred, pays off everywhere) or parse them in-engine, and forbid name-only merges of no-birth-year leads (always require a second discriminator).

  **Blocking fix SHIPPED (2026-07-17, commit `4563cdd`, Option B):** `Lead` gains structured `ageAtDeath` + `place` (v47 migration; threaded through every save/load/reconstruction site so status flips don't lose them). `Lead.effectiveBirthYear = birthYear ?? deathYear − ageAtDeath` gives no-birth-year death leads a real birth window; `LeadDiscoveryEngine` blocks on it and **refuses to merge two leads that both lack a birth signal unless their places agree** (locality tokens only — generic words like "Cemetery"/"Churchyard" never count as agreement). Populated at creation from death/military/probate age and per-record place. Mechanism proven by unit tests (namesake split by implied birth decade; different-cemetery George Wards stay separate). **Caveat:** the ~5,409 leads already persisted carry nil age/place (created pre-fix) — the real-data payoff appears only as leads are *re-created* with the new extraction (a research re-run), or via a one-off evidence-string backfill. A Phase-0 re-run on the stale rows would mislead (age-split can't fire; the place-gate would fragment nil-place leads into singletons), so it was deliberately not run. **Phase 1 is now unblocked.**
- **Phase 1 — Deterministic discovery clustering (read-only). SHIPPED 2026-07-17.** `PossiblePeopleView` (a segmented tab beside Findings in Triage) runs `LeadDiscoveryEngine.discover` off the main actor over the lead pool and lists surfaceable emergent clusters read-only — representative name, consensus birth year, size, event-kind/source/origin coherence, expandable to the member leads. Precision-first: **clusters with a consensus birth year show by default; yearless (place-only) clusters sit behind a "lower confidence" disclosure**, which is where the residual name+place over-merges land (post-fix real-tree: 504 surfaceable = 439 with-birth-year + 65 yearless; largest 51). Engine refinement shipped alongside: **"a person dies once"** — two leads whose death years differ by >1 can't be the same person. No AI, no hypotheses, no mutation. **Known residual:** yearless leads with no distinguishing death year (e.g. 51 "John Thompson" burials sharing a place) still over-merge — they're correctly quarantined as low-confidence, and cracking them needs a second signal (embeddings, Phase 3). The **death-caps-lifespan** clustering hardening shipped earlier (`b120ac9`).
- **Phase 2 — Hypothesis emission.** Emergent clusters become T11/T12 hypotheses through the firewall; review → accept → research subject or proposed link. Dismissed → negative cache.
- **Phase 3 — Embeddings. Deterministic leg SHIPPED 2026-07-17; MLX leg pending package links.** The fuzzy-bridge catches matches the exact-surname block key misses: after `discover`, two clusters whose surnames are spelling variants (CAULDWELL/COLDWELL, Levenshtein ≤2) merge when their representatives agree on given name + birth year (±2) + born-after-death + a-person-dies-once AND their text embeddings are similar (`LeadDiscoveryEngine.bridgeVariantSurnames`). The embedder sits behind a `TextEmbedder` protocol; `DeterministicTextEmbedder` (hashed char-trigram vector, L2-normalised, reproducible) is the always-available fallback and the current default, wired into `PossiblePeopleView`. **AI-proposes / rules-decide holds: the embedder only proposes; the deterministic gates decide.** **Real MLX semantic leg — wired + compile-verified 2026-07-17 (`b34dab0`).** `MLXEmbedders` (from the existing `mlx-swift-lm` package) is linked to the app target; `import MLX` resolves transitively, so no extra package was needed. `MLXTextEmbedder` (actor) loads a small sentence model (`minilm_l6`) and returns L2-normalised vectors behind the `TextEmbedder` contract, guarded by `#if canImport(MLXEmbedders) && canImport(MLX)` so the app still builds with the modules absent. `PossiblePeopleView` has an opt-in "Use semantic model" control that downloads the model on first use and re-clusters; until then the deterministic trigram embedder is used silently. Compile-verified against the real API; **runtime output quality is the user's to validate by loading a model in-app.** (Note: blind `project.pbxproj` editing corrupted the file once — ID collision, reverted; the product was linked via Xcode's UI instead.) AI adjudication on borderline pairs is a further step on top.
- **Phase 4 — AI narration + adjudication. SHIPPED 2026-07-17 (`2d16947`).** Split to keep the sandwich honest: **narration is deterministic** (`ClusterAdjudicator.summary` — one-line cluster story formatted purely from lead fields: span, event kinds, places, origin count; zero-hallucination, always available, on every expanded card) and **AI is adjudication only** — an on-demand "Ask AI: one person or several?" on borderline (yearless) clusters asks the local MLX model to judge namesakes-vs-one-person (skeptical system prompt, prompt capped at 12 leads, strict JSON parse). The verdict renders as an advisory badge + reasoning and **never restructures anything**; no model → quiet caption, panel unchanged. This is the second signal for the yearless residual (51-Thompson class). Household relationship extraction deliberately deferred to the prose-corpus work (`PROSE_CORPUS_SPEC.md`) where extraction-through-firewall belongs. Runtime verdict quality is the user's to validate with a model loaded.
- **Phase 5 — Unify acceptance + discovery. SHIPPED 2026-07-17 (`0072c82`).** Interpretation: what §7 declares shared — and what had actually drifted — is the **identity-rule set**, not the two orchestration algorithms (per-subject assignment scoring and corpus blocking are different shapes for irreducibly different inputs; merging them would be regression risk with no payoff). `IdentityConstraints` is now the single authority both engines consult: unified constants (110/90/2/±5/±2/±1) with the previously-accidental born-after-death divergence (+1 vs +2) made explicit and justified (birth gets registration lag only; burial/probate get the full 2yr), and unified rules (given-name contradiction, birth-window, born-after-death, event-after-death, dies-once, county contradiction, junk-guarded implied-birth derivation). `LeadDiscoveryEngine`, `Lead.effectiveBirthYear`, and `ClusteringEngine`'s vetoes/contradiction checks/constants all route through it; geography *resolution* stays shape-specific (district→catalogue vs lead place tokens) under the shared contradiction principle. Drift detectors in `IdentityConstraintsTests` assert the engine aliases ARE the core's values. **The pivot's staged plan is complete: Phases 0–5 all shipped.**

---

## 10. Success metrics

- Count of coherent emergent clusters surfaced.
- **Precision** (sampled, human-judged: real person/link vs false) — the primary metric.
- Conversion: clusters → accepted hypotheses → new researched subjects / confirmed links.
- Reduction in undifferentiated lead noise the user must wade through.

---

## 11. Open questions / decisions owed

1. **Keep acceptance-clustering, or move to scorer-only acceptance + discovery-clustering?** *Recommendation:* keep it as a hardened namesake guard; discovery is an addition, not a replacement.
2. **Precision target for Phase 1** — how confident before a cluster surfaces? (Lean strict.)
3. **Scope:** cluster *all* leads, or only genuinely-orphan (unresolved) ones? *Recommendation:* orphans only — higher value, smaller pool.
4. Which MLX embedding model (Phase 3).
5. Cross-project discovery (later)?

---

## 12. Relationship to existing systems

- **Evidence Firewall** — hypotheses enter through it; nothing bypasses.
- **Hypothesis framework (RESEARCH_PIPELINE_SPEC Part II, T11/T12 shipped)** — the vehicle for emergent findings.
- **Triage** — the review surface (already hosts research findings + identity-grouped leads).
- **Leads queue + cross-run negative cache** — the input pool; dismissed clusters feed the cache.
- **ClusteringEngine / ConvergenceEngine** — the core to extend/share (incl. §7 constraints).
- **No hardcoded regions** — geography constraints stay config/tree-derived.
