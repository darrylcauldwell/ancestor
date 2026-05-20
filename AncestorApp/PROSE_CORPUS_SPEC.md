# Prose Corpus — Specification

**Status:** Draft
**Scope:** Local prose-corpus subsystem for **user-added** unstructured genealogy sources. The product ships no hardcoded source URLs; users add their own corpora (parish-record sites, local-history archives, county-record-office finding aids) and the ingestion flow is triggered by the act of adding.
**Supersedes:** None
**References:** `RESEARCH_PIPELINE_SPEC.md` (governing pipeline), `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md` (source plugin shape)
**Date:** 2026-05-20

This is the governing spec for the prose-corpus subsystem. Where it interacts with the research pipeline (`pending_facts`, `narrative_findings`, the Evidence Firewall, `LocalInferenceService`), `RESEARCH_PIPELINE_SPEC.md` takes precedence.

---

## 1. Purpose and scope

Existing source plugins (FreeBMD, FreeCen, FreeREG, CWGC, FindAGrave, Probate, Wirksworth, FamilySearch) treat their target sites as structured-record APIs. They work because there is one record per HTTP response and the parser can pull surname, year, district, etc., out of known DOM positions.

Several genuinely useful genealogical sources are not record-shaped. They are long narrative HTML pages — pedigrees that span dozens of generations, parish-chest transcripts that mix marriages with poor-law disbursements, burial narratives that bury a single fact in three paragraphs of context. The current `WirksworthSource.swift` reaches for `NSRegularExpression` against `<PRE>` blocks and best-effort "Name born YEAR" patterns. It works for a handful of clean pedigrees and silently drops everything else.

This spec adds a second retrieval mode that sits alongside structured sources: **prose corpus**. The user adds a corpus by URL; the app crawls that URL, pulls each page locally as cleaned markdown, indexes by SQLite/FTS5 with lexical pivots (surnames mentioned, years mentioned), and at research time the dispatcher selects the top-K matching pages, hands them whole to the existing `LocalInferenceService` (MLX), and routes extracted facts through the Evidence Firewall to `pending_facts` and `narrative_findings`.

**No baked-in source URLs.** The product is the engine — crawler, converter, indexer, retriever, extractor. The source list is per-user, lives in a registry under Application Support, and is managed entirely through the Settings UI. Adding a URL triggers ingestion; removing a URL deletes the local corpus.

**Why user-managed.** Bundling parish-record and local-history URLs into the product is impractical at scale (there are hundreds of relevant volunteer sites) and brittle (URLs and content change). A user managing their own three or four corpora — the ones intersecting their tree — is the natural fit.

**Wirksworth Parish Records** (`http://www.wirksworth.org.uk/`) is the canonical example URL used throughout this spec to illustrate the design; it is not a baked-in source.

**Unifying principle:** lexical retrieval drives selection; the MLX model does extraction only. Deterministic decisions about facts remain with the scorer and the Evidence Firewall — extraction outputs are `pending_facts`, never tree commits.

---

## 2. Architectural decisions

### 2.1 Markdown files vs chunked-vector RAG

**Decision:** one markdown file per source page on disk; SQLite/FTS5 index over the page body. No embedding store, no vector index.

**Reasoning:**

- Genealogy queries are proper-noun-and-integer dominated. "All pages mentioning surname CAULDWELL between 1780 and 1830 in parish Wirksworth" is a lexical predicate, not a semantic one. SQLite + FTS5 answers it natively; embeddings would round-trip through cosine similarity to recover what an FTS5 index already encodes.
- The corpora are small. Wirksworth at 30 MB fits in memory; a 768-d float32 embedding for each of ~5,000 chunks would be ~15 MB just for the vectors before the index overhead — same order of magnitude, with worse retrieval.
- Vectors lose surname spelling. Embedding similarity collapses "Cauldwell" and "Caldwell" toward a generic cluster of English surnames. Lexical retrieval with explicit `SurnameVariants` lookups keeps spelling precision.
- A markdown-on-disk corpus is human-inspectable and `grep`-able. A vector store is opaque.

**Vectors are not in v1.** They may be added as a secondary signal later — for instance, to re-rank within an already-filtered surname/year window — but only if observed extraction quality justifies the storage and complexity.

### 2.2 Page-level retrieval vs sliced chunks

**Decision:** retrieve whole pages. No chunking.

**Reasoning:**

