# Bio Synthesis Spec

How `profile.bio` gets written: from structured facts and accepted
cluster corpus into honest, citation-traceable prose.

This spec **depends on** `SOCIAL_HISTORY_CORPUS_SPEC.md`. Synthesis with
no accepted corpus produces only the base layer (paraphrased facts) and
that's by design — bios scale with the corpus you've built, and an
empty corpus produces a sparse bio rather than a hallucinated one.

## Mission

A bio is an **honest reflection of a person's actual lived life**, built
from:

- **Base layer** — readable prose restating what the structured tree
  knows about the person (dates, places, relationships, occupations,
  life events).
- **Rich layer** — woven social and historical context drawn from the
  **accepted cluster corpus**, scoped to the person's place / time /
  occupation.

A bio for a profile with rich corpus support reads like the kind of
short biographical sketch a careful local-history researcher would
produce. A bio for a profile with no corpus support reads like a sparse
factual paragraph and is *deliberately* not padded.

## The absolute principle

**Bios must be 100% fact-based, with zero hallucination.**

This is not a quality goal. It is the design floor. Every sentence in
every bio in this app must trace back to either:

1. A structured fact in the user's tree (this person's birth date, this
   person's occupation, this relationship), or
2. A cited passage in the accepted cluster corpus.

No exceptions. Not for "obvious" claims ("child labour was common in
1820"). Not for "implied" details ("he walked to the mill before dawn").
Not for narrative colour ("the cobbles were cold underfoot"). Not for
hedged speculation ("he likely attended the parish church").

### Silence is preferable to invention

Where no fact or corpus passage supports a sentence, the system says
**nothing** about that topic. A bio that reads sparser is better than a
bio that reads beautifully but contains a claim the user can't trace.

This is the analogue of the existing deterministic-sandwich principle.
There it's "AI proposes; rules decide." Here it's **"AI styles; sources
decide."** The LM rephrases and stitches over verified inputs. It does
not contribute knowledge. It does not "know" things.

## The provenance contract

Every sentence in the proposed bio carries a **provenance set** — a list
of input IDs the sentence draws from. Inputs are of two types:

- `factID` — a `ProfileField` value, a `Relationship`, a `LifeEvent` row
- `corpusID` — a `cluster_corpus` row ID

A sentence with an empty provenance set is rejected and never emitted.

The provenance set is what the verification pass checks against and
what the rendered bio displays as citation markers.

## The synthesis pipeline

```
   structured facts (profile + relationships + life events + sources)
                       ↓
   ┌───────────────────────────────────────────────────────────┐
   │  STAGE A — deterministic base layer                       │
   │  Templates produce prose like:                            │
   │  "John Smith was born on 21 Dec 1820 in Cromford."        │
   │  No AI involvement. Pure restating.                       │
   └───────────────────────────────────────────────────────────┘
                       ↓
   ┌───────────────────────────────────────────────────────────┐
   │  STAGE B — context retrieval                              │
   │  Query cluster_corpus for passages whose appliesAt        │
   │  intersects this profile's (place, year, occupation).     │
   │  Returns 0..N passages with citation chains.              │
   └───────────────────────────────────────────────────────────┘
                       ↓
   ┌───────────────────────────────────────────────────────────┐
   │  STAGE C — MLX synthesis                                  │
   │  Inputs: base prose + retrieved corpus passages.          │
   │  Task: weave the two into coherent prose. Each output     │
   │  sentence must be paraphrased from inputs OR a near-      │
   │  direct quote. Output includes per-sentence provenance.   │
   └───────────────────────────────────────────────────────────┘
                       ↓
   ┌───────────────────────────────────────────────────────────┐
   │  STAGE D — verification                                   │
   │  Per sentence:                                            │
   │   - entailment check: does this follow from the listed    │
   │     provenance inputs?                                    │
   │   - NER cross-check: do entities/dates/places in the      │
   │     sentence match the structured tree (no               │
   │     contradictions)?                                      │
   │   - empty-provenance check: reject if no IDs listed.      │
   │  Failing sentences are dropped, never softened.           │
   └───────────────────────────────────────────────────────────┘
                       ↓
   proposed bio (sentence list + provenance) → user review →
   user edits → save → profile.bio
```

### Stage A (templates) — what the deterministic base looks like

Reasonable starter templates (subject to refinement):

- Opening: "{firstName} {lastName} was born {birthDateText} in
  {birthLocation}." (Skip elements that are unknown.)
- Parents: "{firstName}'s parents were {father.displayName} and
  {mother.displayName}." (Skip if no parents in tree.)
- Marriage: "{firstName} married {spouse.displayName} {marriageDateText}
  in {marriageLocation}." (One sentence per spouse.)
- Children: "{firstName} and {spouse.displayName} had {N} children: ..."
  (Skip if N=0.)
- Death: "{firstName} died {deathDateText} in {deathLocation}." (Skip
  unknowns.)
- Occupations (from life events): "By {year}, {firstName} was a
  {occupation} in {place}." One sentence per distinct occupation.

These templates produce dry, accurate prose. The base layer is **always
truthful** because it's pure restating; verification is structural, not
semantic.

### Stage C (MLX) — what the synthesis instruction looks like

The MLX prompt is heavily constrained:

> You are stitching a biographical paragraph. You will be given:
>
> 1. A list of factual sentences about the subject (each tagged with
>    its source facts).
> 2. A list of contextual passages about the place, time, and
>    occupation (each tagged with its corpus passage ID).
>
> Your task: produce a paragraph that reads as prose. Each sentence
> you emit must paraphrase or near-quote from the inputs. Do not
> introduce any details, events, places, people, or claims that are
> not in the inputs. Do not generalise from era or place. Do not add
> narrative colour. If you cannot connect two facts with prose without
> inventing, leave them as separate sentences.
>
> For every sentence you emit, list the input IDs it draws from.
> Sentences with no input IDs will be rejected.
>
> Prefer brevity over invention. Silence is preferable to fabrication.

Likely needs few-shot examples that *demonstrate* sparse output as
acceptable so the model doesn't reflexively pad.

### Stage D (verification) — implementation options

The verification step is what makes "no hallucination" enforceable
rather than aspirational. Implementation candidates, in increasing order
of robustness:

1. **Provenance presence check** (trivial). Reject any sentence with
   an empty provenance set. Catches the laziest failure mode.
2. **NER + entity cross-check.** Run NER over each emitted sentence;
   verify every named entity (person, place, date, occupation) appears
   in either the structured tree or the provenance-listed corpus
   passages. Catches "his wife Mary" when the relationship is Margaret.
3. **Sentence-level entailment.** A second LM pass (could be a smaller
   model) checks: "Given these inputs, does this sentence follow?" Per
   sentence: keep / drop. Catches subtler drift than NER alone.
4. **Adversarial paraphrase check.** For each sentence, ask the LM to
   restate the source inputs in its own words; compare to the emitted
   sentence; if the emitted sentence contains content not present in
   the restatement, drop. Catches confident additions disguised as
   paraphrasing.

Phase 1 is mandatory. Phase 2 should land in v1. Phases 3 / 4 are
quality improvements as the local model and verification tooling
mature.

### Stage D — fact-check against the tree

In addition to entailment, the verification pass cross-checks
**structured-fact contradictions**:

- Names mentioned in the bio must match `Profile.displayName` for any
  referenced person.
- Dates must match the structured fields they reference.
- Places must match canonical place IDs from the gazetteer where the
  prose names a place.
- Relationships named in the bio must exist as `Relationship` rows in
  the tree.

A sentence that says "his daughter Mary" when no Mary appears in the
tree, or "in Brighton" when the structured residence was Birmingham,
is a regression and gets dropped. The deterministic-sandwich principle
applies: the structured tree is the source of truth; the LM cannot
contradict it.

## Rendering

The rendered bio in the inspector card shows sentences with **inline
citation markers**:

```
John Smith was born on 21 Dec 1820 in Cromford.[1] His father was a
cotton spinner.[2] Cromford was Richard Arkwright's planned mill
village, the first of its kind in Britain.[3] John appears in the 1841
census as a cotton piecer, aged 12.[4]

[1] tree: birthDate, birthLocation
[2] tree: father's occupation life-event
[3] corpus: WikiTree Space "Cromford and Arkwright" (cited to: Fitton,
    R.S., 'The Arkwrights: Spinners of Fortune', Manchester UP 1989)
[4] tree: 1841 census life-event
```

The citation block is collapsible / expandable. The visual treatment
makes provenance immediately auditable — the user can see where every
claim comes from. An unsourced claim would be *visibly* unsourced (which
is why empty-provenance sentences are rejected at verification — they
must never reach rendering).

For long bios, the inspector card collapses the bio into a "Biography ▸"
disclosure that expands to the full prose.

## Regeneration

Bios are not write-once. As the user adds facts, accepts corpus
passages, or refines the tree, the bio for affected profiles becomes
**stale**. Regeneration must be **diff-aware** and **non-destructive**.

### Staleness detection

A bio is stale when any of the following change since it was last
generated:

- A structured fact this bio references
- A corpus passage this bio cites
- New facts on the profile that the bio doesn't currently reference
- New corpus passages whose `appliesAt` intersects the profile's
  cluster

The UI flags stale bios with a small badge ("regenerate available")
rather than auto-regenerating.

### Preserving user edits

The user is the final author of a bio. If they've refined the prose,
regeneration must not silently overwrite their edits. Two candidate
approaches:

1. **Segmented bios.** The bio is stored as a list of segments, each
   marked `auto` or `user-edited`. Regeneration only touches `auto`
   segments. User-edited segments persist.
2. **Diff-based regeneration.** The regenerator produces a *proposed
   new bio* and shows the user a diff against the current. User
   accepts / rejects per change.

(2) is more powerful but heavier UX. (1) is simpler and matches the
"AI proposes; user decides" model. Start with (1).

## Bio is not a sourced fact

The current code treats `bio` as a `ProfileField` with the same source
provenance, dispute, and Correct-vs-Alternative machinery as a birth
date. **For bios, this is the wrong shape.** Two interpretations of a
date can be "competing"; two pieces of prose are not. This spec calls
for retiring the field-source pipeline for bio:

- `bio` keeps a single `SourceOrigin` indicating the *author*
  (manual / synthesised / imported), but **not** a multi-source set.
- "Disputed bio" is not a possible state.
- The Correct-vs-Alternative picker does not apply.
- The completeness check stops counting `bio` as a missing fact.
  Missing bio is missing *writing*, not missing data.

These are small migrations; cover them as a prep step.

## Phases

1. **Decouple bio from the field-source pipeline.** Remove bio from
   completeness's missing-facts list. Hide it from the dispute UI.
   This is the prep step and is independently valuable.
2. **Stage A (templates).** Deterministic base-layer generation from
   structured facts. Pure paraphrasing. No AI. Wire to a "Generate base
   bio" button in the inspector card's edit mode.
3. **Stage B (corpus retrieval).** Reads `cluster_corpus` (depends on
   `SOCIAL_HISTORY_CORPUS_SPEC.md`). Returns the passages applicable to
   a given profile.
4. **Stage C (MLX synthesis).** Prompt scaffolding + few-shot examples.
   Initially likely DeepSeek-R1 7B; the deferred Qwen 2.5 swap from
   `project_reasoning_model_default.md` may land cleaner here.
5. **Stage D (verification).** Provenance presence check first, then
   NER cross-check, then entailment.
6. **Rendering with citations.** Inline markers, expandable provenance
   block, inspector-card disclosure for long bios.
7. **Regeneration.** Staleness detection + segmented user-edit
   preservation.

## Hard constraints (recap)

- Zero hallucination. Empty-provenance sentences cannot exist.
- Silence > invention. Sparser bios are correct; padded bios are not.
- AI styles; sources decide.
- Bio is narrative, not a fact. Retire the field-source / dispute /
  correct-vs-alt pipeline for it.
- Honour the firewall: synthesis output is a *proposal*; the user
  accepts before `profile.bio` is written.
- No outbound network calls from the shipping app. All synthesis runs
  on MLX, on-device.
- Geography-independent end-to-end. Same engine produces sparse bios
  for unfamiliar regions; richer bios appear automatically as the user
  accepts corpus for those regions.

## Out of scope

- Auto-regenerating bios in the background. Regeneration is
  user-initiated.
- Multi-language bio output. English only for the foreseeable.
- Translating corpus passages between source language and bio language.
- Style preset support ("write this like a Victorian obituary") — the
  prompt is what it is; if the user wants tonal variation they edit
  the prose by hand.
- Bio-driven research suggestions ("this part of the bio is sparse,
  research X next") — adjacent feature, separate spec.

## Dependencies

- `SOCIAL_HISTORY_CORPUS_SPEC.md` — provides the cluster corpus.
  Without it, the rich layer is empty and bios stay at the base layer.
- The deferred reasoning-model default decision (memory:
  `project_reasoning_model_default.md`) — Qwen 2.5 likely a better
  prose-stylist than DeepSeek-R1; align on this before tuning the
  prompt scaffolding.
- The existing MLX integration (`Services/Reasoning/` or wherever the
  current MLX surface lives) — synthesis reuses that runtime; no new
  AI runtime is introduced.

## Cross-references

- `feedback_firewall_sqlite.md` — same firewall extends to bios.
- `feedback_no_hardcoded_regions.md` — bio synthesis is verified by
  producing decent output for non-Derbyshire trees.
- `Ancestor Research/CLAUDE.md` — Evidence Firewall section.
- `RESEARCH_PIPELINE_SPEC.md` — established the deterministic-sandwich
  pattern this spec extends to prose.
- `PROFILE_VIEW_UNIFY_SPEC.md` — the unified card is where the bio
  renders and where the edit flow lives.
