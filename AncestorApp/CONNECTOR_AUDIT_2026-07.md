# CONNECTOR_AUDIT_2026-07 — Free-Trio + Tier-1 Connector Audit (deferred residue)

**Status: 56 of 58 findings SHIPPED 2026-07-11/13** (`git log --grep='#FT-\|#T1-'` is the archive). This doc is thinned to its still-live residue: the two deferred capabilities (**FT-19** place-scoping, **FT-21** witness-probes), the interrupted-verification batch (**UV-01/02/06/07/08/09**), and the four **UNVERIFIED** tier-1 critic morsels (**T1-C1..C4**). Shipped finding bodies, the Top-5 ranking, the §5.1–§5.6 cross-cutting recommendations, and the refuted lists are compressed to one line each — full text is in git history.

Scope was the three volunteer-transcription connectors (FreeBMD, FreeCen, FreeREG) plus the shared machinery (`SearchDispatcher`, `QueryCache`, `SourceHTTPClient`, `SourceQueryResult`), and tier-1 (CWGC / FindAGrave / Probate). Method: find → two-lens adversarial verify (fact lens + value lens), static-analysis-only with one rationed live probe (2026-07-11).

---

## 1. Shipped — one line each (do not re-open; git-only)

### Free-trio (FT-nn) — all SHIPPED except FT-19/FT-21

- **FT-01** county axis via `countyid`, drop the 12-per-district loop (6732596; live-probed).
- **FT-02** `.national` collapses to one `districtid=""` query (6732596).
- **FT-03** same-page spouse recovery via vol/pgno (50e3365).
- **FT-04** county→national escalation on empty results (50e3365).
- **FT-05** unsplittable-overflow honesty into the search-outcome envelope (a6e9c6d).
- **FT-06** soundex field was `sndx=on` not `Phonetic` (never engaged); send `sndx=on` only when enabling — live-probed (bigger than diagnosed).
- **FT-07** strategist district-name→ID resolution (50e3365).
- **FT-08** stale Python district IDs corrected in config.yaml + freebmd.py (live smoke-probe half deferred with the rationed budget).
- **FT-09** era-filtered county fan-out + YKS→WRY/NRY/ERY alias (50e3365).
- **FT-10** faithful `is_target` household port (subject-not-head bug) (2b3d5e4).
- **FT-11** birth-county axis (`birth_chapman_codes`) for FreeCen/FreeREG (503cd22).
- **FT-12** stable URL-derived FreeCen record IDs (2b3d5e4).
- **FT-13** stale-comment fix (S half); the **L place-scoping half is deferred → FT-19** below.
- **FT-14** census-year guard (snap to `validYears`) (503cd22).
- **FT-15** restored dropped household columns (marital_status/birth_county/is_target) (2b3d5e4).
- **FT-16** launch-stable FreeREG + Wirksworth record IDs + v31 orphan purge (46f9f84/1be4145).
- **FT-17** name-split fix (surname no longer swallows middle names) (503cd22).
- **FT-18** FreeREG detail fetch (parent/spouse names) (503cd22).
- **FT-20** Rails validation-error page triage (503cd22).
- **FT-22** page-1 truncation → honesty envelope + pagination (a6e9c6d, 503cd22).
- **FT-23** hit-count/`truncated` on the result envelope (a6e9c6d).
- **FT-24** QueryCache key carries all wire-affecting params (af24a00).
- **FT-25** multi-value chapman batching (default-OFF gate) (dispatcher-side).
- **FT-26** page-state triage fixtures (503cd22 / a6e9c6d).
- **FT-27** live-form ground truth captured; PLAUSIBLE items discharged (FT-01/FT-06).
- **FT-28** national fan-out chunked into groups of 10 (default-OFF gate).
- **FT-29** form-safe x-www-form-urlencoded serializer (78ab374).

### Tier-1 (T1-nn) — all 29 SHIPPED 2026-07-11/13

