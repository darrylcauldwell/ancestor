# CONNECTOR_AUDIT_2026-07 — Free-Trio Connector Audit Findings

**Status: Proposed — awaiting review.** Drafted overnight 2026-07-10/11 from the audit envelope; no fixes started, no commits made. Every item below is a *proposed* backlog entry until Darryl triages it.

---

## 1. Scope, method, date

- **Scope:** the three volunteer-transcription connectors — FreeBMD, FreeCen, FreeREG — plus the shared machinery they ride on (`SearchDispatcher`, `QueryCache`, `SourceHTTPClient`, `SourceQueryResult`). Audited 2026-07-10 against both the Swift connectors (`Ancestor Research/Services/Sources/`) and the Python references (`sources/`).
- **Method:** find → two-lens adversarial verify. Three find agents (parsing fidelity, form-capability gap, query planning) produced 49 raw findings; after dedup each surviving finding was verified by two independent lenses — a **fact lens** (are the citations and mechanics true?) and a **value lens** (is the recommendation net-positive for this engine's invariants?). Result: **29 confirmed, 11 refuted on value, 9 verification-incomplete** (see §4 — verify agents were lost to stalls and a session limit, *not* to refutation). The critic pass also failed on the session limit, so there are **zero critic additions — meaning the critique step didn't run, not that it found nothing**.
- **Constraint:** STATIC ANALYSIS ONLY. No live network calls were made, and the audit's ground-truth live-form payload failed to inject (FT-27). Anything that depends on today's exact form encodings is labelled **PLAUSIBLE / unverified** below and needs the one live probe session (§5.6) before being treated as fact.
- Evidence citations (file:line) are carried from the verified finding text; sizes (S/M/L) are drafting-time guesses, not estimates from code inspection tonight.

### Tier-1 sources — verification in progress

> **⏳ PLACEHOLDER — CWGC / FindAGrave / Probate.** The tier-1 connector audit ran the same night but its adversarial verification is still in progress overnight. That section will be **appended here as §6 when it lands**. Nothing from the unverified tier-1 envelope is included below.

---

## 2. Confirmed fix backlog

Grouped by source, then impact. IDs are stable — reference them in commits as `fix: … #FT-nn`.

### 2.1 FreeBMD

**FT-01 · high · inefficiency — `countyid` never used; county scope loops 12 per-district requests where 1 would do**
`FreeBMDSource` emits only `districtid` (FreeBMDSource.swift:199); nothing in the repo references `countyid`. `SearchDispatcher.buildQueries` enumerates `RegionConfig.districts(forChapmanCode:)` — 12 codes for DBY — one `RecordQuery` per district (SearchDispatcher.swift:282-291, 344-365), multiplied by record types, surname probes, and the spouse-surname fan-out (SearchDispatcher.swift:321-332), all serialized at 500 ms pacing against a source with a 3-trip circuit breaker. The results page carries the district column per row (parsed at FreeBMDSource.swift:714), so the geography gate keeps working at county granularity.
*Recommendation:* add `countyCode` to `FreeBMDParams`; emit `countyid` and drop the district loop for `.county`/`.adjacent`. Keep per-district queries only for surgical `FocusedQuery` dispatches. **Size: M**

**FT-02 · high · inefficiency — national scope fires 632–996 requests where FreeBMD accepts a single all-districts query**
The `.national` branch emits one query per year-filtered catalogue district (SearchDispatcher.swift:286-291, 344-365) — measured against `freebmd-districts.json` (1121 entries): 632 districts for a birth ±2 window, 996 for a death window, 838 for marriage; 5–8 minutes of pure pacing per record type per surname probe per tier. Python proves the wire accepts `district=""` for one national query (sources/freebmd.py:152-153; agent/discover.py:129-144 runs exactly one), Swift already supports it (`"districtid": params?.districtCode ?? ""`, FreeBMDSource.swift:199), and the overflow interstitial is already handled by adaptive year-splitting (FreeBMDSource.swift:280-344). Given FreeBMD's daily budget burns in ~30 min when hammered, one national run can exhaust it alone.
*Recommendation:* `.national` = one `districtid=""` query + existing adaptive split; same change in `ResearchPipeline.dispatchMarriageQuery`'s national branch (ResearchPipeline.swift:1749-1752). **Size: S**

**FT-03 · high · unused-capability — `vol`/`pgno` never sent; same-page spouse recovery burns a full surname sweep and cannot work for unknown spouses**
`baseFields` has no vol/pgno (FreeBMDSource.swift:191-205). Pre-Sep-1912 partner recovery (SamePageCouplePairing.swift:1-38) dispatches a second full spouse-surname district sweep and joins client-side on (year, quarter, district, vol, page) — which requires already knowing the spouse surname. The form's vol+pgno fields would fetch the 2–4 index entries on a known GRO page in one request (parser already extracts vol/page, FreeBMDSource.swift:715/725), recovering partners deterministically even when *no* spouse is on the tree — the "enumerate page 943's couples" mechanism gestured at in FocusedQuery.swift:44-46.
*Recommendation:* add volume/page to `FreeBMDParams`; wire a page-lookup step into `annotateMarriagesWithSamePagePartner`; extend to unknown-spouse marriages. **Size: M**

**FT-04 · high · planning-gap — no county→national escalation on empty results; the Python SCOPE-ESCALATE tier was not ported**
Python escalates geography when the home county is empty (agent/discover.py:129-144, `_freebmd_national_fallback` — motivated by the Lydia Kenworthy case: twin says Stanton DBY, FreeBMD registered Huddersfield YKS). In Swift, `ResearchScope` is fixed for the run and the only empty-then-broaden axis is name strictness (SearchDispatcher.swift:104-131) — spelling widens, geography never does. A subject registered one county over is invisible at default `.county` scope. The geography gate already down-weights distant hits, so escalation adds recall without noise.
*Recommendation:* when all strictness tiers for (freebmd, recordType) are empty at `.county`/`.adjacent`, fire one national `districtid=""` query; log it as a distinct escalation step in searchHistory. **Size: M**

**FT-05 · medium · correctness-bug — unsplittable overflow (single-year window, depth cap, missing bounds) silently returns zero results**
`fetchWindowWithAdaptiveSplit` recurses only when depth < 3 AND both year bounds exist AND the window spans ≥ 2 years (FreeBMDSource.swift:303-306); every other overflow case falls through to parsing the interstitial and returns `[]` (FreeBMDSource.swift:335-343), indistinguishable from a genuine empty. Python surfaces "Too many results (N)" explicitly (sources/freebmd.py:83-86).
*Recommendation:* when overflow is detected but the split guard fails, return a distinct outcome (typed overflow → `.unavailable(reason:)` or the truncated envelope from FT-23); parse the entry count for the reason string. **Size: S**

**FT-06 · medium · correctness-bug — PLAUSIBLE (unverified live): `Phonetic=false` sent on every strict query may enable soundex under checkbox-presence semantics**
Swift sends `Phonetic="true"` for `.loose` and `"false"` otherwise, unconditionally (FreeBMDSource.swift:164, 200). Python never sends the field (freebmd.py:166-184); real browsers omit unchecked checkboxes; `search.pl` is Perl CGI, where presence checks treat `"false"` as TRUE. If so, every `.strict`/`.variant` query has been running server-side soundex — inflated results, more overflow interstitials, and the strict-vs-loose tiers silently collapse. Cannot be confirmed statically (the ground-truth payload never arrived).
*Recommendation:* omit the field entirely unless enabling — correct under *both* server interpretations, zero risk. Then live-verify the checked value string. **Size: S**

**FT-07 · medium · correctness-bug — strategist FocusedQuery sends a district NAME as `districtid` (a numeric-ID field)**
`FocusedQuery.district` is documented as a name the dispatcher "will resolve" (FocusedQuery.swift:56-60), but `toRecordQuery` passes it straight through (FocusedQuery.swift:84-89) and `dispatchOne` does no resolution (SearchDispatcher.swift:78-86) — an MLX query for "Belper" goes out as `districtid=Belper` against numeric options. Either errors or silently searches all districts; the activity summary papers over it (FreeBMDSource.swift:536-537).
*Recommendation:* resolve via `FreeBMDDistrictCatalogue.shared.district(named:)` (FreeBMDDistrictCatalogue.swift:107-112); fall back to `""` with a logged warning. **Size: S**

**FT-08 · medium · correctness-bug — Python reference still ships five district IDs the Swift side proved wrong; parity tooling compares against silent zeros**
Swift verified and corrected five codes in 2026-05 (Bakewell 420→691, Chesterfield 621→1102, Derby 710→1016, Basford 676→707, Worksop 765→630 — RegionConfig.swift:27-56, agreeing with the bundled catalogue), but config.yaml:17-24 and sources/freebmd.py:43-50 still carry the stale codes, which "silently produced zero results". Python is the parity reference for `compare_twins.py`/`compare_gaps.py`, so probes in those districts under-report and mask real divergence. Whether the corrected codes remain valid on *today's* form is unverified (no ground-truth payload).
*Recommendation:* update config.yaml + freebmd.py constants (or have Python read `freebmd-districts.json`); add one live smoke probe per configured district ID to the parity run. **Size: S**

**FT-09 · medium · inefficiency — county district fan-out is not era-filtered; YKS umbrella code resolves to zero districts silently**
`.district`/`.county`/`.adjacent` scopes use `RegionConfig.districts(forChapmanCode:)` with no year filter (SearchDispatcher.swift:282-285) — for an 1850–1900 subject, 4–5 of 12 DBY queries target post-1974/1994/1997 composites that cannot match; catalogue counties are worse (LAN 72 districts, LND 55). The year filter exists (`FreeBMDDistrictCatalogue.covering(yearFrom:yearTo:)`, FreeBMDDistrictCatalogue.swift:89-94) but only the `.national` branch applies it. Worse: `uk-chapman-codes.json` has "YKS" but every Yorkshire district is tagged WRY/NRY/ERY, so a YKS-derived subject gets **zero** FreeBMD county queries with no warning.
*Recommendation:* intersect county district sets with catalogue year validity; alias YKS→[WRY, NRY, ERY] (and other umbrellas); warn when a non-empty chapman resolves to zero districts. **Size: M**

### 2.2 FreeCen

**FT-10 · high · correctness-bug — household enrichment assumes the target is the FIRST household member; Python tracks `is_target`**
`parseHouseholdDetail` builds the returned `CensusRecord` from `membersWithBirthYear.first` (FreeCenSource.swift:491-517). FreeCen lists households head-first; the "person found in your search" marker identifies the real target, but the Swift marker handling (FreeCenSource.swift:446-455) extracts the surname and discards the row position. Python records `target_row_start` and sets `is_target` per member (sources/freecen.py:297-319). Because `enrichWithHousehold` replaces the top hit with the detail record (FreeCenSource.swift:191-215), whenever the subject is not the head, the enriched record carries the **head's** name, age, birthYear, relationship, and occupation as the subject's. Faithfulness-of-port violation (`feedback_port_from_python.md`).
*Recommendation:* port `is_target` — remember the marker's index, select that member (first only as no-marker fallback), add `isTarget` to `HouseholdMember`. Coordinate with FT-15 (same struct change). **Size: M**

**FT-11 · high · unused-capability — `search_query[birth_chapman_codes][]` never used; the one axis that finds migrants is missing while ~90 residence counties get brute-forced**
The POST field list (FreeCenSource.swift:115-130) has residence `chapman_codes` only; `birth_chapman_codes` appears nowhere in the repo. The dispatcher scopes by where the subject *lived* at census time, but the tree-known stable fact is where they were *born*: a DBY-born subject in a Lancashire mill town is invisible to `.county` scope and reachable nationally only via ~90 codes × up to 8 census years of separate requests (SearchDispatcher.swift:385-387). One request with `birth_chapman_codes=[DBY]` and no residence filter covers the same ground server-side, on exactly the field the scorer trusts most (birth_county column already parsed, FreeCenSource.swift:352) — and matches the engine's chapman-anchor philosophy.
*Recommendation:* add `birthChapmanCode` to `FreeCenParams`; make it the primary axis for `.adjacent`/`.national` census sweeps, keeping residence codes for `.county`. **Size: M**

**FT-12 · medium · correctness-bug — record IDs neither unique nor stable: name-based ID collides across people and changes when enrichment succeeds**
Search-row ID is `"freecen_\(censusYear)_\(surname)_\(givenName)"` (FreeCenSource.swift:363) — two John Smiths in one census year collapse to one ID and overwrite each other under `evidence_records`' `"<profile>|<source_record_id>"` primary key (ProjectDatabase.swift:591). The enriched record uses a *different* scheme (`freecen_detail_…`, FreeCenSource.swift:495) swapped in by `enrichWithHousehold`, so the same record's ID depends on whether the detail fetch succeeded that run — a rejection saved against one form fails to suppress the other (rejectionLookup, ResearchPipeline.swift:35-42). The stable unique key is already in hand: the `/search_records/<id>` detail URL (FreeCenSource.swift:342-348).
*Recommendation:* use the `search_records` path segment as the canonical ID for both search row and enriched record; fall back to the composite only when no link parsed. **Size: S**

**FT-13 · medium · unused-capability — `freecen2_place_ids[]`/`search_nearby_places` unused; dispatcher comment points at a `FreeCenParams.parish` field that does not exist**
Place scoping is never used (`search_nearby_places` hardwired `"0"`, FreeCenSource.swift:123). SearchDispatcher's comment says parish restriction "would happen via FreeCenParams.parish… until birthLocationCode ships" (SearchDispatcher.swift:374-377) — but `FreeCenParams` has no parish field at all (RecordTypes.swift:551-563); the documented seam was never built. Parish knowledge exists today (config `district_parishes`, catalogue parish arrays).
*Recommendation:* fix the stale comment **now** (S); when parish scoping is scheduled, add `placeIds`+`searchNearbyPlaces` with a cached place-id lookup keyed on (parish, chapman) (L, deferred). **Size: S now / L deferred**

**FT-14 · medium · correctness-bug — `FreeCenParams.censusYear` and the `validYears` guard are both dead; the strategist path can put a non-census year on the wire**
`FreeCenSource` reads the census year from `query.yearFrom` (FreeCenSource.swift:77), never from `FreeCenParams.censusYear` (write-only); `validYears` (FreeCenSource.swift:61) is never referenced. The main dispatcher filters through `ScoringRules.censusYears`, but `FocusedQuery.toRecordQuery` passes yearFrom straight through (FocusedQuery.swift:90-95, 122) with no validation in `dispatchOne` — an MLX-suggested "FreeCen 1885" emits `record_type=1885`, an option that doesn't exist. Python guards exactly this ("Invalid census year", freecen.py:165-166); the port dropped it. Outcome today: silent zero or a Rails validation page parsed as no-results.
*Recommendation:* snap `query.yearFrom` to the nearest `validYears` member (or return `.outsideCoverage` naming the set); delete or use the dead param. **Size: S**

**FT-15 · low · parsing-gap — household parser drops marital_status, birth_county, disability, notes, and the is_target flag Python captures**
The household table has 11 columns (Swift's own 11-cell grouping, FreeCenSource.swift:443-459), but only indices 0-2, 4-6, 8 reach `HouseholdMember` (FreeCenSource.swift:459-472); marital_status, birth_county, disability, notes are discarded and the struct has no fields for them (RecordTypes.swift:332-339). Marital status distinguishes wife/widow/unmarried sister on identical relationships; birth_county disambiguates common place strings.
*Recommendation:* extend `HouseholdMember` with `maritalStatus`, `birthCounty`, `isTarget` (rows 3/7 + marker); disability/notes into per-member rawFields. Do together with FT-10. **Size: S**

### 2.3 FreeREG

**FT-16 · high · correctness-bug — record IDs use process-randomised `String.hashValue`; unstable across app launches (also Wirksworth)**
`FreeREGSource.swift:308` builds IDs as `"freereg_\(name.hashValue)_\(date.hashValue)"` — SipHash with a per-process random seed, so the same parish record gets a different ID every launch. These IDs are load-bearing across runs: `record_rejections` is keyed (profile_id, record_id) (ProjectDatabase.swift:171-173, 2179-2184), `evidence_records` preserves `user_status` on its `"<profile>|<source_record_id>"` key (ProjectDatabase.swift:586-594, 2260-2280), and `rejectionLookup` suppresses discards by `SourceRecord.id` (ResearchPipeline.swift:35-42) — so **user discard decisions are silently orphaned every launch**. The repo already knows the rule: FamilySearchSource.swift:569 explicitly avoids hashValue for this reason. WirksworthSource.swift:203/247 has the same defect (out of this audit's scope, same fix).
*Recommendation:* derive IDs from stable content — prefer the detail-URL path already extracted at FreeREGSource.swift:250-288 (contains a server-stable ID); fall back to a deterministic digest of name|date|parish|county|event_type. Fix Wirksworth too; consider a one-shot cleanup of orphaned `freereg_*` rows. **Size: M**

**FT-17 · medium · correctness-bug — name split assigns everything after the first token to the surname; middle names corrupt the surname field**
`parseResults` splits the Name cell with maxSplits:1 — parts[1] (the whole remainder) becomes the surname (FreeREGSource.swift:300-302): "Sarah Jane Kenworthy" → surname "Jane Kenworthy". Inconsistent with FreeCen (last token = surname, FreeCenSource.swift:358-360); Python keeps the site's own columns (freereg_search.py:259-261). Surname feeds the scorer's identity gates, so any multi-forename FreeREG record carries a wrong surname.
*Recommendation:* match FreeCen's convention, or better, prefer explicit Surname/Forenames columns from the header map (`row["surname"]` is already consulted at FreeREGSource.swift:292). **Size: S**

**FT-18 · medium · unused-capability — detail pages (parents for baptisms, spouse/witnesses for marriages) never fetched; fatherName/motherName always nil**
The connector extracts `detailURL` per row (FreeREGSource.swift:250-251, 284-289) but conforms only to `RecordSource`, not `DetailFetchingSource` (FreeREGSource.swift:10); every `ParishRecord` ships `fatherName: nil, motherName: nil` (FreeREGSource.swift:322-323). Python implements `fetch_record_detail` (freereg_search.py:298-331) and enriches top results. The app-side pattern already exists (FreeCen: `DetailFetchingSource` + cap-1 enrichment, FreeCenSource.swift:9, 156-160). Parent names on baptism rows are exactly the family-context tokens pre-1837 identity work needs, where FreeREG is the only structured source.
*Recommendation:* mirror the FreeCen pattern — cap 1, existing 1000 ms pacing; populate fatherName/motherName + rawFields; base the stable record ID on the same URL (FT-16). **Size: M**

**FT-19 · medium · unused-capability — `place_ids[]` never used; `FreeREGParams.parish`/`registerType` are dead fields callers populate for nothing**
`FreeREGSource` reads only `chapmanCode` from its params (FreeREGSource.swift:75); `parish` and `registerType` (RecordTypes.swift:613-614) are populated by callers (FocusedQuery.swift:96-101) but never read, and no `place_ids` field is ever emitted (FreeREGSource.swift:89-116). For an inherently parish-event source, county-wide queries are the bluntest instrument; likely parishes are already known (config.yaml:29-85, catalogue parish arrays).
*Recommendation:* either wire parish through a place-id resolution step and emit `place_ids[]`, or delete the two dead fields so callers stop populating no-ops. **Size: S (delete) / L (place scoping, deferred)**

**FT-20 · medium · parsing-gap — Rails validation-error pages parse as zero results; the Python error check was dropped in the port**
Python detects validation failures ("error prohibited", freereg_search.py:182-195); Swift `parseResults` (FreeREGSource.swift:235-328) has no error detection — a rejected POST is indistinguishable from a genuine no-hit and flows into negative-evidence reasoning. Same fragility in FreeCen (`guard html.contains("We found")`, FreeCenSource.swift:315).
*Recommendation:* port the check — Rails error banner (or neither results-marker nor no-results-marker) → `.unavailable(reason:)`, never `.results([])`. Same rule for FreeCen. Overlaps FT-26. **Size: S**

**FT-21 · low · unused-capability — `witness` search unused; marriage-witness probes are an untapped FAN-club channel (deferred)**
No witness field anywhere in the repo; the form can extend name matching to witnesses. Relatives routinely witness marriages — a collateral-kin signal no configured source exposes (HypothesisEngine+SiblingExists currently infers from birth indexes alone). But witness hits are a different evidence class (subject not the principal) and would pollute identity clustering without a record-role concept.
*Recommendation:* defer until `SourceRecord` has a record role (witness/informant); then hypothesis-driven probes only, never the default sweep. **Size: L (deferred)**

### 2.4 Cross-source

**FT-22 · high · parsing-gap — FreeCen and FreeREG fetch only page 1 of paginated Rails results; silent truncation**
Both connectors issue a single POST and parse whatever rows come back (FreeCenSource.swift:132-149, FreeREGSource.swift:118-131); no page/per-page field in either field map, no follow-up GET, no pagination-nav parsing. Any result set larger than one page is silently truncated and returned as complete. Python is identical (freecen.py:188-212, freereg_search.py:161-175). Contrast FreeBMD, which at least detects its overflow interstitial (FreeBMDSource.swift:298-333).
*Recommendation:* (1) run Python's `probe_form` (freereg_search.py:26-59) once against both live forms for a results-per-page select, and max it in the Swift field maps; (2) parse the pagination nav and fetch subsequent pages through existing pacing — or at minimum detect "more pages exist" and surface it via FT-23. **Size: M**

**FT-23 · high · correctness-bug — sites' own hit counts parsed nowhere; `SourceQueryResult` cannot express "truncated", so negative-evidence reasoning trusts partial pages**
FreeCen's "We found N Results" is boolean-checked and N dropped (FreeCenSource.swift:315); FreeREG's count text ignored; FreeBMD's interstitial entry count discarded (Python surfaces all three: freecen.py:90-98, freereg_search.py:204-207, freebmd.py:84-86). Structurally, `SourceQueryResult` (AncestorKit RecordTypes.swift:645-656) has no `totalCount`/`isTruncated`, so parsed-rows vs claimed-total can never be checked — and GPS criterion 1 "reasonably exhaustive search" (GPSScorer.swift:12/56/65-77), the per-run QueryCache, and the activity bus all treat a first page as the complete answer.
*Recommendation:* parse the hit count in all three connectors; extend `SourceQueryResult` (or a result envelope) with `totalCount`/`truncated`. Downstream: never record a negative search and exclude the query from GPS criterion-1 accounting when `truncated == true`; log rows≠total as a parser-drift alarm. **Size: M**

**FT-24 · high · correctness-bug — QueryCache key omits FreeCen/FreeREG chapman code and FreeCen birthYearRange; distinct wire requests collide**
`QueryCache.cacheKey` (QueryCache.swift:78-109) extracts districtCode from `.freeBMD` params only; `chapmanCode` and `birthYearRange` never enter the key despite changing the outbound POST (FreeCenSource.swift:109-113/129, FreeREGSource.swift:91) — violating the key's own contract comment (QueryCache.swift:74-75). Consequences: under `.adjacent`/`.national`, every post-iteration-1 consumer is served whichever single county's results were written last — county coverage silently collapses to one county; and after `refineSubject` narrows the birth window (ResearchPipeline.swift:250), the narrowed probe is served stale wide results (or vice versa, dropping records).
*Recommendation:* serialise each params case's wire-affecting fields into the key (chapman, censusYear, birthYearRange); add a test asserting two queries differing only in chapmanCode or birthYearRange produce different keys. **Size: S**

**FT-25 · high · inefficiency — multi-value form fields are structurally impossible: `postForm` takes `[String:String]`, so one county per request forever**
Both Rails sites accept repeated `search_query[chapman_codes][]` entries (Python builds POST data as a tuple list precisely for this, freereg_search.py:136-149), but the Swift transport signature is `fields: [String: String]` (HTTPClient.swift:7; body assembly SourceHTTPClient.swift:38-40), which cannot encode a repeated key. Hence one request per chapman code: FreeCen `.adjacent` ≈ 6 × up to 8 census years, `.national` ≈ 90 × years; FreeREG `.national` ≈ 70 codes at 1 s pacing.
*Recommendation:* change `postForm` to `[(String, String)]` (or add an overload); then batch scope counties per request. **Sequence after FT-22/FT-23** — wider queries make first-page truncation more likely, and per-code queries currently double as an accidental result partitioner. **Size: M**

**FT-26 · medium · parsing-gap — zero results, validation errors, too-many-results, layout changes, and login walls all conflate to cacheable `.results([])`**
FreeREG returns `.results(records)` on any HTTP-200 body (FreeREGSource.swift:130-134); FreeCen's sole guard is `html.contains("We found")` (FreeCenSource.swift:315). Python distinguishes validation errors, no-results text, and login walls (freereg_search.py:183-226; freecen.py:90-94). The empty arrays propagate as legitimate: QueryCache caches them (QueryCache.swift:66-71), the activity feed reports 0, and nothing marks the source unavailable even though `.unavailable` exists precisely for this.
*Recommendation:* port the page-state triage; distinguish count==0 (genuine empty) from regex-miss (`.unavailable("could not parse results page")`). Add a saved error-page fixture test per site so copy drift fails loudly. Subsumes FT-20's mechanism; ship together. **Size: M**

**FT-27 · medium · planning-gap — the audit's ground-truth live-form payload was never delivered; PLAUSIBLE items need one confirmation pass**
The orchestration's GROUND TRUTH block arrived as the literal string `undefined`, and static-analysis-only was mandated, so live-form claims rest on the task's enumerated field names, the Python references, and in-repo scrape artifacts (freebmd-districts.json, 1121 entries, 2026-05 enrichment per FreeBMDDistrictCatalogue.swift:16-20). Anything depending on today's exact encodings — Phonetic value string (FT-06), count semantics, districtid validity (FT-08), per-page selects (FT-22) — is **PLAUSIBLE, not confirmed**.
*Recommendation:* one budget-conscious live probe session to upgrade/downgrade the PLAUSIBLE items; see §5.6. **Size: S**

**FT-28 · low · inefficiency — national fan-out issues one HTTP request per chapman code (~90 FreeCen / ~70 FreeREG) though the forms accept multiple codes per request**
One `RecordQuery` per code (SearchDispatcher.swift:385-412, 425-449), each a separate POST with a single `chapman_codes[]` value. At enforced pacing, a national sweep costs ~45–70 s of pure rate-limit sleep per record type per surname variant — ~70-90× volunteer-source load per logical question.
*Recommendation:* batch codes into regional groups (or one request) — **only after FT-22/FT-23/FT-25**, with automatic re-split on truncation (mirroring FreeBMD's adaptive split). **Size: M**

**FT-29 · low · correctness-bug — form-body percent-encoding uses `.urlQueryAllowed`; values containing `&`, `+`, or `=` corrupt the POST**
`SourceHTTPClient.postForm` encodes values with `.urlQueryAllowed` (SourceHTTPClient.swift:38-40), which permits `&`, `=`, `+` inside values — `&` splits the pair, `+` decodes as a space. Names rarely contain these, but parish/place strings can ("Clifton & Compton" exists in the district data), and all three connectors share this transport.
*Recommendation:* encode with a form-safe set (alphanumerics + `-._*`, space→`+`) or build the body via URLComponents — one shared fix. **Size: S**

---

## 3. Top-5 priority (proposed)

Ranking principle derived from the data: **persisted-data integrity** (user decisions, evidence keys) beats **evidence correctness** (wrong facts attached to subjects) beats **search honesty** (truncation, negative evidence) beats efficiency. The famous request-storm items (FT-01/02/25/28) are deliberately *not* top-5: they waste budget but corrupt nothing, and FT-25/28 are sequenced behind the honesty envelope anyway.

| # | ID | Finding | Why first |
|---|----|---------|-----------|
| 1 | FT-16 | FreeREG (+Wirksworth) hashValue record IDs | Every launch silently orphans user discard decisions and `user_status` in `evidence_records` — ongoing, compounding data damage; fix is contained |
| 2 | FT-10 | FreeCen household-target bug | Enriched census evidence carries the household **head's** name/age/birthYear/occupation as the subject's whenever the subject isn't head — actively wrong facts feeding the scorer |
| 3 | FT-12 | FreeCen ID collision + enrichment ID flip | Same-name people overwrite each other in `evidence_records`; rejections fail to suppress across enrichment states — the FreeCen half of the ID-integrity class |
| 4 | FT-24 | QueryCache key omits chapman/birthYearRange | Adjacent/national county coverage silently collapses to one county after iteration 1; narrowed probes served stale wide results — invisible recall loss inside one run |
| 5 | FT-22 + FT-23 | Page-1 truncation with no hit-count honesty | Truncated pages are recorded as complete answers — poisons negative-evidence reasoning and GPS "exhaustive search" accounting; precondition for every batching fix |

FT-16 + FT-12 + FT-10 + FT-15 plausibly ship as one "FreeCen/FreeREG integrity" commit series; FT-22/23 as the shared envelope change.

---

## 4. Rejected and unverified findings

The verify phase classified 20 findings as not-confirmed, but the envelope conflates two very different things. The logs show verify agents lost to stalls and a session limit ("Verify phase: 29 confirmed, 20 rejected"; multiple `verify:*` failures: connection closed, session limit). Separated honestly:

### 4.1 Genuinely refuted (11) — do not re-find these

One line each; full two-lens rejection notes are in the audit envelope.

- **FreeBMD "confidence" column dropped** — the live fixture shows parts[0] alternating 41/40 per row: a row-striping display code, not transcription quality; persisting it as "confidence" would enshrine a misreading; the ID-collision half targets an 8-part row shape never observed live.
- **`type=All` merged queries** — birth/marriage/death windows are disjoint by construction (ResearchSubject.swift:206-225), so All-mode needs a ~97-year union window, destroying per-type precision; `s_surname` is type-overloaded (spouse vs MMN); negative_searches is keyed per record_type.
- **`aad`/`agepresent` server-side age filters** — strictly tighter than the scorer's deliberate no-age-pass rule (RecordScorer.swift:388-394): silent recall loss plus corrupted negative evidence; post-1969 the field holds DOB not age.
- **`count` results-per-page probe** — FreeBMD's over-cap behaviour is a refusal interstitial, not pagination (live-derived, commit 95e4b17); multi-thousand-row pages arrive whole; no truncation "middle band" exists to fix.
- **Quarter-level `sq`/`eq` narrowing** — saves zero requests (cost is per-request), contradicts the documented ±1-year registration-slip tolerance, and hides same-year namesakes the multi-hypothesis framework needs.
- **`exactgiven`/`mono`/`spouseidonly` toggles** — bandwidth isn't FreeBMD's constraint; unconfirmed toggles risk the known silent-zero failure class (sq/eq precedent) for zero recall gain; exactgiven's rationale is already documented at the point of change.
- **FreeCen `start_year`/`end_year` semantics doubt** — birth-year semantics are a deliberate spec decision (archived SOURCE_INTEGRATION_SPEC.md:183/232) and empirically validated by months of live results (harness runs returned so many rows enrichment had to be capped).
- **occupation/marital_status as narrowing axes** — no deterministic input exists (Profile has no occupation field); marital-status filters wrongly exclude widowed entries; the documented direction is extraction (FT-15), not filtering.
- **FreeREG `inclusive`/`no_surname`/`region`** — `inclusive` admits undated rows the date gate hard-fails (RecordScorer.swift:317-320): Triage clutter, zero facts; `no_surname` skip is a spec decision; `region` duplicates the built chapman-adjacency machinery.
- **Discover mode should lead strict-first** — loose-first is spec-mandated (RESEARCH_PIPELINE_SPEC.md:719) and test-enshrined; the ladder stops on *any* non-empty batch, so strict-first would foreclose phonetic reach in the one recall-first mode. Residual kernel already tracked as spec gap G3.
- **Staged waves (BMD first, then narrowed census)** — designed no-op: the thin-subject verdict cap prevents wave-A index hits from producing `.fact`, so wave B runs with the same window after serializing wall time behind the most breaker-prone source; Python sequences the *opposite* way.

### 4.2 Fact-confirmed, value lens never ran (5) — carry forward, **not rejected**

These passed the fact lens (citations verified, several with endorsing notes) but their value verification died on infrastructure. Treat as strong candidates pending one value pass; do not implement without it, do not discard.

- **UV-01** — Subject marriage window ignores known children's birth years (44–55-year windows where 10–12 would do; `FamilyContext` has no childBirthYears field, structurally unreachable at query build).
- **UV-02** — Death-search floor never advances from alive-at evidence (census facts / children's births don't tighten the 80-year fallback; `absentFromCensusSuggests` port has zero callers).
- **UV-03** — `.parish` scope silently degrades to county (FreeCen/FreeREG) or zero queries (FreeBMD) while the UI promises parish scoping (ResearchConfigSheet.swift:211) — overlaps FT-13/FT-19.
- **UV-04** — chapman_codes multi-value fan-out (fact notes: "finding stands; recommendation is sound") — substantially covered by confirmed FT-25/FT-28; fold in.
- **UV-05** — FreeBMD `.adjacent` silently equals `.county` on a stale "no per-district chapman data" justification; the catalogue has been 100% chapman-tagged since the 2026-05 enrichment; FreeCen/FreeREG *do* honour `.adjacent` — cross-source inconsistency within one run.

### 4.3 Never verified at all (4) — unverified, titles only

Dropped by the session limit before either lens ran. Candidates for the next audit batch; **treat every claim as unverified**.

- **UV-06** — Hypothesis flows bypass the per-run QueryCache; level-2 ladder windows fully contain level-1 (re-downloads).
- **UV-07** — No cross-run negative-search memory; `negative_searches` used only as a resume-state hack (feeds §5.2).
- **UV-08** — In `.all` mode the variant tier re-fires the strict tier's exact query wire-for-wire; `wildcardSurname` axis dead.
- **UV-09** — Birth-year-candidate census probes are near-duplicates of main-loop census queries.

---

## 5. Cross-cutting recommendations

1. **Truncation/hit-count honesty in `SourceQueryResult` first.** FT-22, FT-23, FT-05, and FT-26 all converge on the same structural hole: connectors cannot say "this answer is partial" or "this page wasn't a results page". One envelope change (`totalCount`, `truncated`, richer `.unavailable` reasons) unblocks all four and is the precondition for every batching change. Negative evidence and GPS criterion-1 must consume the flag from day one.
2. **Persistent negative-search cache — after (1), never before.** Cross-run memory of "searched X, found nothing" is the natural next step (UV-07 raised it; unverified, but the need is corroborated by confirmed findings): a truncated or unparseable page recorded as a durable negative would be worse than no cache. Key it by the full set of wire-affecting axes — the exact lesson of FT-24 — and respect the existing per-run `record_rejections`/user-discard semantics.
3. **Stable content-derived record IDs as a connector-wide invariant.** FT-16 and FT-12 are the same defect class in two connectors (plus Wirksworth). Rule: prefer a server-stable URL path segment, else a deterministic digest of normalised content; never `hashValue`, never name-composites. FamilySearchSource already states the rule (FamilySearchSource.swift:569 per finding text) — add a test or lint that greps connectors for `hashValue`-derived IDs so the class can't recur.
4. **Request-budget discipline, in sequence.** (a) honesty envelope (§5.1) → (b) server-side scoping params that already exist: `countyid` (FT-01), `districtid=""` national (FT-02), `birth_chapman_codes` (FT-11) → (c) multi-value transport + chapman batching with re-split on truncation (FT-25, FT-28). Order matters: batching before truncation-honesty converts silent page-1 truncation from rare to routine.
5. **Page-state triage fixtures.** Every connector gets saved fixture pages for: results, genuine-empty, validation error, login wall, overflow/too-many-results. Parser must classify all five; anything unclassifiable returns `.unavailable`, never a cacheable `[]` (FT-20, FT-26, FT-05).
6. **One live-form confirmation session** (FT-27) to discharge the PLAUSIBLE items in one budget-conscious pass: Phonetic value encoding (FT-06), districtid validity on today's form (FT-08), per-page/result-count selects (FT-22), FreeREG place_ids/witness field semantics (FT-19/FT-21). Volunteer sources: one pass, no hammering (`feedback_volunteer_sources_rate_limits.md`).
7. **Finish the interrupted verification.** Re-run the value lens for UV-01–UV-05 and both lenses for UV-06–UV-09, and re-run the critic pass (it produced zero additions because it *failed*, not because it was satisfied).

---

## 6. Tier-1 sources (CWGC / FindAGrave / Probate)

> **⏳ PENDING — verification in progress overnight.** This section will be appended when the adversarially-verified tier-1 results land. Raw unverified findings exist in the audit envelope (`tier1-audit-unverified.txt`) but are deliberately excluded until verified.