- A Wirksworth pedigree page is a self-contained narrative whose later lines depend on earlier ones (generation numbers, "her son", "the same Thomas"). Chunking at fixed token boundaries severs these references and forces the model to extract facts from contextless fragments.
- MLX/DeepSeek-R1 7B's context window comfortably holds any single page in the Wirksworth corpus. Per-page byte counts cluster around 5–20 KB of markdown.
- Top-K selection over whole pages keeps the model's input small and the extraction prompt's instructions unambiguous: "extract every fact about surname X from this single page."

If a future source produces pages too large for a single inference call, the response is to split at section boundaries in the converter (treating each as its own logical "page" with its own frontmatter), not to introduce sliding-window chunking.

### 2.3 Local build, no central CDN

**Decision:** each user crawls the corpus locally on first sync. No bundled binaries, no shared S3 bucket, no torrent.

**Reasoning:** mirrors the existing `.wikitree-twin.json` pattern. Storage is the user's responsibility; the app does not redistribute third-party content. A polite crawler that runs once and then refreshes by content-hash diff costs the source site one full traversal per installation. Wirksworth at 500 ms per page = ~18 minutes for a full first build.

### 2.4 SQLite per-source, not per-project

**Decision:** the prose corpus index lives in `~/Library/Application Support/AncestorResearch/corpora/<source_id>/index.sqlite`, separate from the project database.

**Reasoning:** the corpus is public data, identical for every user and every project on the same machine. Embedding it in the project SQLite would duplicate 30 MB per project and force re-crawl on every project import. Keeping it under Application Support, keyed by `source_id`, lets multiple projects share a single corpus build and lets the user delete a corpus without touching their tree.

---

## 3. On-disk layout

All corpus files live under the app's sandboxed Application Support directory:

```
~/Library/Containers/dev.dreamfold.Ancestor-Research/Data/
  Library/Application Support/AncestorResearch/
    corpora/
      <source_id>/
        manifest.json                  # build metadata (see §3.1)
        index.sqlite                   # GRDB-managed index (see §4)
        pages/
          <page_hash>.md               # one markdown file per source page
        logs/
          crawl-<iso-timestamp>.log    # plain-text crawler log
```

`<source_id>` matches the `RecordSource.sourceID` (e.g. `wirksworth`, `freereg-narratives`). `<page_hash>` is the first 16 hex chars of the SHA-256 of the canonical source URL — short enough to be filesystem-friendly, long enough to avoid collision across 10⁵ pages.

### 3.1 `manifest.json`

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

The manifest is the single source of truth for "is this corpus built?" The fields supplied by the user at add-time (`display_title`, `seed_url`, `crawl_depth`, `link_filter`, `page_budget`) are immutable for the corpus's lifetime — re-adding under a different seed creates a new `source_id`. The app boots, reads `manifest.json` for every entry in the corpus registry (§3.3), and surfaces missing or stale corpora in the Sync UI.

### 3.3 Corpus registry

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

The registry is the dispatcher's source of truth for which prose corpora exist. It is the only data structure the rest of the app needs to consult to enumerate user-added corpora; `manifest.json` per-corpus carries the full detail.

`source_id` is derived deterministically from the seed URL's hostname plus a path slug: hostname-with-dots-replaced-by-hyphens, plus the first path segment if non-empty, lowercased. Collisions on add (e.g. two corpora from the same host with the same first path segment) get a `-2`, `-3` suffix.

Removing a corpus deletes its `corpora/<source_id>/` directory entirely and the registry entry. No soft-delete.

### 3.4 Filesystem rationale

- Markdown files are written atomically (write-to-temp, rename). A crashed crawler never leaves a half-written page.
- The `pages/` directory is flat — no nesting by date or sub-path. macOS APFS handles directories of 10⁵ entries without degradation, and the SQLite index is the canonical access path; the filesystem is just blob storage.
- `logs/` is purely diagnostic. Old logs may be pruned by a future cleanup pass; nothing depends on their presence.

---

## 4. SQLite index schema

The index lives at `corpora/<source_id>/index.sqlite`, managed by GRDB. Single migration registered as `v1_prose_corpus`.

