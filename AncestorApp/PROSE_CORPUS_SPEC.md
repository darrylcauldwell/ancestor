# Prose Corpus and Bio Synthesis — Specification

**Status:** Draft
**Scope:** Two adjacent subsystems, specified together because they
share storage, retrieval, and Evidence-Firewall mechanics:
1. **Prose Corpus** — local subsystem for user-added unstructured
   genealogy sources. The product ships no hardcoded source URLs;
   users add their own corpora (parish-record sites, local-history
   archives, county-record-office finding aids) and the ingestion
   flow is triggered by adding.
2. **Bio Synthesis** — `profile.bio` generation from structured facts
   + accepted prose-corpus pages into honest, citation-traceable
   prose. Bios scale with corpus depth; empty corpus yields the base
   layer only.
**Supersedes:** `AncestorApp/BIO_SYNTHESIS_SPEC.md` and
`AncestorApp/SOCIAL_HISTORY_CORPUS_SPEC.md`, both retired into this
file on 2026-05-22.
**References:** `RESEARCH_PIPELINE_SPEC.md` (governing pipeline),
`AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md` (source plugin shape).

Where this spec interacts with the research pipeline (`pending_facts`,
`narrative_findings`, the Evidence Firewall, `LocalInferenceService`),
`RESEARCH_PIPELINE_SPEC.md` takes precedence.

---

## Part I: Mission

### 1. The prose-corpus problem

Existing source plugins (FreeBMD, FreeCen, FreeREG, CWGC, FindAGrave,
Probate, Wirksworth, FamilySearch) treat their target sites as
structured-record APIs. They work because there is one record per HTTP
response and the parser can pull surname, year, district, etc., out
of known DOM positions.

Several genuinely useful genealogical sources are not record-shaped.
They are long narrative HTML pages — pedigrees that span dozens of
generations, parish-chest transcripts that mix marriages with poor-law
disbursements, burial narratives that bury a single fact in three
paragraphs of context. The current `WirksworthSource.swift` reaches
for `NSRegularExpression` against `<PRE>` blocks and best-effort
"Name born YEAR" patterns. It works for a handful of clean pedigrees
and silently drops everything else.

This spec adds a second retrieval mode that sits alongside structured
sources: **prose corpus**. The user adds a corpus by URL; the app
crawls that URL, pulls each page locally as cleaned markdown, indexes
by SQLite/FTS5 with lexical pivots (surnames mentioned, years
mentioned), and at research time the dispatcher selects the top-K
matching pages, hands them whole to the existing `LocalInferenceService`
(MLX), and routes extracted facts through the Evidence Firewall to
`pending_facts` and `narrative_findings`.

**No baked-in source URLs.** The product is the engine — crawler,
converter, indexer, retriever, extractor. The source list is per-user,
lives in a registry under Application Support, and is managed entirely
through the Settings UI. Adding a URL triggers ingestion; removing a
URL deletes the local corpus.

**Why user-managed.** Bundling parish-record and local-history URLs
into the product is impractical at scale (there are hundreds of
relevant volunteer sites) and brittle (URLs and content change). A
user managing their own three or four corpora — the ones intersecting
their tree — is the natural fit.

**Wirksworth Parish Records** (`http://www.wirksworth.org.uk/`) is the
canonical example URL used throughout this spec to illustrate the
design; it is not a baked-in source.

**Unifying principle:** lexical retrieval drives selection; the MLX
model does extraction only. Deterministic decisions about facts remain
with the scorer and the Evidence Firewall — extraction outputs are
`pending_facts`, never tree commits.

### 2. The bio-synthesis problem

A bio is an **honest reflection of a person's actual lived life**,
built from:

- **Base layer** — readable prose restating what the structured tree
  knows about the person (dates, places, relationships, occupations,
  life events).
- **Rich layer** — woven social and historical context drawn from
  accepted prose-corpus pages, scoped to the person's place / time /
  occupation.

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
dawn"). Not for narrative colour ("the cobbles were cold underfoot").
Not for hedged speculation ("he likely attended the parish church").

**Silence is preferable to invention.** Where no fact or corpus passage
supports a sentence, the system says nothing about that topic. A bio
that reads sparser is better than a bio that reads beautifully but
contains a claim the user can't trace.

This is the analogue of the existing deterministic-sandwich principle.
There it's "AI proposes; rules decide." Here it's **"AI styles;
sources decide."** The LM rephrases and stitches over verified inputs.
It does not contribute knowledge. It does not "know" things.

### 4. How the two subsystems relate

The prose corpus is the foundation. Bio synthesis is a consumer of it.
The same accepted corpus pages serve two distinct purposes:

- **Research-time fact extraction** (Parts VII–VIII): the dispatcher
  routes corpus pages to MLX with an *extraction* prompt; outputs
  become `pending_facts` / `narrative_findings`.
- **Bio-time context retrieval** (Parts IX–XI): bio synthesis queries
  the same corpus for passages that contextualise a specific profile,
  passes them to MLX with a *synthesis* prompt, and emits citation-
  traced prose.

Both consumers use the same underlying storage, indexer, retrieval
contract, and Evidence Firewall machinery — the corpus is general-
purpose; the consumers differ only in prompt and downstream routing.

---

## Part II: Architectural decisions

### 5. Markdown files vs chunked-vector RAG

**Decision:** one markdown file per source page on disk; SQLite/FTS5
index over the page body. No embedding store, no vector index.

**Reasoning:**

- Genealogy queries are proper-noun-and-integer dominated. "All pages
  mentioning surname CAULDWELL between 1780 and 1830 in parish
  Wirksworth" is a lexical predicate, not a semantic one. SQLite +
  FTS5 answers it natively; embeddings would round-trip through cosine
  similarity to recover what an FTS5 index already encodes.
- The corpora are small. Wirksworth at 30 MB fits in memory; a 768-d
  float32 embedding for each of ~5,000 chunks would be ~15 MB just for
  the vectors before the index overhead — same order of magnitude,
  with worse retrieval.
- Vectors lose surname spelling. Embedding similarity collapses
  "Cauldwell" and "Caldwell" toward a generic cluster of English
  surnames. Lexical retrieval with explicit `SurnameVariants` lookups
  keeps spelling precision.
- A markdown-on-disk corpus is human-inspectable and `grep`-able. A
  vector store is opaque.

**Vectors are not in v1.** They may be added as a secondary signal
later — for instance, to re-rank within an already-filtered
surname/year window — but only if observed extraction quality
justifies the storage and complexity.

### 6. Page-level retrieval, not sliced chunks

**Decision:** retrieve whole pages. No chunking.

**Reasoning:**

