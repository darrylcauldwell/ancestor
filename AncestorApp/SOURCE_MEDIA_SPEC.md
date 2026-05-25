# Source-Surfaced Media — Specification

> **Deferred (2026-05-25):** This spec is paper-only and stays that
> way until `ENGINE_FOUNDATION_SPEC.md` ships. Reason: image capture
> is an output-surface concern; the engine that decides *which*
> records get media attached needs to be trustworthy first.
> Foundation first.

**Status:** Paper-only. No code yet — none of the eight shipping
source plugins captures any image data, even when the upstream
response carries it.
**Scope:** Images and document scans (headstones, certificates,
microfilm waypoints, pedigree-page scans) that arrive **inside source
responses** the pipeline already fetches. Distinct from user-uploaded
attachments (DESIGN.md §5.15), which the user drags in by hand.
**Date:** 2026-05-22 (extracted from `RESEARCH_PIPELINE_SPEC.md` §19;
that doc's pipeline scope was too wide for the topic).
**References:** `RESEARCH_PIPELINE_SPEC.md` (Evidence Firewall and
source-plugin protocol); `FAMILYSEARCH_SOURCE_SPEC.md` (§5.5
`RectangleRegion` qualifier, §13 Memories endpoint).

This document is split into **Part I — Current state (as-built)** and
**Part II — Design pivot (proposed)**. As of this writing, Part I is
"nothing built"; the entire subsystem is proposed.

---

# Part I — Current state (as-built)

**Status: Paper-only.** Nothing in this Part is shipped. It's a
behavioural inventory of what each source plugin *already discards*
when an upstream response carries image references.

## 1. Catalyst

The 2026-05 fix to `FindAGraveSource.swift` that mines years from
inscription/bio free text exposed a larger gap. The memorial-detail
HTML carries `<img id="memPhoto">` and a photo-gallery section that
`parseMemorialDetail` never touches. Headstone photos with carved
dates are some of the strongest direct evidence a free source
produces — and we throw them away on every fetch.

User framing, verbatim: *"Some sources return images relating to
members of tree, I don't think we capture these presently but we
should and store them linked to profile."*

## 2. Source-by-source inventory

| Source | Image-bearing payload | What the parser does today | Code symbol |
|---|---|---|---|
| **Find a Grave** | Headstone photo (`<img id="memPhoto">`), photo gallery (portrait, additional cemetery shots, military emblems), volunteer-uploaded | Drops them entirely — `parseMemorialDetail` extracts inscription/bio/cemetery/plot but never queries any `<img>` tag or photo-gallery div. `BurialRecord` has no image field. | `FindAGraveSource.parseMemorialDetail` |
| **CWGC** | Cemetery photographs and (for many casualties) a headstone or memorial-panel photo on the casualty-details page; downloadable certificate PDF | Drops them — `parseCSV` (the only ingest path) consumes the CSV export which is text-only. The detail-page HTML at `cwgc.org/find-records/.../casualty-details/{id}/` carries the imagery and is never fetched. | `CWGCSource.parseCSV` |
| **FamilySearch** | Image waypoints (digitised microfilm scans) referenced from `sourceDescriptions[].links[]`, plus a `RectangleRegion` source-reference qualifier (FAMILYSEARCH_SOURCE_SPEC §5.5) marking *which row on the page* this persona occupies. Also Memories (user-uploaded portraits, certificates, family photos attached to FamilySearch tree persons). | Current parser decodes a narrow subset of GEDCOMx. `GxRoot` decodes `persons`, `relationships`, `sourceDescriptions` but **not** `links`. There is no Memories endpoint integration. | `FamilySearchSource.GxRoot`, `GxSourceDescription` |
| **Wirksworth** | Pedigree pages occasionally embed scanned images of original pedigree-book pages (HTML `<img>` tags); some pages include parish-register photos | Drops them — the parser is text-only | `WirksworthSource.parsePedigreePage` |
| **FreeBMD** | None directly (index only). But the index entries carry GRO reference fields (volume / page) that *point to* a registry image obtainable separately. | Parser captures volume/page in `rawFields` but does not synthesise a GRO image link. | `FreeBMDSource` — no image fields on `BirthRecord` / `DeathRecord` / `MarriageRecord` |
| **FreeCen** | None directly (transcription only). But each entry carries piece/folio/page from the underlying TNA census, which is the address of a TNA digitised page image. | Parser captures piece/folio/page/schedule/house_number/address in `rawFields` but does not link to the TNA image. | `FreeCenSource` |
| **FreeREG** | None — transcription only. Some parish-register transcriptions reference originals at FamilySearch (cross-source link). | No image handling. | `FreeREGSource` |
| **Probate** | Modern grants page sometimes links to a will-document PDF (post-1996 digital grants); older calendar entries have no image. The Nuxeo JSON response may carry a document URL. | Parser does not extract any URL beyond the grant text. | `ProbateSource` |

**Direct-evidence sources where we drop images today:** Find a Grave,
CWGC, FamilySearch, Wirksworth.

**Index sources where we have a reference but no synthesised image
URL:** FreeBMD (GRO volume/page), FreeCen (TNA piece/folio/page).

**Transcription-only, no image:** FreeREG.

**Modern-records source, image rare:** Probate.

## 3. What's already in the data model

The repo already has an `attachments` table (migration
`v10_attachments_goals`) and an `Attachment` model
(`Models/Attachment.swift`). It was originally scoped to
**user-uploaded** media per DESIGN.md §5.15 — photos and documents
the user drags onto a profile, life event, or field source.

The `AttachmentTarget` union already supports targeting a profile, a
life event, or a specific `(entityID, field)` field-source row.
That's a near-fit for source-surfaced images — a headstone photo from
Find a Grave logically attaches to the burial life event *and*
corroborates the death-date field source.

**What's missing for source-surfaced media:**

1. **Provenance fields.** No `sourceID`, no `sourceRecordID`, no
   `originalURL`. We can't tell a user-uploaded photo from one we
   downloaded from cwgc.org. This is load-bearing for §6 (trust +
   evidence weight).
2. **Subtype.** The current `AttachmentType` enum has only
   `photo / document / transcription`. For source-surfaced media we
   need to distinguish headstone / portrait / certificate / document
   scan / cemetery / pedigree.
3. **URL-only vs blob-cached.** No `fetchStatus` to indicate "URL
   recorded, file not downloaded yet" vs "downloaded and on disk at
   `relativePath`."
4. **Source-record link.** No FK to `source_records.id` — we can't
   trace a photo back to the search hit that surfaced it.

---

# Part II — Design pivot (proposed)

## 4. The Option A / Option B question

Two viable shapes. Pick one before implementation; both have real
costs.

**Option A — extend `attachments` with provenance columns.** Add
`source_id`, `source_record_id`, `original_url`, `fetch_status`, and
refine `media_type` to the six-category subtype list. Keep one table,
one query path, one inspector UI section. The cost is mixing
user-curated media (which the user "owns") with discovered media
(which we surfaced and the user may not even know about yet). A user
clicking "delete photo" on something they uploaded behaves
differently from clicking it on something the pipeline pulled in.

**Option B — new `source_media` table** parallel to `attachments`.
Discovered images live there until the user "accepts" them, at which
point they're either promoted into `attachments` (and the source-
media row marked accepted) or remain in source-media as evidence-
only. The cost is duplication: two queries to render a profile's
image strip, two delete paths, two export rules.

