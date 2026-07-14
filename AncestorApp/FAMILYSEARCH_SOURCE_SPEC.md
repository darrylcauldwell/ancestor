# FamilySearch Source — Coverage Specification

> **Deferred (2026-05-25):** Auth flow (WKWebView + Keychain + Settings)
> is shipped. The content surface specified below is deferred until
> `ENGINE_FOUNDATION_SPEC.md` ships. Reason: adding another source
> into a scorer that over-claims for thin profiles just produces more
> records to mis-classify. Foundation first.

Status: drafting · Author: derived from API/website-backend research, 2026-05-19

> **Amendment (2026-07-11) — official-API pivot. Status: Proposed — awaiting review.**
> FamilySearch accepted the developer into its Beta Program on 2026-07-10
> (Innovator Solution Provider, non-production API access). The signed
> developer agreement's §15 scraping ban makes the §2.1 cookie transport
> **contractually prohibited**, not merely fragile. §§14–19 (appended)
> carry the pivot: migration posture (OAuth2+PKCE, loopback redirect),
> official-API protocol mechanics, licensing posture (pending
> agreement-wording confirmation), evidence-identity columns, the
> hint-score rule, and Beta read-leg demo acceptance criteria.
> Cookie-era content below is retained for the record with superseding
> notes inline; the search/parse/score design (§§3–8) carries over
> unchanged. Supersession index at §14.3.

This document specifies what the in-app FamilySearch source plugin will expose,
how it maps onto the existing pipeline, and which app features it unlocks.
It is the input to `FamilySearchSource.swift` and related work.

The auth flow (WKWebView capture + Keychain persistence + Settings affordance)
already landed; see `Services/Sources/FamilySearchAuth/`. This spec covers the
*content* surface, not auth.

---

## 1. Why this matters now

Three load-bearing observations from the V2 work. The ordering here
matters: pillars 1 and 2 stand alone and deliver value the moment any
FS records flow into the pipeline; pillar 3 depends on additional
matcher work (§5.8.5 of the V2 spec) and is correspondingly more fragile.
First-cut justification should rest on pillars 1 and 2 — pillar 3 is
the bonus that the matcher will unlock later.

1. **Convergence depth.** FamilySearch's England & Wales BMD records are
   independent transcriptions of the same GRO indexes FreeBMD covers.
   The `ConvergenceEngine` today undercounts independence because a
   record only has one transcription source. FamilySearch as a parallel
   transcription turns single-source citations into two-source
   triangulations — measurable confidence uplift across the tree the
   moment FS records start scoring alongside existing sources, no
   matcher needed.

2. **Pre-1837 coverage cliff.** FreeBMD starts 1837 (civil registration).
   Pre-1837 vital records are parish registers, which only FamilySearch
   (and FreeREG to a much lesser extent) covers programmatically. Every
   ancestor born before 1837 currently dead-ends in the pipeline — adding
   FamilySearch extends the tree's reachable depth by another 1–2
   generations on most lines, no matcher needed.

3. **Citation coverage gap (matcher-dependent).** ~50% of the user's
   WikiTree bio citations are FamilySearch references (the WikiTree-twin
   survey in this session found FreeBMD and FamilySearch dominating,
   with FamilySearch slightly more common). Without a FS source plugin
   *and* the §5.8.5 citation matcher both working, the V2 eval harness's
   evidence-reproduction-rate metric measures a circular thing — "does
   the pipeline surface evidence from the same seven sources it already
   cites?" — and remains uninterpretable. This pillar is the most
   fragile of the three because it requires *both* the FS source (this
   spec) and a working prose-citation matcher (§5.8.5, separately at
   ~70% precision tops). De-risking: pillars 1 and 2 above deliver the
   first-cut justification on their own; if the matcher under-delivers,
   the FS source plugin still earns its keep.

### 1.1 Definitions

- **WikiTree twin** — the local NetworkX-backed JSON mirror of the
  user's WikiTree tree, synced via `python -m wikitree.twin sync`.
  453 profiles as of 2026-04-25. The citation survey referenced
  throughout this spec was run against this snapshot.
- **bio citation** — a bullet under a profile's `== Sources ==`
  section in WikiTree's wiki-markup bio. Format varies; ~50% are
  FamilySearch references, ~half of which carry an ARK identifier.

### 1.2 Stacked-risk acknowledgement

Pillar 3 depends on the §5.8.5 matcher; the matcher's ARK-deterministic
path depends on this FS source; this FS source depends on cookie auth
holding (or, post-approval, OAuth working). The full eval-harness story
therefore has three serial dependencies. Pillars 1 and 2 (above)
intentionally don't depend on the matcher — they deliver value on the
first FS-enabled research run regardless of matcher status.

---

## 2. API surface in scope

FamilySearch has two parallel surfaces serving the same data model
(GEDCOMx); we will use whichever the user has access to.

### 2.1 Website backend (cookie-auth, available now)

> **Superseded (2026-07-11, §14):** this transport is now contractually
> prohibited — the developer agreement's §15 scraping ban covers
> cookie-authenticated calls to the website backend
> (`FamilySearchSource.swift:75` still points here today). Retained for
> the record; do not implement further. Official-API equivalent:
> `GET /platform/records/personas` (§15.7).

| Endpoint | Method | Purpose |
|---|---|---|
| `/service/search/hr/v2/personas` | GET | Historical-records search across all collections |

This is what the Python plugin uses. Returns GEDCOMx with `entries[]`,
each carrying `content.gedcomx.{persons, relationships, sourceDescriptions}`.

Auth: session cookies (`fssessionid`, `JSESSIONID`, ...).

### 2.2 Public Platform API (OAuth, available post-App-Store-approval)

> **Amended (2026-07-11, §14):** the gate was never App Store approval —
> it was FamilySearch partner acceptance, which landed 2026-07-10. This
> surface is available **now** on Beta (`apibeta.familysearch.org`,
> §15.1) and is the only permitted transport. Endpoint table below
> stands; the search endpoint is `GET /platform/records/personas`
> (§15.7), matching the `/platform/records/...` rows here.

| Endpoint | Method | Purpose |
|---|---|---|
| `/platform/records/records/{recordId}` | GET | Read a full record by its ARK suffix |
| `/platform/records/personas/{personaId}` | GET | Read a persona (one person within one record) |
| `/platform/records/collections` | GET | Collection metadata |
| `/platform/tree/search` | GET | Search the user-contributed Family Tree (different from historical records) |
| `/platform/tree/persons/{pid}/matches` | GET | FamilySearch's own match suggestions for a tree person |
| `/cv/{vocab-id}` | GET | Controlled vocabulary lookup (fact types, place types, etc.) |

Auth: `Authorization: Bearer <token>` via OAuth 2.0.

### 2.3 Auth-transition contract

`FamilySearchSource` should treat auth as a transport detail, not a
behaviour change. Define a `Credential` sum type:

```swift
enum FamilySearchCredential: Sendable {
    case cookieSession(header: String)      // captured via WKWebView
    case bearerToken(String)                 // post-OAuth approval
}
```

The search/parse/score logic above this is identical. When the user's
App Store / Partner approval lands, only the credential acquisition and
the URL prefix (`/service/search/hr/v2/...` → `/platform/...`) change.
This is the load-bearing reason to invest in coverage work now: every
hour spent on search-parameter design and response parsing carries over
unchanged.

> **Amended (2026-07-11, §14):** the bet paid off — partner approval
> landed and the change is exactly the predicted prefix swap. But the
> `.cookieSession` case is **removed**, not kept as fallback: the
> agreement's §15 scraping ban means there is no lawful cookie
> transport to fall back to. `FamilySearchCredential` collapses to
> the bearer-token case (OAuth2+PKCE acquisition per §15.2); the
> `FamilySearchAuth/` WKWebView capture stack
> (`FamilySearchCookieStore`, `FamilySearchAuthView`,
> `FamilySearchTestProbe`) is retired.

### 2.4 Excluded from scope