```sql
CREATE TABLE pages (
    page_hash       TEXT PRIMARY KEY,    -- first 16 hex of sha256(source_url)
    source_url      TEXT NOT NULL UNIQUE,
    title           TEXT,                -- extracted <title> or first H1
    fetched_at      TIMESTAMP NOT NULL,
    content_hash    TEXT NOT NULL,       -- sha256 of cleaned markdown body
    byte_length     INTEGER NOT NULL,
    last_indexed_at TIMESTAMP NOT NULL
);

CREATE INDEX idx_pages_content_hash ON pages(content_hash);

CREATE TABLE page_surnames (
    page_hash       TEXT NOT NULL,
    surname_upper   TEXT NOT NULL,       -- always uppercased before insert
    mention_count   INTEGER NOT NULL,    -- raw count in the page
    PRIMARY KEY (page_hash, surname_upper),
    FOREIGN KEY (page_hash) REFERENCES pages(page_hash) ON DELETE CASCADE
);

CREATE INDEX idx_page_surnames_surname ON page_surnames(surname_upper);

CREATE TABLE page_years (
    page_hash       TEXT NOT NULL,
    year            INTEGER NOT NULL,    -- four-digit Gregorian
    mention_count   INTEGER NOT NULL,
    PRIMARY KEY (page_hash, year),
    FOREIGN KEY (page_hash) REFERENCES pages(page_hash) ON DELETE CASCADE
);

CREATE INDEX idx_page_years_year ON page_years(year);

CREATE TABLE page_places (
    page_hash       TEXT NOT NULL,
    place_lower     TEXT NOT NULL,       -- lowercased, normalised whitespace
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

### 4.1 FTS5 usage

`page_fts` is the full-text body. The Porter stemmer is enabled (queries against "marriage" also hit "marriages", "married"). `remove_diacritics 1` folds accented characters so the converter doesn't have to normalise input. The stemmer is deliberately not used for the `page_surnames` table — surnames are stored uppercase and queried by exact equality plus the existing `SurnameVariants` map.

Triggers keep `page_fts` in sync with `pages.body` (the body itself is not stored in `pages` to keep the row narrow; the canonical body lives in the markdown file on disk, and the indexer reads the file when populating `page_fts`).

### 4.2 Index population

The indexer (§8) is the only writer. The retrieval path (§9) does read-only queries. There is no migration past v1 in this spec; future schema changes register additional migrations alongside existing GRDB conventions.

---

## 5. Markdown frontmatter contract

Every file under `pages/` has YAML frontmatter followed by the cleaned markdown body. The frontmatter is parsed during indexing and during retrieval to confirm provenance.

```markdown
---
source_id: wirksworth
source_url: http://www.wirksworth.org.uk/CAULDW1.htm
fetched_at: 2026-05-20T14:34:01Z
content_hash: a3f1b9c2d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f50617283940a1b2c3d4e
title: Cauldwell of Wirksworth — Pedigree
crawler_version: 1.0.0
---

# Cauldwell of Wirksworth — Pedigree

(rest of cleaned markdown body)
```

### 5.1 Required keys

| Key | Type | Notes |
|---|---|---|
| `source_id` | string | Matches `RecordSource.sourceID`. |
| `source_url` | string | Canonical URL the page was fetched from. The Evidence Firewall uses this for attribution. |
| `fetched_at` | RFC 3339 timestamp | UTC. |
| `content_hash` | hex string (64 chars) | SHA-256 of the markdown body (everything after the closing `---`, with trailing whitespace trimmed). |
| `title` | string | Extracted from `<title>` or first `<h1>`. May be empty if the source page has neither. |
| `crawler_version` | semver string | Distinguishes corpus rebuilds that change conversion rules. |

### 5.2 Content-hash algorithm

```
content_hash = SHA-256(
    markdown_body
      with trailing whitespace stripped
      with line endings normalised to LF
)
```

The hash is computed over the **body only**, not the frontmatter. This means `fetched_at` updates do not change `content_hash`, and re-fetching an unchanged source page produces a no-op at the indexer.

### 5.3 Optional keys

Sources may add their own keys under a `source_extra` map. The indexer ignores unknown top-level keys but preserves them on rewrite. Example:

```yaml
source_extra:
  pedigree_code: CAULDW1
  contributor: Smith, John