Recommendation, not decision: **Option B** mirrors the existing
Evidence Firewall pattern — `pending_facts` for proposed facts is
separate from the `field_sources` table for accepted ones. Source-
surfaced media is to user-curated media as `pending_facts` is to
`field_sources`. The user "accepting" a Find a Grave headstone photo
via TreeDiffView is the analogue of accepting a date — it crosses
the firewall.

What is **not** deferrable is recording provenance the moment a
parser sees an image URL.

## 5. Proposed data-model additions (Option B sketch)

```swift
/// An image (or PDF) surfaced by a source plugin during research,
/// attached to the profile the surfacing search was about. Lives
/// behind the Evidence Firewall: pipeline writes, user accepts in
/// TreeDiffView.
struct SourceMediaCandidate: Codable, Identifiable, Sendable {
    let id: UUID
    let profileID: String
    let sourceID: String                  // "findagrave", "cwgc", "familysearch", ...
    let sourceRecordID: String            // FK into source_records.id
    let mediaKind: SourceMediaKind
    let originalURL: String               // canonical, never null at insert
    let caption: String?                  // alt text or scraped figure caption
    let mimeTypeHint: String?             // "image/jpeg", "application/pdf"
    let fetchStatus: FetchStatus          // urlOnly / cached / failed(reason)
    let cachedRelativePath: String?       // populated when fetchStatus == .cached
    let cachedAt: Date?
    let cachedByteSize: Int64?
    let discoveredAt: Date
    let createdByTransactionID: String    // undo-tracked like every other firewall write
    var acceptedAt: Date?                 // user accepted into permanent attachments
    var promotedAttachmentID: UUID?       // FK into attachments.id when accepted
}

enum SourceMediaKind: String, Codable {
    case headstone, portrait, certificate, documentScan, cemetery, pedigree, other
}

enum FetchStatus: Codable {
    case urlOnly                          // we know the URL, file not on disk
    case cached                           // file is on disk at cachedRelativePath
    case failed(reason: String)           // tried to fetch, host returned error
}
```