- A Wirksworth pedigree page is a self-contained narrative whose later
  lines depend on earlier ones (generation numbers, "her son", "the
  same Thomas"). Chunking at fixed token boundaries severs these
  references and forces the model to extract facts from contextless
  fragments.
- MLX/DeepSeek-R1 7B's context window comfortably holds any single
  page in the Wirksworth corpus. Per-page byte counts cluster around
  5–20 KB of markdown.
- Top-K selection over whole pages keeps the model's input small and
  the extraction prompt's instructions unambiguous: "extract every
  fact about surname X from this single page."

If a future source produces pages too large for a single inference
call, the response is to split at section boundaries in the converter
(treating each as its own logical "page" with its own frontmatter),
not to introduce sliding-window chunking.

### 7. Local build, no central CDN

**Decision:** each user crawls the corpus locally on first sync. No
bundled binaries, no shared S3 bucket, no torrent.

**Reasoning:** mirrors the existing `.wikitree-twin.json` pattern.
Storage is the user's responsibility; the app does not redistribute
third-party content. A polite crawler that runs once and then
refreshes by content-hash diff costs the source site one full
traversal per installation. Wirksworth at 500 ms per page = ~18
minutes for a full first build.

### 8. SQLite per-source, not per-project

**Decision:** the prose corpus index lives in
`~/Library/Application Support/AncestorResearch/corpora/<source_id>/index.sqlite`,
separate from the project database.

**Reasoning:** the corpus is public data, identical for every user and
every project on the same machine. Embedding it in the project SQLite
would duplicate 30 MB per project and force re-crawl on every project
import. Keeping it under Application Support, keyed by `source_id`,
lets multiple projects share a single corpus build and lets the user
delete a corpus without touching their tree.

### 9. Bio is not a sourced fact

The current code treats `bio` as a `ProfileField` with the same source
provenance, dispute, and Correct-vs-Alternative machinery as a birth
date. **For bios, this is the wrong shape.** Two interpretations of a
date can be "competing"; two pieces of prose are not.

- `bio` keeps a single `SourceOrigin` indicating the *author*
  (manual / synthesised / imported), but **not** a multi-source set.
- "Disputed bio" is not a possible state.
- The Correct-vs-Alternative picker does not apply.
- The completeness check stops counting `bio` as a missing fact.
  Missing bio is missing *writing*, not missing data.

These are small migrations; cover them as a prep step (Phase B-1, §38).

### 10. The provenance contract

Every sentence in a proposed bio carries a **provenance set** — a list
of input IDs the sentence draws from. Inputs are of two types:

- `factID` — a `ProfileField` value, a `Relationship`, a `LifeEvent` row.
- `pageHash` — a `pages.page_hash` from a corpus index (see §13).
  The page's `source_url` and `content_hash` become the citation
  marker on the rendered bio.

A sentence with an empty provenance set is rejected and never emitted.
The provenance set is what the verification pass checks against and
what the rendered bio displays as citation markers.

---

## Part III: Corpus storage

### 11. On-disk layout

All corpus files live under the app's sandboxed Application Support
directory:

```
~/Library/Containers/dev.dreamfold.Ancestor-Research/Data/
  Library/Application Support/AncestorResearch/
    corpora/
      <source_id>/
        manifest.json                  # build metadata (see §11.1)
        index.sqlite                   # GRDB-managed index (see §13)
        pages/
          <page_hash>.md               # one markdown file per source page
        logs/
          crawl-<iso-timestamp>.log    # plain-text crawler log
```

`<source_id>` matches the `RecordSource.sourceID` (e.g. `wirksworth`,
`freereg-narratives`). `<page_hash>` is the first 16 hex chars of the
SHA-256 of the canonical source URL — short enough to be filesystem-
friendly, long enough to avoid collision across 10⁵ pages.

#### 11.1 `manifest.json`

```json
{
  "source_id": "wirksworth",
  "display_title": "Wirksworth Parish Records 1600–1900",
  "seed_url": "http://www.wirksworth.org.uk/PEDIGREE.htm",
  "added_by_user_at": "2026-05-20T14:31:55Z",
  "schema_version": 1,
  "crawler_version": "1.0.0",
  "crawl_depth": 4,
  "link_filter": null,
  "page_budget": 10000,
  "first_built_at": "2026-05-20T14:32:11Z",
  "last_synced_at": "2026-05-25T09:01:44Z",
  "page_count": 2187,
  "total_bytes": 31285194,
  "robots_txt_url": "http://www.wirksworth.org.uk/robots.txt",
  "robots_txt_fetched_at": "2026-05-20T14:32:09Z",
  "user_agent": "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"
}
```

The manifest is the single source of truth for "is this corpus built?"
The fields supplied by the user at add-time (`display_title`,
`seed_url`, `crawl_depth`, `link_filter`, `page_budget`) are immutable
for the corpus's lifetime — re-adding under a different seed creates a
new `source_id`. The app boots, reads `manifest.json` for every entry
in the corpus registry (§12), and surfaces missing or stale corpora in
the Sync UI.

### 12. Corpus registry

A single global registry at:

```
~/Library/Containers/dev.dreamfold.Ancestor-Research/Data/
  Library/Application Support/AncestorResearch/
    corpora/
      registry.json
```

```json
{
  "schema_version": 1,
  "corpora": [
    { "source_id": "wirksworth",   "display_title": "Wirksworth Parish Records 1600–1900", "added_at": "2026-05-20T14:31:55Z" },
    { "source_id": "geneuksrt-yks", "display_title": "GENUKI Yorkshire — South Riding parishes", "added_at": "2026-05-22T08:14:02Z" }
  ]
}
```

The registry is the dispatcher's source of truth for which prose
corpora exist. It is the only data structure the rest of the app
needs to consult to enumerate user-added corpora; `manifest.json`
per-corpus carries the full detail.

`source_id` is derived deterministically from the seed URL's hostname
plus a path slug: hostname-with-dots-replaced-by-hyphens, plus the
first path segment if non-empty, lowercased. Collisions on add (e.g.
two corpora from the same host with the same first path segment) get
a `-2`, `-3` suffix.

Removing a corpus deletes its `corpora/<source_id>/` directory
entirely and the registry entry. No soft-delete.

#### 12.1 Filesystem rationale

- Markdown files are written atomically (write-to-temp, rename). A
  crashed crawler never leaves a half-written page.
- The `pages/` directory is flat — no nesting by date or sub-path.
  macOS APFS handles directories of 10⁵ entries without degradation,
  and the SQLite index is the canonical access path; the filesystem
  is just blob storage.
- `logs/` is purely diagnostic. Old logs may be pruned by a future
  cleanup pass; nothing depends on their presence.

### 13. SQLite index schema

The index lives at `corpora/<source_id>/index.sqlite`, managed by
GRDB. Single migration registered as `v1_prose_corpus`.

```sql
CREATE TABLE pages (
    page_hash             TEXT PRIMARY KEY,    -- first 16 hex of sha256(source_url)
    source_url            TEXT NOT NULL UNIQUE,
    title                 TEXT,                -- extracted <title> or first H1
    fetched_at            TIMESTAMP NOT NULL,
    content_hash          TEXT NOT NULL,       -- sha256 of cleaned markdown body
    byte_length           INTEGER NOT NULL,
    last_indexed_at       TIMESTAMP NOT NULL,
    -- Applicability metadata. All nullable; null = universally applicable.
    -- Read from frontmatter at indexer time; consumed by bio-synthesis
    -- retrieval (Part X) to scope passages to the right era/occupation.
    applies_at_start      INTEGER,             -- earliest year content applies
    applies_at_end        INTEGER,             -- latest year content applies
    applies_at_occupation TEXT                 -- optional occupation tag
);

CREATE INDEX idx_pages_content_hash ON pages(content_hash);
CREATE INDEX idx_pages_applies_at ON pages(applies_at_start, applies_at_end);

CREATE TABLE page_surnames (
    page_hash       TEXT NOT NULL,
    surname_upper   TEXT NOT NULL,             -- always uppercased before insert
    mention_count   INTEGER NOT NULL,          -- raw count in the page
    PRIMARY KEY (page_hash, surname_upper),
    FOREIGN KEY (page_hash) REFERENCES pages(page_hash) ON DELETE CASCADE
);

CREATE INDEX idx_page_surnames_surname ON page_surnames(surname_upper);

CREATE TABLE page_years (
    page_hash       TEXT NOT NULL,
    year            INTEGER NOT NULL,          -- four-digit Gregorian
    mention_count   INTEGER NOT NULL,
    PRIMARY KEY (page_hash, year),
    FOREIGN KEY (page_hash) REFERENCES pages(page_hash) ON DELETE CASCADE
);

CREATE INDEX idx_page_years_year ON page_years(year);

CREATE TABLE page_places (
    page_hash       TEXT NOT NULL,
    place_lower     TEXT NOT NULL,             -- lowercased, normalised whitespace
    mention_count   INTEGER NOT NULL,
    PRIMARY KEY (page_hash, place_lower),
    FOREIGN KEY (page_hash) REFERENCES pages(page_hash) ON DELETE CASCADE
);

CREATE INDEX idx_page_places_place ON page_places(place_lower);

CREATE VIRTUAL TABLE page_fts USING fts5(
    page_hash UNINDEXED,
    body,
    tokenize = 'porter unicode61 remove_diacritics 1'
);
```

#### 13.1 FTS5 usage

`page_fts` is the full-text body. The Porter stemmer is enabled
(queries against "marriage" also hit "marriages", "married").
`remove_diacritics 1` folds accented characters so the converter
doesn't have to normalise input. The stemmer is deliberately not used
for the `page_surnames` table — surnames are stored uppercase and
queried by exact equality plus the existing `SurnameVariants` map.

Triggers keep `page_fts` in sync with `pages.body` (the body itself
is not stored in `pages` to keep the row narrow; the canonical body
lives in the markdown file on disk, and the indexer reads the file
when populating `page_fts`).

#### 13.2 Index population

The indexer (§18) is the only writer. The retrieval path (§19) does
read-only queries.

### 14. Markdown frontmatter contract

Every file under `pages/` has YAML frontmatter followed by the cleaned
markdown body. The frontmatter is parsed during indexing and during
retrieval to confirm provenance.

```markdown
---
source_id: wirksworth
source_url: http://www.wirksworth.org.uk/CAULDW1.htm
fetched_at: 2026-05-20T14:34:01Z
content_hash: a3f1b9c2d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f50617283940a1b2c3d4e
title: Cauldwell of Wirksworth — Pedigree
crawler_version: 1.0.0
applies_at_start: 1750
applies_at_end: 1900
applies_at_occupation: lead-miner
---

# Cauldwell of Wirksworth — Pedigree

(rest of cleaned markdown body)
```

#### 14.1 Required keys

| Key | Type | Notes |
|---|---|---|
| `source_id` | string | Matches `RecordSource.sourceID`. |
| `source_url` | string | Canonical URL the page was fetched from. The Evidence Firewall uses this for attribution. |
| `fetched_at` | RFC 3339 timestamp | UTC. |
| `content_hash` | hex string (64 chars) | SHA-256 of the markdown body (everything after the closing `---`, with trailing whitespace trimmed). |
| `title` | string | Extracted from `<title>` or first `<h1>`. May be empty if the source page has neither. |
| `crawler_version` | semver string | Distinguishes corpus rebuilds that change conversion rules. |

#### 14.2 Optional applicability keys

When the converter can derive a temporal or occupational scope for the
page (from URL pattern, page heading, declared "covers" line, or any
source-specific cue), it writes:

| Key | Type | Notes |
|---|---|---|
| `applies_at_start` | integer year | Earliest year the page's content applies. |
| `applies_at_end` | integer year | Latest year it applies. |
| `applies_at_occupation` | string | Optional occupation tag (e.g. `lead-miner`, `cotton-spinner`). |

Absent fields are treated as "universally applicable" by retrieval;
bio synthesis retrieval (Part X) gates on the fields when present to
avoid surfacing anachronistic context.

#### 14.3 Content-hash algorithm

```
content_hash = SHA-256(
    markdown_body
      with trailing whitespace stripped
      with line endings normalised to LF
)
```

The hash is computed over the **body only**, not the frontmatter.
This means `fetched_at` updates do not change `content_hash`, and
re-fetching an unchanged source page produces a no-op at the indexer.

#### 14.4 Optional `source_extra`

Sources may add their own keys under a `source_extra` map. The indexer
ignores unknown top-level keys but preserves them on rewrite. Example:

```yaml
source_extra:
  pedigree_code: CAULDW1
  contributor: Smith, John
```

---

## Part IV: Corpus ingestion

### 15. Crawler design

The crawler reuses the same politeness primitives as the existing
source plugins. It is not a generic web scraper — each source's
crawler is a small, named type that knows that source's discovery
model.

#### 15.1 Politeness rules (all sources)

- **User-Agent header:** identical string to existing source plugins
  — `"AncestorResearch/1.0 (macOS; genealogy research tool;
  github.com/darrylcauldwell/ancestor)"`. The maintainer's GitHub URL
  is the contact path.
- **Rate limit:** 500 ms between requests per host, enforced by the
  existing `nextRequestSlot` pattern in `FreeBMDSource.swift`. The
  crawler does not run multiple parallel requests against a single
  host.
- **`robots.txt`:** fetched at the start of every crawl, parsed for
  `Disallow` rules under the configured User-Agent (and `*` as
  fallback). Disallowed paths are skipped and logged. The fetch
  timestamp is recorded in `manifest.json`.
- **HTTP errors:** 429 trips the same circuit breaker as
  `FreeBMDSource` (60 s, 300 s, 900 s ladder, then give up for the
  process). 5xx errors retry once after 5 s; further failures mark
  the URL as failed and continue.
- **Conditional requests:** the crawler sends `If-Modified-Since`
  based on the existing row's `fetched_at` when refreshing. 304
  responses skip download entirely.

#### 15.2 Generic discovery

The crawler is source-agnostic. All discovery rules apply uniformly
to any user-added corpus.

- **Seed:** the URL the user supplied when adding the corpus. The
  first request always fetches this URL.
- **Frontier:** the converter reports outbound `<a href>` links from
  each fetched page. Links to the same registrable host (using the
  Public Suffix List for host comparison) that have not been visited
  are added to the frontier. Links to other hosts are recorded in an
  `external_links.json` log but not followed.
- **Maximum depth:** default **4 link-hops** from the seed;
  user-configurable per corpus (range 1–8) at add-time. The cap is a
  safety net against accidental sprawl; volunteer genealogy sites
  are typically 2–3 hops deep.
- **Optional link filter:** the user may supply a glob or regex
  (`/PEDIGREE-*.htm`, `^.*\.htm$`) at add-time. URLs not matching the
  filter are not enqueued. Empty filter = follow everything that
  passes the same-host and depth checks.
- **`sitemap.xml` is consulted first** when present. URLs listed in
  the sitemap are added to the frontier ahead of link-discovery
  walking; this short-circuits BFS on sites that publish a complete
  sitemap.
- **Content-type guard:** the crawler only fetches `text/html`
  (verified by `HEAD` if the URL has an ambiguous extension,
  otherwise by the `Content-Type` response header). Non-HTML
  responses are logged and skipped — no PDFs, no images, no archives
  in v1.
- **Page budget:** soft cap of 10,000 pages per corpus; configurable
  at add-time. The crawler stops with a warning if the cap is
  reached, leaves the partial corpus usable, and surfaces the partial
  state in the Settings UI.
- **Site verification at add-time:** before accepting the URL, the
  app does a `HEAD` (or small `GET`) to confirm reachability,
  fetches `robots.txt`, and parses the seed page enough to count
  outbound links and estimate corpus size. The user sees this
  estimate ("looks like ~2,200 pages on the same host") before
  confirming the add.

#### 15.3 Crawler state

A small JSON file under `corpora/<source_id>/crawl-state.json` tracks
the frontier, the visited set, and the in-progress URL. The crawler
resumes from this file after a crash. State is committed every 50
pages.

#### 15.4 Reusing existing infrastructure

The crawler uses `SourceHTTPClient.shared` (the existing `HTTPClient`
actor with rate limiting and 429 handling) verbatim. It does not
introduce a new HTTP layer.

### 16. HTML → markdown conversion contract

The converter is a pure function: HTML in, markdown out, no I/O. It
is callable from the crawler (to populate a page file) and from unit
tests (to verify conversion stability against fixtures).

#### 16.1 Preserved

- Headings (`<h1>`–`<h6>` → `#`–`######`).
- Paragraphs (`<p>` → blank-line-separated text).
- Strong / em (`<strong>`, `<b>` → `**…**`; `<em>`, `<i>` → `_…_`).
- Lists (`<ul>`, `<ol>` → `-` / `1.`).
- Tables (`<table>` → GitHub-flavoured pipe tables; collapsed to
  plain paragraphs if any cell contains a nested table).
- `<pre>` blocks (preserved verbatim inside fenced code blocks).
  Wirksworth's structured pedigrees live in `<PRE>` and must survive
  intact.
- Inline links — rendered as `[text](url)`. URLs are resolved against
  the page's base before writing.
- The first `<title>` and `<h1>` are also extracted into the
  frontmatter `title` field.

#### 16.2 Stripped

- All `<script>`, `<style>`, `<noscript>` blocks.
- Navigation chrome: `<nav>`, `<header>`, `<footer>`, and any element
  whose class or id contains any of: `nav`, `menu`, `sidebar`,
  `breadcrumb`, `header`, `footer`. The match is lowercased substring
  on the element's literal class/id attribute.
- Comments (`<!-- … -->`).
- Empty elements after stripping.
- All event-handler attributes (`onclick`, etc.).

#### 16.3 Image handling

Images are **not** downloaded. The converter rewrites every
`<img src="…">` to a markdown link of the form:

```markdown
[image: <alt-text or filename>](<absolute-image-url>)
```

The link is preserved so a future extraction step can decide whether
to fetch (e.g. for an OCR pass over a scanned register), but v1
stores no image bytes.

#### 16.4 Whitespace and encoding

- All output is UTF-8, NFC-normalised.
- HTML entities decoded (`&amp;` → `&`, `&nbsp;` → space, numeric
  entities decoded to characters).
- Runs of internal whitespace collapsed to a single space, except
  inside fenced code blocks.
- Trailing whitespace stripped per line.
- Line endings normalised to LF.

#### 16.5 Determinism

Given the same HTML input and the same crawler version, the converter
must produce byte-identical markdown output. This is a hard
requirement — content-hash comparison depends on it. A test fixture
pinned per source verifies stability.

#### 16.6 Applicability extraction

When the converter can derive a temporal or occupational scope from
the source page's structure (URL pattern, page heading, explicit
"covers 1750–1900" line, source-specific cues), it writes the
relevant `applies_at_*` fields into the frontmatter. Sources without
these cues simply omit the fields — the page becomes universally
applicable for retrieval.