```

---

## 6. Crawler design

The crawler reuses the same politeness primitives as the existing source plugins. It is not a generic web scraper — each source's crawler is a small, named type that knows that source's discovery model.

### 6.1 Politeness rules (all sources)

- **User-Agent header:** identical string to existing source plugins — `"AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"`. The maintainer's GitHub URL is the contact path.
- **Rate limit:** 500 ms between requests per host, enforced by the existing `nextRequestSlot` pattern in `FreeBMDSource.swift`. The crawler does not run multiple parallel requests against a single host.
- **`robots.txt`:** fetched at the start of every crawl, parsed for `Disallow` rules under the configured User-Agent (and `*` as fallback). Disallowed paths are skipped and logged. The fetch timestamp is recorded in `manifest.json`.
- **HTTP errors:** 429 trips the same circuit breaker as `FreeBMDSource` (60 s, 300 s, 900 s ladder, then give up for the process). 5xx errors retry once after 5 s; further failures mark the URL as failed and continue.
- **Conditional requests:** the crawler sends `If-Modified-Since` based on the existing row's `fetched_at` when refreshing. 304 responses skip download entirely.

### 6.2 Generic discovery

The crawler is source-agnostic. All discovery rules apply uniformly to any user-added corpus.

- **Seed:** the URL the user supplied when adding the corpus. The first request always fetches this URL.
- **Frontier:** the converter reports outbound `<a href>` links from each fetched page. Links to the same registrable host (using the Public Suffix List for host comparison) that have not been visited are added to the frontier. Links to other hosts are recorded in a `external_links.json` log but not followed.
- **Maximum depth:** default **4 link-hops** from the seed; user-configurable per corpus (range 1–8) at add-time. The cap is a safety net against accidental sprawl; volunteer genealogy sites are typically 2–3 hops deep.
- **Optional link filter:** the user may supply a glob or regex (`/PEDIGREE-*.htm`, `^.*\.htm$`) at add-time. URLs not matching the filter are not enqueued. Empty filter = follow everything that passes the same-host and depth checks.
- **`sitemap.xml` is consulted first** when present. URLs listed in the sitemap are added to the frontier ahead of link-discovery walking; this short-circuits BFS on sites that publish a complete sitemap.
- **Content-type guard:** the crawler only fetches `text/html` (verified by `HEAD` if the URL has an ambiguous extension, otherwise by the `Content-Type` response header). Non-HTML responses are logged and skipped — no PDFs, no images, no archives in v1.
- **Page budget:** soft cap of 10,000 pages per corpus; configurable at add-time. The crawler stops with a warning if the cap is reached, leaves the partial corpus usable, and surfaces the partial state in the Settings UI so the user can decide whether to widen the cap or accept the cut.
- **Site verification at add-time:** before accepting the URL, the app does a `HEAD` (or small `GET`) to confirm reachability, fetches `robots.txt`, and parses the seed page enough to count outbound links and estimate corpus size. The user sees this estimate ("looks like ~2,200 pages on the same host") before confirming the add. Estimates that fail (timeout, 4xx, no outbound links) prevent the add until the user adjusts the URL or overrides explicitly.

### 6.3 Crawler state

A small JSON file under `corpora/<source_id>/crawl-state.json` tracks the frontier, the visited set, and the in-progress URL. The crawler resumes from this file after a crash. State is committed every 50 pages.

### 6.4 Reusing existing infrastructure

The crawler uses `SourceHTTPClient.shared` (the existing `HTTPClient` actor with rate limiting and 429 handling) verbatim. It does not introduce a new HTTP layer. This means the crawler benefits from any future improvements to the shared client (proxy support, etc.).

---

## 7. HTML → markdown conversion contract

The converter is a pure function: HTML in, markdown out, no I/O. It is callable from the crawler (to populate a page file) and from unit tests (to verify conversion stability against fixtures).

### 7.1 Preserved

- Headings (`<h1>`–`<h6>` → `#`–`######`).
- Paragraphs (`<p>` → blank-line-separated text).
- Strong / em (`<strong>`, `<b>` → `**…**`; `<em>`, `<i>` → `_…_`).
- Lists (`<ul>`, `<ol>` → `-` / `1.`).
- Tables (`<table>` → GitHub-flavoured pipe tables; collapsed to plain paragraphs if any cell contains a nested table).
- `<pre>` blocks (preserved verbatim inside fenced code blocks). Wirksworth's structured pedigrees live in `<PRE>` and must survive intact.
- Inline links — rendered as `[text](url)`. URLs are resolved against the page's base before writing.
- The first `<title>` and `<h1>` are also extracted into the frontmatter `title` field.

### 7.2 Stripped

- All `<script>`, `<style>`, `<noscript>` blocks.
- Navigation chrome: `<nav>`, `<header>`, `<footer>`, and any element whose class or id contains `nav`, `menu`, `sidebar`, `breadcrumb`. The match is exact lowercased substring on the element's literal class/id attribute.
- Comments (`<!-- … -->`).
- Empty elements after stripping.
- All event-handler attributes (`onclick`, etc.).

### 7.3 Image handling

Images are **not** downloaded. The converter rewrites every `<img src="…">` to a markdown link of the form:

```markdown
[image: <alt-text or filename>](<absolute-image-url>)
```

