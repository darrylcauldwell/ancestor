# FamilySearch Read Leg — Build Plan

**Status: Active** · 2026-07-14
**Parent spec:** `FAMILYSEARCH_SOURCE_SPEC.md` (§§14–19 official-API amendment; §19 defines the
acceptance criteria A1–A9 this plan implements). This document is the implementation slicing —
commits reference these change numbers (`feat: … #Change3`).

## Context

The FamilySearch Beta AppKey arrived 2026-07-13 (stored in gitignored `.env` as
`FAMILYSEARCH_BETA_APPKEY`; Confidential per the FSI Developer Agreement — never committed,
never logged). Its arrival follows agreement countersigning in FS's own onboarding sequence, so
the agreement's §15 scraping ban is treated as live: **the cookie transport is contractually
dead**. A 2026-07-14 five-way capability audit (Swift connector / spec catalog / Python parity /
pipeline blast radius / research corpus — findings in the session scratchpad `fs-audit/`)
confirmed the spec's §2.3 bet: the q.* search grammar, GEDCOMX parser, trust tiering, and scorer
wiring carry over to `GET /platform/records/personas` with only a credential + URL-prefix swap.

**Scope rule for the interim window** (cookie transport still wired until Change 5 verifies
live): transport-agnostic improvements only — parser fixes, honesty metadata we already receive,
schema commits. **No new request volume and no new endpoints on the cookie path.** Pagination
therefore lands only with the OAuth transport.

Awaiting FamilySearch: registration of redirect URIs
(`http://127.0.0.1:49877/familysearch-auth` primary, `dev.dreamfold.ancestor-research://familysearch-auth`
fallback) and Realm `https://dreamfold.dev/ancestor-research`. Changes 1–4, 6, 7 are buildable
and testable before that lands; Change 5's live verification and all of Change 8 are gated on it.

## Decision log

- **Funeral stays `.death`, diverging from spec §3.1's `Funeral → .burial`.** A funeral notice
  dates death to within days and must stay eligible to write `.deathDate` via ApplyEngine
  (`.burial` never writes profile date fields). Shipped 2026-07-13 (`0a11a22`) with regression
  tests; the §3.1 table row is treated as amended by this log entry.
- **Divorce family (Divorce/DivorceFiling/Annulment/Engagement/Separation) is NOT mapped to
  `.marriage`.** A divorce year flowing into `ApplyEngine.applyMarriageToSubjectSpouseEdge` and
  ConvergenceEngine's `marriage:<year>` pooling would assert a wrong marriage date. They fall
  through to the query-hint default; a `.divorce` RecordType is second-cut enum work per the
  defer-enum-sprawl rule.
- **Obituary is NOT explicitly promoted cross-hint.** Under a `.death` query it already
  classifies `.death` via the query-hint default; explicit promotion from other hints risks
  publication-lag false-fails against the `.death` ±1 scorer tolerance.
- **Burial nil-date carve-out is keyed on `memorialID` presence.** The FS→FindAGrave bridge
  guard (`burial.deathYear == nil`, ResearchPipeline) must keep firing for FAG-collection
  records; all other burial/cremation records get their real dates.
- **`negative_searches` reader must filter on `result_kind`.** Today the table holds only
  clean-zero rows by writer construction; once truncated/positive kinds are persisted, only
  exhaustive-zero rows may suppress re-searches (T1-04 correctness guard (a) moves into the
  reader).
- **FS hint/match scores order leads only** (ADR-005 / spec §18): never trust tier, gate,
  verdict, or convergence inputs. Unit-test-asserted at Change 8 (A8).
- **§16 pointer-only licensing posture stands** until the Compatibility Checklist wording is
  fetched from the developer portal (first action once OAuth works — Change 8).

## Changes

**Status (2026-07-14):** Changes 1–4, 6, 7, 9, 10, 11 SHIPPED and gated (full suite green,
2559 tests). Change 5 (transport swap) + Change 8 (beta probes/acceptance) gated on
FamilySearch registering the redirect URI + confirming the records-search grant.
Commits: 1 `a1d946d` · 2 `178dd49` · 3 `e77fa6a` · 4 `a1e745f` · 6 `8e417be` · 7 `3fbc92e`.

### Change 1 — Fact-type map expansion (S, transport-agnostic) — SHIPPED `a1d946d`
`recordType(forGedcomxFact:queryHint:)` and `pickPrimaryFact`'s hinted-types sets are a
**mirrored pair — update in the same commit**:
`BirthNotice → .birth`; `Blessing → .baptism`; `MarriageLicense`/`MarriageContract`/
`MarriageNotice`/`CommonLawMarriage → .marriage`. Primary facts whose suffix remains unmapped
record `rawFields["unmappedFactType"] = suffix` (observability for second-cut enum decisions).
Fixture tests per new mapping. Update `GEDCOMX_CONCEPT_MAPPING.md` in the same commit (ADR-003).