### 17. Indexer

The indexer reads markdown files under `pages/` and populates the
SQLite index. It runs once after a crawl and incrementally on `sync`.

#### 17.1 What gets extracted

For each markdown file:

1. **Frontmatter parse.** YAML parsed; `source_url`, `fetched_at`,
   `content_hash`, `title`, and the optional `applies_at_*` keys are
   read.
2. **Body normalisation.** Frontmatter stripped. The remaining text
   is the FTS5 body and the corpus for the other tokenisers.
3. **Surname tokenisation.** Capitalised tokens of length ≥ 3,
   optionally followed by `'s`. Uppercased, stop-word filtered.
   Multi-word capitalised runs split on whitespace; each token
   recorded separately. Mention counts are raw integers.
4. **Year tokenisation.** Four-digit integers in the range
   1500–1999. Two-digit dates (e.g. "in 76") are not recognised in
   v1.
5. **Place tokenisation.** Lowercased tokens matching the existing
   `LocationGazetteer` entries. Indexing places at v1 is
   best-effort — the gazetteer is the canonical list, no fuzzy
   matching, no Levenshtein. Pages with no recognised place yield
   zero rows in `page_places`.
6. **Applicability columns.** `applies_at_start`, `applies_at_end`,
   `applies_at_occupation` written to `pages` from frontmatter when
   present; null otherwise.