The link is preserved so a future extraction step can decide whether to fetch (e.g. for an OCR pass over a scanned register), but v1 stores no image bytes. This keeps corpus size predictable and avoids re-distributing third-party scans.

### 7.4 Whitespace and encoding

- All output is UTF-8, NFC-normalised.
- HTML entities decoded (`&amp;` → `&`, `&nbsp;` → space, numeric entities decoded to characters).
- Runs of internal whitespace collapsed to a single space, except inside fenced code blocks.
- Trailing whitespace stripped per line.
- Line endings normalised to LF.

### 7.5 Determinism

Given the same HTML input and the same crawler version, the converter must produce byte-identical markdown output. This is a hard requirement — content-hash comparison depends on it. A test fixture pinned per source verifies stability.

---

## 8. Indexer

The indexer reads markdown files under `pages/` and populates the SQLite index. It runs once after a crawl and incrementally on `sync`.

### 8.1 What gets extracted

For each markdown file:

1. **Frontmatter parse.** YAML parsed; `source_url`, `fetched_at`, `content_hash`, `title` are read.
2. **Body normalisation.** Frontmatter stripped. The remaining text is the FTS5 body and the corpus for the other tokenisers.
3. **Surname tokenisation.** Capitalised tokens of length ≥ 3, optionally followed by `'s`. Uppercased, stop-word filtered. The stop-word list is the existing genealogy English-word list (e.g. `OF`, `THE`, `AND`, month names, day names, "Wirksworth" / "Derbyshire" — names that show up in every page). Multi-word capitalised runs split on whitespace; each token recorded separately. Mention counts are raw integers.
4. **Year tokenisation.** Four-digit integers in the range 1500–1999 (the corpus range). Two-digit dates (e.g. "in 76") are not recognised in v1; they will be addressed in a v1.x refinement if extraction quality demands it.
5. **Place tokenisation.** Lowercased tokens matching the existing `LocationGazetteer` entries. Indexing places at v1 is best-effort — the gazetteer is the canonical list, no fuzzy matching, no Levenshtein. Pages with no recognised place yield zero rows in `page_places`.

The indexer is idempotent: deleting all rows for a `page_hash` and re-inserting is the refresh path. No partial updates.

### 8.2 Refresh

On `sync`, the indexer compares each markdown file's frontmatter `content_hash` against the value in the `pages.content_hash` column. Matches are skipped. Mismatches re-index that single page (delete + insert across all four tables). Pages on disk that are not in the database are inserted; rows in the database whose markdown file no longer exists are deleted (cascade via foreign key).

### 8.3 Reusing existing infrastructure

The indexer uses GRDB the same way the project database does. No new persistence layer. Each prose-source's `index.sqlite` is a standalone `DatabaseQueue`. The project database remains untouched.

---

## 9. Retrieval

The retrieval path is invoked by the existing `SearchDispatcher` (see `RESEARCH_PIPELINE_SPEC.md` §8) when it routes a query to a prose source. The prose source's `search(_:)` method translates `RecordQuery` into an SQL filter, selects top-K pages, and returns them as `SourceRecord` values whose `detailURL` carries the original `source_url`.

### 9.1 Query construction from `ResearchSubject`

The dispatcher builds the query exactly as it does for `WirksworthSource` today (see `WirksworthSource.activitySummary` and surrounding code). The new behaviour is in the prose-corpus retriever, not in the dispatcher.

From `RecordQuery`, the retriever pulls:

- `surname` → required. Looked up as `surname_upper`. Variants come from the existing `SurnameVariants` map and produce an SQL `IN` clause.
- `yearRange` → optional. When present, used to constrain `page_years.year`.
- `region` → optional. Used to constrain `page_places.place_lower` against the gazetteer's tokens for that region. When the region is unsupported by the source's coverage, the retriever returns `.outsideCoverage`.

