# Social History Corpus Spec

A geography-independent system for discovering, curating, and storing the
**social and historical context** that bios need in order to read as
honest reflections of real lived lives.

This is the **foundational** spec — `BIO_SYNTHESIS_SPEC.md` depends on it.
Synthesis cannot produce a rich bio if no cited contextual material
exists for the relevant cluster. Build this first.

## Mission

For the bio of a 12-year-old cotton spinner in 1820s Cromford to read as
more than "John was a cotton spinner born in Cromford in 1820", the app
needs **cited material about the world that person lived in** — what
Cromford was, what a cotton spinner did, what 1820 meant for that
combination.

For a coal-mining ancestor in 1880s Rhondda, or a tin miner in 1850s
Cornwall, or a millworker in 1840s Lowell Massachusetts, the *same
machinery* must surface different material. The corpus is **derived from
the user's tree**, not hand-curated per region.

## Hard principles

These follow from the wider architecture (the deterministic sandwich,
the Evidence Firewall, the "no hardcoded regions" memory) and from the
user's explicit constraint that bios must be honest:

1. **No hardcoded geographies.** No code path mentions Derbyshire,
   Wirksworth, Cromford, cotton, lead, or any specific place/industry.
   Same engine works for a Welsh coal family, an East Anglian
   agricultural family, a Cornish fishing family, a New England
   millworker family. Region knowledge is **discovered from the tree**.
2. **Citation strictness.** Every accepted corpus passage carries an
   explicit citation chain — to a Wikipedia article whose claim itself
   has an inline ref, to a WikiTree Space page, to a digitised archive
   record, to a book with page reference, to a user-uploaded PDF with
   provenance metadata. **Uncited passages cannot enter the corpus.**
3. **Human gates acceptance.** No external proposal lands in the
   accepted corpus without explicit user review. This extends the
   existing Evidence Firewall pattern — `pending_facts → human review →
   profile` becomes `pending_corpus → human review → cluster corpus`.
4. **Applicability is windowed.** Every corpus passage carries
   `appliesAt: (place, startYear, endYear, occupation?)` metadata so
   retrieval respects temporal scope. A passage about Arkwright's mill
   village applies to Cromford 1771-onwards but not to Cromford 1750.
5. **Geography independence is verified, not promised.** The cluster
   engine is implemented entirely over structured-tree data. If any
   region-specific list, dictionary, or heuristic creeps in, the test
   suite must catch it.

## The cluster fingerprint

The corpus query space is derived from the structured tree:

```
fingerprint = {
    placeConcentrations: [(place, weight, timeWindow)]
    occupationProfile:   [(occupation, place, timeWindow)]
    eventDensity:        [(place, year, eventCount)]
}
```

- **Place concentrations** — cluster vital events (birth / marriage /
  death / census residences) by place and time. A family with 40% of
  its 19th-century vital events in a 20km radius around Wirksworth
  produces a "Wirksworth 1800–1900" cluster with high weight.
- **Occupation profile** — extract structured occupations from census
  life events (already captured). A cluster of "lead miner" occupations
  in Wirksworth 1830–1900 produces a `(Wirksworth, 1830–1900, lead
  miner)` cluster.
- **Event density** — supports "this place mattered most during these
  decades" reasoning. Avoids surfacing Cromford material for a family
  who only had one ancestor pass through Cromford for a year.

Clusters are ranked. The top N (by weight × density) become the targets
for corpus discovery. Low-weight clusters can be marked for later
attention or ignored entirely.

### Time-stable vs. time-bounded patterns

Some patterns are geography-driven and stable across centuries
(limestone quarrying in the Peak District, fishing in Cornwall, tin
mining in West Cornwall). Others are sharp industrial spikes (cotton
mills in Derbyshire ~1770–1860 before migrating to Lancashire). Others
are continuous-but-volume-varying (agricultural labour, stone masonry).

