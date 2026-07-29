# FreeREG Integration — the perfect model

**Status:** Design (2026-07-29). Ground-truth models below are derived from **FreeUKGen/MyopicVicar** (Apache-2.0), the open-source Rails engine that actually powers FreeREG — specifically `app/models/freereg1_csv_entry.rb` (the record schema), `app/models/search_query.rb` (the query schema), and the form partial `app/views/search_queries/_form_freereg.html.erb` (the exact wire keys), cross-checked against the live search form at `freereg.org.uk/search_queries/new`. This supersedes the reverse-engineered subset the current `FreeREGSource`/`FreeREGParams`/`ParishRecord` capture.

**Production validated (2026-07-29).** MyopicVicar *is* production: the field names in `_form_freereg.html.erb` match the current scraper's already-working wire keys verbatim (`search_query[last_name]`, `[chapman_codes][]`, `[record_type]`, `[start_year]`/`[end_year]`, `[fuzzy]`). The new axes below were confirmed present in the *same* template, so version-drift risk on them is low. Two corrections the template forced on the first-draft model: the place param is **`search_query[place_ids][]`** (not `places[]`), and **`wildcard_search` is not on the FreeREG form** (it's a FreeCEN/BMD axis) — FreeREG matching is `exact | soundex` only.

**Why authoritative, not scraped:** MyopicVicar is the open-source Rails engine behind FreeREG. Reading its models is reading the source of truth — no server load, no ToS question (the *code* is Apache-2.0; the *data*-access posture is separate, see `ADR-008`).

**Which of our live connectors this covers (verified 2026-07-29 by endpoint):**

| Connector | Live endpoint | Engine | This spec applies? |
|---|---|---|---|
| FreeREG | `freereg.org.uk/search_queries` (Rails) | **MyopicVicar** | ✅ directly — query **and** record model |
| FreeCEN | `freecen.org.uk/search_queries` + `/search_records` (Rails) | **MyopicVicar / FreeCEN2** family | ⚠️ **query model** applies (same `SearchQuery`: honeypot, 3-county cap, validations); **record** schema differs (census, not parish) — validate against freecen2 |
| FreeBMD | `freebmd.org.uk/cgi/search.pl` (**Perl CGI**) | **classic FreeBMD**, *not* MyopicVicar | ❌ does **not** apply — MyopicVicar powers only the not-yet-live **FreeBMD2**. If `freebmd.org.uk` cuts over to FreeBMD2 (Rails), `FreeBMDSource` needs a rewrite to the `search_queries` shape |

The query model therefore generalizes to **FreeREG + FreeCEN** (shared `SearchQuery`; `FreeREGSource.nextPageURL` already delegates to `FreeCenSource.nextPaginationHref`), **not** to the FreeBMD we currently scrape.

---

## 0. Two critical operational findings (fix these regardless of the model refactor)

1. **`region` is a bot honeypot** — confirmed verbatim in the form partial: `<input id="region" name="search_query[region]" type="text">`. It flags automated clients when populated. **Never emit `search_query[region]`.** The current scraper does not (good) — this must stay a hard invariant, called out so no future "add a region axis" change trips it. §3 adds a test that asserts the field is never on the wire.
2. **Hard max of 3 counties per query** (`chapman_codes`), the sole exception being the Channel-Islands quartet `["ALD","GSY","JSY","SRK"]`. This **resolves CONNECTOR_AUDIT FT-27** (the "does the form honour repeated `chapman_codes[]` keys?" unknown): it honours **1–3**, not more. So:
   - The current `.national` (~70-code) / `.adjacent` (~7-code) fan-out must stay **one query per ≤3 codes** — `FreeREGParams.multiCodeBatchEnabled` should batch in groups of **≤3**, not 10, and never send the whole national set in one request.
   - `FreeREGParams.batchGroupSize = 10` is **wrong for FreeREG** (it would exceed the cap). Set it to 3.

---

## 1. The perfect query model — how searches interact

Mapped 1:1 to `SearchQuery`. Wire keys are the exact `search_query[...]` names.