- **T1-01** engine-wide search-outcome honesty envelope (a6e9c6d).
- **T1-02** date gate reads CWGC `AgeAtDeath` (1cd73db).
- **T1-03** skip wire-identical strictness re-fires for FAG/Probate (08a4912).
- **T1-04** cross-run negative-search cache (08a4912; = §5.2).
- **T1-05** CWGC geography-gate port (additional_info next-of-kin) (1cd73db).
- **T1-06** CWGC initials-indexed casualties matchable (1cd73db).
- **T1-07** CWGC death-year bounds + WarSelect overlap test (cd0eb4d).
- **T1-08** CWGC eligibility interval-overlap + death-window trigger (cd0eb4d).
- **T1-09** CWGC CSV parsed via header-keyed DictReader semantics (cd0eb4d).
- **T1-10** CWGC additional_info deterministic parse → parents/spouse/residence (1cd73db).
- **T1-11** projection wires honours/countryOfService + FAG plot (cd0eb4d).
- **T1-12** CWGC dispatched once (`.death` only) (50e3365).
- **T1-13** CWGC CSV-header sanity check → `.unavailable` (cd0eb4d); detail port deferred.
- **T1-14** CWGCParams.conflict wired (cd0eb4d).
- **T1-15** FAG block/error → `.unavailable` (a6e9c6d).
- **T1-16** FAG year filters plumbed + total/tooMany parsed + limit raised (800e661).
- **T1-17** FAG detail-fetch cap on the FS bridge + symmetric native enrich (9a6cfcb).
- **T1-18** FAG `includeNickName=true` (1a4abfc).
- **T1-19** FAG location scoping + cemetery URL (1a4abfc).
- **T1-20** FAG memorial family-links → leads (1a4abfc).
- **T1-21** FAG location into QueryCache key (af24a00).
- **T1-22** FAG detail-page age captured onto BurialRecord (1a4abfc).
- **T1-23** FAG structured name fields incl. maidenName (800e661/1a4abfc).
- **T1-24** Probate pagination to a 500 budget (e186dd7).
- **T1-25** Probate `hasError` → `.unavailable` (a6e9c6d).
- **T1-26** Probate `.outsideCoverage` for pre-1996 windows + soldier-wills carve-out (34d0882).
- **T1-27** stable Probate uid / FAG memorialId IDs (1a4abfc).
- **T1-28** Probate postcode/title parsed + courtType wired (34d0882).
- **T1-29** Probate firstnames semantics + date-of-probate probe (34d0882).

**§3 Top-5 priority** (record-ID integrity → wrong-facts → search-honesty → efficiency) all shipped 2026-07-11/12 — history only.

**§5.1–§5.6 cross-cutting recommendations** — truncation/hit-count honesty envelope, persistent negative-search cache, stable content-derived IDs, request-budget discipline, page-state triage fixtures, one live-form confirmation session — all shipped 2026-07-11/12 (T1-01/FT-22/FT-23, T1-04, FT-16/FT-12/T1-27, FT-01/02/11/25/28, FT-20/26, FT-06/FT-27).

---

## 2. Deferred capabilities (OPEN)

**FT-19 · medium · unused-capability — FreeREG `place_ids[]` never used; parish-level scoping deferred (L)**
`FreeREGSource` reads only `chapmanCode` from its params (FreeREGSource.swift:75); `parish`/`registerType` (RecordTypes.swift:613-614) are populated by callers (FocusedQuery.swift:96-101) but never read, and no `place_ids` field is ever emitted (FreeREGSource.swift:89-116). For an inherently parish-event source, county-wide queries are the bluntest instrument; likely parishes are already known (config.yaml:29-85, catalogue parish arrays). The S half (delete the dead fields) can ship anytime; the L half — wire parish through a place-id resolution step and emit `place_ids[]` — is the deferred capability. Overlaps **FT-13**'s deferred place-scoping half and **UV-03**. **Size: S (delete) / L (place scoping, deferred).**

**FT-21 · low · unused-capability — FreeREG witness search unused; marriage-witness probes are an untapped FAN-club channel (blocked)**
No witness field anywhere in the repo; the form can extend name matching to witnesses. Relatives routinely witness marriages — a collateral-kin signal no configured source exposes (`HypothesisEngine+SiblingExists` currently infers from birth indexes alone). But witness hits are a different evidence class (subject not the principal) and would pollute identity clustering **without a record-role concept on `SourceRecord`**. Defer until `SourceRecord` has a record role (witness/informant); then hypothesis-driven probes only, never the default sweep. **Size: L (blocked on SourceRecord record-role).**

---

## 3. Finish interrupted verification — UV batch (§5.7)