- **Family Tree write API** (creating/editing tree persons, conclusions,
  source references). The Evidence Firewall already prohibits writing
  directly to profiles; FS Tree writes would compound the issue.
  *Future direction worth not forgetting*: "attach source to FS tree
  person" as a soft-write would contribute the app's verified findings
  back to FS community knowledge as a side effect, plausibly without
  violating the firewall (it writes to FS, not to the app's tree).
  Out of V2 scope but flagged so it doesn't drop off the radar.
- **Memories upload** (photos, stories, documents). Not pipeline-relevant.
- **DNA matching**. Private to the user, separate auth, out of V2 scope.
- **Discussions / forum threads**. Conversational, not evidentiary.

---

## 3. GEDCOMx taxonomy and RecordType mapping

GEDCOMx defines three controlled vocabularies that govern what FamilySearch
returns: **fact types** (86), **event types** (46, mostly overlap with
facts), and **relationship types** (small enumeration).

### 3.1 Person fact types (86 total)

Grouped by what they tell the pipeline:

**Already-mapped to existing `RecordType` cases**

| GEDCOMx fact | Current RecordType | Notes |
|---|---|---|
| Birth, BirthNotice | `.birth` | Plus christening as evidence-of-birth |
| Death | `.death` | |
| Burial, Cremation, Funeral | `.burial` | Cremation/Funeral currently dropped |
| Baptism, Christening, AdultChristening, Blessing | `.baptism` / `.christening` | Blessing currently dropped |
| Census, Residence | `.census` | Residence is broader (any address fact) |
| Probate, Will | `.probate` | Will is a new finer-grained case |
| MilitaryService, MilitaryDischarge, MilitaryAward, MilitaryDraftRegistration, MilitaryInduction | `.military` | All collapse to `.military` today |

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

**Map to a new `LifeEvent.attributes` field rather than RecordType**

These describe *attributes* of a person rather than discrete record events:

`MaritalStatus`, `Occupation` (as field), `Religion`, `Nationality`,
`Ethnicity`, `Race`, `Caste`, `Clan`, `Tribe`, `PhysicalDescription`,
`Language`, `Heimat`, `NumberOfChildren`, `NumberOfMarriages`,
`NationalId`, `GenerationNumber`.

Recommendation: extend the existing `RecordCommon.rawFields: [String: String]`
to hold these, keyed by GEDCOMx fact-type suffix. Avoids enum sprawl;
the matcher and hypothesis engine can opt-in to specific keys as needed.

**Deferred**

`Heimat`, `AncestralHall`, `AncestralPoem`, `Yahrzeit` — culturally
specific facts that won't appear in this user's UK-focused tree. Parse
and store in `rawFields` for completeness; no first-class handling.

### 3.2 Couple-relationship fact types (14 total)

| GEDCOMx fact | Current/proposed mapping |
|---|---|
| Marriage | `.marriage` (already) |
| MarriageBanns | `.marriage` with `subtype: .banns` (or new `.marriageBanns`) |
| MarriageLicense | `.marriage` with `subtype: .license` |
| MarriageContract | `.marriage` with `subtype: .contract` |
| MarriageNotice | `.marriage` with `subtype: .notice` |
| CommonLawMarriage | `.marriage` with `subtype: .commonLaw` |
| CivilUnion, DomesticPartnership | `.marriage` with `subtype: .nonTraditional` |
| Divorce | new `.divorce` |
| DivorceFiling | new `.divorce` with `subtype: .filing` |
| Annulment | new `.divorce` with `subtype: .annulment` (semantic stretch but reasonable) |
| Engagement | new `.engagement` |
| Separation | new `.separation` |
| NumberOfChildren | extension field, not record type |

The Python plugin currently maps MarriageBanns and MarriageRegistration
into the same bucket and drops everything else. Spec change: introduce a
`MarriageSubtype` enum on the existing `MarriageRecord` to preserve
which kind of marriage record this is (matters for trust tiering — a
banns reading is weaker evidence than a registered ceremony).

### 3.3 Parent-child relationship types (10)

| GEDCOMx fact | Mapping |
|---|---|
| BiologicalParent | default; no marker needed |
| AdoptiveParent | new `RelationshipKind.adoptive` |
| FosterParent | new `RelationshipKind.foster` |
| StepParent | new `RelationshipKind.step` |
| GuardianParent | new `RelationshipKind.guardian` |
| SurrogateParent | new `RelationshipKind.surrogate` |
| SociologicalParent | new `RelationshipKind.sociological` |
| ChildOrder | order metadata; on the relationship not as a kind |
| EnteringHeir, ExitingHeir | metadata; not currently load-bearing for V2 |

The app's existing `Relationship` model is biologically-assumed. The
expansion here is non-trivial — affects cluster matching (a foster
relationship to a "father" shouldn't pull a child's surname). Mark this
as *deferred from first cut*: detect and store the kind, but treat
non-biological the same as biological in the deterministic engines for
now. Promote to first-class once we have eval-corpus evidence of where
the conflation harms outcomes.

### 3.4 Event vs fact (the conceptual model wrinkle)

GEDCOMx has both "fact" types (86) and "event" types (46, with overlap).
The semantic difference: a *fact* is a data point on a single subject
(person.facts[]); an *event* is a first-class entity with multiple
participants (event.participants[]). FamilySearch search results typically
return facts on persons, not standalone events. We mirror that:
parse `person.facts[]` exhaustively; ignore the rarely-populated
`events[]` collection unless it shows up in profiling.

### 3.5 GEDCOM 5.5/7.0 ↔ GEDCOMx translation

The user's tree exports as GEDCOM 5.5.1 (the `twin_to_gedcom.py` exporter
this session produced). FamilySearch serves GEDCOMx. The §5.8.5 citation
matcher must canonicalise across both formats. Make the translation
table explicit so the matcher and the FS parser agree on the same
canonical fact-key shape.

| GEDCOM 5.5.1 tag | GEDCOMx fact URI suffix | Canonical fact-key kind |
|---|---|---|
| BIRT | Birth | `birth(subject, year, place)` |
| CHR | Christening | `christening(subject, year, place, parish?)` |
| BAPM | Baptism | `baptism(subject, year, place)` |
| DEAT | Death | `death(subject, year, place)` |
| BURI | Burial | `burial(subject, year, place)` |
| CREM | Cremation | `cremation(subject, year, place)` |
| MARR | Marriage | `marriage(subject1, subject2, year, place)` |
| MARB | MarriageBanns | `marriage(...).subtype=.banns` |
| MARL | MarriageLicense | `marriage(...).subtype=.license` |
| DIV | Divorce | `divorce(subject1, subject2, year, place)` |
| CENS | Census | `census(subject, year, place, householdARK?)` |
| RESI | Residence | `residence(subject, year, place)` |
| OCCU | Occupation | `occupation.attribute` (not record-key-eligible) |
| EMIG | Emigration | `emigration(subject, year, fromPlace, toPlace?)` |
| IMMI | Immigration | `immigration(subject, year, fromPlace?, toPlace)` |
| NATU | Naturalization | `naturalization(subject, year, place)` |
| PROB | Probate | `probate(subject, year, jurisdiction)` |
| WILL | Will | `will(subject, year, jurisdiction)` |

Plus the inverse mapping for re-emitting matcher-canonicalised facts
back as GEDCOM 5.5.1 tags when needed (e.g. exporting reconciled tree
state).

Mappings missing from the table fall through to an `unmappedFact` key
preserved in `rawFields` — same defer-enum-sprawl rule as §9.1.

---

## 4. Search axes

### 4.1 Parameters used today (Python plugin)

```
q.surname, q.givenName
q.birthLikePlace, q.birthLikeDate.from, q.birthLikeDate.to
q.deathLikePlace, q.deathLikeDate.from, q.deathLikeDate.to
q.residenceLikePlace, q.residenceDate.from, q.residenceDate.to
q.marriageLikePlace, q.marriageLikeDate.from, q.marriageLikeDate.to
q.spouseSurname, q.spouseGivenName
q.fatherSurname, q.fatherGivenName
q.motherSurname, q.motherGivenName
offset, count
m.defaultFacets=on
```

### 4.2 Parameters to add

Found in the official-API tree search but not in the Python plugin:

| Parameter | Purpose | Value notes |
|---|---|---|
| `q.sex` | Gender filter | `Male`, `Female` |
| `q.motherBirthLikePlace` | Mother's birth place | Useful for disambiguating mothers with common names |
| `q.motherBirthLikeDate.from/.to` | Mother's birth date range | |
| `q.fatherBirthLikePlace` | Father's birth place | |
| `q.fatherBirthLikeDate.from/.to` | Father's birth date range | |
| `q.spouseBirthLikePlace`, `q.spouseBirthLikeDate.from/.to` | Spouse birth filter | |
| `q.recordType` | Filter by GEDCOMx record type | E.g. only marriage records |
| `q.collectionId` | Filter by specific collection | E.g. only the 1939 Register |
| `q.anyPlace`, `q.anyDate.from/.to` | Any life event in this place/year | Useful for "lived in Derbyshire at some point" queries |

### 4.3 Wildcards and modifiers

The official API supports modifiers on each `q.<field>` parameter:

- **Wildcards**: `q.surname=Cauld*` or `q.givenName=J?hn` (asterisk +
  question mark; same shape as the search website's advanced UI).
- **Exact vs fuzzy**: append `~` to a name parameter to opt out of
  phonetic / soundex matching (`q.surname=Cauldwell~`).
- **Cardinality**: query parameters have a "must / should / not" axis
  exposed as separate parameters in some docs (e.g. `q.surname.exact=`,
  `q.surname.contains=`). Confirm during implementation by probing live.

The Swift `search()` interface should expose:

```swift
struct FamilySearchQuery {
    enum Match { case fuzzy, exact, wildcard }
    var surname: (String, Match)?
    var givenName: (String, Match)?
    var sex: Sex?
    // ... life events with Match per name field
    var collectionFilter: String?      // e.g. specific collection id
    var recordTypeFilter: RecordType?  // server-side record-type filter
    var count: Int = 20
    var offset: Int = 0
}
```

Plus a translation layer that converts `RecordQuery` (the app's existing
query type) into `FamilySearchQuery`, fanning out across multiple axes
when the query covers several event types.

---

## 5. Response shape and field mapping

### 5.0 Multi-persona records — the data-flow shape

**One search hit → N candidate records, not one.** A FamilySearch
"persona" is one person within one source document; most documents
have multiple personas in `content.gedcomx.persons[]`:

- A 1901 census household: head + spouse + children + servants =
  often 5–10 personas in one persons[] array.
- A marriage record: bride + groom + (sometimes) both fathers = 2–4
  personas.
- A parish baptism: child + mother + father = 3 personas.

The Python plugin's `_parse_entries` treats `persons[0]` as the primary
subject and folds the rest into a `household: [...]` field — single
record output per search hit. **This is wrong for the Swift port.**
Every persona is a candidate SourceRecord against the pipeline's scorer:
the head's census record, the wife's census record, each child's census
record are all separately scoreable identity hypotheses for whichever
profile the pipeline is researching.

Implication for the parser:

```
parseEntry(gedcomx) -> [SourceRecord]
  // returns N records, one per persona, each carrying:
  //   - that persona's facts (date, place, fields)
  //   - that persona's name + gender
  //   - the SAME source description (collection title, collection ARK)
  //   - household-role context from relationships[] (parent, spouse,
  //     sibling, child) for the OTHER personas in the record
```

The relationships[] array stays as enrichment metadata, not the
primary record output. A `.censusHouseholdComposition` hypothesis kind
(§8.1) consumes it post-extraction to verify spouse/child consistency.

**Pipeline-impact note**: this multiplies candidate volume per FS
search hit by typical household size (3–8×). The cluster-review
surface will feel different on the first FS-enabled research run than
on the seven existing sources, where 1-to-1 search-hit-to-record is
the norm. ClusteringEngine's "When in doubt, split" invariant
absorbs this gracefully but the cluster count per profile rises.
Worth a brief soak test on a known profile before promoting FS to
default-enabled in research config.

### 5.1 Top-level response

```jsonc
{
  "entries": [ ... ],    // search hits
  "results": 2318797,    // total matching records (NB: huge for common surnames)
  "facets": { ... }      // breakdown by collection / record type, when m.defaultFacets=on
}
```

Per-entry structure:

```jsonc
{
  "content": {
    "gedcomx": {
      "persons": [ ... ],
      "relationships": [ ... ],
      "sourceDescriptions": [ ... ]
    }
  },
  "score": 0.87,          // relevance score
  "id": "...",            // entry identifier (not the persona ARK)
  "title": "..."          // collection title / short label
}
```

### 5.2 Person field extraction

```jsonc
{
  "id": "MXYZ-1234",      // persona identifier — becomes ARK suffix
  "names": [
    {
      "nameForms": [
        { "fullText": "John Cauldwell",
          "parts": [
            {"type": ".../GivenName", "value": "John"},
            {"type": ".../Surname",   "value": "Cauldwell"}
          ]
        }
      ]
    }
  ],
  "gender": { "type": "http://gedcomx.org/Male" },
  "facts": [
    { "type": "http://gedcomx.org/Birth",
      "date": { "original": "12 Mar 1875", "formal": "+1875-03-12" },
      "place": { "original": "Worksop, Notts.", "normalized": [{"value": "Worksop, Nottinghamshire, England"}] }
    },
    ...
  ],
  "fields": [
    { "type": "http://familysearch.org/types/fields/Age", "values": [{"text": "25"}] },
    { "type": "http://familysearch.org/types/fields/RelationshipToHead", "values": [{"text": "Son"}] }
  ],
  "principal": true        // is this person the subject of the record?
}
```

Field mapping rules for the Swift parser:

| GEDCOMx path | Swift target |
|---|---|
| `persons[].id` | `RecordCommon.id` + ARK construction |
| `persons[].names[0].nameForms[0].fullText` | `RecordCommon.name` |
| `persons[].names[0].nameForms[0].parts[type=GivenName]` | `RecordCommon.givenName` |
| `persons[].names[0].nameForms[0].parts[type=Surname]` | `RecordCommon.surname` |
| `persons[].gender.type` | New `RecordCommon.sex: Sex?` |
| `persons[].facts[].type` | Drives record-type selection (birth/death/etc.) |
| `persons[].facts[].date.original` | Per-record `date` string |
| `persons[].facts[].date.formal` | Per-record `formalDate` (parseable: +1875-03-12) |
| `persons[].facts[].place.original` | Per-record `place` string |
| `persons[].facts[].place.normalized[0].value` | Per-record `normalizedPlace` |
| `persons[].facts[].place.normalized[0].description` | Place ARK — feeds Place authority lookup |
| `persons[].fields[].values[type=Original]` | `rawFields["<fieldTypeSuffix>.original"]` — verbatim from the document |
| `persons[].fields[].values[type=Interpreted]` | `rawFields["<fieldTypeSuffix>.interpreted"]` — FS's parsed/standardised reading |
| `persons[].fields[]` (no value-type or single value) | `rawFields[fieldTypeSuffix]` — fall-through key when there's only one value |
| `persons[].principal` | Mark the primary subject in multi-person records |

**Why persist both Original and Interpreted from day one**: even if the
scorer uses only Interpreted at first cut, storing both is two extra
string-stores per field — trivial. Backfilling later requires
re-fetching the record, which costs rate-limit budget. Keeping both
also enables a future `.transcriptionAmbiguity` hypothesis kind that
fires when Original differs significantly from Interpreted (suggests
the transcriber made an interpretive call worth surfacing for human
review).

### 5.3 Relationship extraction

```jsonc
{
  "type": "http://gedcomx.org/Couple",   // or ParentChild
  "person1": { "resourceId": "MXYZ-1234" },
  "person2": { "resourceId": "MABC-5678" },
  "facts": [
    { "type": "http://gedcomx.org/Marriage", "date": {...}, "place": {...} }
  ]
}
```

Extraction:
- Couple → enrich marriage records with date/place from the relationship
- ParentChild → tag household members with their role
  (Parent → parent; siblings → sibling via shared FAMC inference)
- Detect and store relationship `type` URI for non-biological cases
  (AdoptiveParent etc.) even when treated as biological by the engines

### 5.4 Source description

```jsonc
{
  "id": "SD-1",
  "about": "https://familysearch.org/ark:/61903/3:1:KW8W-RF8",  // collection ARK
  "titles": [{"value": "England, Marriages, 1538-1973"}],
  "citations": [{"value": "..."}],
  "descriptorRef": "...",
  "sortKey": "..."
}
```

The collection ARK is more important than the collection title for the
matcher — it's the stable identifier for cross-source citation matching
when the user's bio cites the same collection in different language.

### 5.5 Source-reference qualifiers (image-pixel-region anchors)

GEDCOMx's `SourceReference` carries optional `qualifier[]` entries that
locate the persona within the source document at sub-record granularity:

| Qualifier type | Means | Example use |
|---|---|---|
| `http://gedcomx.org/RectangleRegion` | Pixel region on a document image | "The registrar's handwriting on this row of this page" |
| `http://gedcomx.org/CharacterRegion` | Character offset in a text transcription | Position within a transcribed will or court record |
| `http://gedcomx.org/TimeRegion` | Time offset in audio/video | Mostly irrelevant for genealogy, parse-but-ignore |

The `RectangleRegion` qualifier is the transformational one for
verification UX. When FS surfaces a record like "John Cauldwell, age 4,
1881 census, RG11/3450/89", the registrar's actual handwriting for that
row sits at a specific rectangle on the digitised page image. Capturing
the qualifier means a citation card can later deep-link to a viewer
that highlights *that exact rectangle* on the source image — the user
verifies pixel-accurately rather than against a transcription.

Capture from day one in `rawFields["sourceQualifier"]` as a JSON-encoded
struct: `{type, x, y, width, height, imageARK}`. UI to surface this is
deferred (post-first-cut), but the data must be in the pipeline from
the start — refetching to backfill is rate-limit-expensive.

### 5.6 Python plugin lessons audit

> **Amended (2026-07-11, §14):** items 4 (Safari-UA/Referer header
> spoofing) and 5 (cookie-expiry handling) are moot — both are
> cookie-transport survival tactics, and UA spoofing against the
> official API would itself smell like the scraping the agreement
> bans. Items 1–3 and 6 (fact-URI suffix stripping, household
> resolution, ARK construction, response edge cases) still stand:
> they are GEDCOMx-shape lessons and the official API serves the
> same data model.

The reference implementation (`sources/familysearch.py`, 502 lines) has
accumulated knowledge worth preserving in the Swift port. Before
writing FS source code, do an explicit audit pass:

1. **Read every regex / string-match in `_parse_entries`** and confirm
   the Swift parser matches the same fact-type URI suffixes. Particularly
   the `ftype = fact.get("type", "").split("/")[-1]` pattern — the
   plugin strips the URI prefix to leave bare suffix names like "Birth",
   "BirthRegistration", "MarriageBanns". The Swift parser must do the
   same or it'll miss every fact.
2. **Note the household-from-relationships pattern** (`_parse_entries`
   lines 397–446): the plugin uses `relationships[].type == "ParentChild"`
   and `"Couple"` + `resourceId` resolution to tag household roles. The
   Swift port reuses this logic but applies it to N candidate records
   (per §5.0) not the single primary subject.
3. **ARK construction** (`_parse_entries` line 385): the plugin assumes
   `1:1:<id>` for persona ARKs. Confirm this still holds — different
   `<type>:<n>:` prefixes encode different resource kinds (§5.7).
4. **HTTP headers from `__init__`**: the Safari-UA + Referer header is
   load-bearing. FS rejects default URLSession UAs as bots. The
   `FamilySearchTestProbe` we already wrote uses these — keep the same
   set in the source plugin.
5. **Cookies-expire-every-1-to-2-hours assumption**: the plugin doesn't
   know about cookie expiry, just retries; the Swift port must
   distinguish "no cookies" (auth required) from "cookies invalid"
   (re-auth required) from "throttled" (back off) via HTTP status code
   and content inspection.
6. **Edge cases the plugin handles silently**: a search may return
   `entries[]` empty even with hits (faceted query interactions); a
   record may have `persons[]` empty (citation-only); a fact may have
   `date` but no `place` (or vice versa). The Swift parser needs to
   handle each gracefully — port the plugin's tolerance.

Output: a short `FamilySearchSource.lessons.md` adjacent to the Swift
source file capturing these as inline comments where appropriate, and
a fixture file (§9.4) per archetype.

### 5.7 ARK construction and persistence

FamilySearch ARKs:
```
https://familysearch.org/ark:/61903/<type>:<n>:<id>
```

The `<type>:<n>` segment encodes what kind of resource:
- `1:1:` — persona (default for search results)
- `3:1:` — collection / source description
- `4:1:` — record

For our purposes the persona ARK is what we attach to records; record-level
ARKs come from the `sourceDescriptions[].about` field when we follow a
search hit to its full record.

ARKs are guaranteed persistent — store them and they remain valid years
later. This is the deterministic anchor for the citation matcher: bio
cites "ARK p_10268864404" → matcher canonicalises to
`familysearch_persona(10268864404)` → search results carrying the same
ARK match by identity, no fuzzy comparison needed.

---

## 6. Beyond search — endpoints worth wrapping

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

Cookie-mode equivalent: the website backend has a similar URL pattern
under `/service/search/...` that requires probing during implementation
(not documented publicly). Worst case we fall back to scraping the
public record page HTML.

> **Superseded (2026-07-11, §14):** both the cookie-mode probe and the
> scrape-the-HTML fallback are prohibited under the developer
> agreement's §15. The OAuth endpoint above is the only path. Note
> also that detail-fetch persistence is constrained by the §16
> licensing posture until the agreement wording is confirmed.

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

This data is **load-bearing for the SourceTierRegistry**. Today the
registry tiers FamilySearch as a single source; in reality "FamilySearch
England, Marriages 1538-1973" (parish register transcription) deserves
`.transcription` tier while "FamilySearch Community Trees" deserves
`.community` tier. Without collection metadata we cannot tier records
correctly.

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

### 6.5 Tree Person Matches (subscribe, don't poll)

`GET /platform/tree/persons/{pid}/matches` (OAuth)

If the user has a FamilySearch tree, this returns FamilySearch's own
ML-driven match suggestions for each person. We could mirror these as
high-confidence candidates in our pipeline — they're work FamilySearch
has already done.

**Subscription, not poll.** The endpoint returns hints as an Atom feed
with `published` timestamps. That makes it natively subscribable: per
tree person, record `last_seen_at`, on subsequent runs only fetch hints
newer than that. This is the antidote to G2 (stall on no-result) for
the long tail — once a person is stuck in the pipeline, FS's hint feed
quietly accrues new matches as their corpus grows. The pipeline can
then resurface "since we last looked, 3 new potential matches have
appeared." Essentially free continuous discovery, costing one HTTP call
per tree person per re-run.

**Decision 7 re-evaluation trigger.** The V2 spec's Decision 7 committed
to local MLX (rather than outbound API) for T9 subjectIdentity
disambiguation specifically to preserve App Store posture and minimise
disclosure. The FS integration partially invalidates that reasoning:
once we're sending the user's ancestor names/dates/places to FS for
record search, sending the same bundle to FS's *Person Matches by
Example* endpoint to ask "which of your tree persons matches?" is a
small incremental disclosure — and the matching is against actual
genealogical corpus, not a local model reasoning over the records we
happen to have fetched. Worth flagging here so it doesn't get lost:
**this triggers a V2-spec Decision 7 revisit.** The FS spec doesn't
make the V2 change unilaterally; the deliberation belongs in V2.

Caveat: requires the user to have populated a FamilySearch tree, which
may not be their workflow. Deferred to a later session; the cost/benefit
is high but the prerequisite is uncertain. See §13 for the tiered
roadmap that schedules this work properly.

### 6.6 Caching taxonomy

FamilySearch records *content* is functionally immutable (a 1881 census
entry doesn't change). FamilySearch *result sets* are emphatically not
— new collections, re-indexing, and corpus growth all shift which
records exist or surface for a given query over time. Conflating the
two destroys the long-tail discovery property that makes FS integration
worthwhile in the first place (a cached "no hits" from a year ago
silently hides newly-indexed records). The cache must distinguish
these explicitly.

| Endpoint                          | Cache | TTL        | Why |
|---|---|---|---|
| Per-ARK record fetch              | Permanent (or 1y safety) | ~indefinite | Record content immutable; rare withdrawals are the only risk |
| Search results (positive, ≥N hits) | TTL'd  | ~90 days   | New indexing adds hits gradually |
| Search results (zero / sparse)    | TTL'd  | ~30 days   | The "first hit appearing" case is exactly the long-tail value |
| Search results (truncated at max) | TTL'd  | ~30 days   | More records behind the truncation; re-running matters |
| Collections metadata              | TTL'd  | ~30 days   | Slow-changing but new collections do appear |
| Place authority                   | Permanent (or 1y) | ~indefinite | Boundary changes are glacial |
| Tree Person Matches               | TTL'd, short | ~7–14 days | FS's own ML refreshes as their corpus grows — this is the hint-feed value |
| Controlled vocabulary             | Permanent (or 1y) | ~indefinite | Hardcoded in Swift anyway, online refresh as safety net |

**The negative/sparse asymmetry is the load-bearing nuance.** A cached
"zero hits" result is the worst failure mode because (a) it's silent
— the pipeline just doesn't surface anything new — and (b) it's
exactly the case where long-tail value is highest. Shorter TTL for
empty results corrects this without spending rate budget on results
that genuinely won't change much.

**Unify with `negative_searches`.** The existing v2 migration table
(`negative_searches`: `profile_id, source_id, record_type, searched_at,
search_params`) is functionally the same mechanism as the search-result
cache here. Both record "we ran query Q against source S and the result
was R as of time T." Generalisation path:

```sql
ALTER TABLE negative_searches ADD COLUMN result_kind TEXT;  -- 'zero' | 'sparse' | 'positive' | 'truncated'
ALTER TABLE negative_searches ADD COLUMN hit_count INTEGER; -- 0 for zero, N for positive/sparse, would-be-N for truncated
-- TTL is computed at read time from `searched_at` + per-`result_kind` policy
```

Rename to `search_result_cache` once columns settle. Single mechanism;
TTL semantics derived from `result_kind`. (Implementation may choose
extend-existing vs parallel-new-table — the data-model commitment is
the four-way state and the TTL-by-kind policy.)

**Per-ARK record cache** is a separate table: `familysearch_record_cache
(ark TEXT PRIMARY KEY, gedcomx_json TEXT, fetched_at DATETIME)`. No
TTL on the data; `fetched_at` exists for replay-debugging only. Cache
is functionally an immutable lookup with a probabilistic "1y safety"
refresh that the user can also bypass manually (below).

**Collection completeness weights negative-search evidence.** When the
parser captures `CollectionContent.completeness` (a 0–1 score on each
collection's coverage of its declared scope — see §5.7), the
`negative_searches` row carries it. Then "we looked in a 90%-complete
collection and found nothing" is materially stronger evidence than
"we looked in a 40%-complete collection." The scorer's
`.unavailable`-evidence weighting consumes this directly. No new
hypothesis kind needed; just richer negative-search semantics.

**Cache-bypass affordance for the user.** "I know this person should
be in FS, run a fresh search even if we have a recent cached result."
Genealogy users have moments where they have new context that makes
them want to re-run — a newly-discovered middle name, a corrected
birth-place, an unconfirmed alternate surname. Without a bypass they
wait out the TTL; with a bypass the cache stays correct for the bulk
of cases and the user can override when they need to. Surface as:

- A "Force fresh" toggle in `ResearchConfigSheet`
- A per-search "Re-search FamilySearch (bypass cache)" button in
  `SourceExplorerView`
- A "Re-research this profile (ignore cache)" affordance on the
  profile detail view's research summary

All three are cheap to wire, prevent the cache from becoming a
frustration surface, and don't compromise the cache's primary
benefit (rate-limit conservation for the bulk case).

### 6.7 Place authorities

`/platform/places/{placeId}` (OAuth)

FamilySearch maintains a structured place hierarchy with stable IDs.

**Decide once now, integrate later.** Integration of the FS place
authority into the gazetteer is genuinely V3 work. But the *data-model
decision* — does the FS place ARK become a canonical side-channel key
on `RecordCommon`, layer over the existing gazetteer, or stay an
opaque blob in `rawFields`? — must be made *now*, because per-record
persistence happens from first cut and migrations cost more than
forward-thinking columns. Commitment: **the FS place ARK is stored as
a side-channel key on `RecordCommon` (new field `placeARK: String?`)**;
gazetteer integration is downstream V3 work that promotes this
side-channel to a canonical lookup. This way the first-cut parser
captures the ARK whenever it's present in the response, and
gazetteer-aware engines can light up against existing data when V3
ships.

---

## 7. Trust tiering — by collection AND by attribution

FamilySearch publishes records from 2000+ distinct collections. Trust
varies dramatically across them — but trust also varies *within* a
single collection (especially the Family Tree) by attribution: a
source-extracted fact and a user-concluded fact in the same Tree
person record have very different evidentiary weights. The tiering
extension must capture both axes.

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

Tree persons have `Person Change History` (see §13 tiered roadmap). A
person with 50 edits across 8 contributors over 6 years is a
*contested attribution* — community-tier with the volatility known is
meaningfully different from community-tier with the volatility unknown.

Add a `volatilityScore: Double?` field on `RecordCommon`, populated
from change-history data when available. The scorer downweights
records with high volatility within their tier — without abandoning
them entirely. Same field defined for `Couple` and `Child-and-Parents`
relationship records.

**First-cut commitment**: `volatilityScore` is a nullable column from
day one even though the change-history endpoint that populates it is
post-first-cut work. Migrations cost more than forward-thinking
columns. Adding the column to `RecordCommon` now means the
change-history work later doesn't require a schema migration.

### 7.4 Collection completeness (negative-search evidence)

The GEDCOMx Record spec defines `CollectionContent.completeness`: a
0–1 score declaring how complete a collection's coverage of its
declared resource type is. This is the structured form of what
§7.1 tries to derive from title pattern-matching.

Capture from day one when present in the response. Persist as
`collectionCompleteness: Double?` on `RecordCommon`. Two consumers:

1. **`negative_searches` enrichment** (§6.6 caching): a zero-result
   search against a 0.9-completeness collection is materially
   stronger evidence of absence than against a 0.4-completeness
   collection. The cache row carries the completeness; the scorer
   weights `.unavailable`-evidence with it.
2. **Pending-fact display** (§8.4): "from England Parish Registers
   (94% complete coverage 1538–1812)" tells the user how seriously
   to take a fact's absence elsewhere.

**First-cut commitment**: parse and persist whenever
`sourceDescriptions[].coverage[].completeness` is present in the
response. The scorer's consumption of this field is post-first-cut,
but the data flows in from day one — same reasoning as §7.3.

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

## 8. App enhancement opportunities

This is the "ultrathink" part. Each item is something the app couldn't
do (or did poorly) before; FamilySearch makes it possible. Sized
informally as S/M/L.

### 8.1 Pipeline-internal (deterministic engines)

**[L] Pre-1837 reach extension.** Parish register collections
(christenings, marriages, burials) extend the tree's reachable depth
by 100+ years. Today every line dead-ends at 1837 unless covered by
FreeREG (sparse) or Wirksworth (Derbyshire-only). FS makes pre-1837 a
first-class search axis. **Files affected**: `RecordType.swift` for
`.christening`/`.parish`, `RecordQuery.swift` for parish-name
parameter, pipeline strictness ladder for parish-period date ranges.

**[L] Cross-source convergence triangulation.** Same GRO record cited
by FreeBMD + FamilySearch counts as two parallel transcriptions of one
original — convergence stays at parallel-not-independent. Same census
record cited by FreeCen + FamilySearch — likewise parallel. This
hardens single-source citations into properly-rated parallel pairs;
expect the average profile's evidence-confidence histogram to shift up
without any clustering change. **Files affected**:
`SourceTierRegistry.swift` (collection-aware lineage),
`ConvergenceEngine.swift` (no change — the lineage marker is enough).

**[M] Household-composition verification.** Census records expose
household members and their relationship-to-head. A sibling, spouse,
or child appearing in the same household at the right age is strong
evidence of family structure. New hypothesis kind:
`.censusHouseholdComposition` — given a candidate census record for a
profile, are the household members consistent with the known/inferred
family? **Files affected**: new hypothesis kind, new deficit-query
ladder for census-only searches.

**[M] Sibling discovery via mother's maiden name on FS births.**
FreeBMD started recording MMN on birth registrations from Sep 1911.
FamilySearch parish christening records often capture MMN earlier
(via the priest's record of the marriage). Extends the
`SiblingInferenceEngine` reach back into the 18th and early 19th
centuries. **Files affected**: `SiblingInferenceEngine.swift` query
construction, FamilySearch source parameter mapping.

**[S] Negative-result recording.** A search returning zero results is
itself evidence. Existing `negative_searches` table already supports
this. FS source plugin should write a row per zero-result search.
**Files affected**: search-result handler in `FamilySearchSource.swift`.

### 8.2 Hypothesis engine

**[L] Bio-cited record verification.** Each FamilySearch citation in
the user's bios (~half of all citations) becomes a deterministic
hypothesis: "FamilySearch holds a record at ARK X for this profile."
ARK lookup is the test; pass/fail is deterministic. This is the
single biggest unlock for the §5.8.5 eval harness — the
evidence-reproduction-rate metric becomes interpretable on the bulk
of the user's citations. **Files affected**: new `.familysearchAtARK`
or `.bioCitedRecord` hypothesis kind; deficit query that fetches ARK
detail; matcher canonicalisation.

**[M] Emigration / immigration chain.** New hypothesis kind
`.emigrationLink` — connect a UK birth/early-residence record to a
US (or AUS/NZ) immigration record. Currently impossible because the
pipeline has no non-UK source. **Files affected**: new hypothesis kind,
new search-axis (residence place outside UK).

**[M] Probate-death cross-reference.** When a death year is known but
the death record isn't found, search FS probate collections — a will
or grant of administration in the right year confirms death.
**Files affected**: new hypothesis kind `.probateDeath`; ladder.

**[S] Pre-1837 christening-as-birth.** When a birth record isn't
found in FreeBMD (because <1837), search FS for a christening or
baptism in a reasonable window post-birth. Already partially
supported via `.christening` in the existing `RecordType` enum;
needs FS query support.

### 8.3 Citation matcher (§5.8.5)

**[L] Deterministic FS citation handling.** ARK-bearing citations
("FamilySearch 1901 census: ... (ARK p_10268864404)") map directly to
canonical fact-key via ARK extraction. No regex parsing of free prose
needed for these — they're identifier-anchored. Roughly half of the
user's FamilySearch citations have ARKs. **Files affected**:
`CitationMatcher.swift` (new), ARK-extraction regex, canonical-key
lookup. **Precision**: deterministic by construction — modulo the
matcher's own ARK-parsing bugs, this is ~100% precision on the
ARK-bearing subset.

**[M] Non-ARK FamilySearch citations.** "FamilySearch 1901 census:
Albert, son, age 3, Middleton by Wirksworth" — no ARK. Parser keys
off "FamilySearch" prefix + event-type word + place; emits
`familysearch_census(year, place, person, age)` as canonical key.
The matcher then runs a live FS search with those terms and matches
on first-result-ARK if confidence > threshold. **Honest precision
estimate**: this is much harder than it reads. Free-prose citation
parsing is irreducibly ambiguous, and the user's bios were written by
hand over years with varying conventions. **Expect ~70% precision tops
on the non-ARK path**; the residual ~30% surfaces as
"unparseable citation, manual review needed" findings in the eval
harness. Plan for this from day one rather than discovering it via
disappointing eval numbers. **Files affected**: matcher prose parser;
cross-check against live search.

**[S] Citation-quality audit side effect.** As the matcher
canonicalises citations, it surfaces inconsistencies in the user's
own data ("FreeBMD birth 1951 ..." in one bio vs "FreeBMD birth 1952
..." for the same canonical record in another). New surface:
"data-quality findings" report from the eval harness.

### 8.4 UI / UX

**[M] "From collection X" in citation cards.** When a FamilySearch
record is surfaced as a pending fact, show the collection title
("England, Marriages, 1538-1973") not just "FamilySearch." Users can
gauge plausibility before accepting. Requires `sourceDescriptions[]`
title pull-through. **Files affected**:
`PendingFactsReviewView.swift`, `Citation.swift`.

**[M] Image-availability badge.** Some FS records have linked
microfilm images; many don't. Surface this in pending-fact cards as a
"View original at FamilySearch →" deep link. Requires extracting the
image waypoint from `sourceDescriptions[].links[]`. **Files affected**:
`PendingFactsReviewView.swift`, FS source plugin link extraction.

**[S] Source-status banner in research view.** When a FS search
returns "not authenticated" mid-run (cookies expired), surface a
banner with a one-click re-auth. Already half-built via the Settings
sheet — needs in-research-view promotion. **Files affected**:
`ResearchView.swift`, `SourceRegistry.swift`.

### 8.5 Place / time / language enrichment

**[M] FS place IDs as gazetteer keys.** Each FS place reference
includes a normalized place name AND a place ARK. Storing the place
ARK alongside our existing normalised place names gives a stable
cross-source identifier — useful for "same Bakewell, different
spelling" disambiguation across sources. **Files affected**:
`LocationGazetteer.swift`.

**[S] Formal-date parsing.** `date.formal` (e.g. `+1875-03-12`) is
machine-parseable in a way `date.original` ("12 Mar 1875") isn't.
Use `formal` for engine work, `original` for display.
**Files affected**: FS source plugin date parser.

**[S] Cultural fact preservation.** Heimat, ancestralPoem, etc. are
unlikely to appear in this user's UK tree, but parsing-and-storing
them in `rawFields` keeps the source plugin future-proof if the tree
extends into other cultural contexts.

### 8.6 Eval-harness benefits

**[L] Evidence-reproduction-rate becomes meaningful.** The metric
goes from "near-circular against ~10% of citations" to a two-band
result once FS is wired:

- ~50% of citations are ARK-bearing FS references → matcher-deterministic
  reproduction rate, near-100% precision modulo matcher bugs.
- ~30% of citations are non-ARK FS prose → matcher prose-parses with
  ~70% precision (§8.3); the harness reports both "matched" and
  "unparseable" counts so the residual is visible.
- ~20% of citations are FreeBMD/FreeCen/etc., unchanged — already
  handled by existing source plugins.

Net headline: ~50% deterministic + ~21% fuzzy-matched + ~20% existing
= **~91% citation reproducibility**, not the earlier optimistic 95%.
Single biggest harness uplift available, but the residual ~9%
unparseable tail is real and the eval-harness report should surface
it explicitly rather than smoothing it into a percentage.

**[M] Known-errors corpus seeded by FS auto-detection.** As we
canonicalise FS-cited records, mismatches (typo in year, wrong
volume number) surface automatically. These populate the
known-errors corpus without per-profile manual curation —
the §5.8.2 hopes-for-tight-loop becomes realised.

---

## 9. Implementation phasing

### 9.1 First-cut scope (one focused session)

> **Amended (2026-07-11, §14):** the transport rows below invert —
> "Cookie-auth path only (OAuth path stubs in place but not wired)"
> becomes **OAuth-only; cookie path deleted**, and "OAuth transport
> (post-App-Store-approval)" leaves the out-of-scope list. The
> session-start probes run against `apibeta.familysearch.org` with a
> bearer token (§15.1–§15.2), inside the per-user processing-time
> budget (§15.3). Persistence lines ("Original + Interpreted both
> stored", `rawFields["sourceQualifier"]`, per-ARK record cache) are
> conditional on the §16 licensing confirmation. Everything else
> stands.

**Goal**: FS records flow into the pipeline like any other source,
with conservative coverage and zero deferred-feature interference.

**Session-start probes (BEFORE committing to search-axis design).**
The implementation must begin with two empirical probes against the
live cookie-authenticated endpoint. Both unlock or constrain large
parts of the rest of the work:

1. **Does `q.recordType=Birth` actually restrict results, or only
   re-rank them?** A filter that doesn't filter changes the search
   strategy ladder dramatically — we'd have to over-fetch and
   filter client-side, costing rate-limit budget. Compare hit count
   with vs without the parameter on a known query.
2. **What is the collection-filter parameter name?** Docs ambiguous
   on whether it's `q.collectionId`, `q.collection`, or something
   else. Probe with a known collection ARK.
3. **Capture golden fixtures** (§9.4) from a dozen real responses
   while you're online — census household, marriage with banns,
   non-conformist baptism, 1939 Register entry, parish christening
   pre-1837, probate record, FS Tree person record (for §7.2 attribution
   testing), etc. These become the parser test fixtures.

**Then, with probe results in hand, write the source plugin:**

- `FamilySearchSource: RecordSource, DetailFetchingSource, AuthenticatingSource`
- Cookie-auth path only (OAuth path stubs in place but not wired)
- Record types: `.birth, .death, .marriage, .census, .baptism, .christening, .burial, .probate, .military` — the nine that map cleanly to existing Swift cases
- All Python search parameters + `q.sex`
- **Multi-persona parser** — one search hit → N candidate SourceRecords (§5.0), not one
- GEDCOMx parse covering: names, gender, facts (date+place+formal), fields (Original + Interpreted both stored, §5.2), source description (collection title + ARK + completeness), source-reference qualifiers in `rawFields["sourceQualifier"]` (§5.5), relationships (Couple, ParentChild)
- New `RecordCommon` fields: `placeARK: String?` (§6.7), `collectionCompleteness: Double?` (§7.4), `volatilityScore: Double?` (nullable, populated post-first-cut, §7.3)
- ARK construction for personas; persona ARK preserved in `RecordCommon.rawFields`
- Trust tiering by collection title pattern (§7.1) + attribution sub-band for Tree records (§7.2)
- Rate limit + 429 circuit-breaker pattern from `FreeBMDSource`
- Per-ARK record cache table; `negative_searches` extended with `result_kind` + `hit_count` columns (§6.6)
- Cache-bypass affordances wired into research config and source explorer (§6.6)
- Failure-mode contract: `.unavailable` reasons don't increment hypothesis `attempts` (§11)
- Registered in `SourceBootstrap.swift`; surfaced in the Settings source list
- Auth affordance promoted from "(development)" section to inline in the source row

**Out of scope for first cut**:
- New `RecordType` cases (`.immigration`, `.naturalization`, etc.) — log unmapped types in `rawFields[unmappedFactType]`, defer enum sprawl until eval data shows need
- ARK lookup endpoint — search-only; detail fetch comes in second cut
- Collection metadata caching as a separate table (rely on parsed-from-response data for now)
- Memories read endpoint (Tier 1 roadmap, §13)
- Tree Person Matches subscription (Tier 1 roadmap, §13)
- Change-history fetching to populate `volatilityScore` (Tier 1 roadmap, §13)
- Source-references cross-query (Tier 1 roadmap, §13)
- Place authority enrichment (Tier 3 roadmap, §13)
- Non-biological relationship distinctions
- OAuth transport (post-App-Store-approval)

### 9.2 Second cut (next session)

- ARK lookup (cookie path: scrape; OAuth path: `/platform/records/personas/`)
- Bio-citation matcher with ARK-deterministic path
- Collection metadata caching → trust-tier refinement
- New `RecordType` cases driven by what unmapped types showed up in first-cut data

### 9.3 Third cut and beyond

- OAuth path wired when partner approval lands
- Non-biological relationship handling
- Place authority enrichment
- New hypothesis kinds (`.censusHouseholdComposition`, `.emigrationLink`, `.probateDeath`)

(Tier-1 secondary-metadata items — Memories read, Tree Match
subscription, change-history volatility, source cross-references —
land between first and third cut; see the prioritised roadmap in §13.)

### 9.4 Testing strategy and golden fixtures

GEDCOMx parsing is complex enough to need fixtures. The Python plugin
has been running against real data for months; the Swift port should
not re-discover the same edge cases.

**Capture a fixture corpus during the first-session probes (§9.1):**

| Archetype | Why |
|---|---|
| Census household (1881, multi-persona) | Tests multi-persona extraction + household-role resolution |
| Marriage with banns | Tests subtype handling + couple relationship |
| Non-conformist baptism | Tests parish-register variant (Methodist, Quaker etc.) |
| 1939 Register entry | Common in user's tree; specific record structure |
| Parish christening pre-1837 | Pre-civil-registration parish-register format |
| Probate / will record | Tests `.probate` mapping + Will sub-distinction |
| FS Tree person record with mixed attribution | Tests §7.2 user-concluded vs source-extracted |
| Record with image waypoint | Tests §5.5 source-reference qualifiers |
| Empty-result search | Tests negative-search caching path |
| Truncated search at max | Tests truncated-result caching policy (§6.6) |
| Record with non-ASCII (Welsh / Gaelic place names) | Tests encoding round-trip |
| Record with `principal` flag set on non-first persona | Tests `principal` semantics resolution |

Anonymise (replace personal names/IDs but preserve structure) and
commit as fixtures under `Ancestor Research Tests/Fixtures/FamilySearch/`.
Use as the parser test suite — every fixture exercises a specific edge
case, and any future parser change must keep them all green.

The fixtures also serve as a *canary monitor* (§11.2 below): periodic
re-fetch of equivalent live records (different name but same archetype)
and diff against the fixture detects silent FS backend drift.

---

## 10. Open questions for implementation

> **Amended (2026-07-11, §14):** Q4 (cookie-path ARK lookup) and Q5
> (cookie-path rate ceiling) are moot — no cookie path exists. Q5's
> replacement is answered by the documented throttling contract
> (§15.3); the remaining questions convert to official-API probes on
> Beta. Q2's collection-filter ambiguity may resolve via the
> documented `f.*` exact-filter / `c.*` facet parameter categories
> (§15.7) — confirm live.

These convert directly into the first-session probe sequence (§9.1):

1. **Server-side record-type filter** — does `q.recordType=Birth` actually
   restrict results, or does it only re-rank? Probe with live search and
   compare counts vs unfiltered.
2. **Collection filter parameter name** — is it `q.collectionId` or
   `q.collection`? Docs ambiguous; probe.
3. **Wildcards and exact-match suffix** — confirm `~` for exact-match
   suffix syntax against live API.
4. **Cookie-path equivalent for ARK lookup** — does `www.familysearch.org/ark:/...`
   return GEDCOMx with the right Accept header, or only HTML? Probe.
5. **Rate-limit ceiling** — Python plugin has no explicit pacing.
   FamilySearch publishes no rate limits for the cookie path. Conservative
   starting point: 1 req/sec, 429 backoff via existing circuit-breaker
   pattern.
6. **Image waypoint extraction** — exact JSON path varies by collection.
   Probe a known image-bearing record (e.g. a 1911 census record) for
   shape.
7. **GEDCOMx `principal` semantics** — when `persons[].principal == true`,
   is that always the search hit's target person, or can it be a different
   person in the record? Affects multi-persona parsing logic in §5.0.
8. **Attribution shape on Tree person facts** — what does the JSON look like
   when a Tree fact is source-extracted vs user-concluded? §7.2 depends
   on parsing this; probe by fetching a known Tree person with mixed
   attribution.
9. **CollectionContent.completeness availability** — is this field
   actually populated in the website-backend response, or only in the
   OAuth-path response? §7.4 depends on this being captured from day
   one. If website backend omits it, the field stays nullable until
   OAuth lands.

---

## 11. Operational concerns

The spec to this point has covered correctness (what to fetch, how to
parse, how to score). This section covers what happens when things go
wrong — and what we have to design for from day one because retrofitting
operational concerns later is expensive.

### 11.1 Failure-mode contract for FS-dependent hypotheses

Hypotheses like `.familysearchAtARK` and (future)
`.censusHouseholdComposition` are inherently FS-dependent: if FS is
unreachable, these hypotheses cannot be tested. The verdict for an
untestable hypothesis is *not* the same as the verdict for a tested
hypothesis that came back inconclusive — the T7 attempts-counter logic
specifically distinguishes "tried and failed" from "never tried."

Contract:

| Outcome | Verdict | Attempts increment? | Re-try on next iteration? |
|---|---|---|---|
| Search ran, found supporting evidence | `.supported` | yes | no — settled |
| Search ran, found contradicting evidence | `.contradicted` | yes | no — settled |
| Search ran, returned nothing useful | `.inconclusive(reason: .deficitQueryReturnedNothing)` | **yes** | yes — level-up |
| Search couldn't run (auth failure, network) | `.inconclusive(reason: .sourceUnavailable)` | **no** | yes — re-try same level |
| Search couldn't run (cookies expired) | `.inconclusive(reason: .requiresReauth)` | **no** | yes — after user re-auth |
| Search couldn't run (FS throttled us) | `.inconclusive(reason: .throttled)` | **no** | yes — after circuit-breaker cool-down |

The reason-tagged `.inconclusive` is critical: without it, a transient
FS outage silently exhausts a hypothesis's deficit-query ladder, marking
it `.exhausted` when it has not actually been deficit-explored.

Add to `ResearchHypothesis` model:

```swift
extension ResearchHypothesis {
    enum InconclusiveReason: String, Codable, Sendable {
        case deficitQueryReturnedNothing  // genuinely tried, nothing found
        case sourceUnavailable            // didn't get to try
        case requiresReauth               // didn't get to try, user action needed
        case throttled                    // didn't get to try, will retry
    }
}
```

The T7 deficit-query dispatcher reads `attempts` and `reason` to decide
whether to advance the ladder level. Only `.deficitQueryReturnedNothing`
advances.

### 11.2 Cookie-auth fragility and canary monitoring

> **Superseded (2026-07-11, §14):** the cookie transport this canary
> guards is gone. The silent-drift concern survives in reduced form —
> the official API changes on a published cadence instead of without
> notice: breaking changes activate only on four fixed quarterly dates
> (Mar 1 / Jun 1 / Sep 1 / Dec 1) via the Pending-Modifications
> mechanism (§15.6). Replacement practice: newsletter subscription +
> golden-fixture regression runs around those dates, not a weekly
> scrape canary. The §9.4 fixtures keep their second job.

§2.1's website-backend endpoint (`/service/search/hr/v2/personas`) is
undocumented and could change without notice. The Credential abstraction
in §2.3 handles the OAuth *transition*, but it doesn't address what
happens if FS unilaterally redesigns the website backend before OAuth
approval lands.

Failure mode is likely **silent parse drift, not HTTP errors**: a
response that's still HTTP 200 but with a field renamed or
restructured. The parser will return empty records or wrong records,
which the existing pipeline absorbs without surfacing the underlying
problem.

Monitoring strategy: a **golden-record canary**. Schedule (e.g. via
the existing `Scripts/` directory, run weekly) a small set of known
fixed queries against the live endpoint, parse the responses, and
compare against the §9.4 golden fixtures. Any diff that isn't trivial
formatting (whitespace, IDs) is silent drift — flag for manual review
before users notice.

Cheap to wire (one CLI command, scheduled via launchd or
`scheduled-tasks.json`), catches the class of failure that's otherwise
invisible.

### 11.3 Decision 7 re-evaluation trigger

(See §6.5 for the full reasoning.) The FS integration partially
invalidates V2 Decision 7's local-MLX-only-for-T9 commitment. This
spec doesn't make the V2 change unilaterally; it flags the trigger so
the V2 deliberation happens at the right time — *after* first-cut FS
integration, *before* T9 implementation. Capture this as a TODO in
the V2 spec's open questions section so the cross-reference is
two-way.

---

## 12. Secondary metadata roadmap (Tier 1 / 2 / 3)

The first-cut spec (§9.1) is record-fetch-centric. The contextual
metadata that surrounds records — collection completeness, persona
cross-references, change-history volatility, attached photos and
transcribed wills — is where the second-order value sits. This roadmap
keeps it on the radar so the right items land at the right cuts.

### 12.1 Tier 1 — high value, post-first-cut

**Memories (read-only).** FS users attach photos of gravestones,
transcribed wills, family bibles, photographed letters, even audio
interviews to person records. These are real evidentiary artifacts —
a transcribed will photographed on FS is exactly the probate evidence
a `.probate` record promises but rarely delivers. Endpoints: Memory
Persona resource (which memories tag this person), Memory Artifact
resource (the file). Trust tier `.community` but content like a
photographed gravestone is closer to primary evidence than any
transcription. **Currently the pipeline cannot see this class of
evidence at all.** Second-cut work.

**Source-references cross-query.** GEDCOMx's
`/persons/{pid}/sources` and inverse queries answer "what other
personas use this source?" For a census record, the answer is "every
household member" — the multi-persona household-extraction problem
from a different angle. Cleaner than re-parsing the persons[] array.
Second-cut work; folds in alongside ARK lookup.

**Tree Person Matches subscription.** Atom-feed-with-published-timestamps;
once-per-tree-person poll captures the long-tail discovery that FS
matches into us via their own ML pipeline. See §6.5 for full design.
Second-cut work.

**Change-history volatility scoring.** `volatilityScore` column on
`RecordCommon` lands in first cut (§7.3); the change-history endpoint
that populates it is second-cut work. Cheap once the column exists.

**CollectionContent.completeness extraction.** Already first-cut
(§7.4) — parse-and-store whenever present in the response. The
*consumption* of this field by the scorer's negative-evidence
weighting is second-cut work.

### 12.2 Tier 2 — interesting but more nuanced

**Ancestry / Descendancy resources.** `/persons/{pid}/ancestry?generations=N`
returns N-gen pedigree in one call. If a Tree-match candidate surfaces,
fetching its ancestry and comparing against the user's own pedigree is
structurally stronger than per-person matching — tests the V2 spec's
G6 (family-graph plausibility) with FS's tree as the comparison corpus.
Third-cut.

**Discussions as reasoning trails.** Tree person discussions often
contain "I changed her birth year because the 1851 census suggests 23
not 25" — user-written analogue of `ResearchHypothesis.reasoning`. Read
as displayable context for Tree-match candidates; not a fact source but
a meta-signal about confidence. Third-cut.

**RecordDescriptor for schema-aware parsing.** Collections carry
descriptor metadata declaring "records in this collection have these
fields with these labels." A persona missing a field that the
descriptor says should exist is a transcription gap, not a real
absence — stronger negative information. Third-cut, alongside the
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

The Tier 1 endpoint additions (Memories, source-references,
match subscription, change-history) are real second-cut work.
But the *data-model commitments* required to receive their data
gracefully — `volatilityScore`, `collectionCompleteness`, `placeARK`
on `RecordCommon`; `result_kind` + `hit_count` on `negative_searches`;
the attribution sub-band on `SourceTrustTier` — all land in first cut.
This way the second-cut endpoint work doesn't need a schema migration;
the columns already exist, populated to `nil` until the endpoint that
fills them is wired.

Pattern: **data-model commits early, endpoint integration commits
later.** This is the cheapest way to keep first-cut tight without
foreclosing on the secondary-metadata value.

---

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
  - `sources/familysearch.py` — 502-line Python plugin, reference implementation
  - `Ancestor Research/Services/Research/RecordSource.swift` — protocol contract
  - `Ancestor Research/Services/Research/RecordTypes.swift` — `RecordType` enum + per-type structs
  - `Ancestor Research/Services/Sources/FreeBMDSource.swift` — reference for rate-limit + circuit-breaker patterns

### 13.1 Amendment sources (2026-07-11)

§§14–19 were synthesised from the R1/R2 FamilySearch research corpus
(overnight runs 2026-07-10/11, adversarially cross-checked; anything the
corpus's contradiction audit could not verify is labelled *unverified*
below) plus the signed developer agreement:

- [Getting Started](https://developers.familysearch.org/main/docs/getting-started) — environment tiers, Beta = production-data snapshot
- [Authentication](https://developers.familysearch.org/main/docs/authentication) — OAuth endpoints, Realm quirk
- [OAuth 2.0 for Native Apps](https://developers.familysearch.org/main/docs/oauth-20-for-native-apps) — PKCE mandate, loopback redirect, redirect_uri registration
- [Throttling](https://developers.familysearch.org/main/docs/throttling) — per-user budget, Retry-After, X-PROCESSING-TIME, test hook
- [HTTP Status Codes](https://developers.familysearch.org/main/docs/http-status-codes) — 301/410 semantics, Warning header
- [Caching guide](https://www.familysearch.org/developers/docs/guides/caching) — ETag/If-None-Match/304
- [API Evolution](https://developers.familysearch.org/main/docs/api-evolution) — Pending Modifications, quarterly dates
- [Record Persona Search resource](https://www.familysearch.org/en/developers/docs/api/records/Record_Persona_Search_resource) — endpoint, parameter grammar, pagination caps
- [Persistent Identifiers](https://developers.familysearch.org/main/docs/persistent-identifiers) — ARK permanence scope
- [Compatibility Checklist](https://developers.familysearch.org/main/docs/compatibility-checklist) — records-display restriction (**paraphrase-only**, page resisted direct fetch)
- [Read certification](https://www.familysearch.org/en/developers/docs/certification/read) — per-capability certification tiers
- [App Approval Considerations](https://developers.familysearch.org/main/docs/app-approval-considerations) — Beta ≠ production approval
- [fs-js-lite source](https://github.com/FamilySearch/fs-js-lite/blob/master/src/FamilySearch.js) — environment hostnames (docs omit them)
- [gedcomx-familysearch-extensions#3](https://github.com/FamilySearch/gedcomx-familysearch-extensions/issues/3) — undocumented error-body shape
- Signed FamilySearch developer agreement (§15 scraping ban; not a public URL)

---

## 14. Amendment (2026-07-11) — official-API pivot

**Status: Proposed — awaiting review.**

### 14.1 What happened

1. **2026-07-10 — Beta Program acceptance.** FamilySearch accepted the
   developer as an **Innovator Solution Provider** with non-production
   API access. Integration (synthetic sandbox) is auto-granted at
   signup; Beta is a separately granted tier holding a **snapshot of
   real production genealogical data** (§15.1) — so genuine research
   queries against real records can run there
   ([getting-started](https://developers.familysearch.org/main/docs/getting-started)).
   OAuth redirect_uri and Realm setup are still pending (§15.2).
2. **The scraping ban.** The signed developer agreement's §15 prohibits
   scraping / automated access outside the official API. Consequence:
   the §2.1 cookie transport — WKWebView-captured session cookies
   against `/service/search/hr/v2/personas`
   (`FamilySearchSource.swift:75`, doc comment at lines 8–11) — is
   **contractually prohibited** the moment the agreement was signed,
   independent of its technical fragility. It also kills §6.1's
   scrape-the-record-page fallback and moots §11.2's cookie canary.
   (Wording is from the signed agreement itself; the public docs corpus
   does not restate it — treat the clause number as agreement-internal.)
3. **Beta access is not production approval.** FamilySearch explicitly
   disclaims that Beta access implies eventual approval
   ([app-approval-considerations](https://developers.familysearch.org/main/docs/app-approval-considerations)).
   Production write access has its own multi-stage legal + security
   review; none of that is this spec's concern.

### 14.2 Migration posture (decisions)

1. **Official API only.** All FS traffic goes to the platform API on
   the §15.1 environment hosts. The cookie transport is **deleted, not
   deprecated** — there is no lawful fallback to keep warm. The
   `FamilySearchAuth/` capture stack (`FamilySearchCookieStore`,
   `FamilySearchAuthView`, `FamilySearchTestProbe`) is retired;
   `FamilySearchCredential.cookieSession` (§2.3) is removed.
2. **OAuth2 Authorization Code + PKCE (S256) — mandatory**, not
   optional, for native apps per FamilySearch's own guidance
   ([oauth-20-for-native-apps](https://developers.familysearch.org/main/docs/oauth-20-for-native-apps)).
3. **Loopback redirect** (`http://127.0.0.1:{port>1024}/path` or
   `http://[::1]:{port}/path`), which FS recommends over a custom URL
   scheme for desktop apps specifically. The authorization step must
   run in the **system default browser** (RFC 8252 pattern) — embedded
   webviews are not acceptable; the documented exceptions
   (SFSafariViewController / Custom Tabs) are mobile-only.
   *Unverified:* no macOS-specific carve-out is documented — the
   inference that ASWebAuthenticationSession / default-browser handoff
   is required on macOS is medium-confidence and needs confirming
   during setup.
4. **The §2.3 bet paid off.** Auth was specced as a transport detail;
   §§3–8 (GEDCOMx taxonomy, search axes, multi-persona parsing, trust
   tiering) carry over unchanged. The endpoint change is the predicted
   prefix swap: `/service/search/hr/v2/personas` →
   `GET /platform/records/personas` (§15.7).
5. **Plugin identity declarations update.** The `RecordSource`
   conformance keeps `dataLineage` / `trustTier` /
   `evidenceDirectness` as-is (`RecordSource.swift:29–32`,
   `FamilySearchSource.swift:29–31` — FS-transcribes-GRO shared-lineage
   handling per §7.5 unchanged); `tosStatus` (currently "Authenticated;
   cookie-based until OAuth API access is approved",
   `FamilySearchSource.swift:32–35`) becomes: *"Official API; OAuth2 +
   PKCE; Beta (non-production) access under the Innovator Solution
   Provider agreement — demo scope only."*
6. **Demo capability, not a feature.** The current agreement tier bans
   making the solution available to end users. Everything this
   amendment adds is scoped to a bounded **read-leg demo on Beta**
   (§19). No sync, no mirror, no shipping surface. The write leg
   (Family Tree source-attach) is a separate module with its own spec
   per the R2 architecture decisions — this spec must not grow
   tree-service scope, and §2.4's exclusion of Tree writes stands.

### 14.3 Supersession index

| Cookie-era content | Status after this amendment |
|---|---|
| §2.1 website-backend transport | Prohibited (agreement §15); retained for the record |
| §2.3 `.cookieSession` credential case | Removed |
| §5.6 lessons 4–5 (UA spoofing, cookie expiry) | Moot |
| §6.1 scrape-HTML fallback | Prohibited |
| §9.1 "cookie-auth path only" first cut | Inverted: OAuth-only |
| §10 open questions 4–5 | Moot (§15.3 answers the rate question) |
| §11.2 cookie canary | Replaced by quarterly Pending-Modifications watch (§15.6) |
| §§3–8 search/parse/score/tiering design | Unchanged — carries over |
| §5.2 Original+Interpreted persistence, §5.5 qualifiers, §6.6 per-ARK content cache | Conditional on §16 licensing confirmation |
| §11.1 failure-mode contract | Unchanged (`.requiresReauth` now = invalid/expired OAuth token) |

---

## 15. Protocol mechanics (official API)

Everything in this section lives *inside* `FamilySearchSource` (and its
HTTP client) — none of it leaks into the pipeline, which continues to
see plain `SourceRecord`s and the §11.1 failure contract. Confidence
flags follow the research corpus; items its contradiction audit could
not verify are marked.

### 15.1 Environments

| Env | API host | Ident host | Data |
|---|---|---|---|
| Integration (sandbox) | `api-integ.familysearch.org` | `identint.familysearch.org` | Synthetic test data only; auto-granted at developer signup |
| Beta | `apibeta.familysearch.org` | `identbeta.familysearch.org` | **Real production snapshot**, up to ~1 year stale; separately granted (we have it as of 2026-07-10) |
| Production | `api.familysearch.org` | `ident.familysearch.org` | Live; requires full Compatible Solution Program completion |

Hostnames read from the fs-js-lite SDK source — the prose docs omit
them ([fs-js-lite](https://github.com/FamilySearch/fs-js-lite/blob/master/src/FamilySearch.js)).

**Beta refresh outage:** Beta is refreshed once a year by wholesale
overwrite from production — last week of November through the first 1–2
weeks of December — with outages during the window; anything written to
Beta during the year is wiped
([getting-started](https://developers.familysearch.org/main/docs/getting-started)).
Consequences: never hardcode Beta ARKs/IDs in tests; do not schedule
the §19 demo inside that window; treat Beta record content as up to a
year behind production when comparing against FreeBMD results.

The environment is a plugin configuration value (Beta now, production
if certification ever lands) — never a compile-time constant.

### 15.2 OAuth lifecycle

- **Endpoints**: authorize =
  `https://ident{beta}.familysearch.org/cis-web/oauth2/v3/authorization`,
  token = `POST …/cis-web/oauth2/v3/token`, per environment row above
  ([authentication](https://developers.familysearch.org/main/docs/authentication)).
- **Grant**: Authorization Code + PKCE only. Password/ROPC has been
  discontinued platform-wide; the Unauthenticated Session grant is
  deprecated; Client Credentials needs special provisioning and is not
  generally available — the plugin always operates as the signed-in
  user ([client-credentials](https://developers.familysearch.org/main/docs/client-credentials-authentication)).
- **redirect_uri registration — contested; plan conservatively.**
  One R1 source says all redirect_uris must be **pre-registered by
  emailing devsupport@familysearch.org** (app key + environment + exact
  URI, [oauth-20-for-native-apps](https://developers.familysearch.org/main/docs/oauth-20-for-native-apps));
  another says mismatches are self-service fixable in the console. The
  contradiction audit flags this unresolved. Assume the email
  round-trip (worst case) and verify in the partner portal on first
  login. *(unverified)*
- **Realm** — opaque, support-ticket-only: the documented failure
  (`error=invalid_request … Client registration required`) is fixed by
  devsupport "adding a realm to your app key"; no public doc defines
  what a Realm gates. Ours is pending. Resolve directly with the Beta
  Program contact — further research cannot answer it. *(unverified)*
- **Token lifetimes** — reported 24 h max access token (plus inactivity
  expiry) and 90-day refresh token, from a single summarized fetch;
  refresh-token issuance for native apps reportedly requires app-key
  level enablement by devsupport (sources disagree about an
  `offline_access`/"private computer" alternative — likely stale docs).
  Decode a real token's `exp` before hardcoding TTLs anywhere.
  *(unverified)*
- **Storage**: bearer + refresh tokens in the Keychain, replacing the
  cookie store. §11.1's `.requiresReauth` reason maps to
  invalid/expired-token 401s; the contract is otherwise untouched.

### 15.3 Throttling (replaces the §9.1 "1 req/sec" guess)

([throttling doc](https://developers.familysearch.org/main/docs/throttling) throughout)

- **Per-user, not per-key**: a signed-in user's throttle budget is
  shared across *every* session and app they are using — the user
  browsing familysearch.org in Safari can get this app 429'd. Treat
  429 as possibly external in origin; never interpret it as a bug in
  our pacing.
- **Processing-time-based**, not request-count: budget is cumulative
  server execution time per rolling window (the docs' "18 s per 60 s"
  figure is an illustrative example, not a published constant;
  per-endpoint budgets are undisclosed). A request-count limiter
  cannot predict a 429.
- **Client obligations**: honour `Retry-After` (seconds) on 429
  exactly; accumulate `X-PROCESSING-TIME` (ms, present on every
  response) and self-throttle proactively before the server does it
  for us. The FreeBMD circuit-breaker pattern (§9.1) is kept but its
  input signal changes from request count to accumulated processing
  time.
- **Test hook**: `GET /platform/throttled?processingTime=60001`
  deliberately trips a controlled 429 — the only reliable way to
  exercise the backoff path on demand, and how §19-A5 is demoed.
- 429 maps to `.inconclusive(reason: .throttled)` per §11.1 — attempts
  not incremented.

### 15.4 Merged persons, deletions, error bodies

([http-status-codes](https://developers.familysearch.org/main/docs/http-status-codes))

- **301 = merged**: `Location` + `X-Entity-Forwarded-Id` headers point
  at the surviving entity. Chains are possible — follow with a bounded
  hop count (propose 5), and **record every hop**: each deprecated ID
  is appended to the evidence row's identity trail (§17.1) so
  previously stored links and old bio citations keep resolving.
- **410 = deleted**: the body is still returned — parse it for
  tombstone context, mark the stored pointer dead, and never delete
  the local evidence row (stash-don't-destroy, §17.2).
- **Error bodies are not trustworthy GEDCOMx**: the `fs:error` /
  `errors` shape is acknowledged by a FamilySearch engineer as
  undocumented
  ([gedcomx-familysearch-extensions#3](https://github.com/FamilySearch/gedcomx-familysearch-extensions/issues/3)).
  Parse defensively; fall back to HTTP status + the `Warning` header
  (the documented mechanism for explaining 400s). Never strict-decode
  an error payload.

### 15.5 Conditional GET / caching

- ETag-based revalidation is documented and working: weak ETags on
  responses; send `If-None-Match`, get `304 Not Modified`;
  `Cache-Control` (e.g. `no-transform, max-age=3600`) also present
  ([caching guide](https://www.familysearch.org/developers/docs/guides/caching)).
  304s are cheap on the §15.3 budget — revalidate rather than re-fetch.
- §6.6's taxonomy stands **structurally** (result-set vs record-content
  split, TTL-by-result-kind, `negative_searches` unification,
  cache-bypass affordances) but per-ARK **content** caching
  (`familysearch_record_cache.gedcomx_json`) is conditional on §16:
  under the conservative licensing reading the cache row holds
  pointer + licensed summary + ETag, not GEDCOMx content. ETag/304
  makes the pointer-revalidation variant workable.

### 15.6 Change cadence (replaces the cookie canary)

- No URI versioning — resource paths never change. Breaking
  ("incompatible") changes ship via **Pending Modifications**: opt in
  early with the `X-FS-Feature-Tag` request header, then the change
  activates for everyone on one of **4 fixed quarterly dates — Mar 1 /
  Jun 1 / Sep 1 / Dec 1** — pre-announced in the developer newsletter
  ([api-evolution](https://developers.familysearch.org/main/docs/api-evolution)).
- Practice: subscribe to the newsletter; treat the four dates as
  calendar risk windows; run the §9.4 golden fixtures against Beta
  around each date. This is the official-API replacement for §11.2.
- New resources take ~30 d prototype → ~60 d beta → release before
  stability (figures from a summarized fetch — re-verify before
  relying on them; *unverified*). Don't build against a resource
  younger than that cycle.

### 15.7 Records search endpoint specifics

([Record Persona Search resource](https://www.familysearch.org/en/developers/docs/api/records/Record_Persona_Search_resource))

- Endpoint: `GET /platform/records/personas` (note: *not*
  `/platform/records/search`; naming shifted during FS's API-reference
  migration — verify against the live OpenAPI reference once
  credentials work).
- Parameter grammar is `category.term.modifier.cardinality`: `q.*`
  fuzzy terms (the §4.1/§4.2 axes carry over), `f.*` exact filters,
  `c.*` facets/counts; modifiers include `exact`, `require`,
  `from`/`to`; numbered cardinality (`q.spouseGivenName.1`). This
  partially answers §4.3's must/should probe — confirm live.
- Pagination: `offset` (0–4999) + `count` (1–100), **hard cap 5000
  retrievable results** — the §6.6 "truncated" result-kind triggers at
  this cap. Link-header absence is inferred, not confirmed
  *(unverified)*.
- Status codes: 200 = results; **204 = no results** (a clean
  negative — write the `negative_searches` row, do not treat as an
  error); 400 = malformed (read the `Warning` header); 429 = §15.3.

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
>    empirically by the Change 8 beta probes
>    (FAMILYSEARCH_READ_LEG_PLAN).
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

The paragraph below is retained for the record of how the posture was
derived before verification:

The governing restriction was originally paraphrase-confirmed only: the
Compatibility Checklist page resisted direct fetch during the
2026-07-10/11 research phase, and the substance — third-party apps lack
privileges to display FamilySearch historical-record content to end
users; users must be **redirected to FamilySearch.org to view
records**; framed as a *legal* data-licensing restriction
(record-holding partners), not a technical gate — converged across 3+
independent search summaries without being read verbatim
([compatibility-checklist](https://developers.familysearch.org/main/docs/compatibility-checklist)).

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

## 18. Hint/match-score rule

FS surfaces proprietary match confidence: Record-Hinting-certified
apps may read persons, request hints, and show match summaries and
confidence ratings
([compatibility-checklist](https://developers.familysearch.org/main/docs/compatibility-checklist)
via paraphrase, [read certification](https://www.familysearch.org/en/developers/docs/certification/read)).
The public "3-star hints" description comes from an **undated** FS blog
post whose currency the contradiction audit could not confirm — the
hints surface iterates on the quarterly cadence, so do not design
against the star count or any specific scale. *(unverified)*

**Rule (decision, R2 item L5): an FS hint/match score is a
lead-ordering signal only.** It may:

- order FS-sourced leads in review lists, and
- prioritise which candidate gets a detail fetch first within the
  §15.3 budget.

It must **never**:

- set or influence a `SourceTrustTier` — trust is URL-derived via
  `SourceTierRegistry` (`SourceTierRegistry.swift:54` — the
  load-bearing "source trust is URL-derived" invariant),
- enter any of the 4 gates or the scorer verdict
  (`fact` / `lead` / `impossible`),
- count toward convergence — an FS score is FS's opinion about a
  match, not an independent transcription of anything.

This is the deterministic sandwich applied to a *remote* ML system:
FS's matcher proposes ordering; our rules decide. Persist the raw
score in `rawFields["fsMatchScore"]` (permitted under §16.1's
"confidence" allowance) so lead ordering is reproducible after the
fact.

---

## 19. Demo read-leg acceptance criteria (Beta)

The bounded deliverable this spec now targets (§14.2.6): a
demonstrable read leg on Beta, doubling as collateral for FS
compatibility review. Write-leg criteria belong to the tree-service
spec, not here.

**Preconditions**: app key with Beta access (have, 2026-07-10);
redirect_uri registered (§15.2 — contested path, resolve first); Realm
attached (§15.2 — pending); scheduled **outside** the Nov/Dec Beta
refresh window (§15.1); licensing wording confirmed or the §16
conservative posture consciously accepted for the demo.

| # | Criterion | Proves |
|---|---|---|
| A1 | OAuth2 Authorization Code + PKCE (S256) completes against `identbeta.familysearch.org` via loopback redirect in the system default browser; tokens land in the Keychain | §15.2 lifecycle |
| A2 | Relaunch reuses the stored token; an expired/revoked token surfaces `.inconclusive(reason: .requiresReauth)` with a re-auth affordance and does **not** increment hypothesis attempts | §11.1 contract on the new transport |
| A3 | `GET /platform/records/personas` on `apibeta` for a known eval-corpus subject (e.g. Ernest Cauldwell, b. 1887) parses into one-`SourceRecord`-per-persona (§5.0) with correct §3 RecordType mapping, exercised against the §9.4 fixtures | search + parser carry-over |
| A4 | The same run persists only the §16-licensed subset (pointer + titles + confidence + our verdicts); `external_persona_id` carries the bare `ark:/` path (§17.1); a zero-result query (204) writes a `negative_searches` row, not an error | licensing posture + identity columns |
| A5 | `GET /platform/throttled?processingTime=60001` trips a controlled 429; the client honours `Retry-After`, accumulates `X-PROCESSING-TIME`, resumes cleanly, and no hypothesis is marked `.exhausted` (`.throttled` reason, §11.1) | §15.3 throttling |
| A6 | 301 chain followed via `X-Entity-Forwarded-Id` with each deprecated ID appended to the identity trail; 410 marks the pointer dead without deleting the evidence row (fixture-tested; live if Beta surfaces either) | §15.4 |
| A7 | A repeat fetch of an unchanged resource sends `If-None-Match` and takes the 304 path | §15.5 |
| A8 | Where a match score is returned it orders the lead list and appears in **no** gate input, trust tier, or verdict — asserted by a unit test, not by inspection | §18 |
| A9 | UI shows collection title + confidence + "View on FamilySearch" ARK link-out; no FS record content is rendered or stored in-app | §16 posture |

Pass = all nine green on Beta, captured (screen recording + logs).
A3/A4 outputs flow through the Evidence Firewall like any source —
`pending_facts` and `leads` only; nothing here relaxes that.