```swift
/// A complete FreeREG search. Field-name comments are the exact wire keys
/// (MyopicVicar `SearchQuery`, Apache-2.0). Server-side, `firstName` is
/// auto-expanded to abbreviations + Latin forms; do NOT pre-expand given
/// names ourselves (double expansion widens recall noise — the app's own
/// given-name variant ladder should defer to the server for this source).
public struct FreeREGQuery: Sendable, Equatable {

    // — Identity —
    public var lastName: String?          // search_query[last_name]
    public var firstName: String?         // search_query[first_name]
    public var noSurname: Bool            // search_query[no_surname]

    // — Event kind —  nil = all three types
    public var recordType: FreeREGRecordType?   // search_query[record_type]

    // — Time —  both-or-neither; start ≤ end
    public var startYear: Int?            // search_query[start_year]
    public var endYear: Int?              // search_query[end_year]

    // — Place (hierarchical) —
    public var chapmanCodes: [String]     // search_query[chapman_codes][]  (1…3; CI quartet exempt)
    public var placeIDs: [String]         // search_query[place_ids][]  — ONLY when exactly ONE county (FT-19)
    public var searchNearbyPlaces: Bool   // search_query[search_nearby_places] — radius; requires ≥1 placeID
    // NB: `region` (search_query[region]) is a HONEYPOT — intentionally absent from this type.
    // (`radius_factor` is a server-side default (101); the form exposes no input for it, so we never send it.)

    // — Matching mode — exact | soundex (fuzzy). Wildcard is NOT a FreeREG axis. —
    public var matching: FreeREGMatching  // .exact | .soundex

    // — Relationship scope (FT-21 collateral-kin channel) —
    public var includeFamilyMembers: Bool // search_query[inclusive] — person as relative/spouse
    public var includeWitnesses: Bool     // search_query[witness]   — person as marriage/baptism witness

    // — Secondary server-side filters —
    public var sex: FreeREGSex?           // search_query[sex]
    public var maritalStatus: String?     // search_query[marital_status]
    public var occupation: String?        // search_query[occupation]
    public var role: String?              // search_query[role]  (NameRole::ALL_ROLES)
}

public enum FreeREGRecordType: String, Sendable {
    case baptism = "ba", marriage = "ma", burial = "bu"
}

public enum FreeREGMatching: Sendable, Equatable {
    case exact
    case soundex               // search_query[fuzzy]=true — applies to BOTH surname and forename
    // NB: MyopicVicar's SearchQuery has `wildcard_search`, but the FreeREG form
    // partial does not render it — it's a FreeCEN/BMD axis. Do not emit it here.
}

public enum FreeREGSex: String, Sendable { case male = "m", female = "f", unknown = "u" }
```

### 1.1 Interaction rules (the validation contract — port verbatim)

These are `SearchQuery`'s own validations. A `FreeREGQuery.validate() -> [ValidationError]` should enforce them **before** hitting the wire (a rejected POST is indistinguishable from a genuine no-hit downstream — the FT-20/FT-26 lesson):

