# FamilySearch Client — Build Spec

**Status: Active** · 2026-07-21
**Supersedes (for the client build):** the diagnostic `FamilySearchTreeProbe` (guessed grammar) and, as a records surface, the cookie-era `FAMILYSEARCH_READ_LEG_PLAN.md`. The licensing/hint posture in `FAMILYSEARCH_SOURCE_SPEC.md` §16–§18 still binds.

## Owner decisions (2026-07-21)

- **In-app module**, not a separate Swift package. Lives at `Ancestor Research/Services/Sources/FamilySearch/`, internally layered (transport / model / query / source-adapter) so it *could* be extracted later, but no package ceremony now. Reuses the shipped `FamilySearchOAuth`, `FamilySearchTokenStore`, and `FamilySearchEnvironment` directly.
- **Full grant surface, records included.** Build the historical-records persona search as a real scored `RecordSource` now. This reverses the same-day "FS is not a data source / delete the records leg" pivot *for the build* — records **code** is back in scope. Records **access** stays tier-gated and licence-walled at runtime; the S4 live call is the gate on whether our key returns anything. Also build the enrichment/tree surface (tree search, person read, record/duplicate hints, memories pointers).
- **Reuse, don't rebuild.** `FamilySearchOAuth` + `FamilySearchTokenStore` supply the bearer. The transport-agnostic GEDCOM X parser + `q.*` emission logic lift from the deleted `FamilySearchSource` (`git show 9facbc1:"Ancestor Research/Services/Sources/FamilySearchSource.swift"`).

## Source of truth

FamilySearch official API docs + reference SDKs (`fs-js-lite`, `gedcomx`, the FS Bruno collection), cross-checked against `FAMILYSEARCH_SOURCE_SPEC.md` (which carries some stale endpoints). Full gather + rationale: session scratchpad `fs-ref/` (`findings/01…06`, `DESIGN_DRAFT.md`). The in-repo spec is authoritative for **strategy/licensing**; the **raw API contract** comes from FS's live docs + SDKs.

## Endpoints (verbatim from docs / Bruno)

| Purpose | Method + path | Notes |
|---|---|---|
| Records persona search | `GET /platform/records/personas` | historical-record source (scored); Atom feed |
| Tree person search | `GET /platform/tree/search` | `f.treeId` scopes to a user tree |
| Person matches / hints | `GET /platform/tree/persons/{pid}/matches?collection=…/records` | record hints → leads; omit `collection` ⇒ duplicate-person matches |
| Person read | `GET /platform/tree/persons/{pid}` · batch `?pids=a,b,c` | `x-fs-v1+json` |
| Memories | `GET /platform/tree/persons/{pid}/memories` | image POINTERS only (link-only) |
| Current user | `GET /platform/users/current` | connection check |

**Grammar:** structured `q.*` fuzzy terms (givenName, surname[req], sex, birth/death/marriage/residence `LikeDate`+`Place` with `.from`/`.to` ranges, father/mother/spouse axes, `.exact=on`), `f.*` exact filters (treeId, collectionId), pagination `count` 1–100 / `offset` 0–4999 (5000 cap). Accept `application/json` / `x-fs-v1+json` (tree) or `application/x-gedcomx-atom+json` (search feed). Status 200 / 204 no-results / 400 (Warning header) / 429 (Retry-After secs; X-PROCESSING-TIME ms). 301 merge (X-Entity-Forwarded-Id), 410 delete (tombstone body). Persist the bare `ark:/…` path segment only.

## Slices (each = one commit, `xcodebuild test`-gated)

**Status (2026-07-21):** **S1–S6 ALL SHIPPED-TO-GREEN + live-verified in the real pipeline; full suite green (2915/2916, only the known MultiWindow flake, isolation-cleared). Uncommitted.** Files under `Ancestor Research/Services/Sources/FamilySearch/`: `FamilySearchQuery`, `FamilySearchEndpoints`, `FamilySearchGedcomX`, `FamilySearchClient` (+ typed endpoints), `FamilySearchSource` (records `RecordSource`, registered in `SourceBootstrap`), `FamilySearchEnrichment` (`FamilySearchEnrichmentService`: record hints → §18-ordered `FamilySearchHint` leads; memories → link-only `FamilySearchImagePointer`). Settings probe UI repointed at the real client; broken `FamilySearchTreeProbe` DELETED. **★ Records ARE granted** (live: `HTTP 200, ~21,047` for Ernest Cauldwell b.1887); **★ verified in a real research run** (William Holmes: FamilySearch 192 records scored alongside the free sources — parser + query mapping correct; the 0% fact was the anchor-less common-name subject, not a parser gap). **Home-country `anyPlace` fallback added** (`SearchDispatcher.homeCountry(fromChapmanCode:)`): a region-less subject now gets the project home-nation as the soft country axis, so FS's global records API biases to the home nation instead of pulling worldwide namesakes (config-derived, no hardcoded region).