### Change 2 — Burial/cremation dates (S, transport-agnostic) — SHIPPED `178dd49`
Populate `deathDate`/`deathYear` on FS burial records from the primary fact **except** when
`extractFindAGraveMemorialID` returned non-nil (bridge carve-out keeps nils). Update
`RecordScorer.summarise`'s burial line to show the year. Tests: dated burial passes the date
gate; FAG-collection burial keeps nil and still triggers the bridge guard. Expected drift:
FS burials become fact/impossible-capable; cluster shapes may shift on re-runs (over-split-safe).

### Change 3 — Honesty envelope + result-kind persistence (M, transport-agnostic) — SHIPPED `e77fa6a`
`FamilySearchSource` overrides `searchWithOutcome` (joining the 5 sources that already do):
`totalAvailable` from the envelope's top-level `results` int (decoded today, discarded),
`truncated = entries == count && total > count`. **No pagination loop in this change.**
Migration `v42_negative_search_outcome`: `ALTER TABLE negative_searches ADD COLUMN result_kind
TEXT` + `ADD COLUMN hit_count INTEGER`; extend `saveNegativeSearch`'s UPSERT `DO UPDATE SET` to
refresh both; writer stamps `result_kind='zero', hit_count=0` for genuine negatives; reader
(`loadNegativeSearchKeys`/`NegativeSearchCache`) filters to zero-kind rows (NULL = legacy zero).
Closes the live GPS honesty gap: a 100-record page-1 of a 2M-hit query no longer reads as
conclusive.

### Change 4 — OAuth foundation: `FamilySearchOAuthService` (M) — SHIPPED `a1e745f`
Authorization-code + PKCE (S256), system default browser, loopback listener on
`127.0.0.1:49877/familysearch-auth`; token exchange at
`identbeta.familysearch.org/cis-web/oauth2/v3/token`; access + refresh tokens in Keychain (new
`FamilySearchTokenStore`); AppKey resolved from Keychain setting with `FAMILYSEARCH_BETA_APPKEY`
env fallback for dev; environment as plugin config (`integration`/`beta`/`production` hosts).
Add `com.apple.security.network.server` entitlement. Settings UI: OAuth sign-in section.
Unit tests: PKCE verifier/challenge vectors, auth-URL construction, token-response parse,
Keychain roundtrip, refresh flow. Live end-to-end blocked on FS registering the redirect URI.

### Change 5 — Transport swap + pagination (M) — GATED on FS redirect-URI registration
When a valid OAuth token exists, `FamilySearchSource` targets
`https://apibeta.familysearch.org/platform/records/personas` with `Authorization: Bearer`; same
q.* params; **204 = clean negative** (zero-kind row, not an error); 429 honours `Retry-After`
exactly (circuit-breaker input swap per §15.3); `X-PROCESSING-TIME` accumulated and logged; no
UA spoofing/Referer. Pagination loop lands here (offset ≤ 4999, count = 100, ≤ 3 pages first
cut, `truncated = true` when pages remain; loop inside `searchWithOutcome` so the QueryCache key
stays per-logical-query; `throttleIfNeeded` per page). Cookie path remains as silent fallback
until the beta transport is verified live, then the cookie stack (`FamilySearchCookieStore`,
`FamilySearchAuthView`, `FamilySearchTestProbe`, Settings section) is retired in a dedicated
removal commit.

### Change 6 — Query axes: residence + marriage place (S) — SHIPPED `8e417be`
`RecordQuery.residencePlace` + `.marriagePlace` (Python-confirmed params
`q.residenceLikePlace`, `q.marriageLikePlace`). One axis touches exactly five places: init,
**both** `with()` copiers, `QueryCache.cacheKey` (appended at end; accept the one-time
cross-run negative-key invalidation), FS URL emission, dispatcher population (residence from
tree/census context, marriage from FamilyContext — no-hardcoded-regions invariant).

### Change 7 — Data-model first-cut commits (S–M) — SHIPPED `3fbc92e`
Per §12.4 + §17.1: `RecordCommon.placeARK`/`collectionCompleteness`/`volatilityScore`
(nullable; completeness promoted from today's rawFields capture, others populated when their
endpoints arrive); migration `v43_evidence_external_ids`: `evidence_records.external_persona_id`
+ `external_record_id` storing **bare `ark:/…` path segments** (never full URLs), stamped at FS
evidence ingestion — the idempotency key and the citation matcher's deterministic join.
`.userConcluded` SourceTrustTier sub-band deferred to its own change when §7.2 attribution
parsing lands (scorer-visible enum change; needs its own gate).

### Change 8 — Beta probes, fixtures, acceptance — GATED on FS registration
§9.1 probes against apibeta with bearer token (recordType filter-vs-rerank; collection-filter
param name; `~` exact suffix; principal semantics; attribution shape; completeness presence).
Capture the §9.4 twelve golden-fixture archetypes into
`Ancestor Research Tests/Fixtures/FamilySearch/`. Fetch the Compatibility Checklist wording
(§16 first action) and confirm/adjust the persistence posture. Run the §19 A1–A9 acceptance
checklist end-to-end on the eval-corpus subject (Ernest Cauldwell b. 1887), incl. the A8
match-score sandwich test.