Corpus passages encode this via `appliesAt.startYear / endYear`. The
cluster engine doesn't need to know which is which — retrieval simply
honours the windows. The user is the judge of "is this passage in the
right window".

## Discovery via the harness

This is where **external SaaS access via Claude Code + the MCP server**
earns its keep. Per the tier architecture ("route up only at the wall"),
corpus discovery operates on **public sources, not on people**, so it
can leave the device. Per the App Store / privacy constraint, the
shipping app itself stays MLX-only.

The harness role:

1. **Cluster surfacing.** Claude Code, via the MCP server, reads the
   project's structured facts (place / time / occupation tuples) and
   surfaces the top N clusters. Output: a list of (place, timeWindow,
   occupation?) tuples with weights and supporting event lists.
2. **Source surveying.** For each cluster, Claude Code surveys
   citation-strict source candidates:
   - **Wikipedia** — only sections whose claims carry inline `<ref>`
     tags to verifiable primary sources. Uncited prose is rejected.
   - **WikiTree Space pages** — community-curated essays on places /
     events / families / occupations, often with citation trails.
   - **County / regional history wikis** — many exist (Derbyshire
     Heritage, Cornwall Heritage Environment Record, etc.).
   - **Industrial heritage organisations** — National Trust pages,
     mining heritage sites, occupation-specific archives.
   - **User-supplied material** — PDFs, transcribed book extracts,
     archive photos with captions. Carry user-provided provenance.
3. **Citation chain validation.** For each candidate passage, walk
   back from the in-text reference to a primary source. Reject
   passages whose chain doesn't terminate at a reputable origin.
4. **Applicability tagging.** Determine the time window each passage
   applies to. Flag anachronisms (a passage about 1880s Cromford has
   no business in a corpus for 1760s Cromford).
5. **Geographic-scope tagging.** Distinguish "applies to this specific
   place" from "applies to a wider region/era". Prevents conflating
   "general industrial revolution England" with "specifically what
   happened in Cromford".

Output: `pending_corpus` rows — proposed passages with metadata, awaiting
human review.

### What the harness must NOT do

- **Write to `profile.*` directly.** The firewall is unchanged. Bios
  are not facts; corpus is not facts; both go through human review
  before they influence what's displayed about a person.
- **Bypass corpus review.** Even a strong model proposes; the user
  decides. The firewall isn't about model quality — it's about who has
  authority to assert.
- **Hallucinate citations.** A passage with a fabricated reference chain
  is a critical failure. The validation step exists specifically to
  catch this and reject. Better to surface fewer well-cited passages
  than many shaky ones.

## Acceptance flow

```
   tree (places, dates, occupations from facts + life events)
                       ↓
   cluster engine → family social-history fingerprint
                       ↓
       (cluster discovery / candidate retrieval — via harness)
                       ↓
   pending_corpus rows (passage text + citation chain + appliesAt)
                       ↓
       in-app corpus review UI:
         - shows each candidate with its citation chain
         - shows what cluster it would attach to
         - user can: accept, reject, or edit-and-accept
                       ↓
   accepted cluster_corpus rows
   (visible / queryable by bio synthesis)
```

The review UI is the most important UX surface this spec defines. It
must make citation chains **immediately auditable**:

- Quoted passage text
- Inline-cited source URL / book / archive reference
- The walk-back to the primary source (one or more hops)
- The cluster this passage would attach to (place, timeWindow,
  occupation?)
