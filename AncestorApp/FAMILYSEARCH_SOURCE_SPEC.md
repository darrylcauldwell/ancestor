# FamilySearch Source — Deferred Work & Reference

> **Status (2026-07-21) — implemented surface SHIPPED.** The FamilySearch
> OAuth transport (OAuth2 + PKCE, loopback redirect, Keychain tokens), the
> historical-records `/platform/records/personas` scored `RecordSource`
> (GEDCOM X search + multi-persona parse + collection-pattern trust tiering),
> and the tree hint enrichment surface (record hints → §18-ordered leads,
> memories → link-only image pointers) are **built and live-verified on Beta**
> (client library shipped, git-only). See
> `Ancestor Research/Services/Sources/FamilySearch/` for the as-built
> implementation. Git history archives the shipped design detail.
>
> **This document is now the home for the still-DEFERRED FamilySearch work**
> — the Family-Tree write / contribute-then-enrich leg, ARK / persona
> detail-fetch endpoints, per-collection trust tiering, place & vocabulary
> authorities, new `RecordType` cases, and the secondary-metadata roadmap —
> **plus the load-bearing reference**: the verbatim §16 licensing posture,
> the GEDCOM X taxonomy pointers, the §17 evidence-identity rules, and the
> one-line §18 hint invariant. It also carries the FS enrichment-polish
> follow-ups (§19) absorbed from the retired client spec.
>
> **Pivot note (2026-07-11):** cookie-transport scraping was retired as
> contractually prohibited (dev-agreement §15); the app moved to the official
> OAuth API. Full pivot is git-only (client library shipped, git-only).

---

## 2.4 Excluded from scope