### 9.2 SQL filter shape

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
ORDER BY (sc * 3 + yc * 2 + pc) DESC
LIMIT ?;
```

Surname is the gate (`INNER JOIN`). Year and place are scoring axes. The weighting (3:2:1) is a starting point; tuning is an open question (§14).

### 9.3 Top-K selection

`K` defaults to **5**. Higher K wastes MLX inference time; lower K risks missing the right page. Per-mode override:

| Mode | K |
|---|---|
| `.verify` | 3 |
| `.extend` | 3 |
| `.discover` | 5 |
| `.all` | 8 |

The retriever reads the selected markdown files from disk, strips frontmatter, and passes the bodies to the MLX extractor.

### 9.4 No FTS5 in the primary path

The `page_fts` table is for two narrow uses:

1. **Diagnostic search from the corpus inspector UI** (a future Sync tab) — "show me every page mentioning 'apprentice'."
2. **Tie-breaking in v1.x:** when many pages share the top surname-year score, an FTS5 search for given names plus context terms (`father`, `wife`) can re-rank. Not in v1.

Primary retrieval uses the pivot tables, not FTS5. This is deliberate — FTS5 ranking is opaque and tuning it would re-introduce the embedding-search problem this design rejected.

---

## 10. MLX integration

The retriever's output is K markdown files. They are passed to `LocalInferenceService.reason(...)` with an extraction prompt. The extractor is **not** a new MLX service — it reuses `LocalInferenceService.shared` exactly as `StrategyAdvisor` does (`RESEARCH_PIPELINE_SPEC.md` §14).

### 10.1 Prompt shape

A new bundled prompt file at `Resources/Prompts/prose_extraction_system.txt`. The system prompt is fixed; the user prompt is built per call.

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
  (markdown body, capped at 24 KB; if larger, the page is split at section
   boundaries and each section is run as a separate inference call)

TASK
  Return JSON with two arrays:
    facts: [{ kind, value, evidence_text, reasoning }]
    narratives: [{ category, description, date_or_period, evidence_text, reasoning }]
  - `kind` is one of: birth_year, death_year, marriage_year, spouse, occupation, residence.
  - `evidence_text` must be a verbatim substring of CONTENT, ≤200 characters.
  - `reasoning` is one sentence explaining how evidence_text supports the value.
  - Return {"facts": [], "narratives": []} if nothing about the subject appears on the page.
```

The reasoning model's `<think>` blocks are stripped by `LocalInferenceService` (lines 188–203 of `LocalInferenceService.swift`) before JSON parsing.

### 10.2 Routing extracted output to `pending_facts`

Each item in `facts` is converted to a `PendingFact` and submitted through the Evidence Firewall. The relevant existing column set on `pending_facts` (after the v5 migration in `ProjectDatabase.swift` lines 302–311) already carries everything needed:

- `source_url` ← the page's `source_url` from frontmatter.
- `source_title` ← the page's `title`.
- `evidence_text` ← the verbatim substring (capped at 200 chars in the schema).
- `reasoning` ← the model's one-sentence justification.
- `agent_id` ← `"prose-extractor:<source_id>"` (e.g. `prose-extractor:wirksworth`).
- `source_trust_tier` ← copied from the source plugin's `trustTier`.
- `source_directness` ← copied from the source plugin's `evidenceDirectness`.

The Evidence Firewall's existing hallucination checks (URL verification, evidence-text-must-be-substring) run unchanged. The prose extractor is just another agent submitting facts.

### 10.3 Routing extracted output to `narrative_findings`

Each item in `narratives` is converted to a `NarrativeFinding` (shape from `EvidenceFirewall.swift` lines 198–211) and inserted into the `narrative_findings` table (schema in `ProjectDatabase.swift` lines 262–275). Field mapping:

- `profile_id` ← the `ResearchSubject.profileID`.
- `category` ← extractor output (apprenticeship, will, residence, etc.).
- `description` ← extractor output, capped at 500 chars.
- `date_or_period` ← extractor output.
- `source_url`, `source_title` ← from frontmatter.
- `evidence_text` ← capped at 200 chars.
- `reasoning` ← model output.
- `agent_id` ← `"prose-extractor:<source_id>"`.

Both pending facts and narrative findings flow through the existing review UI — the prose corpus does not introduce a new review surface.

### 10.4 Reusing existing infrastructure

- `LocalInferenceService.shared` is the only MLX call site.
- Prompts live in `Resources/Prompts/` alongside `strategy_system.txt`.
- The Evidence Firewall is unchanged. URLs are verified by the existing pipeline (cached page snapshot in `page_cache`, content-hash compare against `content_hash` from frontmatter — same algorithm as the existing source-page provenance check).

---

## 11. Mode gating

MLX extraction is expensive. The dispatcher gates it by `ResearchMode`.

| Mode | Index lookup | MLX extraction |
|---|---|---|
| `.verify` | yes (informational only) | **no** |
| `.extend` | yes (informational only) | **no** |
| `.discover` | yes | **yes** |
| `.all` | yes | **yes** |