### Change 9 — Gate FS place axes by record type (S) — SHIPPED
**Root cause (surfaced by live verification, not the audit's guess of record-type-filter /
pagination):** `SearchDispatcher` populated *every* place axis on *every* FS record-type query,
so a `.death`/`.burial` search also carried `q.birthLikePlace` + `q.residenceLikePlace` — axes
that describe **census** personas. FamilySearch then ranked census records above the real death
record and buried it below the single fetched page (no pagination on the interim cookie path).
**Fix:** gate each place axis to its own record type — `birthPlace`→birth-shape,
`deathPlace`→death-shape (with a soft home-region fallback when the death place is unknown, since
people usually die near home — a re-rank, never a hard filter), `residencePlace`→census,
`marriagePlace`→marriage; `anyPlace` (soft country) and the person axes (spouse/parents) stay
broad. `SearchDispatcher` "case familysearch:" block only; new tests in
`FamilyContextAxisDispatchTests` (`familySearchPlaceAxesAreGatedByRecordType` +
death-place-fallback pair). **Verified live:** Kenneth Howard Cauldwell (b.1917) — 6 prior runs
all `facts:0`/`inconclusive`; after the fix `identity:supported`, death axis 490→216 results, and
his **2007 death landed confirmed** with FS `ark:/61903/1:1:p_301639472418`. Full suite green
(2552 tests; only the known MultiWindow flake, isolation-cleared).
**Recovery is partial** (measured on a 3-profile sample, 1 recovered): the fix recovers
well-anchored profiles whose death is indexed in FS; it does not help deaths that aren't indexed
(George-class) or thin/common-name profiles with no birth year (Ethel-class → 100-yr window,
unconfirmable). Those point to separate follow-ups: (a) infer a birth-year window from the
marriage/spouse edge; (b) revisit strict middle-name gating that may reject a death indexed
without middle names. *(Both George-class follow-ups landed as Changes 10–11; (a) remains open.)*

### Change 10 — Gate FS family axes by record type (S) — SHIPPED
Same principle as Change 9 extended to the FAMILY axes: an axis rides only the record kinds
that carry it. UK civil death/burial/probate records are parent-less (the GRO death index has
name, age, district — no parents), so `q.fatherSurname`/`q.motherSurname` etc. on a death-shape
query boost parent-carrying personas (christenings, censuses) and bury the actual death
registration below the single fetched page. **Proven by direct axis-isolation probe** (cookie,
outside the app) on George Eric Vaughn Cauldwell's 1986 DeathRegistration: **#1 hit without
parent axes; ABSENT from the top-100 with them** — place axes and `anyPlace` exonerated.
Gating: parents → birth-shape/parish/census only; spouse → marriage/census/death-shape only
(funeral notices, probate widows, FAG memorials genuinely carry spouses — Kenneth's Change 9
funeral notice surfaced WITH spouse on), never birth-shape/parish. Mirrors the FreeBMD
dispatcher rules that already encode this record-content reality. Test:
`familySearchFamilyAxesAreGatedByRecordType`. Live effect: George's death axis 8 → 197 results.

### Change 11 — Exact-birth-date rescue for given-name variants (S) — SHIPPED
Scorer (name gate): FS indexes some records under a middle-name variant — George's 1986 death
is filed as **"Vaughan Eric Cauldwell"** (drops "George", Vaughn→Vaughan) — and the first-token
given-name comparison hard-failed it despite the record carrying his exact birth date. New rule:
a given-name first-token mismatch is rescued iff (a) surname passed, (b) the record shares an
**exact day+month+year birth date** with the subject (`subject.birthDateOriginal` vs the
persona's `rawFields["fact.Birth*.date(.formal)"]` — FS captures every persona fact into
rawFields), and (c) every multi-letter record given-token resembles a subject token (shared
first letter + normalised Levenshtein ≥ 0.8 — `nameSimilarity` is too coarse: it scores
VAUGHAN/VAUGHN 0.0). Guards proven by tests: one-day-off DOB, unrelated given name, year-only
subject, and birth-fact-less record all stay rejected; George William/Harold still fail
middle-name checks. Tests: `RecordScorerBirthDateRescueTests` (6).
**Live verification (run D3CC64D0, 2026-07-14): George's 1986 death LANDED as a confirmed
hypothesis** with citation `ark:/61903/1:1:p_100845597241`; the engine immediately re-probed
with the discovered 1984–1988 death window (self-narrowing), and wrong-year candidates began
failing "outside subject's known death window 1986–1986".

## Order

1 → 2 → 3 (today: transport-agnostic, fixture-tested, committed individually)
→ 4 (buildable now, live-blocked) → 5 → 6 → 7 → 8 (FS-gated).
Gate: `xcodebuild test` per change (known parallel flakes isolation-cleared per memory), plus a
real-tree FS run + `get_scored_records` verdict diff after Changes 2 and 5 land (accept-flow
class of change is only visible on real data).