The indexer is idempotent: deleting all rows for a `page_hash` and
re-inserting is the refresh path. No partial updates.

#### 17.2 Refresh

On `sync`, the indexer compares each markdown file's frontmatter
`content_hash` against the value in the `pages.content_hash` column.
Matches are skipped. Mismatches re-index that single page (delete +
insert across all four tables). Pages on disk that are not in the
database are inserted; rows in the database whose markdown file no
longer exists are deleted (cascade via foreign key).

#### 17.3 Reusing existing infrastructure

The indexer uses GRDB the same way the project database does. No new
persistence layer. Each prose-source's `index.sqlite` is a standalone
`DatabaseQueue`. The project database remains untouched.

---

## Part V: Discovery — where corpus URLs come from

### 18. User-added (the default)

The user types a URL into Settings → *Prose Corpora* → *Add*. The
app does site verification (§15.2), confirms reachability and
estimated size with the user, then kicks off the background crawl.
The corpus appears in `registry.json` and becomes available to
retrieval as soon as it has at least one indexed page.

### 19. Cluster-driven candidate URLs (harness-assisted)

For bio synthesis to scale across geographies without the user
knowing in advance which sources matter, two affordances sit *above*
the user-added flow. Both are optional; the corpus subsystem itself
is unchanged whether or not they're used.

#### 19.1 Family social-history fingerprint

A deterministic engine analyses the tree's vital events and surfaces
**`(place, time-window, occupation?)` clusters** where the family
has density:

- **Place concentrations** — cluster vital events (birth / marriage /
  death / census residences) by canonical place codes and time. A
  family with 40% of its 19th-century vital events in a 20km radius
  around Wirksworth produces a `(Wirksworth, 1800–1900)` cluster
  with high weight.
- **Occupation profile** — extract structured occupations from
  census `LifeEvent.details`. A cluster of "lead miner" occupations
  in Wirksworth 1830–1900 produces a `(Wirksworth, 1830–1900,
  lead-miner)` cluster.
- **Event density** — supports "this place mattered most during these
  decades" reasoning. Avoids surfacing irrelevant material.

Clusters are ranked. The top N (by weight × density) become the
targets for candidate-URL discovery. No AI is involved at this
stage; the cluster engine is pure structured-tree analysis.

#### 19.2 Harness-proposed candidate URLs

For each cluster, the user is shown candidate URLs to consider
adding as prose corpora — local-history archives, county wikis,
occupational heritage sites, WikiTree Space pages — *suggested* by
the harness (Claude Code + MCP + external SaaS, operating on public
sources, off-device).