Migration shape:

```sql
CREATE TABLE source_media (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    source_record_id TEXT NOT NULL,
    media_kind TEXT NOT NULL,
    original_url TEXT NOT NULL,
    caption TEXT,
    mime_type_hint TEXT,
    fetch_status TEXT NOT NULL DEFAULT 'urlOnly',
    cached_relative_path TEXT,
    cached_at DATETIME,
    cached_byte_size INTEGER,
    discovered_at DATETIME NOT NULL,
    created_by_transaction_id TEXT NOT NULL,
    accepted_at DATETIME,
    promoted_attachment_id TEXT,
    FOREIGN KEY (source_record_id) REFERENCES source_records(id),
    FOREIGN KEY (promoted_attachment_id) REFERENCES attachments(id)
);
CREATE INDEX idx_source_media_profile ON source_media (profile_id);
CREATE INDEX idx_source_media_record ON source_media (source_record_id);
```

`RecordCommon.rawFields` is the wrong home (string-only, no schema,
lost on re-parse). The parsers should populate a new optional
`discoveredMedia: [SourceMediaURL]` on `RecordCommon` (or per-typed
record where it makes sense) and the persistence layer is
responsible for writing rows into `source_media` keyed off
`source_records.id`. Keeping `discoveredMedia` on the typed record
(not just `rawFields`) means tests can assert on it and the scorer
can read it.

## 6. Open question: do images count toward the 4-gate scorer / evidence directness?

Today's `EvidenceDirectness` ladder is
`.primary / .directTranscription / .derivative`. A Find a Grave
memorial is `.derivative` because the volunteer transcribed dates
from a headstone they did not necessarily photograph. **But a Find a
Grave memorial with a headstone photo carrying the carved dates
collapses that gap** — the user (or, post-MLX, the local model) can
read the dates off the stone themselves.

Three positions, all defensible:

1. **Images don't affect scoring.** They're decoration / verification
   aid.
2. **Images upgrade directness, deterministically.** A Find a Grave
   record with an attached headstone photo of the actual gravestone
   gets re-tiered from `.derivative` to `.primary` for the death-date
   field specifically.