**S6b — scorer-routed on-demand hint enrichment SHIPPED-TO-GREEN 2026-07-21** (owner chose the complete path). On-demand **per profile** ("Fetch FamilySearch hints" — tree right-click menu + profile card "More" menu → `AppState.requestFetchFSHints` intent → `ContentView` drain → `AppState.fetchFamilySearchHints(profileID:)`). Hints route through the SAME deterministic scorer + firewall as records search: `personMatches(…/records)` → `FamilySearchEnrichmentService.recordHintsAsSourceRecords` (parses the matches feed via the S5 `parseSearchFeed`/`buildRecord`, so full typed records) → `FamilySearchHintRouting.route` (`RecordScorer.classify` → `ResearchResult`) → `ResearchRunService.persist`. **Dedup is automatic** — evidence keys on `"<profileID>|<persona.id>"`, so a hint record collapses onto its records-search twin. **§18 held by construction:** the FS match confidence rides in `rawFields["fsMatchScore"]` (+ `fsTreePersonID` provenance), and `RecordScorer.classify` never reads it — pinned by the `fsMatchScoreIsInertToTheScorer` invariant test. Full suite green. **Deposited-but-unwired:** lead-list *sorting* by `fsMatchScore` (the §18 signal is stored; sorting the triage list on it is the remaining follow-up).

**Follow-ups (enhancements, not blockers):** (a) attribute-only FS personas (Nationality/Occupation-only facts) become low-value "parish" leads — could skip/map; (b) sort the lead/triage list by `rawFields["fsMatchScore"]` (§18 consumer); (c) FS memories response shape is minimally modelled + not live-confirmed; (d) the shipped-but-unused `FamilySearchHint`/`recordHints` DTO surface (superseded by the SourceRecord path) could be removed.

- **S1 — query + endpoint URL builders (no network).** `FamilySearchQuery` (q.*/f.* emission) + `FamilySearchEndpoints` (pure URL builders). Unit-tested against the verbatim doc/Bruno URLs. ✅ built + tested
- **S2 — GEDCOM X Codable model + fixture decode.** ~20 `FS*` structs, two envelopes (x-fs-v1 tree read + x-gedcomx-atom search feed), seeded from the deleted plugin's structs, reconciled to the full graph (Field/FieldValue, `identifiers` map, ChildAndParentsRelationship). Decode real SDK fixtures.
- **S3 — transport client (actor) + mock URLSession.** Bearer attach (reuse token store), Accept negotiation, `X-FS-Feature-Tag`, 429/Retry-After bounded retry, 301/410/forwarded-id surfacing, 401→refresh-once, ETag/304, X-PROCESSING-TIME capture. No live network in tests.
- **S4 — endpoint methods + first live Beta smoke.** currentUser/readPerson(s)/treeSearch/personMatches/recordsPersonaSearch. First live call: confirm Atom member names + answer the records key-grant question; capture a fixture (not the probe hack).
- **S5 — records `RecordSource` + honesty envelope.** `FamilySearchSource: RecordSource, AuthenticatingSource`; feed→[SourceRecord] via the lifted parser; `searchWithOutcome` truncation/availability; register in `SourceBootstrap`. Pointer-only persistence.
- **S6 — enrichment service → firewall as leads + memories pointers.** hints→leads (never facts/direct writes); memories→link-only citations (never stored bytes).

## Constraints that still bind

- **§16 pointer-only:** persist collection title + confidence + ARKs + our verdicts; never transcription text, field values, or image bytes. FS content caches are session-scoped only.
- **§18 hints order leads only:** an FS match score never sets a trust tier, enters a gate, or counts toward convergence.
- **Source trust is URL-derived** via `SourceTierRegistry` (familysearch.org → community/derivative), never from the score.
- **Records entitlement + the licence wall are empirical:** S4's live call gates whether S5's records source returns anything at our tier.