The harness does the discovery work over citation-strict source
candidates:

- **Wikipedia** sections whose claims carry inline `<ref>` tags to
  verifiable primary sources.
- **WikiTree Space pages** — community-curated essays.
- **County / regional history wikis** (Derbyshire Heritage, Cornwall
  Heritage Environment Record, etc.).
- **Industrial heritage organisations** — National Trust pages,
  mining heritage sites, occupation-specific archives.

The user reviews provenance + content of each candidate URL and
chooses which to add. Once added, the URL flows into the normal
user-added path (§18). The harness has no write access to the
corpus directly; its role is *suggesting URLs to add*, nothing
more.

This keeps geography-independence honest: no place / industry list
is hardcoded; the harness queries public sources for whatever
fingerprints the user's tree produces. A Cornish tin-mining family
surfaces Cornish heritage candidates; a Lancashire weaving family
surfaces weaving-trade candidates; same machinery.

#### 19.3 What the harness must not do

- **Write to `profile.*` directly.** The firewall is unchanged.
  Bios are not facts; corpus is not facts; both go through human
  review before they influence what's displayed about a person.
- **Bypass corpus review.** Even a strong model proposes; the user
  decides. The firewall isn't about model quality — it's about who
  has authority to assert.
- **Hallucinate citations.** A candidate URL whose advertised
  content turns out to be missing, paywalled, or fabricated is a
  critical failure. The harness must verify reachability and
  content presence before surfacing.

---

## Part VI: Retrieval

The retrieval path is invoked by the existing `SearchDispatcher` (see
`RESEARCH_PIPELINE_SPEC.md` §8) when it routes a query to a prose
source. The prose source's `search(_:)` method translates
`RecordQuery` into an SQL filter, selects top-K pages, and returns
them as `SourceRecord` values whose `detailURL` carries the original
`source_url`.

### 20. Query construction from `ResearchSubject`

From `RecordQuery`, the retriever pulls:

- `surname` → required. Looked up as `surname_upper`. Variants come
  from the existing `SurnameVariants` map and produce an SQL `IN`
  clause.
- `yearRange` → optional. When present, used to constrain
  `page_years.year`.
- `region` → optional. Used to constrain `page_places.place_lower`
  against the gazetteer's tokens for that region. When the region
  is unsupported by the source's coverage, the retriever returns
  `.outsideCoverage`.

### 21. SQL filter shape

```sql
WITH surname_hits AS (
    SELECT page_hash, SUM(mention_count) AS surname_count
    FROM page_surnames
    WHERE surname_upper IN (?, ?, ?)        -- surname + variants
    GROUP BY page_hash
),
year_hits AS (
    SELECT page_hash, COUNT(*) AS year_count
    FROM page_years
    WHERE year BETWEEN ? AND ?
    GROUP BY page_hash
),
place_hits AS (
    SELECT page_hash, COUNT(*) AS place_count
    FROM page_places
    WHERE place_lower IN (?, ?)             -- gazetteer tokens for region
    GROUP BY page_hash
)
SELECT
    p.page_hash, p.source_url, p.title,
    COALESCE(s.surname_count, 0) AS sc,
    COALESCE(y.year_count, 0)    AS yc,
    COALESCE(pl.place_count, 0)  AS pc
FROM pages p
INNER JOIN surname_hits s ON s.page_hash = p.page_hash
LEFT JOIN year_hits y   ON y.page_hash = p.page_hash
LEFT JOIN place_hits pl ON pl.page_hash = p.page_hash
WHERE
    -- Optional applicability gate: when the subject has a known
    -- birth/death window, exclude pages whose applies_at_* window
    -- doesn't intersect it. Null applies_at_* fields are treated
    -- as universally applicable.
    (p.applies_at_start IS NULL OR p.applies_at_start <= ?)
    AND (p.applies_at_end IS NULL OR p.applies_at_end >= ?)
ORDER BY (sc * 3 + yc * 2 + pc) DESC
LIMIT ?;
```

Surname is the gate (`INNER JOIN`). Year and place are scoring axes.
The weighting (3:2:1) is a starting point; tuning is an open
question (§42).

### 22. Top-K selection

`K` defaults to **5**. Higher K wastes MLX inference time; lower K
risks missing the right page. Per-mode override:

| Mode | K |
|---|---|
| `.verify` | 3 |
| `.extend` | 3 |
| `.discover` | 5 |
| `.all` | 8 |

For bio-synthesis retrieval, K defaults to **3** per registered
corpus (the synthesis prompt benefits from focused inputs more than
breadth).

The retriever reads the selected markdown files from disk, strips
frontmatter, and passes the bodies to the MLX extractor or
synthesiser.

### 23. No FTS5 in the primary path

The `page_fts` table is for two narrow uses:

1. **Diagnostic search from the corpus inspector UI** (a future Sync
   tab) — "show me every page mentioning 'apprentice'."
2. **Tie-breaking in v1.x:** when many pages share the top
   surname-year score, an FTS5 search for given names plus context
   terms (`father`, `wife`) can re-rank. Not in v1.

Primary retrieval uses the pivot tables, not FTS5. This is
deliberate — FTS5 ranking is opaque and tuning it would re-introduce
the embedding-search problem this design rejected.

---

## Part VII: MLX extraction (research-time)

The retriever's output is K markdown files. They are passed to
`LocalInferenceService.reason(...)` with an extraction prompt. The
extractor is **not** a new MLX service — it reuses
`LocalInferenceService.shared` exactly as `StrategyAdvisor` does
(`RESEARCH_PIPELINE_SPEC.md` §14).

### 24. Prompt shape

A bundled prompt file at `Resources/Prompts/prose_extraction_system.txt`.
The system prompt is fixed; the user prompt is built per call.

User prompt structure:

```
SUBJECT
  surname: Cauldwell
  given:   Thomas
  born:    1780–1790
  region:  Wirksworth, Derbyshire

SOURCE
  url:   http://www.wirksworth.org.uk/CAULDW1.htm
  title: Cauldwell of Wirksworth — Pedigree

CONTENT
  (markdown body, capped at 24 KB; if larger, the page is split at
   section boundaries and each section is run as a separate
   inference call)

TASK
  Return JSON with two arrays:
    facts: [{ kind, value, evidence_text, reasoning }]
    narratives: [{ category, description, date_or_period, evidence_text, reasoning }]
  - `kind` is one of: birth_year, death_year, marriage_year, spouse, occupation, residence.
  - `evidence_text` must be a verbatim substring of CONTENT, ≤200 characters.
  - `reasoning` is one sentence explaining how evidence_text supports the value.
  - Return {"facts": [], "narratives": []} if nothing about the subject appears on the page.
```

The reasoning model's `<think>` blocks are stripped by
`LocalInferenceService` (lines 188–203 of
`LocalInferenceService.swift`) before JSON parsing.

### 25. Routing extracted facts to `pending_facts`

Each item in `facts` is converted to a `PendingFact` and submitted
through the Evidence Firewall. The existing column set on
`pending_facts` (after the v5 migration in `ProjectDatabase.swift`
lines 302–311) already carries everything needed:

- `source_url` ← the page's `source_url` from frontmatter.
- `source_title` ← the page's `title`.
- `evidence_text` ← the verbatim substring (capped at 200 chars in
  the schema).
- `reasoning` ← the model's one-sentence justification.
- `agent_id` ← `"prose-extractor:<source_id>"` (e.g.
  `prose-extractor:wirksworth`).
