# Prose Corpus and Bio Synthesis — Specification

> **Phase A (corpus subsystem) is SHIPPED.** The crawler, HTML→markdown
> converter, per-source SQLite index, retrieval source, research-time
> MLX extraction, and Settings UI all live in code
> (`Ancestor Research/Services/Corpus/` — `HTMLToMarkdownConverter`,
> `ProseCorpusCrawler`, `ProseCorpusStorage`, `ProseCorpusRegistry`,
> `ProseCorpusIndex`+`Indexer`, `ProseCorpusSource`, `ProseCorpusService`,
> `ProseCorpusAdder`, `ProseCorpusExtractor` + `Resources/Prompts/
> prose_extraction_system.txt` + `ProseCorporaSettingsView` /
> `AddProseCorpusSheet`). Built in commits `32f8d85`…`b91d7d6`, `ffc883c`.
> **The Phase-A build detail that used to live here — on-disk layout,
> SQLite schema, crawler politeness, converter contract, indexer,
> retrieval SQL, research-time MLX routing/mode-gating, and the AC-B*/
> AC-C*/AC-I*/AC-R*/AC-M*/AC-E* acceptance criteria — is now in the
> code + git history and has been cut from this spec.**
>
> **Phase B (bio synthesis, Stages A–D) and Phase C (cluster-driven URL
> discovery) are unbuilt and forward-looking — that is what remains here.**
>
> Phase B was originally gated behind the (now-shipped, git-only) engine
> foundation work: bio synthesis on top of a scorer that over-claims for
> thin profiles would produce confident, citation-traceable prose about
> facts the engine isn't sure about. The foundation shipped 2026-07-13;
> the gate is cleared, so Phase B is now queued-by-priority behind a
> "solid core" declaration rather than blocked.

**Status:** Phase A shipped (git-only). Phase B / Phase C forward.
**Supersedes:** `AncestorApp/BIO_SYNTHESIS_SPEC.md` and
`AncestorApp/SOCIAL_HISTORY_CORPUS_SPEC.md`, both retired into this
file on 2026-05-22 (provenance note — both files are deleted / git-only).
**References:** `RESEARCH_PIPELINE_SPEC.md` (governing pipeline),
`AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md` (source plugin shape),
`AncestorApp/DOSSIER_SPEC.md` (shared grounding types — see the
Phase B-5 reuse note).

Where this spec interacts with the research pipeline (`pending_facts`,
`narrative_findings`, the Evidence Firewall, `LocalInferenceService`),
`RESEARCH_PIPELINE_SPEC.md` takes precedence.

---

## Part I: Mission (reference)

### 2. The bio-synthesis problem

A bio is an **honest reflection of a person's actual lived life**,
built from:

- **Base layer** — readable prose restating what the structured tree
  knows about the person (dates, places, relationships, occupations,
  life events).
- **Rich layer** — woven social and historical context drawn from
  accepted prose-corpus pages (the shipped Phase-A corpus), scoped to
  the person's place / time / occupation.

A bio for a profile with rich corpus support reads like the kind of
short biographical sketch a careful local-history researcher would
produce. A bio for a profile with no corpus support reads like a
sparse factual paragraph and is *deliberately* not padded.

### 3. The absolute principle: zero hallucination

Bios must be 100% fact-based. This is not a quality goal; it is the
design floor. Every sentence in every bio must trace back to either:

1. A structured fact in the user's tree (this person's birth date,
   this person's occupation, this relationship), or
2. A cited passage in an accepted prose corpus page.