- Reason for proposal (which fact in the user's tree triggered this)
- Reject reasons surfaced as one-click buttons: "anachronism",
  "off-place", "weak citation", "off-topic", "duplicate"

## Storage shape

Provisional schema (subject to migration design):

```sql
CREATE TABLE pending_corpus (
    id              TEXT PRIMARY KEY,
    passage         TEXT NOT NULL,
    sourceURL       TEXT,
    sourceTitle     TEXT,
    citationChain   TEXT NOT NULL,  -- JSON: ordered list of hops
    appliesAtPlace  TEXT,           -- canonical place ref
    appliesAtStart  INTEGER,        -- year, inclusive
    appliesAtEnd    INTEGER,        -- year, inclusive
    appliesAtOccupation TEXT,       -- nullable
    triggerCluster  TEXT NOT NULL,  -- which cluster surfaced this
    triggerReason   TEXT,           -- which fact / event triggered
    proposedBy      TEXT NOT NULL,  -- harness / user / external
    proposedAt      DATETIME NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    reviewedAt      DATETIME,
    reviewerNote    TEXT
);

CREATE TABLE cluster_corpus (
    id              TEXT PRIMARY KEY,
    passage         TEXT NOT NULL,
    sourceURL       TEXT,
    sourceTitle     TEXT,
    citationChain   TEXT NOT NULL,
    appliesAtPlace  TEXT,
    appliesAtStart  INTEGER,
    appliesAtEnd    INTEGER,
    appliesAtOccupation TEXT,
    acceptedFrom    TEXT REFERENCES pending_corpus(id),
    acceptedAt      DATETIME NOT NULL
);
```

Notes:
- Corpus is **per-project**, not global. Each project's tree drives its
  own cluster set; cousin researchers in entirely different regions
  build entirely different corpora.
- Soft-delete via `status` rather than hard-delete on rejection — useful
  for auditing what was considered and refused, and for not re-surfacing
  the same rejected passage on subsequent runs.

## Cluster discovery — implementation notes

- Reuse existing `Region` / `Place` / `LocationGazetteer` types where
  possible. Don't invent a parallel place model.
- Place clustering: spatial-distance-on-gazetteer grouping (e.g.
  k-means-ish over canonical place coordinates), gated by event count.
- Time-window inference: simple density passes over the event years per
  place; merge windows separated by < N years.
- Occupation extraction: structured `LifeEvent.details` already captures
  census occupations; aggregate by (place, decade).
- Geography-independence test: run the cluster engine over a synthetic
  tree with all events in (say) South Wales coal valleys. Verify the
  output clusters look like coal-mining clusters, no Derbyshire residue
  anywhere.

## Phases

1. **Cluster engine.** Pure structured-tree analysis, no AI. Outputs the
   fingerprint deterministically. Testable in isolation. Should be the
   first thing built — it's geography-independent by construction and
   provides the API the harness consumes.
2. **Manual corpus management.** UI for users to add corpus passages by
   hand (paste text + citation, tag with cluster). Lets bio synthesis
   get bootstrapped without any harness integration.
3. **Harness integration.** Claude Code commands / scripts that invoke
   the MCP server, surface clusters, propose passages via SaaS,
   write to `pending_corpus`. This is dev-tooling, not shipping app
   functionality.
4. **Review UI.** In-app surface for triaging `pending_corpus` —
   accept / reject / edit. Modelled on the existing pending-facts
   triage flow.

## Out of scope

- Bio prose generation (lives in `BIO_SYNTHESIS_SPEC.md`).
- Building any pre-curated regional corpus that ships with the app —
  the corpus is per-project, per-user, derived from their tree.
- Network calls from the shipping app to external SaaS — the harness
  is a developer surface, not an app feature.
- Translating the user's tree to other languages or supporting
  non-English source material — defer.
- Automatic corpus expansion in the background — discovery is
  user-initiated via the harness.

## Cross-references

- `feedback_no_hardcoded_regions.md` (memory) — same principle, this
  spec is its extension to the corpus layer.
- `feedback_firewall_sqlite.md` (memory) — corpus writes go through the
  MCP server, not direct SQLite.
- `Ancestor Research/CLAUDE.md` — Evidence Firewall section.
- `BIO_SYNTHESIS_SPEC.md` — depends on this; consumes the cluster
  corpus.
- `RESEARCH_PIPELINE_SPEC.md` — established the firewall and tier
  architecture this spec extends.