- **Shared Family Tree write API** (creating/editing SHARED-tree persons,
  conclusions, source references). The Evidence Firewall already prohibits
  writing directly to profiles; collaborative-tree writes would compound
  the issue. *Future direction worth not forgetting*: "attach source to FS
  tree person" as a soft-write (now WF-C in the write-leg spec).
  **SUPERSEDED IN PART 2026-07-30: the USER TREE write leg (a separate
  app-created tree, not the shared Family Tree) is BUILT** — see
  `FAMILYSEARCH_TREES_WRITE_SPEC.md` (#WL0–#WL6). Uploading the local tree
  to a private/owned User Tree is outbound-only and firewall-clean: nothing
  writes back into app profiles except the E1 pid identifiers.
- **Memories upload** (photos, stories, documents). Not pipeline-relevant.
- **DNA matching**. Private to the user, separate auth, out of V2 scope.
- **Discussions / forum threads**. Conversational, not evidentiary.

---

## 3. GEDCOM X taxonomy — deferred new RecordType cases

The full GEDCOM X taxonomy → `RecordType` mapping is implemented in
`FamilySearchSource.parseSearchFeed`/`buildRecord` (see the shipped source).
What remains deferred is the introduction of **new `RecordType` cases** for
fact types that don't yet map cleanly to an existing case. Log unmapped fact
types in `rawFields[unmappedFactType]` until eval data shows the need, then
promote:

**Propose new RecordType cases**

| GEDCOMx fact | Proposed RecordType | Why |
|---|---|---|
| Immigration | `.immigration` | Distinct event for cross-border ancestors |
| Emigration | `.emigration` | Inverse of Immigration |
| Naturalization | `.naturalization` | Citizenship grant — load-bearing for US/UK trees |
| LandTransaction | `.landTransaction` | Geographic + property anchor |
| Property | `.property` | E.g. tax lists, property registers |
| TaxAssessment | `.taxAssessment` | Census-adjacent, fills inter-census decades |
| Occupation | `.occupation` | Currently captured as a field, not a record type — but FS treats it as a fact |
| Education, EducationEnrollment, Graduation | `.education` | School records, common in C19+ |
| Apprenticeship | `.apprenticeship` | C18-C19 trade records |
| Court | `.court` | Criminal / civil court records |
| Imprisonment, Arrest, Pardon | `.legalEvent` | Catch-all for non-court legal facts |
| Obituary | `.obituary` | Newspaper-derived, useful for late-C19 onwards |
| Adoption | `.adoption` | Non-biological parenthood marker |
| Ordination, Mission, FirstCommunion, Confirmation, BarMitzvah, BatMitzvah | `.religiousRite` | Catch-all for non-baptism rites |

Couple-relationship new cases (Divorce / DivorceFiling / Annulment →
`.divorce` with subtypes; `.engagement`; `.separation`) and the
non-biological parent-child `RelationshipKind` distinctions (adoptive,
foster, step, guardian, surrogate, sociological) are the same class of
deferred enum-expansion work: detect and store the kind, but treat
non-biological the same as biological in the deterministic engines until
eval-corpus evidence shows where the conflation harms outcomes.

Mappings missing from any table fall through to an `unmappedFact` key
preserved in `rawFields`.

The GEDCOM X taxonomy source specifications (fact-types, event-types,
record-field model) are linked in §13.

---

## 6. Beyond search — deferred endpoints worth wrapping

### 6.1 ARK / persona lookup (highest priority after search)

`GET /platform/records/personas/{personaId}` (OAuth)

What it adds over search:
- Full fact set (search returns a subset for relevance/size)
- Cross-references to the same person in other FamilySearch records (Person Match)
- Image / waypoint references (where digitised originals exist)
- Source citation in canonical format

Why it matters for us:
- **Citation matcher**: ~half of the user's bio citations are ARK-bearing
  FamilySearch references. ARK lookup is the deterministic test for "is
  this record real and does it match the cited person."
- **Hypothesis testing**: a `.familysearchAtARK(ark)` hypothesis becomes
  testable in one HTTP call.
- **Detail enrichment**: when a search hit passes the 4-gate scorer with
  `.likelyMatch`, fetching the full record yields more facts → more
  cluster signal → more convergence opportunities.

Note: detail-fetch persistence is constrained by the §16 licensing posture
— under the pointer-only reading there is nothing to backfill locally.

### 6.2 Record by ARK

`GET /platform/records/records/{recordId}` (OAuth)

Same as persona lookup but returns the whole record (every person
extracted from the document, not just one). Useful for census records
where the household structure matters.

### 6.3 Collection metadata

`GET /platform/records/collections` (OAuth) and per-collection
endpoints.

What it adds:
- Trust tier classification per collection (parish-register
  transcription vs civil-registration index vs user-submitted tree)
- Date range, geographic coverage per collection
- Image-availability flags

This data is **load-bearing for the SourceTierRegistry**. The shipped
source tiers FamilySearch by collection-title pattern; per-collection
metadata would let "FamilySearch England, Marriages 1538-1973" (parish
register transcription) earn `.transcription` tier while "FamilySearch
Community Trees" earns `.community` tier from authoritative data rather
than a title heuristic. This is the deferred upgrade path — see §7.

Recommendation: cache the collection list at first run (it's ~2000
entries, slow-changing) into a local SQLite table; refresh monthly.

### 6.4 Vocabulary lookup

`GET /cv/{vocab-id}` (OAuth)

Returns controlled vocabularies. For us the relevant ones are:
- `cv/fact-type` — current list of fact types (extends over time)
- `cv/place-type` — for the Place authority work
- `cv/source-citation-type` — citation format types

Low priority; we hard-code GEDCOMx URIs in the Swift enum and update
when FamilySearch publishes new ones. Useful as a future refresh path.

### 6.5 Tree Person Matches — SHIPPED, see git

`GET /platform/tree/persons/{pid}/matches` → record hints → §18-ordered leads.

### 6.7 Place authorities

`/platform/places/{placeId}` (OAuth)

FamilySearch maintains a structured place hierarchy with stable IDs.

The data-model side-channel is **shipped**: `RecordCommon.placeARK: String?`
captures the FS place ARK whenever the response carries one. **Deferred:**
wire `/platform/places/{placeId}` and promote that side-channel key into a
canonical gazetteer lookup so gazetteer-aware engines light up against it.
Genuinely V3 work (rides the gazetteer expansion).

---

## 7. Trust tiering — by collection AND by attribution (deferred)

FamilySearch publishes records from 2000+ distinct collections. Trust
varies dramatically across them — but trust also varies *within* a
single collection (especially the Family Tree) by attribution: a
source-extracted fact and a user-concluded fact in the same Tree
person record have very different evidentiary weights. The tiering
extension must capture both axes. The shipped source tiers by collection
*title pattern*; the per-collection-metadata and attribution-aware tiering
below is the deferred upgrade (it depends on §6.3 collection metadata).

### 7.1 Collection-level tiering

```swift
extension SourceTierRegistry {
    static func tier(for collectionARK: String) -> SourceTrustTier
    static func category(for collectionARK: String) -> SourceCategory
    static func lineage(for collectionARK: String) -> SourceLineage
    static func completeness(for collectionARK: String) -> Double?  // 0–1
}
```

Initial mapping rules (refine with data):

| Collection pattern | Tier | Lineage | Category |
|---|---|---|---|
| `*Civil Registration*` | `.transcription` | `.independentTranscription(of: "GRO-indexes")` | `.officialArchive` |
| `*Parish Register*` | `.transcription` | `.independentTranscription(of: "parish-registers")` | `.officialArchive` |
| `*Census*` | `.transcription` | `.independentTranscription(of: "<census-year>")` | `.officialArchive` |
| `*1939 Register*` | `.transcription` | `.independentTranscription(of: "1939-register")` | `.officialArchive` |
| `*Community Trees*`, `*Member Trees*` | `.community` | `.userContributed` | `.userTree` |
| `*Family Tree*` (the FS official tree) | `.community` | `.userContributed` | `.userTree` |
| Everything else | `.transcription` (default) | `.independentTranscription(of: "unknown")` | `.aggregator` |

### 7.2 Attribution-level tiering (within community-tier collections)

Within a Family Tree person record, individual facts carry an
`attribution` field with a contributor reference and timestamp. The
critical distinction:

- **Source-extracted**: the fact was extracted from a historical
  record and attached to the tree person. Evidentiary weight inherits
  from the *source* record (and that record's collection tier).
- **User-concluded**: the fact was entered or inferred by a tree
  contributor without a source citation. Evidentiary weight should
  reflect that — `.community` is right, but a `.userConcluded`
  sub-band lets the scorer downweight further.

Proposed sub-tier extension:

```swift
enum SourceTrustTier {
    case community         // existing
    case userConcluded     // NEW — tree facts without source citation
    case transcription
    case primary
}
```

Same logic for `Couple` and `Child-and-Parents` relationship facts
within Tree records — facts without source attribution downweight.

### 7.3 Volatility signal (Tree records)

Tree persons have `Person Change History` (see §12 tiered roadmap). A
person with 50 edits across 8 contributors over 6 years is a
*contested attribution* — community-tier with the volatility known is
meaningfully different from community-tier with the volatility unknown.

The `volatilityScore: Double?` field on `RecordCommon` is **shipped**
(nullable, pinned by `SecondaryMetadataColumnsTests`). **Deferred:** wire
the change-history endpoint that fills it, and have the scorer downweight
high-volatility records within their tier (without abandoning them). Same
field applies to `Couple` and `Child-and-Parents` relationship records.

### 7.4 Collection completeness (negative-search evidence)

The GEDCOMx Record spec defines `CollectionContent.completeness`: a
0–1 score declaring how complete a collection's coverage of its
declared resource type is. This is the structured form of what
§7.1 tries to derive from title pattern-matching.

The `collectionCompleteness: Double?` field on `RecordCommon` is
**shipped** and parsed from `sourceDescriptions[].coverage[].completeness`
when present. **Deferred:** wire the two consumers —

1. **`negative_searches` enrichment**: a zero-result search against a
   0.9-completeness collection is materially stronger evidence of
   absence than against a 0.4-completeness collection. The cache row
   carries the completeness; the scorer weights `.unavailable`-evidence
   with it.
2. **Pending-fact display**: "from England Parish Registers
   (94% complete coverage 1538–1812)" tells the user how seriously
   to take a fact's absence elsewhere.

### 7.5 Convergence engine implication

A FamilySearch parish-register transcription and a FreeREG
parish-register transcription of the same event count as TWO
transcriptions of one original → convergence `.parallel`
not `.independent`. The lineage `independentTranscription(of: "parish-registers")`
encodes this so the existing engine handles it correctly.

A FamilySearch GRO-indexes transcription and a FreeBMD GRO-indexes
transcription likewise count as parallel transcriptions of one
underlying record. Today they'd both score as separate sources and
inflate confidence — the lineage marker fixes this without changing
engine logic.

---

## 12. Secondary metadata roadmap (Tier 1 / 2 / 3) — deferred

The shipped source is record-fetch-centric. The contextual metadata that
surrounds records — collection completeness, persona cross-references,
change-history volatility, attached photos and transcribed wills — is
where the second-order value sits. This roadmap keeps it on the radar so
the right items land at the right cuts.

### 12.1 Tier 1 — high value, post-first-cut

**Memories (read-only).** FS users attach photos of gravestones,
transcribed wills, family bibles, photographed letters, even audio
interviews to person records. These are real evidentiary artifacts —
a transcribed will photographed on FS is exactly the probate evidence
a `.probate` record promises but rarely delivers. Endpoints: Memory
Persona resource (which memories tag this person), Memory Artifact
resource (the file). Trust tier `.community` but content like a
photographed gravestone is closer to primary evidence than any
transcription. (Memories are surfaced as **link-only** image pointers
today per §16 — the deferred item is deeper artifact handling.)

**Source-references cross-query.** GEDCOMx's
`/persons/{pid}/sources` and inverse queries answer "what other
personas use this source?" For a census record, the answer is "every
household member" — the multi-persona household-extraction problem
from a different angle. Cleaner than re-parsing the persons[] array.
Folds in alongside ARK lookup (§6.1).

**Change-history volatility scoring.** `volatilityScore` column on
`RecordCommon` (§7.3); the change-history endpoint that populates it is
deferred work. Cheap once the column exists.

**CollectionContent.completeness extraction.** Parse-and-store whenever
present in the response (§7.4). The *consumption* of this field by the
scorer's negative-evidence weighting is deferred work.

### 12.2 Tier 2 — interesting but more nuanced

**Ancestry / Descendancy resources.** `/persons/{pid}/ancestry?generations=N`
returns N-gen pedigree in one call. If a Tree-match candidate surfaces,
fetching its ancestry and comparing against the user's own pedigree is
structurally stronger than per-person matching — tests the V2 spec's
G6 (family-graph plausibility) with FS's tree as the comparison corpus.

**Discussions as reasoning trails.** Tree person discussions often
contain "I changed her birth year because the 1851 census suggests 23
not 25" — user-written analogue of `ResearchHypothesis.reasoning`. Read
as displayable context for Tree-match candidates; not a fact source but
a meta-signal about confidence.

**RecordDescriptor for schema-aware parsing.** Collections carry
descriptor metadata declaring "records in this collection have these
fields with these labels." A persona missing a field that the
descriptor says should exist is a transcription gap, not a real
absence — stronger negative information. Alongside the
collections-metadata-caching work.

### 12.3 Tier 3 — defer

**Notes on persons and relationships** — lower-volume sibling of
discussions; low value-per-byte.

**Place type hierarchies and historical jurisdictions** — richer than
just place IDs, but probably below the bar unless gazetteer work picks
it up specifically.

**Genealogies (separate from Family Tree)** — parallel user-submitted
corpus, mostly redundant with Family Tree for matching purposes.

**Soft writes — attaching a citation to a tree person** — gives back
to the community as a side effect. V3+. Worth a future-direction note
so it doesn't get forgotten (also flagged in §2.4).

### 12.4 The pragmatic recommendation

The Tier 1 endpoint additions (Memories artifacts, source-references,
change-history) are the real deferred work. The *data-model commitments*
that receive their data gracefully — `volatilityScore`,
`collectionCompleteness`, `placeARK` on `RecordCommon` — are **shipped**
(nullable, populated to `nil` until the endpoint that fills each is wired).
Still owed on the data-model side: `result_kind` + `hit_count` on
`negative_searches` and the attribution sub-band on `SourceTrustTier`.

Pattern held: **data-model commits early, endpoint integration commits
later** — the columns exist, so no deferred endpoint needs a schema
migration.

---

## 13. Sources

This spec was synthesised from:

- **GEDCOMx specifications** (open standard, github.com/FamilySearch/gedcomx)
  - [fact-types-specification.md](https://github.com/FamilySearch/gedcomx/blob/master/specifications/fact-types-specification.md) — 86 person facts + 14 couple + 10 parent-child
  - [event-types-specification.md](https://github.com/FamilySearch/gedcomx/blob/master/specifications/event-types-specification.md) — 46 event types
  - [GEDCOM X Record Specification](https://github.com/FamilySearch/gedcomx-record) — Field model with Original/Interpreted
  - [Specifications index](http://gedcomx.org/Specifications.html)
- **FamilySearch Developer Center**
  - [API Reference Guide](https://developers.familysearch.org/main/reference/api-reference-guide)
  - [API Resources](https://www.familysearch.org/en/developers/docs/api/resources)
  - [Read Record example](https://www.familysearch.org/en/developers/docs/api/records/Read_Record_usecase)
  - [Read Record Persona example](https://www.familysearch.org/en/developers/docs/api/records/Read_Record_Persona_usecase)
  - [Search Tree Persons example](https://developers.familysearch.org/main/docs/search-for-tree-persons-first-page)
  - [Persistent Identifiers (ARKs)](https://www.familysearch.org/developers/docs/guides/persistent-identifiers)
- **FamilySearch Historical Records**
  - [Collections list (2000+ collections)](https://www.familysearch.org/en/search/collection/list)
- **In-repo**
  - the as-built client + records + enrichment (slices S1–S6b) — client library shipped, git-only
  - `Ancestor Research/Services/Sources/FamilySearch/` — the shipped implementation
  - `Ancestor Research/Services/Research/RecordSource.swift` — protocol contract
  - `Ancestor Research/Services/Research/RecordTypes.swift` — `RecordType` enum + per-type structs
  - `Ancestor Research/Services/Sources/FreeBMDSource.swift` — reference for rate-limit + circuit-breaker patterns

---

## 16. Licensing posture — checklist wording VERIFIED 2026-07-14

> **Amendment (2026-07-14):** the Compatibility Checklist was fetched
> directly (the 2026-07-10 research-phase fetch failures were
> transient). Verbatim findings, replacing the paraphrase-only status
> below:
>
> 1. **Record Hinting**: "The application can show the summary and
>    ratings of the possible matches but no additional information is
>    provided by this API resource." and "The user must be directed to
>    FamilySearch to analyze and attach possible matches because
>    third-party applications do not have adequate access privileges to
>    the FamilySearch historical records collection." — confirms the
>    redirect-to-FS.org rule AND keeps §16.2's tier question live:
>    whether our key grants records search at all is answered
>    empirically by the Change 8 beta probes (client S4 live-smoke,
>    shipped, git-only).
> 2. **Read Compatibility, caching**: "do not store it in local
>    memory, purge the cache if the back button is used and at the end
>    of your user session." Memories: "Temporarily stored FamilySearch
>    data should be eliminated when the browser is closed." — phrased
>    for web apps; the native-app reading is that cached FS **content**
>    must be session-scoped, never durable. This is *stricter* than the
>    §16.1 persist row anticipated: it independently validates
>    pointer-only persistence and rules out any durable per-ARK content
>    cache (§6.6's `gedcomx_json` cache column stays dead).
> 3. **Attribution/linking**: follow the FamilySearch Trademark and
>    Logo Guidelines; link only per the Linking to FamilySearch guide.
> 4. The checklist adds no hint-score rules beyond "summary and
>    ratings" (our §18 lead-ordering-only rule remains self-imposed and
>    stricter) and says nothing about post-termination retention (the
>    signed agreement's data-use-stops-on-termination clause governs).
>
> Net effect: **§16.1's three-verb posture is confirmed as the
> operative rule, not a placeholder.** The persist row is upgraded from
> "conservative planning posture" to "compliance requirement".

(Pre-verification derivation is git-only: the posture was originally
paraphrase-confirmed from 3+ search summaries before the checklist was
fetched verbatim above; the verified §16.1 posture is what binds.)

### 16.1 The posture (until wording says otherwise)

Three distinct verbs, three different rules:

| Verb | Rule |
|---|---|
| **Read/score** | The plugin parses full search responses in memory and runs the 4-gate scorer over them at query time, exactly as for any source. (If responses to our key turn out to carry only match summaries, not full persona detail — an open question — the gates degrade gracefully to the fields present.) |
| **Persist** | **Pointer-only**: collection title, FS match confidence (§18), persona/record ARKs, our own scorer verdicts and derived conclusions. No transcription text, no Original/Interpreted field values, no image waypoints, no GEDCOMx blobs into `page_cache` or a per-ARK content cache. |
| **Display** | Titles + confidence + a **"View on FamilySearch" ARK link-out**. No in-app record viewer for FS content. |

Consequences, all reversible if the wording is more permissive:

1. §5.2's "persist both Original and Interpreted from day one" and
   §5.5's `rawFields["sourceQualifier"]` capture are **suspended for
   FS records** (they were justified by re-fetch cost; under
   pointer-only there is nothing to backfill locally).
2. **Pointer-only evidence representation.** An FS-sourced
   `EvidenceRecord` is legitimate with a near-empty content payload:
   identity (ARKs, §17.1), source description (collection title +
   collection ARK), scorer verdict + gate outcomes, and the typed
   conclusions the pipeline derived at query time. The "never throw
   away a source response" doctrine (`EvidenceRecord.swift:19–26`)
   is amended for FS to: *never throw away the pointer and whatever
   we were licensed to keep*. The pointer **is** the persona.
3. **Evidence Firewall URL-verification carve-out.** The firewall's
   URL-content-verification practice (and the `page_cache` that backs
   it) assumes cited content is cacheable. For FS ARKs where content
   is uncacheable, verification degrades to an **HTTP-level resolution
   check**: the ARK resolves (200, or a 301 chain ending in 200 —
   redirects are sanctioned ARK-resolution behaviour, not errors
   ([persistent-identifiers](https://developers.familysearch.org/main/docs/persistent-identifiers)));
   404/hard failure marks the pointer questionable; 410 marks it dead
   (§15.4). A 301 hop feeds the §17.1 identity trail. No content is
   stored to prove the citation was live — the check result + timestamp
   is the record.
4. Re-verification of an FS-scored conclusion requires a live
   re-fetch — budget it against §15.3 and prefer ETag revalidation
   (§15.5).

### 16.2 Known unknowns (updated 2026-07-14)

- ~~Exact restriction scope~~ **RESOLVED**: the checklist's caching rule
  covers FS **content** (record data fetched from the API — purge at
  session end); pointers (ARKs, collection titles) and our own derived
  conclusions/verdicts are not FS content. §17.2's stash rules stand.
- Whether `/platform/records/personas` responses under our key carry
  full persona detail or match summaries only — **still open**; the
  checklist's "do not have adequate access privileges to the
  historical records collection" (Record Hinting section) makes this
  MORE likely to bind than before. Answered empirically by the
  Change 8 beta probes.
- Which certification tier gates that endpoint — read certification is
  **per-capability**, granted independently (general read vs Record
  Hinting vs Genealogies)
  ([read certification](https://www.familysearch.org/en/developers/docs/certification/read));
  confirm which tier our Innovator status maps to before promising the
  demo query set. Worth asking devsupport@familysearch.org directly
  alongside the redirect_uri registration.

---

## 17. Evidence identity and stash-don't-destroy

### 17.1 ARK/persona columns on `evidence_records` (adopt now)

Decision (R2 information-loss item L3 — flagged high-severity,
cheap-to-fix): persona↔person linkage currently collapses into the
`sourceRecordID` string (`EvidenceRecord.swift:33`). Add two nullable
columns in the next project-DB migration:

```sql
ALTER TABLE evidence_records ADD COLUMN external_persona_id TEXT;  -- bare 'ark:/61903/1:1:XXXX' path
ALTER TABLE evidence_records ADD COLUMN external_record_id  TEXT;  -- bare 'ark:/61903/4:1:XXXX' path
```

Rules:

- **Store the bare `ark:/…` path segment, never the full URL.** FS's
  permanence commitment covers only `ark:/` through the ID segment —
  the domain is explicitly *not* guaranteed stable and query-string
  decorations (access_token, context) are excluded
  ([persistent-identifiers](https://developers.familysearch.org/main/docs/persistent-identifiers)).
  Match and dedupe on the path segment. (§5.7's "store the ARK"
  guidance is hereby narrowed to the path segment.)
- The typed column makes FS ingestion **idempotent** (same persona seen
  twice = same row) and is the join key for the §8.3 ARK-deterministic
  citation matcher — which works under pointer-only licensing too,
  since it matches on identity, not content.
- **301 handling**: when a stored ID resolves as merged (§15.4), append
  the deprecated→survivor mapping to the row's identity trail rather
  than overwriting — deprecated IDs stay resolvable by design (GEDCOMx
  `Deprecated` identifier type) and the user's old bio citations will
  keep using them.
- **Codify the extracted-conclusion invariant as a test**: *an evidence
  record references exactly one source.* GEDCOMx §4 imposes exactly
  this on personas; `EvidenceRecord` already holds it implicitly by
  construction — make it explicit in the test suite.

Scope note: this is the spec-level item only. The full typed
external-identifier lifecycle on AncestorKit (`externalIDs`
deprecation chains — R2 evolution E1) is a schema programme with its
own spec change number elsewhere. A source spec never drives
AncestorKit schema.

### 17.2 Stash-don't-destroy (interim rules until E2/E3 land elsewhere)

Two lossy flattenings the parser must not make silently:

- **Name conclusions (L2).** GEDCOMx serves multiple `Name`
  conclusions per persona (BirthName / MarriedName / Nickname types,
  multiple NameForms with BCP-47 lang tags). Our model flattens to
  given/surname + one marriedSurname/nickName — WikiTree ingest
  already demonstrates the data-loss failure mode. Interim rule:
  **whatever name data we are licensed to persist (§16.2), persist
  completely** — variants beyond the flattened projection go verbatim
  into `rawFields["names.json"]` on the evidence payload. If licensing
  confirms persona name fields are pointer-only, the rule still binds
  the display projection: never render a flattened name as if it were
  the only one FS asserted. Promotion to typed repeatable name forms
  is evolution E2, specced elsewhere.
- **Place authority IDs (L8).** FS place references carry a normalized
  name plus a place ID/ARK. §6.7 already commits
  `RecordCommon.placeARK: String?` — reaffirmed: **stash now** (same
  bare-path rule as §17.1), integrate never *in this spec*. Promotion
  to first-class place-authority records (registration districts,
  temporal jurisdiction) is evolution E3, riding the gazetteer
  expansion, specced elsewhere.

The general rule both instances follow: when the official API offers
structure our model cannot yet hold, the plugin **stashes it losslessly
where licensing permits and drops it visibly where it doesn't** — it
never destroys silently.

---

## 18. Hint/match-score rule (invariant)

**An FS hint/match score is a lead-ordering signal only** — it never sets a
`SourceTrustTier`, enters any of the 4 gates or the scorer verdict, or counts
toward convergence. Enforced in code (the FS match confidence rides in
`rawFields["fsMatchScore"]`, which `RecordScorer.classify` never reads);
pinned by the `fsMatchScoreIsInertToTheScorer` invariant test (client S6b,
shipped, git-only).

---

## 19. FS enrichment-polish follow-ups (deferred)

Absorbed from the retired client spec (client library shipped, git-only).
Small enhancements on the shipped enrichment surface — none is a blocker.

1. **Sort the lead/triage list by `rawFields["fsMatchScore"]`** (§18
   consumer). Size S; no deps — the score is already stored on the record
   ("deposited-but-unwired"). Cheapest FS item; completes the §18 story.
   Do FIRST.
2. **Map/skip attribute-only FS personas** — Nationality/Occupation-only
   facts currently become low-value "parish" leads. Size S; after #1.
3. **Live-confirm + firm up the FS Memories response shape** (minimally
   modelled today, not live-confirmed). Size S; needs a Beta call against a
   person that has memories. Low urgency.
4. **Remove the unused `FamilySearchHint`/`recordHints` DTO surface**,
   superseded by the `SourceRecord` path. Size XS; opportunistic dead-code
   cleanup.