3. **Images are an MLX-task.** The local model OCRs/reads the
   headstone photo, emits its own structured facts, those go through
   `pending_facts` as an independent source.

Recommendation, not decision: **(3) is the only one that respects the
deterministic sandwich**. Position (2) would let the *presence* of an
image dictate scoring, which makes the scorer dependent on a network
fetch having succeeded — non-deterministic. Position (3) treats the
image as fresh data, lets the convergence engine decide, and keeps
the scorer pure.

For the first cut, **adopt (1)**: capture and display, no scoring
impact. Revisit when the local-vision story exists.

## 7. First-cut scope (one focused session)

**Goal:** Source-surfaced images flow into a persistent table, are
visible on the profile inspector, and survive across sessions. No
download-by-default; no scoring impact; no GEDCOM export.

**In scope:**

- Migration `v_source_media` adding the table from §5.
- `SourceMediaCandidate` model + read/write in a new
  `ProjectDatabase+SourceMedia.swift`.
- `RecordCommon` (or per-record-type) gains optional
  `discoveredMedia: [SourceMediaURL]`.
- **Find a Grave first** (highest-yield, lowest-risk).
  `parseMemorialDetail` extracts the hero photo and gallery (capped
  at 20 per memorial).
- **CWGC second.** Extend the source to fetch the casualty-details
  HTML page and extract the headstone/memorial photograph plus the
  certificate PDF URL.
- **FamilySearch third.** Decode `links[]` on `GxSourceDescription`
  and capture the image-waypoint URL + the `RectangleRegion`
  qualifier alongside it.
- URL-only persistence by default. **No automatic download.** A
  "Download" affordance on each media row in the inspector triggers
  a fetch with the same rate-limit + auth contract as the parent
  source.
- Inspector UI: a collapsed-by-default "Source-discovered images (N)"
  disclosure under the existing Sources section on the profile
  detail view.

**Out of scope for first cut:**

- Wirksworth pedigree-page image extraction.
- FreeBMD GRO image-link synthesis.
- FreeCen TNA image-link synthesis.
- Probate will-PDF.
- Memories endpoint integration on FamilySearch.
- Image-driven evidence promotion (position 2 or 3).
- GEDCOM `OBJE` export.
- Vision-model OCR of headstones.
- Copyright/redistribution surfacing in shared exports.
- Background eviction of cached blobs to manage disk.

## 8. Storage strategy: URL-only vs blob-cached

Both are needed, and the tradeoffs argue for "URL recorded on
discovery, blob cached on demand" — the `fetchStatus` field in §5
encodes the lifecycle.

**Proposed policy:**

- On parse, always write a `source_media` row with
  `fetchStatus = .urlOnly` and the URL.
- **Auto-cache** when *any* of: the source is Find a Grave
  (volunteer deletion risk); the source requires auth and we have a
  valid session right now (FamilySearch — fetch while we can); the
  image is small (`<200KB` heuristic, from `Content-Length` HEAD).
- **Manual cache** ("Download" button) for everything else.
- **Settings toggle**: "Cache all source-discovered images
  automatically" (default off) for power users who want the offline
  archive.

This is the same pattern as the existing `page_cache` — speculative
caching of source HTML for re-parse. Source media is the binary
analogue.

## 9. Trust + provenance

Every `source_media` row carries `sourceID` and `sourceRecordID`. The
trust tier of the media is inherited from the source — there is no
LLM-driven "this looks like a real headstone" judgement
(`RESEARCH_PIPELINE_SPEC.md` §3.1 invariant: source trust is
URL-derived). A Find a Grave photo is `.community`-tier evidence by
virtue of being from Find a Grave, regardless of how authoritative
the image *looks*.

When the user accepts a `source_media` row into permanent
`attachments` (via the §4 Option B promote path), the new
`Attachment` row carries `sourceID` and `originalURL` columns so the
provenance chain is preserved indefinitely.