- `source_trust_tier` ← copied from the source plugin's `trustTier`.
- `source_directness` ← copied from the source plugin's
  `evidenceDirectness`.

The Evidence Firewall's existing hallucination checks (URL
verification, evidence-text-must-be-substring) run unchanged. The
prose extractor is just another agent submitting facts.

### 26. Routing extracted narratives to `narrative_findings`

Each item in `narratives` is converted to a `NarrativeFinding` (shape
from `EvidenceFirewall.swift` lines 198–211) and inserted into the
`narrative_findings` table (schema in `ProjectDatabase.swift` lines
262–275). Field mapping:

- `profile_id` ← the `ResearchSubject.profileID`.
- `category` ← extractor output (apprenticeship, will, residence,
  etc.).
- `description` ← extractor output, capped at 500 chars.
- `date_or_period` ← extractor output.
- `source_url`, `source_title` ← from frontmatter.
- `evidence_text` ← capped at 200 chars.
- `reasoning` ← model output.
- `agent_id` ← `"prose-extractor:<source_id>"`.

Both pending facts and narrative findings flow through the existing
review UI — the prose corpus does not introduce a new review surface.

### 27. Reusing existing infrastructure

- `LocalInferenceService.shared` is the only MLX call site.
- Prompts live in `Resources/Prompts/` alongside `strategy_system.txt`.
- The Evidence Firewall is unchanged. URLs are verified by the
  existing pipeline (cached page snapshot in `page_cache`,
  content-hash compare against `content_hash` from frontmatter —
  same algorithm as the existing source-page provenance check).

---

## Part VIII: Mode gating (research-time)

MLX extraction is expensive. The dispatcher gates it by `ResearchMode`.

| Mode | Index lookup | MLX extraction |
|---|---|---|
| `.verify` | yes (informational only) | **no** |
| `.extend` | yes (informational only) | **no** |
| `.discover` | yes | **yes** |
| `.all` | yes | **yes** |

In `.verify` and `.extend` modes, the prose source returns the top-K
pages' titles and URLs as `SourceRecord` values of a new `recordType`
`.proseCandidate` — surfaced in the research activity log so the user
knows there is biographical context to read, but not handed to MLX.
In `.discover` and `.all`, the same top-K pages are also passed
through the extraction prompt and the resulting `pending_facts` /
`narrative_findings` flow through the Evidence Firewall.

The gate is enforced in the prose-source's `search(_:)`
implementation, not in the dispatcher. This keeps the dispatcher
uniform across structured and prose sources.

---

## Part IX: Bio synthesis pipeline

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
   │  Query each registered prose corpus (Part VI) for         │
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
not semantic. Reasonable starter templates (subject to refinement):

- Opening: "{firstName} {lastName} was born {birthDateText} in
  {birthLocation}." (Skip elements that are unknown.)
- Parents: "{firstName}'s parents were {father.displayName} and
  {mother.displayName}." (Skip if no parents in tree.)
- Marriage: "{firstName} married {spouse.displayName}
  {marriageDateText} in {marriageLocation}." (One sentence per
  spouse.)
- Children: "{firstName} and {spouse.displayName} had {N} children:
  ..." (Skip if N=0.)
- Death: "{firstName} died {deathDateText} in {deathLocation}."
  (Skip unknowns.)
- Occupations (from life events): "By {year}, {firstName} was a
  {occupation} in {place}." One sentence per distinct occupation.

### 29. Stage B — context retrieval

Bio-side retrieval queries every registered prose corpus
(`ProseCorpusRegistry`) in turn. Per corpus, the same SQL as §21
runs with the subject's surname, year window, and place. The
`applies_at_*` gate (§21) narrows to pages whose temporal scope
intersects the subject's `birthYear...deathYear` (or `birthYear ± 50`
when death year is unknown).

Returned page bodies, alongside their `source_url` and
`content_hash`, become the **`pageHash` provenance set** for Stage C.

### 30. Stage C — MLX synthesis

The MLX prompt is heavily constrained. A bundled prompt file at
`Resources/Prompts/bio_synthesis_system.txt`. The user prompt is
built per call:

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
acceptable so the model doesn't reflexively pad.

### 31. Stage D — verification

The verification step is what makes "no hallucination" enforceable
rather than aspirational. Implementation candidates, in increasing
order of robustness:

1. **Provenance presence check** (trivial). Reject any sentence with
   an empty provenance set. Catches the laziest failure mode.
2. **NER + entity cross-check.** Run NER over each emitted sentence;
   verify every named entity (person, place, date, occupation)
   appears in either the structured tree or the provenance-listed
   corpus passages. Catches "his wife Mary" when the relationship
   is Margaret.
3. **Sentence-level entailment.** A second LM pass (could be a
   smaller model) checks: "Given these inputs, does this sentence
   follow?" Per sentence: keep / drop.
4. **Adversarial paraphrase check.** For each sentence, ask the LM
   to restate the source inputs in its own words; compare to the
   emitted sentence; if the emitted sentence contains content not
   present in the restatement, drop. Catches confident additions
   disguised as paraphrasing.

Phase 1 is mandatory. Phase 2 should land in v1. Phases 3 / 4 are
quality improvements as the local model and verification tooling
mature.

#### 31.1 Fact-check against the tree

In addition to entailment, the verification pass cross-checks
**structured-fact contradictions**:

- Names mentioned in the bio must match `Profile.displayName` for
  any referenced person.
- Dates must match the structured fields they reference.
- Places must match canonical place IDs from the gazetteer where
  the prose names a place.
- Relationships named in the bio must exist as `Relationship` rows
  in the tree.

A sentence that says "his daughter Mary" when no Mary appears in
the tree, or "in Brighton" when the structured residence was
Birmingham, is a regression and gets dropped. The deterministic-
sandwich principle applies: the structured tree is the source of
truth; the LM cannot contradict it.

---

## Part X: Bio rendering

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
makes provenance immediately auditable — the user can see where every
claim comes from. An unsourced claim would be *visibly* unsourced
(which is why empty-provenance sentences are rejected at verification
— they must never reach rendering).

### 33. Inspector-card disclosure

For long bios, the inspector card collapses the bio into a
"Biography ▸" disclosure that expands to the full prose. Card width
remains stable; long bios don't dominate the inspector.

---

## Part XI: Bio regeneration

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
- New corpus pages whose `applies_at_*` window intersects the
  profile's date span.

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
   new bio* and shows the user a diff against the current. User
   accepts / rejects per change.

(2) is more powerful but heavier UX. (1) is simpler and matches the
"AI proposes; user decides" model. Start with (1).

---

## Part XII: Acceptance criteria

The following assertions are testable against a built corpus and a
fixture project. A future agent or test suite should be able to
verify each mechanically.

### 36. Build pipeline (corpus)

- **AC-B1** After a fresh `sync` of any registered corpus, the
  directory `corpora/<source_id>/pages/` contains at least one `.md`
  file (or the crawler reports a partial/empty outcome with an
  explicit reason in the manifest).
- **AC-B2** Every `.md` file under `pages/` has valid YAML
  frontmatter containing `source_id`, `source_url`, `fetched_at`,
  `content_hash`, `title`, and `crawler_version`. Optional
  applicability fields, when present, parse as integers / strings.
- **AC-B3** For every file,
  `frontmatter.content_hash == sha256(body_normalised)`. A test runs
  this check across the entire corpus.