| Rule | Constraint |
|---|---|
| **No county** | If `chapmanCodes` is empty, `recordType` **and** both years are required. |
| **County cap** | `chapmanCodes.count ≤ 3`, unless every code ∈ `{ALD,GSY,JSY,SRK}`. |
| **Places gate** | `placeIDs` is only valid when `chapmanCodes.count == 1` (the form's "Places box fills only when a single county is selected"). |
| **Radius gate** | `searchNearbyPlaces` requires `placeIDs` non-empty. |
| **No-surname gate** | `noSurname` requires `firstName` **and** `chapmanCodes` **and** `placeIDs`. |
| **Date pairing** | `startYear` and `endYear` are both-or-neither; `startYear ≤ endYear`. |

### 1.2 Gap vs current `FreeREGParams`

Current struct carries only `chapmanCode` / `chapmanCodes` (single + batch). Everything else is read off `RecordQuery` at emit time, and these axes are **unreachable**:

| Axis | Current state | Perfect model |
|---|---|---|
| Parish / place scoping (`places[]`) | **Removed** (SOURCE_WEIGHTING Change 3 — "form has no parish axis") — but the form **does** have it (cascading on single county) | `placeIDs` (**FT-19**) |
| Witness search (`witness`) | absent | `includeWitnesses` (**FT-21**) |
| Family/relative (`inclusive`) | absent | `includeFamilyMembers` |
| Nearby/radius | absent | `searchNearbyPlaces` + `radiusFactor` |
| No-surname | absent | `noSurname` |
| Soundex | only via `.loose` strictness | explicit `.soundex` matching (both names) |
| sex / marital / occupation / role | absent | secondary filters |
| County batch size | `batchGroupSize = 10` (**exceeds cap**) | **3** |

---

## 2. The perfect data model — what a record holds

Mapped from `Freereg1CsvEntry`. The DB schema is the **ceiling** of what's transcribed; the live search-results *table* exposes a summary subset (name/date/parish/county/type), and the record *detail* page exposes most of the rest — so capture is two-tier (list row → detail enrich), but the model should type the full ceiling and let unfetched fields be `nil`.

```swift
/// One FreeREG parish-register entry. Modelled on MyopicVicar `Freereg1CsvEntry`.
public struct FreeREGRecord: Codable, Sendable {
    public let id: String                    // server entry id (from detail URL) or content digest
    public let event: FreeREGEvent           // discriminated by kind — the payload differs per type
    public let place: FreeREGPlace
    public let register: FreeREGRegisterReference
    public let provenance: FreeREGProvenance
    public let notes: FreeREGNotes
}

public enum FreeREGEvent: Codable, Sendable {
    case baptism(FreeREGBaptism)
    case marriage(FreeREGMarriage)
    case burial(FreeREGBurial)
}

public struct FreeREGPerson: Codable, Sendable {  // reused everywhere a name appears
    public var forename: String?
    public var surname: String?
    public var title: String?
    public var sex: FreeREGSex?
    public var age: String?          // free-text ("infant", "3 mo", "24") — never coerce to Int blindly
    public var condition: String?    // bachelor/spinster/widow(er)
    public var occupation: String?
    public var abode: String?
}

public struct FreeREGBaptism: Codable, Sendable {
    public var child: FreeREGPerson           // person_forename/surname/sex/…
    public var birthDate: String?             // birth_date (distinct from baptism)
    public var baptismDate: String?           // baptism_date
    public var isPrivate: Bool?               // private_baptism
    public var father: FreeREGPerson?         // father_* incl. occupation, abode, place, county
    public var mother: FreeREGMother?         // mother_* incl. condition/place PRIOR TO MARRIAGE (maiden clues)
    public var witnesses: [FreeREGPerson]     // baptism can name witnesses too
}

public struct FreeREGMother: Codable, Sendable {
    public var person: FreeREGPerson
    public var conditionPriorToMarriage: String?  // mother_condition_prior_to_marriage
    public var placePriorToMarriage: String?      // mother_place_prior_to_marriage — maiden-origin lead
    public var countyPriorToMarriage: String?
}

public struct FreeREGMarriage: Codable, Sendable {
    public var groom: FreeREGPerson           // groom_* + groom_parish
    public var bride: FreeREGPerson           // bride_* + bride_parish
    public var groomParish: String?
    public var brideParish: String?
    public var groomFather: FreeREGPerson?    // groom_father_* (+ occupation)
    public var groomMother: FreeREGPerson?
    public var brideFather: FreeREGPerson?
    public var brideMother: FreeREGPerson?
    public var marriageDate: String?
    public var byLicence: Bool?               // marriage_by_licence (else by banns)
    public var marriageBy: String?            // officiant / form
    public var witnesses: [FreeREGPerson]     // multiple_witnesses (embeds_many) ∪ witness1…8
}

public struct FreeREGBurial: Codable, Sendable {
    public var deceased: FreeREGPerson        // burial_person_* + person_age
    public var burialDate: String?
    public var deathDate: String?
    public var causeOfDeath: String?
    public var placeOfDeath: String?
    /// Burials often name a RELATIVE rather than fully identifying the deceased
    /// (e.g. "Mary, dau of John Smith"): relationship + the relative's name.
    public var relationship: String?          // relationship / person_relationship
    public var relative: FreeREGPerson?       // male_relative_* / female_relative_* / relative_surname
    public var memorialInformation: String?
    public var consecratedGround: String?
}

public struct FreeREGPlace: Codable, Sendable {
    public var parish: String?                // place
    public var churchName: String?            // church_name
    public var county: String?                // county (Chapman-coded)
    public var location: String?              // location
}

public struct FreeREGRegisterReference: Codable, Sendable {
    public var register: String?              // register
    public var registerType: String?          // register_type (CofE/RC/Nonconformist/…)
    public var registerEntryNumber: String?   // register_entry_number
    public var film: String?                  // film / film_number
    public var imageFileName: String?         // image_file_name (media lead — SOURCE_MEDIA_SPEC)
}

public struct FreeREGProvenance: Codable, Sendable {
    public var transcribedBy: String?         // transcribed_by
    public var credit: String?                // credit — MUST be surfaced in citations (transcriber attribution)
    public var recordDigest: String?          // record_digest
    public var lineID: String?                // line_id
}

public struct FreeREGNotes: Codable, Sendable {
    public var notes: String?
    public var notesFromTranscriber: String?
}
```

### 2.1 Gap vs current `ParishRecord`

`ParishRecord` is flat: `{eventType, eventDate, eventYear, parish, county, fatherName, motherName}` + everything else stuffed untyped into `common.rawFields`. High-value data lost to typing:

| Lost / untyped today | Why it matters |
|---|---|
| `mother_place_prior_to_marriage`, `mother_condition_prior_to_marriage` | **Maiden-origin leads** — direct fuel for the census/marriage maiden-name reconciler. |
| Marriage `groom_father` / `bride_father` (+ occupations) | Two generations from **one** marriage record — parentage for both spouses. |
| Witnesses (`multiple_witnesses`) | Collateral-kin signal (FT-21); relatives routinely witness. |
| Burial `relationship` + `relative` | A burial that only names a relative is currently mis-parsed as the deceased's own identity. |
| `person_age`, `condition`, `occupation`, `abode` | Discriminators the scorer needs to separate namesakes. |
| `credit` / `transcribed_by` | Transcriber **attribution** — a ToS-and-courtesy obligation on every citation. |
| `image_file_name` | Feeds `SOURCE_MEDIA_SPEC` (register-image lead). |
| `register_type` | Church vs Nonconformist vs RC — source-tiering + denomination context. |

---

## 3. Build sequence (design → code, follow-on)

Not built by this spec — this is the plan. Suggested order, smallest-blast-radius first:

1. **Honeypot + county-cap hardening** (§0) — set `batchGroupSize = 3`, assert `region` never emitted, cap `chapman_codes` at 3. *No model change; pure safety.* Do first — **and apply to BOTH `FreeREGParams` and `FreeCenParams`** (both currently `= 10`; both hit the same 3-county MyopicVicar cap).
2. **Query model** (§1) — wire the missing axes onto `FreeREGParams` + a testable `validate()`; add `placeIDs` (FT-19), `includeWitnesses`/`includeFamilyMembers` (FT-21), `noSurname`. Emit only after `validate()` passes.
3. **Data model** (§2) — introduce `FreeREGRecord`/`FreeREGEvent`; parse detail pages into the typed structs; keep `ParishRecord` as a lossy projection for the existing scorer/convergence call sites until they migrate (avoid a big-bang rewrite of the decision core).
4. **Attribution** — thread `credit`/`transcribed_by` into `Citation` rendering.
5. **FreeCEN record model** (separate, larger) — the census-household equivalent of §2, plus applying the shared `validate()` to `FreeCenSource`. Best done as its own increment.
6. **Generalize** — lift the shared `SearchQuery`-shaped validation + honeypot/cap rules + pagination into a `FreeUKGenSource` base that both FreeREG and FreeCEN reuse (their *record* schemas differ; the *query contract* is identical). `FreeBMDSource` stays out — it's the classic Perl CGI site, a different engine.

## 4. Open items to verify against a live run

- **`place_ids[]` option values** — the exact IDs the cascading Places select emits (confirm they're numeric place IDs, and how to resolve a parish name → place ID). Needs one inspection of the rendered `<option value>`s for a single county. *(Wire key itself is resolved: `search_query[place_ids][]`.)*
- **`record_type` "all" encoding** — the current code omits the field for "all"; the template shows an explicit `""` option value for "all three types". Confirm omitting vs sending `""` behave the same.
- **The ⚠ "returned 0" symptom** (see memory `reference_freereg_active_interim_use`): the current guard already refuses county-less queries, so it is **not** a missing-county rejection. More likely a results-table parse drift or a `record_type` mismatch. Needs a live probe — the §1.1 validation won't self-resolve it.
```