The free-trio verify phase lost agents to stalls and a session limit; the critic pass produced zero additions because it *failed*, not because it was satisfied. These findings need their interrupted lens(es) re-run **before** any member is built. Re-verify DS-adjacent scope against current code (several were substantially covered by shipped FT/T1 work — fold, don't rebuild).

- **UV-01 · fact-confirmed, value lens never ran** — Subject marriage window ignores known children's birth years (44–55-year windows where 10–12 would do; `FamilyContext` has no childBirthYears field, structurally unreachable at query build).
- **UV-02 · fact-confirmed, value lens never ran** — Death-search floor never advances from alive-at evidence (census facts / children's births don't tighten the 80-year fallback; `absentFromCensusSuggests` port has zero callers). *(= the DS-27 dead-code residue.)*
- **UV-06 · never verified (titles only)** — Hypothesis flows bypass the per-run QueryCache; level-2 ladder windows fully contain level-1 (re-downloads).
- **UV-07 · never verified (titles only)** — No cross-run negative-search memory; `negative_searches` used only as a resume-state hack. **Mostly shipped as T1-04** — re-verify the residue, don't rebuild.
- **UV-08 · never verified (titles only)** — In `.all` mode the variant tier re-fires the strict tier's exact query wire-for-wire; `wildcardSurname` axis dead.
- **UV-09 · never verified (titles only)** — Birth-year-candidate census probes are near-duplicates of main-loop census queries.

*(UV-03 marriage/parish scope-degrade overlaps FT-13/FT-19 above; UV-04 chapman multi-value is covered by shipped FT-25/FT-28; UV-05 FreeBMD `.adjacent`==`.county` — carry forward with the UV batch if the value pass revives it.)*

---

## 4. Refuted — do not re-find (one line each)

Full two-lens rejection notes are in the audit envelopes (git-only).

**Free-trio (11):** FreeBMD "confidence" column is a row-striping display code, not transcription quality · `type=All` merged queries destroy per-type precision (disjoint windows) · `aad`/`agepresent` server-side age filters are tighter than the deliberate no-age-pass rule · FreeBMD `count` results-per-page is a refusal interstitial, not pagination · quarter-level `sq`/`eq` narrowing saves zero requests and hides namesakes · `exactgiven`/`mono`/`spouseidonly` toggles risk the silent-zero class for no recall gain · FreeCen `start_year`/`end_year` semantics are a deliberate spec decision, empirically validated · occupation/marital_status narrowing has no deterministic input · FreeREG `inclusive`/`no_surname`/`region` are spec decisions / duplicate machinery · discover-mode strict-first contradicts spec-mandated loose-first · staged BMD-then-census waves are a designed no-op.

**Tier-1 (11):** Probate detailURL nil is the deliberate non-addressable pattern · FAG bio/inscription enrich-native adds Cloudflare load (capped kernel = T1-17) · CWGC AgeOfDeath server-side filter would drop unknown-age casualties (gate half = T1-02) · CWGC AdditionalInfo as a search *input* is unevidenced · CWGC ServedIn/Regiment/Rank/Honours query params are speculative narrowing · Tab=exact drift / delete-500-sniff is documented + graceful · eligibility-excludes-women is spec-pinned (widening = new feature) · `includeMaidenName` request param was invented (real fix = response-side T1-23) · FAG family-relationship query axes don't exist (parsing version = T1-20) · deficit-driven record-type routing already exists at the hypothesis layer · FAG location gazetteer-normalisation is backwards (indexes cemetery location).

---

## 5. Tier-1 critic additions — **UNVERIFIED**

The tier-1 critic pass ran to completion and produced four additions. **Neither lens has verified them** — candidates for the next verify batch, not backlog entries.

- **T1-C1 · findagrave · unused-capability · medium — dead Cloudflare-clearance path.** `ensureCloudflareClearance()` (FindAGraveSource.swift:222-235), the Keychain-backed `FindAGraveCookieStore`, and `FindAGraveCloudflareClearance.acquire()` are never invoked from search()/fetchDetail(), which call `FindAGraveBrowserFetcher` directly (its `WKWebsiteDataStore` cookie jar is a separate persistence mechanism). Wire the store into the fetch path or delete the subsystem and its misleading doc comments.
- **T1-C2 · findagrave · inefficiency · medium — WKWebView fetch has zero retry.** CWGC/Probate ride `SourceHTTPClient`'s `withRetry(retries: 3)` backoff (SourceHTTPClient.swift:49-60); FAG's browser fetch is a single load() with a 45 s deadline (FindAGraveBrowserFetcher.swift:62, 117-121) — one transient hiccup fails the whole query as `.unavailable`. Bounded retry for timeout/loadFailed only (not challengeUnresolved).
- **T1-C3 · findagrave · correctness-bug · low — search URL built with `.urlQueryAllowed`** (FindAGraveSource.swift:121): '&', '+', '=' inside values corrupt the query string. Same class as FT-29 but a different call site (FT-29 is scoped to `SourceHTTPClient.postForm`). Build via URLComponents/URLQueryItem as CWGC/Probate already do.
- **T1-C4 · cross-source · planning-gap · low — zero test coverage for apostrophes/diacritics** (O'Brien, Müller) across all three connectors' fixtures; CWGC's quote-toggle CSV scanner has never been exercised against an apostrophe inside a quoted AdditionalInfo. One fixture/test per connector closes it.