- **AC-B4** Re-running `sync` against an unchanged source produces
  zero filesystem writes (verified by file mtime).
- **AC-B5** Re-running `sync` against a source where exactly one
  page has changed (verified by altered HTTP response) rewrites
  exactly one `.md` file and reindexes exactly one `page_hash` row.
- **AC-B6** A page that returns HTTP 404 on refresh is deleted from
  disk and its row cascades out of `pages`, `page_surnames`,
  `page_years`, `page_places`, and `page_fts`.

### 37. Crawler politeness

- **AC-C1** Time between consecutive HTTP requests to the same host
  during a crawl is ≥ 500 ms in 99% of cases (measured from the
  crawler log).
- **AC-C2** A `robots.txt` `Disallow: /PRIVATE/` entry causes the
  crawler to skip every URL beginning with `/PRIVATE/` and log the
  skip.
- **AC-C3** Three consecutive HTTP 429 responses trip the circuit
  breaker; the fourth request is parked for ≥ 60 s.
- **AC-C4** The User-Agent header on every crawler request matches
  the existing `WirksworthSource.userAgent` string.

### 38. Index

- **AC-I1** For any surname present on more than one indexed page,
  `SELECT COUNT(*) FROM page_surnames WHERE surname_upper = ?`
  returns the expected count when verified against a hand-counted
  fixture corpus of five pages.
- **AC-I2** Every `page_hash` in `page_surnames`, `page_years`,
  `page_places` has a matching row in `pages`.
- **AC-I3** `page_fts` contains exactly one row per row in `pages`
  (verified by `COUNT(*)` parity).
- **AC-I4** `applies_at_*` columns on `pages` are correctly null
  when frontmatter omits them, and correctly integer/string when
  frontmatter supplies them.

### 39. Retrieval

- **AC-R1** A `RecordQuery` with `surname: "Cauldwell"`,
  `yearRange: 1780...1830`, `region: .parish("Wirksworth", county:
  "Derbyshire")` returns ≤ K pages, all of which contain
  "CAULDWELL" in `page_surnames`.
- **AC-R2** A `RecordQuery` for a surname not present in any
  `page_surnames` row returns `.results([])` (not an error).
- **AC-R3** Top-K selection is deterministic — given the same query
  against the same corpus, the same K pages come back in the same
  order.
- **AC-R4** A page with `applies_at_start=1900, applies_at_end=2000`
  is excluded from retrieval for a subject with `birthYear=1820`,
  even when surname and place match.

### 40. MLX extraction (research-time)

- **AC-M1** In `.verify` mode, the prose source's `search` never
  calls `LocalInferenceService.reason(...)`. Verified by injecting
  a mock service that fails the test if invoked.
- **AC-M2** In `.discover` mode, each of the K retrieved pages
  results in exactly one `LocalInferenceService.reason(...)` call.
- **AC-M3** Every fact submitted to `pending_facts` has `source_url`
  equal to a `source_url` in `pages` and `evidence_text` that is a
  verbatim substring of the corresponding markdown body.
- **AC-M4** Every narrative finding submitted has `agent_id`
  matching `prose-extractor:<source_id>`.
- **AC-M5** A page that contains no information about the subject
  produces zero pending facts and zero narrative findings — even
  if the MLX call returns a non-empty JSON. The Evidence Firewall's
  existing substring check rejects fabrications.

### 41. Bio synthesis

- **AC-S1** A bio whose Stage C output contains a sentence with an
  empty provenance set is rejected at Stage D and never reaches
  rendering.
- **AC-S2** A bio whose Stage C output contains a sentence
  asserting "his wife Mary" when the tree records his wife as
  Margaret is dropped at Stage D's NER cross-check.
- **AC-S3** A profile with no accepted corpus pages produces only
  the Stage A base-layer prose. The bio is never empty for a
  profile with any structured facts.
- **AC-S4** Every rendered bio sentence carries at least one
  citation marker. Unsourced sentences are structurally impossible
  to render.
- **AC-S5** Regenerating a bio after a user edit preserves the
  user-edited segments and only touches `auto` segments.

### 42. Evidence Firewall integration

- **AC-E1** A pending fact whose `evidence_text` is not a substring
  of the cached page is rejected
  (`verification_status = contentMismatch`) — using the same logic
  the existing firewall already applies.
- **AC-E2** A pending fact whose `source_url` does not resolve to a
  page in the corpus marks `verification_status = failed`.
- **AC-E3** The user reviewing pending facts in
  `PendingFactsReviewView` sees prose-extracted facts in the same
  UI as MCP-submitted facts. No new view.

---

## Part XIII: Phased build

### Phase A — Corpus subsystem

| Phase | Slice | Depends on |
|---|---|---|
| **A1** | **Converter + storage primitives.** `HTMLToMarkdownConverter` (pure function), `ProseCorpusStorage` (frontmatter write, content-hash, atomic file replace). Five pinned HTML fixtures covering the conversion contract (§16). Unit-testable in isolation. No network, no SQLite, no UI. | none |
| **A2** | **Generic crawler.** `ProseCorpusCrawler` actor: same-host BFS from a seed URL, depth cap, `robots.txt`, `sitemap.xml`, content-type guard, page budget. Uses `SourceHTTPClient.shared`. Crawl a developer-supplied URL into `corpora/<source_id>/` on disk; verify against the canonical Wirksworth example URL. | A1 |
| **A3** | **Corpus registry + add-corpus flow.** `ProseCorpusRegistry` (Application Support `registry.json`). Settings UI gains a *Prose Corpora* section with *Add* / *Sync* / *Remove* actions. *Add* runs site verification and confirms with the user before kicking off the background crawl. Progress surfaced as the crawl runs. | A2 |
| **A4** | **Indexer.** Per-corpus SQLite index. Schema v1 migration. Indexer populates `pages`, `page_surnames`, `page_years`, `page_places`, `page_fts`, plus the `applies_at_*` columns. Re-run-idempotent via content-hash comparison. | A3 |
| **A5** | **Retrieval-only integration.** `ProseCorpusSource` (single source plugin that dispatches across all registered corpora). `search(_:)` returns top-K page URLs as `SourceRecord` of `.proseCandidate` type. Surfaced in research activity log. No MLX. | A4 |
| **A6** | **MLX extraction.** `.discover` and `.all` modes route the retrieved pages through `LocalInferenceService` with `prose_extraction_system.txt`. Outputs flow to `pending_facts` and `narrative_findings` with `agent_id = "prose-extractor:<source_id>"`. | A5 |
| **A7** | **UI surfacing.** *Prose Corpora* section in Settings shows per-corpus status (page count, last synced, partial-crawl warnings). Pending-facts review gains a filter chip for `agent_id = prose-extractor:*`. | A6 |
| **A8** | **Second user-added corpus.** Validate the generic crawler against a second site of the user's choosing (different host, different structure). No new code — just an empirical confirmation that the design generalises. | A7 |

### Phase B — Bio synthesis