In `.verify` and `.extend` modes, the prose source returns the top-K pages' titles and URLs as `SourceRecord` values of a new `recordType` `.proseCandidate` — surfaced in the research activity log so the user knows there is biographical context to read, but not handed to MLX. In `.discover` and `.all`, the same top-K pages are also passed through the extraction prompt and the resulting `pending_facts` / `narrative_findings` flow through the Evidence Firewall.

The gate is enforced in the prose-source's `search(_:)` implementation, not in the dispatcher. This keeps the dispatcher uniform across structured and prose sources.

---

## 12. Acceptance criteria

The following assertions are testable against a built corpus and a fixture project. A future agent or test suite should be able to verify each mechanically.

### 12.1 Build pipeline

- **AC-B1** After a fresh `sync` of any registered corpus, the directory `corpora/<source_id>/pages/` contains at least one `.md` file (or the crawler reports a partial/empty outcome with an explicit reason in the manifest).
- **AC-B2** Every `.md` file under `pages/` has valid YAML frontmatter containing `source_id`, `source_url`, `fetched_at`, `content_hash`, `title`, and `crawler_version`.
- **AC-B3** For every file, `frontmatter.content_hash == sha256(body_normalised)`. A test runs this check across the entire corpus.
- **AC-B4** Re-running `sync` against an unchanged source produces zero filesystem writes (verified by file mtime).
- **AC-B5** Re-running `sync` against a source where exactly one page has changed (verified by altered HTTP response) rewrites exactly one `.md` file and reindexes exactly one `page_hash` row.
- **AC-B6** A page that returns HTTP 404 on refresh is deleted from disk and its row cascades out of `pages`, `page_surnames`, `page_years`, `page_places`, and `page_fts`.

### 12.2 Crawler politeness

- **AC-C1** Time between consecutive HTTP requests to the same host during a crawl is ≥ 500 ms in 99% of cases (measured from the crawler log).
- **AC-C2** A `robots.txt` `Disallow: /PRIVATE/` entry causes the crawler to skip every URL beginning with `/PRIVATE/` and log the skip.
- **AC-C3** Three consecutive HTTP 429 responses trip the circuit breaker; the fourth request is parked for ≥ 60 s.
- **AC-C4** The User-Agent header on every crawler request matches the existing `WirksworthSource.userAgent` string.

### 12.3 Index

- **AC-I1** For any surname present on more than one indexed page, `SELECT COUNT(*) FROM page_surnames WHERE surname_upper = ?` returns the expected count when verified against a hand-counted fixture corpus of five pages.
- **AC-I2** Every `page_hash` in `page_surnames`, `page_years`, `page_places` has a matching row in `pages`.
- **AC-I3** `page_fts` contains exactly one row per row in `pages` (verified by `COUNT(*)` parity).

### 12.4 Retrieval

- **AC-R1** A `RecordQuery` with `surname: "Cauldwell"`, `yearRange: 1780...1830`, `region: .parish("Wirksworth", county: "Derbyshire")` returns ≤ K pages, all of which contain "CAULDWELL" in `page_surnames`.
- **AC-R2** A `RecordQuery` for a surname not present in any `page_surnames` row returns `.results([])` (not an error).
- **AC-R3** Top-K selection is deterministic — given the same query against the same corpus, the same K pages come back in the same order.

### 12.5 MLX extraction

- **AC-M1** In `.verify` mode, the prose source's `search` never calls `LocalInferenceService.reason(...)`. Verified by injecting a mock service that fails the test if invoked.
- **AC-M2** In `.discover` mode, each of the K retrieved pages results in exactly one `LocalInferenceService.reason(...)` call.
- **AC-M3** Every fact submitted to `pending_facts` has `source_url` equal to a `source_url` in `pages` and `evidence_text` that is a verbatim substring of the corresponding markdown body.
- **AC-M4** Every narrative finding submitted has `agent_id` matching `prose-extractor:<source_id>`.
- **AC-M5** A page that contains no information about the subject produces zero pending facts and zero narrative findings — even if the MLX call returns a non-empty JSON. The Evidence Firewall's existing substring check rejects fabrications.

### 12.6 Evidence Firewall integration

- **AC-E1** A pending fact whose `evidence_text` is not a substring of the cached page is rejected (`verification_status = contentMismatch`) — using the same logic the existing firewall already applies.
- **AC-E2** A pending fact whose `source_url` does not resolve to a page in the corpus marks `verification_status = failed`.
- **AC-E3** The user reviewing pending facts in `PendingFactsReviewView` sees prose-extracted facts in the same UI as MCP-submitted facts. No new view.

---

## 13. Phased build