No exceptions. Not for "obvious" claims ("child labour was common in
1820"). Not for "implied" details ("he walked to the mill before
dawn"). Not for narrative colour. Not for hedged speculation ("he
likely attended the parish church").

**Silence is preferable to invention.** Where no fact or corpus passage
supports a sentence, the system says nothing about that topic. A bio
that reads sparser is better than a bio that reads beautifully but
contains a claim the user can't trace.

This is the analogue of the existing deterministic-sandwich principle.
There it's "AI proposes; rules decide." Here it's **"AI styles;
sources decide."** The LM rephrases and stitches over verified inputs.
It does not contribute knowledge.

---

## Part II: Load-bearing architectural rationale (reference)

The full Phase-A architecture (storage layout, per-source SQLite schema,
crawler politeness, indexer, retrieval SQL, MLX routing) is **shipped**
— see `Ancestor Research/Services/Corpus/` and the `ProseCorpusIndex`
schema. Two decisions remain load-bearing for Phase B and are kept here
as reference.

### 5. Markdown files vs chunked-vector RAG

**Decision:** one markdown file per source page on disk; SQLite/FTS5
index over the page body. No embedding store, no vector index.

**Reasoning:**

- Genealogy queries are proper-noun-and-integer dominated. "All pages
  mentioning surname CAULDWELL between 1780 and 1830 in parish
  Wirksworth" is a lexical predicate, not a semantic one. SQLite +
  FTS5 answers it natively.
- The corpora are small. Wirksworth at 30 MB fits in memory; an
  embedding store would be the same order of magnitude with worse
  retrieval.
- Vectors lose surname spelling — embedding similarity collapses
  "Cauldwell" and "Caldwell" toward a generic English-surname cluster.
  Lexical retrieval with explicit `SurnameVariants` lookups keeps
  spelling precision.
- A markdown-on-disk corpus is human-inspectable and `grep`-able; a
  vector store is opaque.

Vectors are out of scope (Part XVI). They may be added later only as a
re-rank signal within an already-filtered surname/year window, and only
if observed extraction quality justifies the storage and complexity.

### 9. Bio is not a sourced fact

Two interpretations of a date can be "competing"; two pieces of prose
are not. So `bio` must not carry the field-source / dispute /
Correct-vs-Alternative machinery of a birth date:

- `bio` keeps a single `SourceOrigin` indicating the *author*
  (manual / synthesised / imported), but **not** a multi-source set.
- "Disputed bio" is not a possible state.
- The Correct-vs-Alternative picker does not apply.
- The completeness check stops counting `bio` as a missing fact.
  Missing bio is missing *writing*, not missing data.

These are small migrations; cover them as the Phase B-1 prep step (§38).
⚠ Reconcile against the shipped `bio` field + `PublishBioBuilder`
(`Services/Publish/`) when doing B-1.

### 10. The provenance contract

Every sentence in a proposed bio carries a **provenance set** — a list
of input IDs the sentence draws from. Inputs are of two types:

- `factID` — a `ProfileField` value, a `Relationship`, a `LifeEvent` row.
- `pageHash` — a corpus page hash (Phase-A `ProseCorpusIndex`). The
  page's `source_url` and `content_hash` become the citation marker on
  the rendered bio.

A sentence with an empty provenance set is rejected and never emitted.
The provenance set is what the Stage-D verification pass checks against
and what the rendered bio displays as citation markers.

---

## Part V: Cluster-driven candidate URLs — Phase C intent (forward)

> Phase A user-add flow (Settings → *Prose Corpora* → *Add*, site
> verification, background crawl, registry) is **shipped**. What remains
> is the *cluster-driven* discovery layer below — **Phase C**.

### 19. Cluster-driven candidate URLs (harness-assisted)

For bio synthesis to scale across geographies without the user knowing
in advance which sources matter, two affordances sit *above* the
shipped user-added flow. Both are optional; the corpus subsystem is
unchanged whether or not they're used.

#### 19.1 Family social-history fingerprint

A deterministic engine analyses the tree's vital events and surfaces
**`(place, time-window, occupation?)` clusters** where the family has
density:

- **Place concentrations** — cluster vital events (birth / marriage /
  death / census residences) by canonical place codes and time. A
  family with 40% of its 19th-century vital events in a 20km radius
  around Wirksworth produces a `(Wirksworth, 1800–1900)` cluster with
  high weight.
- **Occupation profile** — extract structured occupations from census
  `LifeEvent.details`. A cluster of "lead miner" occupations in
  Wirksworth 1830–1900 produces a `(Wirksworth, 1830–1900, lead-miner)`
  cluster.
- **Event density** — supports "this place mattered most during these
  decades" reasoning. Avoids surfacing irrelevant material.

Clusters are ranked. The top N (by weight × density) become the targets
for candidate-URL discovery. No AI is involved at this stage; the
cluster engine is pure structured-tree analysis.

#### 19.2 Harness-proposed candidate URLs

For each cluster, the user is shown candidate URLs to consider adding as
prose corpora — local-history archives, county wikis, occupational
heritage sites, WikiTree Space pages — *suggested* by the harness
(Claude Code + MCP + external SaaS, operating on public sources,
off-device).

The harness does the discovery work over citation-strict source
candidates:

- **Wikipedia** sections whose claims carry inline `<ref>` tags to
  verifiable primary sources.
- **WikiTree Space pages** — community-curated essays.
- **County / regional history wikis** (Derbyshire Heritage, Cornwall
  Heritage Environment Record, etc.).
- **Industrial heritage organisations** — National Trust pages, mining
  heritage sites, occupation-specific archives.

The user reviews provenance + content of each candidate URL and chooses
which to add. Once added, the URL flows into the normal (shipped)
user-added path. The harness has no write access to the corpus
directly; its role is *suggesting URLs to add*, nothing more.

This keeps geography-independence honest: no place / industry list is
hardcoded; the harness queries public sources for whatever fingerprints
the user's tree produces. A Cornish tin-mining family surfaces Cornish
heritage candidates; a Lancashire weaving family surfaces weaving-trade
candidates; same machinery.

#### 19.3 What the harness must not do

- **Write to `profile.*` directly.** The firewall is unchanged. Bios
  are not facts; corpus is not facts; both go through human review.
- **Bypass corpus review.** Even a strong model proposes; the user
  decides.
- **Hallucinate citations.** A candidate URL whose advertised content
  turns out missing, paywalled, or fabricated is a critical failure.
  The harness must verify reachability and content presence before
  surfacing.

---

## Part IX: Bio synthesis pipeline (forward — Phase B)

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
   │  Query each registered prose corpus (shipped Phase A) for │
   │  pages matching this profile's (surname / place / year).  │
   │  Returns 0..K page bodies + provenance per corpus.        │
   └───────────────────────────────────────────────────────────┘
                       ↓
   ┌───────────────────────────────────────────────────────────┐
   │  STAGE C — MLX synthesis                                  │
   │  Inputs: base prose + retrieved corpus pages.             │
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
   │     sentence match the structured tree (no                │
   │     contradictions)?                                      │
   │   - empty-provenance check: reject if no IDs listed.      │
   │  Failing sentences are dropped, never softened.           │
   └───────────────────────────────────────────────────────────┘
                       ↓
   proposed bio (sentence list + provenance) → user review →
   user edits → save → profile.bio
```

### 28. Stage A — deterministic base layer

Templates produce dry, accurate prose. The base layer is **always
truthful** because it's pure restating; verification is structural,
not semantic.

> **REUSE, don't rebuild.** `Services/Publish/PublishBioBuilder.swift`
> (shipped, PUBLISHER_SPEC #Change6) already emits deterministic,
> committed-facts-only template prose via
> `NarrativeAssembler.templateNarrative` — that is the spirit of Stage A
> (base-layer templates). Phase B-2 should **reuse
> `PublishBioBuilder` / `NarrativeAssembler`**, not re-implement the
> templates. The difference is only that Stage A runs at bio-authoring
> time (feeding Stages B–D) rather than at publish time.

Reasonable starter templates (subject to refinement):

- Opening: "{firstName} {lastName} was born {birthDateText} in
  {birthLocation}." (Skip unknown elements.)
- Parents: "{firstName}'s parents were {father.displayName} and
  {mother.displayName}." (Skip if no parents in tree.)
- Marriage: "{firstName} married {spouse.displayName}
  {marriageDateText} in {marriageLocation}." (One sentence per spouse.)
- Children: "{firstName} and {spouse.displayName} had {N} children: …"
  (Skip if N=0.)
- Death: "{firstName} died {deathDateText} in {deathLocation}." (Skip
  unknowns.)
- Occupations (from life events): "By {year}, {firstName} was a
  {occupation} in {place}." One sentence per distinct occupation.

### 29. Stage B — context retrieval

Bio-side retrieval queries every registered prose corpus
(`ProseCorpusRegistry`, shipped) in turn. Per corpus, the same
retrieval path the shipped `ProseCorpusSource` uses runs with the
subject's surname, year window, and place. The `applies_at_*` gate
narrows to pages whose temporal scope intersects the subject's
`birthYear...deathYear` (or `birthYear ± 50` when death year is
unknown).

Returned page bodies, alongside their `source_url` and `content_hash`,
become the **`pageHash` provenance set** for Stage C.

### 30. Stage C — MLX synthesis

The MLX prompt is heavily constrained. A bundled prompt file at
`Resources/Prompts/bio_synthesis_system.txt` (unbuilt). The user prompt
is built per call:

```
SUBJECT (structured tree)
  John Smith
  born 21 Dec 1820 in Cromford, Derbyshire
  father a cotton spinner
  married Mary Barker 14 Apr 1842 in Cromford
  …

CONTEXT (cited corpus passages, each with pageHash and source_url)
  [pageHash:a3f1b9c2…] from http://www.wirksworth.org.uk/…
    "Cromford was Richard Arkwright's planned mill village, the
     first of its kind in Britain, …"
  [pageHash:b1e2c3d4…] from …

TASK
  Produce a paragraph that reads as prose. Each sentence you emit
  must paraphrase or near-quote from the inputs. Do not introduce
  any details, events, places, people, or claims that are not in
  the inputs. Do not generalise from era or place. Do not add
  narrative colour. If you cannot connect two facts with prose
  without inventing, leave them as separate sentences.

  For every sentence you emit, list the input IDs it draws from
  (factID or pageHash). Sentences with no input IDs will be
  rejected.

  Prefer brevity over invention. Silence is preferable to fabrication.
```

Likely needs few-shot examples that *demonstrate* sparse output as
acceptable so the model doesn't reflexively pad. Reuses
`LocalInferenceService.shared` (the only MLX call site); no new service.

### 31. Stage D — verification

The verification step is what makes "no hallucination" enforceable
rather than aspirational. Implementation candidates, in increasing
order of robustness:

1. **Provenance presence check** (trivial). Reject any sentence with an
   empty provenance set. Catches the laziest failure mode.
2. **NER + entity cross-check.** Run NER over each emitted sentence;
   verify every named entity (person, place, date, occupation) appears
   in either the structured tree or the provenance-listed corpus
   passages. Catches "his wife Mary" when the relationship is Margaret.
3. **Sentence-level entailment.** A second LM pass checks "Given these
   inputs, does this sentence follow?" Per sentence: keep / drop.
4. **Adversarial paraphrase check.** For each sentence, ask the LM to
   restate the source inputs in its own words; compare to the emitted
   sentence; if the emitted sentence contains content not present in
   the restatement, drop.

Phase 1 is mandatory. Phase 2 should land in v1. Phases 3 / 4 are
quality improvements as the local model and verification tooling mature.

> **Shared asset.** Stage D's verifier is the same
> `GroundedProseVerifier` (AncestorKit) that `DOSSIER_SPEC.md` builds
> for pre-commit decision prose. Build it **once** — DOSSIER
> #T9-Change1/5 create `GroundedSentence` / `ConfidenceVocabulary` /
> `GroundedProseVerifier`, and PROSE_CORPUS Phase B-5 consumes them.
> This creates an ordering dependency: DOSSIER lands **before or
> alongside** Phase B-5.

#### 31.1 Fact-check against the tree

In addition to entailment, the verification pass cross-checks
**structured-fact contradictions**:

- Names in the bio must match `Profile.displayName` for any referenced
  person.
- Dates must match the structured fields they reference.
- Places must match canonical place IDs from the gazetteer where the
  prose names a place.
- Relationships named in the bio must exist as `Relationship` rows.

A sentence that says "his daughter Mary" when no Mary appears in the
tree, or "in Brighton" when the structured residence was Birmingham, is
a regression and gets dropped. The structured tree is the source of
truth; the LM cannot contradict it.

---

## Part X: Bio rendering (forward — Phase B)

### 32. Inline citation markers

The rendered bio in the inspector card shows sentences with **inline
citation markers**:

```
John Smith was born on 21 Dec 1820 in Cromford.[1] His father was a
cotton spinner.[2] Cromford was Richard Arkwright's planned mill
village, the first of its kind in Britain.[3] John appears in the
1841 census as a cotton piecer, aged 12.[4]

[1] tree: birthDate, birthLocation
[2] tree: father's occupation life-event
[3] corpus: Wirksworth pageHash a3f1b9c2…
[4] tree: 1841 census life-event
```

The citation block is collapsible / expandable. The visual treatment
makes provenance immediately auditable. An unsourced claim would be
*visibly* unsourced — which is why empty-provenance sentences are
rejected at verification and never reach rendering.

### 33. Inspector-card disclosure

For long bios, the inspector card collapses the bio into a
"Biography ▸" disclosure that expands to the full prose. Card width
remains stable; long bios don't dominate the inspector.

---

## Part XI: Bio regeneration (forward — Phase B)

Bios are not write-once. As the user adds facts, accepts corpus
passages, or refines the tree, the bio for affected profiles becomes
**stale**. Regeneration must be **diff-aware** and **non-destructive**.

### 34. Staleness detection

A bio is stale when any of the following change since it was last
generated:

- A structured fact this bio references.
- A corpus page this bio cites (its `content_hash` changes, or it's
  deleted).
- New facts on the profile that the bio doesn't currently reference.
- New corpus pages whose `applies_at_*` window intersects the profile's
  date span.

The UI flags stale bios with a small badge ("regenerate available")
rather than auto-regenerating.

### 35. Preserving user edits

The user is the final author of a bio. If they've refined the prose,
regeneration must not silently overwrite their edits. Two candidate
approaches:

1. **Segmented bios.** The bio is stored as a list of segments, each
   marked `auto` or `user-edited`. Regeneration only touches `auto`
   segments. User-edited segments persist.
2. **Diff-based regeneration.** The regenerator produces a *proposed
   new bio* and shows a diff against the current. User accepts / rejects
   per change.

(2) is more powerful but heavier UX. (1) is simpler and matches the
"AI proposes; user decides" model. Start with (1).

---

## Part XII: Acceptance criteria — Phase B bio synthesis (AC-S*)

> The Phase-A acceptance criteria (AC-B* build, AC-C* crawler
> politeness, AC-I* index, AC-R* retrieval, AC-M* research-time MLX
> extraction, AC-E* firewall integration) covered shipped work and are
> now enforced by the Phase-A test suite in code / git. Only the Phase B
> bio-synthesis criteria remain forward.

- **AC-S1** A bio whose Stage C output contains a sentence with an empty
  provenance set is rejected at Stage D and never reaches rendering.
- **AC-S2** A bio whose Stage C output asserts "his wife Mary" when the
  tree records his wife as Margaret is dropped at Stage D's NER
  cross-check.
- **AC-S3** A profile with no accepted corpus pages produces only the
  Stage A base-layer prose. The bio is never empty for a profile with
  any structured facts.
- **AC-S4** Every rendered bio sentence carries at least one citation
  marker. Unsourced sentences are structurally impossible to render.
- **AC-S5** Regenerating a bio after a user edit preserves the
  user-edited segments and only touches `auto` segments.

---

## Part XIII: Phased build (forward)

> **Phase A (corpus subsystem, slices A1–A8) is SHIPPED** — see the
> `Services/Corpus/` file list in the header and git commits
> `32f8d85`…`b91d7d6`, `ffc883c`. The A1–A8 slice table is git-only.

### Phase B — Bio synthesis

| Phase | Slice | Depends on |
|---|---|---|
| **B1** | **Decouple bio from the field-source pipeline.** Remove bio from completeness's missing-facts list. Hide it from the dispute UI. Retire Correct-vs-Alternative for bio. Prep step; reconcile with the shipped `bio` field + `PublishBioBuilder`. | none (does not depend on corpus) |
| **B2** | **Stage A (templates).** Deterministic base-layer generation from structured facts. Pure paraphrasing, no AI. Wire to a "Generate base bio" button in the inspector card's edit mode. **REUSE `PublishBioBuilder` / `NarrativeAssembler.templateNarrative` (shipped) rather than rebuild.** | B1 |
| **B3** | **Stage B (corpus retrieval).** Bio-side retrieval over `ProseCorpusRegistry` (shipped Phase A). Honours the `applies_at_*` gate. | Phase A (shipped), B2 |
| **B4** | **Stage C (MLX synthesis).** Prompt scaffolding + few-shot examples via `LocalInferenceService.shared`. The deferred Qwen swap (`project_reasoning_model_default.md`) may land cleaner here. | B3 |
| **B5** | **Stage D (verification).** Provenance presence check first, then NER cross-check, then entailment. Sentences that fail are dropped, never softened. **Shared `GroundedProseVerifier` (AncestorKit) — build once with DOSSIER; DOSSIER lands first or alongside.** | B4 |
| **B6** | **Rendering with citations.** Inline markers, expandable provenance block, inspector-card disclosure for long bios. | B5 |
| **B7** | **Regeneration.** Staleness detection + segmented user-edit preservation. | B6 |

### Phase C — Cluster-driven URL discovery (optional, harness-side)

| Phase | Slice | Depends on |
|---|---|---|
| **C1** | **Cluster engine.** Pure structured-tree analysis, no AI. Outputs the (place × time × occupation) fingerprint deterministically (§19.1). Testable in isolation. | none |
| **C2** | **Harness integration.** Claude Code commands / scripts that invoke the MCP server, surface clusters, propose candidate URLs via SaaS over public sources (§19.2). Dev-tooling, not shipping app functionality. | C1 |
| **C3** | **In-app review surface for candidate URLs.** Settings UI shows harness-proposed URLs per cluster, with provenance trail. User accepts / rejects; accepted URLs flow into the shipped user-add corpus path. | C2 |

Each phase ships independently. B6 is the first user-visible bio
rendering. C3 only matters once enough bios have been written to justify
the harness-assisted discovery layer.

---

## Part XIV: Hard constraints (recap)

- **Zero hallucination** in bios. Empty-provenance sentences cannot
  exist.
- **Silence > invention.** Sparser bios are correct; padded bios are
  not.
- **AI styles; sources decide.** The LM rephrases and stitches over
  verified inputs. It does not contribute knowledge.
- **Bio is narrative, not a fact.** Retire the field-source / dispute /
  Correct-vs-Alternative pipeline for it (§9).
- **Honour the Evidence Firewall.** All extracted facts and proposed
  bios are *proposals*; the user accepts before they reach the tree.
- **No outbound network calls from the shipping app.** All MLX
  inference runs on-device. Harness-assisted candidate URL discovery
  (§19) happens in Claude Code via SaaS, off-device.
- **Geography-independent end-to-end.** No code path mentions
  Derbyshire, Wirksworth, Cromford, cotton, lead, or any specific
  place/industry. Region knowledge is derived from the tree and the
  user's accepted corpora.
- **Citation-strict corpus.** Every accepted page carries verifiable
  provenance back to its source.
- **Default-deny.** Anything the corpus / synthesis doesn't explicitly
  support is forbidden, not silently best-effort.

---

## Part XV: Open questions

These cannot be settled without empirical data from a built corpus.
Several relate to shipped Phase-A parameters that Phase B retrieval
inherits; all need a real built corpus + hand-labelled validation set.

### 43. Pivot-score weighting

Retrieval scores pages by `surname_count * 3 + year_count * 2 +
place_count`. Whether this ranks the correct page first across realistic
queries is unknown until a built corpus is queried with a hand-labelled
validation set ("for surname X in year range Y, the correct page is Z").
Tuning may reveal that mention-count is the wrong signal and
presence-only is better.

### 44. Page-size split threshold

The extraction prompt caps its CONTENT block at ~24 KB, splitting at
section boundaries above that. The number is a guess; the real threshold
needs measurement against actual pages and observed MLX OOM behaviour on
representative hardware (M1 8 GB, M2 16 GB, M3 32 GB).

### 45. Stop-word list scope

What counts as a "surname-shaped token" needs an empirically grounded
stop-word list built from the corpus itself (e.g. tokens appearing in
>40% of pages are almost certainly common nouns). Whether this is
per-source or universal is unknown.

### 46. Applicability window calibration

The optional time/occupation scope per page (`applies_at_*`) — how
generous to be with the window (strict intersection vs tolerant overlap)
needs empirical tuning against real bios to balance "missing relevant
context" against "surfacing anachronistic context".

### 47. Verification depth

§31 lists four candidate verification techniques in increasing
robustness. How far up that ladder to climb before user-facing bio
quality is acceptable is empirical. The cost of stronger verification is
more MLX inference per bio; the benefit is fewer false-positive
sentences reaching rendering.

---

## Part XVI: Out of scope

- **Vector embeddings.** §5 rejects them. Revisit only if §43 tuning
  fails to produce acceptable top-K precision.
- **Cross-source corpus linking.** Each corpus is an independent island.
- **Bundled prebuilt corpora.** Each user builds locally. No central
  CDN, no signed corpus archive, no torrent.
- **OCR over linked images.** The converter stores the image URL but
  never fetches the bytes.
- **Writing back to source sites.** The crawler is read-only.
- **Generalised free-form web search.** This subsystem indexes named
  source corpora, not the open web.
- **In-app corpus editing.** The markdown files are produced by the
  converter and should not be hand-edited; any edit invalidates
  `content_hash`.
- **Auto-regenerating bios in the background.** Regeneration is
  user-initiated.
- **Multi-language bio output.** English only for the foreseeable.
- **Style preset support** ("write this like a Victorian obituary").
- **Bio-driven research suggestions** ("this part of the bio is sparse,
  research X next") — adjacent feature, separate spec.
- **Auto-promotion of corpus material into the tree.** The Evidence
  Firewall is unchanged.

---

## Part XVII: Cross-references

- `feedback_firewall_sqlite.md` (memory) — corpus writes go through the
  MCP server, not direct SQLite. Same firewall applies to bio synthesis
  output.
- `feedback_no_hardcoded_regions.md` (memory) — cluster-driven discovery
  (§19) and the corpus mechanics generally must derive region context
  from tree data, not from baked-in lists.
- `Ancestor Research/CLAUDE.md` — Evidence Firewall section.
- `RESEARCH_PIPELINE_SPEC.md` — established the deterministic-sandwich
  pattern this spec extends to bio synthesis output. §14 (MCP-driven
  auto-approval) is orthogonal — bio synthesis output never goes through
  auto-approval (bios are narrative, not facts, per §9).
- `DOSSIER_SPEC.md` — builds the shared `GroundedProseVerifier` /
  `GroundedSentence` / `ConfidenceVocabulary` (AncestorKit) that Phase
  B-5 reuses. Build once; DOSSIER lands first or alongside.
- `project_reasoning_model_default.md` (memory) — deferred Qwen swap;
  this spec's MLX components benefit from that decision.