| Phase | Slice | Depends on |
|---|---|---|
| **B1** | **Decouple bio from the field-source pipeline.** Remove bio from completeness's missing-facts list. Hide it from the dispute UI. Retire Correct-vs-Alternative for bio. Independently valuable; prep step. | none (does not depend on corpus) |
| **B2** | **Stage A (templates).** Deterministic base-layer generation from structured facts. Pure paraphrasing. No AI. Wire to a "Generate base bio" button in the inspector card's edit mode. | B1 |
| **B3** | **Stage B (corpus retrieval).** Bio-side retrieval over `ProseCorpusRegistry`. Honours `applies_at_*` gate. | A5, B2 |
| **B4** | **Stage C (MLX synthesis).** Prompt scaffolding + few-shot examples. Initially likely DeepSeek-R1 7B; the deferred Qwen 2.5 swap from `project_reasoning_model_default.md` may land cleaner here. | B3 |
| **B5** | **Stage D (verification).** Provenance presence check first, then NER cross-check, then entailment. Sentences that fail are dropped, never softened. | B4 |
| **B6** | **Rendering with citations.** Inline markers, expandable provenance block, inspector-card disclosure for long bios. | B5 |
| **B7** | **Regeneration.** Staleness detection + segmented user-edit preservation. | B6 |

### Phase C — Cluster-driven URL discovery (optional, harness-side)

| Phase | Slice | Depends on |
|---|---|---|
| **C1** | **Cluster engine.** Pure structured-tree analysis, no AI. Outputs the (place × time × occupation) fingerprint deterministically. Testable in isolation. | none |
| **C2** | **Harness integration.** Claude Code commands / scripts that invoke the MCP server, surface clusters, propose candidate URLs via SaaS over public sources. This is dev-tooling, not shipping app functionality. | C1 |
| **C3** | **In-app review surface for candidate URLs.** Settings UI shows harness-proposed URLs per cluster, with provenance trail. User accepts / rejects; accepted URLs flow into the normal A3 add-corpus path. | A3, C2 |

Each phase ships independently. A3 is the first user-visible release —
the user can add a URL and see a corpus build, even before retrieval
is wired. A5 is the first useful release for research workflows. B6
is the first user-visible bio rendering. C3 only matters once enough
bios have been written to justify the harness-assisted discovery
layer.

---

## Part XIV: Hard constraints (recap)

- **Zero hallucination** in bios. Empty-provenance sentences cannot
  exist.
- **Silence > invention.** Sparser bios are correct; padded bios are
  not.
- **AI styles; sources decide.** The LM rephrases and stitches over
  verified inputs. It does not contribute knowledge.
- **Bio is narrative, not a fact.** Retire the field-source / dispute
  / Correct-vs-Alternative pipeline for it.
- **Honour the Evidence Firewall.** All extracted facts and proposed
  bios are *proposals*; the user accepts before they reach the tree.
- **No outbound network calls from the shipping app.** All MLX
  inference runs on-device. Harness-assisted candidate URL discovery
  (Part V §19) happens in Claude Code via SaaS, off-device.
- **Geography-independent end-to-end.** No code path mentions
  Derbyshire, Wirksworth, Cromford, cotton, lead, or any specific
  place/industry. Region knowledge is derived from the tree and the
  user's accepted corpora.
- **Citation-strict corpus.** Every accepted page carries verifiable
  provenance back to its source.
- **Default-deny.** Anything the corpus / synthesis doesn't
  explicitly support is forbidden, not silently best-effort.

---

## Part XV: Open questions

These cannot be settled without empirical data from a built corpus.

### 43. Pivot-score weighting

§21 uses `surname_count * 3 + year_count * 2 + place_count`. Whether
this ranks the correct page first across realistic queries is
unknown until a built Wirksworth corpus is queried with a hand-
labelled validation set ("for surname X in year range Y, the correct
page is Z"). Tuning may also reveal that mention-count is the wrong
signal and presence-only is better.

### 44. Page-size split threshold

§24 caps the user prompt's CONTENT block at 24 KB, splitting at
section boundaries above that. The 24 KB number is a guess based on
DeepSeek-R1 7B's effective context plus the extraction prompt
overhead. The real threshold needs measurement against actual
Wirksworth pages and observed MLX OOM behaviour on representative
hardware (M1 8 GB, M2 16 GB, M3 32 GB).

### 45. Stop-word list scope

§17.1 mentions an "existing genealogy English-word list" but in
practice no such list exists in the codebase yet — what counts as a
"surname-shaped token" needs an empirically grounded stop-word list
built from the corpus itself (e.g. tokens appearing in >40% of pages
are almost certainly common nouns, not surnames). Whether this is
per-source or universal is unknown.

### 46. Applicability window calibration

§14.2 introduces optional time/occupation scope per page. How
generous to be with the window — strict intersection vs. tolerant
overlap — needs empirical tuning against real bios to balance
"missing relevant context" against "surfacing anachronistic
context".

### 47. Verification depth

§31 lists four candidate verification techniques in increasing
robustness. How far up that ladder to climb before user-facing bio
quality is acceptable is an empirical question. The cost of stronger
verification is more MLX inference per bio; the benefit is fewer
false-positive sentences making it to rendering.

---

## Part XVI: Out of scope

- **Vector embeddings.** §5 rejects them. Revisit only if §43 tuning
  fails to produce acceptable top-K precision.
- **Cross-source corpus linking.** A future "this page in Wirksworth
  references the same will as that page in FreeREG" feature is not
  in v1. Each corpus is an independent island.
- **Bundled prebuilt corpora.** §7 — each user builds locally. No
  central CDN, no signed corpus archive, no torrent.
- **OCR over linked images.** §16.3 stores the image URL but never
  fetches the bytes.
- **Writing back to source sites.** The crawler is read-only against
  every source.
- **Generalised free-form web search.** This subsystem indexes named
  source corpora, not the open web. There is no DuckDuckGo
  integration.
- **In-app corpus editing.** The markdown files are produced by the
  converter and should not be hand-edited; any edit invalidates
  `content_hash`.
- **Auto-regenerating bios in the background.** Regeneration is
  user-initiated.
- **Multi-language bio output.** English only for the foreseeable.
- **Translating corpus passages between source language and bio
  language.**
- **Style preset support** ("write this like a Victorian obituary")
  — the prompt is what it is; if the user wants tonal variation
  they edit the prose by hand.
- **Bio-driven research suggestions** ("this part of the bio is
  sparse, research X next") — adjacent feature, separate spec.
- **Auto-promotion of corpus material into the tree.** The Evidence
  Firewall is unchanged: corpus pages can produce `pending_facts`
  via MLX extraction, but the user reviews before tree commit.

---

## Part XVII: Cross-references

- `feedback_firewall_sqlite.md` (memory) — corpus writes go through
  the MCP server, not direct SQLite. Same firewall applies to bio
  synthesis output.
- `feedback_no_hardcoded_regions.md` (memory) — this spec's
  cluster-driven discovery (§19) and the corpus mechanics
  generally must derive region context from tree data, not from
  baked-in lists.
- `Ancestor Research/CLAUDE.md` — Evidence Firewall section.
- `RESEARCH_PIPELINE_SPEC.md` — established the deterministic-
  sandwich pattern this spec extends to prose-extracted facts and
  to bio synthesis output.
- `RESEARCH_PIPELINE_SPEC.md` §14 (MCP-driven auto-approval) —
  orthogonal; auto-approval covers commit-side friction for facts
  the rules judge unambiguous. Bio synthesis output never goes
  through auto-approval (bios are narrative, not facts, per §9).
- The unified profile inspector card (delivered in commit db8b30f;
  the spec that drove it has been retired into git history) is where
  bios render (Part X) and where bio editing happens.
- `project_reasoning_model_default.md` (memory) — deferred Qwen 2.5
  swap; this spec's MLX components benefit from that decision.