| Phase | Slice | Depends on |
|---|---|---|
| **P1** | **Converter + storage primitives.** `HTMLToMarkdownConverter` (pure function), `ProseCorpusStorage` (frontmatter write, content-hash, atomic file replace). Five pinned HTML fixtures covering the conversion contract (§7). Unit-testable in isolation. No network, no SQLite, no UI. | none |
| **P2** | **Generic crawler.** `ProseCorpusCrawler` actor: same-host BFS from a seed URL, depth cap, `robots.txt`, `sitemap.xml`, content-type guard, page budget. Uses `SourceHTTPClient.shared`. Crawl a developer-supplied URL into `corpora/<source_id>/` on disk; verify against the canonical Wirksworth example URL. | P1 |
| **P3** | **Corpus registry + add-corpus flow.** `ProseCorpusRegistry` (Application Support `registry.json`). Settings UI gains a *Prose Corpora* section with *Add* / *Sync* / *Remove* actions. *Add* runs site verification (reachability, `robots.txt`, outbound-link count estimate) and confirms with the user before kicking off the background crawl. Progress surfaced as the crawl runs. | P2 |
| **P4** | **Indexer.** Per-corpus SQLite index. Schema v1 migration. Indexer populates `pages`, `page_surnames`, `page_years`, `page_places`, `page_fts`. Re-run-idempotent via content-hash comparison. | P3 |
| **P5** | **Retrieval-only integration.** `ProseCorpusSource` (single source plugin that dispatches across all registered corpora). `search(_:)` returns top-K page URLs as `SourceRecord` of `.proseCandidate` type. Surfaced in research activity log. No MLX. | P4 |
| **P6** | **MLX extraction.** `.discover` and `.all` modes route the retrieved pages through `LocalInferenceService` with `prose_extraction_system.txt`. Outputs flow to `pending_facts` and `narrative_findings` with `agent_id = "prose-extractor:<source_id>"`. | P5 |
| **P7** | **UI surfacing.** *Prose Corpora* section in Settings shows per-corpus status (page count, last synced, partial-crawl warnings). Pending-facts review gains a filter chip for `agent_id = prose-extractor:*`. | P6 |
| **P8** | **Second user-added corpus.** Validate the generic crawler against a second site of the user's choosing (different host, different structure). No new code — just an empirical confirmation that the design generalises. | P7 |

Each phase ships independently. P3 is the first user-visible release — the user can add a URL and see a corpus build, even before retrieval is wired. P5 is the first useful release for research workflows.

---

## 14. Open questions

These cannot be settled without empirical data from a built corpus.

1. **Pivot-score weighting.** §9.2 uses `surname_count * 3 + year_count * 2 + place_count`. Whether this ranks the correct page first across realistic queries is unknown until a built Wirksworth corpus is queried with a hand-labelled validation set ("for surname X in year range Y, the correct page is Z"). Tuning may also reveal that mention-count is the wrong signal and presence-only is better.
2. **Page-size split threshold.** §10.1 caps the user prompt's CONTENT block at 24 KB, splitting at section boundaries above that. The 24 KB number is a guess based on DeepSeek-R1 7B's effective context plus the extraction prompt overhead. The real threshold needs measurement against actual Wirksworth pages and observed MLX OOM behaviour on representative hardware (M1 8 GB, M2 16 GB, M3 32 GB).
3. **Stop-word list scope.** §8.1 mentions an "existing genealogy English-word list" but in practice no such list exists in the codebase yet — what counts as a "surname-shaped token" needs an empirically grounded stop-word list built from the corpus itself (e.g. tokens appearing in >40% of pages are almost certainly common nouns, not surnames). Whether this is per-source or universal is unknown.

---

## 15. Out of scope

- **Vector embeddings.** §2.1 rejects them. Revisit only if §14.1 tuning fails to produce acceptable top-K precision.
- **Cross-source corpus linking.** A future "this page in Wirksworth references the same will as that page in FreeREG" feature is not in v1. Each corpus is an independent island.
- **Bundled prebuilt corpora.** §2.3 — each user builds locally. No central CDN, no signed corpus archive, no torrent.
- **OCR over linked images.** §7.3 stores the image URL but never fetches the bytes.
- **Writing back to source sites.** The crawler is read-only against every source.
- **Generalised free-form web search.** This subsystem indexes named source corpora, not the open web. There is no DuckDuckGo integration.
- **In-app corpus editing.** The markdown files are produced by the converter and should not be hand-edited; any edit invalidates `content_hash`.
