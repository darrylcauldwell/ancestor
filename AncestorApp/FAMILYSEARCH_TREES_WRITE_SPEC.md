# FAMILYSEARCH_TREES_WRITE_SPEC — User Tree write leg

**Status:** Accepted 2026-07-30 (owner directive: "implement the write-leg spec and deliver this completely"). Build in slices WL1–WL6, each one commit, gated on `xcodebuild test`.
**Wire contracts:** `FS_WRITE_WIRE_CONTRACTS.md` (verbatim request/response extracts from developers.familysearch.org, captured 2026-07-30). This spec summarises; the appendix is authoritative for exact JSON shapes.
**Governing context:** `FAMILYSEARCH_SOURCE_SPEC.md` §2.4 (write leg deferred → now this spec), `GEDCOMX_CONCEPT_MAPPING.md` (boundary contract — every mapping below follows it), ADR-001/003 (our model canonical; GEDCOM X = vocabulary), ADR-009 (deterministic changeMessage).

## 1. Purpose

Upload the local tree to a FamilySearch **User Tree** ("special trees" — the capability our beta AppKey was issued for). This completes our side of the FS Innovator compatibility expectation (auth ✅ + read ✅ + **write**) and unlocks the contribute-then-enrich strategy: persons contributed to a searchable user tree become hintable, so FS record hints start returning value.

Out of scope for v1 (sequenced follow-ups, §8 — not parked): change-history sync, FS→local tree import, hint source attach-back, Memories upload (excluded deliberately: API-added memories are public even on private trees).

## 2. Call sequence (from the wire contracts)

```
1. POST /platform/groups                      x-fs-v1+json   → group ID (X-entity-id)
2. POST /platform/trees                       x-fs-v1+json   → tree ID  (X-entity-id); groupIds=[group], exactly 1
3. POST /platform/trees/current               x-fs-v1+json   → 204; sets session tree context (ONLY targeting mechanism — no per-call override exists)
4. POST /platform/tree/persons                x-fs-v1+json   → person ID per call (X-entity-id, fallback Location header); one person per POST, no id field in body
5. POST /platform/tree/relationships          x-fs-v1+json   → relationship ID; body key selects type:
      relationships[]                 = Couple (person1/person2 + Marriage facts)
      childAndParentsRelationships[]  = child + parent1/parent2 (+ per-parent lineage facts)
6. POST /platform/sources/descriptions        x-gedcomx-v1+json → source description ID (create once, reference many)
   POST /platform/tree/persons/{pid}          x-gedcomx-v1+json → person source reference (body = persons[].sources[])
   POST /platform/tree/couple-relationships/{rid}/source-references            x-gedcomx-v1+json
   POST /platform/tree/child-and-parents-relationships/{rid}/source-references x-fs-v1+json  (note: FS extension type here)
7. POST /platform/trees/{tid}  (finalize)     → 204; sets startingPersonId, hidden:false, private:<user choice>
8. POST /platform/trees/current  body id "GLOBAL"  → restore shared-tree context
```

**Ordering rules (binding):** group before tree; tree before context; context before persons (defensively re-assert context before every write batch — session scope is undocumented); persons before relationships (relationships reference pids; cross-tree relationships are rejected); descriptions before references; finalize last ("hidden and private should only be changed to false once your tree has all details"); restore GLOBAL context afterwards so read paths (tree search, hints) are unaffected.

**Irreversibles surfaced to the user:** hidden→false is ONE-WAY. Access fields are fixed at creation for the tree's lifetime. Private trees never appear in FS Searches/Matches; FS auto-publicises after 2 years of owner inactivity (+30-day email notice).

## 3. Design decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Deceased persons only.** A profile uploads iff NOT living, where living = `resolvedAttributes.privacy == .livingPrivate` OR `FamilyGraphSnapshot.potentiallyLiving` (publisher heuristic: no death and birth within 100y or unbounded). Uploaded persons carry explicit `living: false`. | Owner's standing decision (living stay in-app); FS classifies unspecified-living as living and hides them anyway; exclusion is the safest *explicit* handling and satisfies the checklist. |
| D2 | **Anonymous stubs excluded; placeholders included if they carry data.** Exclusion test = `Profile.isAnonymousStub` (single source of truth), not `nameStatus == .placeholder` (Ruth Wheeldon lesson). | Mapping-doc/model rule: real data wins over a lingering flag. |
| D3 | **Access fields all `AnyApps` at creation** (`ownerAccess`/`groupAccess`/`allAccess`). | Fixed for the tree's lifetime; anything less permanently disqualifies the tree from FS search/match and kills contribute-then-enrich. Wire value needs the WL4 live probe (docs are inconsistent: bare `AnyApps` vs `http://familysearch.org/v1/AnyApps`); encoder makes it a single constant. |
| D4 | **Private-by-default at finalize; user chooses in the wizard.** Wizard states plainly: private ⇒ no FS search/match ⇒ no hints back; public ⇒ deceased persons publicly searchable. Hidden flip is confirmed explicitly (one-way). | Privacy is the owner's call per tree; the app never silently publicises. |
| D5 | **changeMessage is deterministic** on every attributed write: `"Uploaded from Ancestor Research (deterministic pipeline; human-reviewed)"` + per-fact provenance summary where cheap. | ADR-009; FS write etiquette. |
| D6 | **pid storage = E1 `ExternalIdentifier`** (`system: "familysearch"`, bare pid value, kind `.primary`, `supersededBy` ready for 301-merge chains) dual-written per the v34 idiom, PLUS a `familysearch_person_links` table for upload-run bookkeeping (§5). | E1 was built as "the prerequisite for any FS person linkage"; the table adds run/resume/sync state E1 doesn't model. |
| D7 | **Resumable, idempotent upload.** Every created entity is recorded (links table) before the next call; re-running an interrupted upload skips already-linked persons/relationships/sources and continues. No entity is ever created twice for the same local ID + tree. | One-person-per-POST × hundreds of persons × throttling ⇒ interruption is normal, not exceptional. |
| D8 | **Marriage data uploads on the Couple relationship** (Marriage fact: date original+formal, place original), never as person facts. Divorce ⇒ Divorce fact on the same Couple. | Model alignment: marriage lives on our spouse edge. |
| D9 | **Per-fact provenance flattens to entity-level source references.** Union of a person's `field_sources` citations → deduped SourceDescriptions → references on the person (tags preserved where the field maps to a GEDCOM X conclusion type). Marriage-field citations reference the Couple relationship. Documented, accepted loss of per-field pinpointing (mapping doc row 4/5). | FS User Trees attach sources at person/relationship level. Local per-fact ledger is untouched. |
| D10 | **No Memories in v1.** | Public-even-on-private-trees footgun. |
| D11 | **Fixed beta environment**, same as the rest of the FS stack; production is a config flip when certification lands. | Environment enum already models production. |
| D12 | **Evidence layer never uploads.** Scored records, cluster verdicts, disputes, hypotheses, leads have no GEDCOM X analogue and stay local. Fields with an **open dispute** upload the current field value (the app's concluded view) — disputes are workflow state, not data. | Mapping doc §3; deterministic-sandwich moat. |

## 4. Model → wire mapping (per GEDCOMX_CONCEPT_MAPPING)

- **Person**: flat name fields → one preferred `BirthName` (Given = first+middle, Surname = lastName/maiden); `marriedSurname` → additional `MarriedName` form; `nickName` → `Nickname`. Gender enum → `http://gedcomx.org/{Male,Female,Unknown}` (`.other` → Unknown, documented). `birthDate/deathDate` → Birth/Death facts (`original` = verbatim string, `formal` = `A`-prefixed `±YYYY[-MM[-DD]]` from qualifier per mapping row 6). `birth/deathLocation` → place `original` string. LifeEvents map by type: baptism→Christening(`http://gedcomx.org/Christening`), burial→Burial, census→Census, residence→Residence, occupation→Occupation, militaryService→MilitaryService, immigration/emigration→Immigration/Emigration, probate→Probate, education/religion/other→Education/Religion/skip. `display` block: name + gender for FS UI hygiene.
- **Families**: reuse `GEDCOMExporter.buildFamilies` reconstruction semantics (spouse edges → Couple; parent edges grouped per child; parents who are a spouse-pair → one two-parent ChildAndParents; leftover single parents → one-parent ChildAndParents). `Relationship.subtype` → parentNFacts lineage type (biological→BiologicalParent, adoptive→AdoptiveParent, step→StepParent, unknown→omit). Parent1/parent2 assignment: father→parent1, mother→parent2 when roles known; else stable by pid. Edges touching excluded (living/stub) profiles are dropped with the same `omittedIDs` bookkeeping as the GEDCOM exporter.
- **Sources**: `CitationRegistry`-style dedup by full-field equality → one SourceDescription per distinct citation (`about` = citation URL if present; `citations[].value` = `Citation.formatted` prose; `titles` = citation title). References carry D5 changeMessage.

## 5. Persistence (migration `v52_familysearch_upload`)

```sql
familysearch_tree_uploads(
  id TEXT PRIMARY KEY,            -- UUID run id
  environment TEXT NOT NULL,      -- 'beta' | 'production'
  fs_group_id TEXT, fs_tree_id TEXT,
  tree_name TEXT NOT NULL, tree_description TEXT,
  starting_profile_id TEXT,
  private INTEGER,                -- chosen at finalize; NULL until finalized
  phase TEXT NOT NULL,            -- 'created'|'uploading'|'finalized'|'failed'
  started_at DATETIME NOT NULL, finalized_at DATETIME,
  persons_uploaded INTEGER NOT NULL DEFAULT 0,
  relationships_uploaded INTEGER NOT NULL DEFAULT 0,
  sources_uploaded INTEGER NOT NULL DEFAULT 0)

familysearch_person_links(
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  fs_tree_id TEXT NOT NULL,
  fs_pid TEXT NOT NULL,           -- bare pid (ExternalIdentifier bare-value rule)
  status TEXT NOT NULL DEFAULT 'created',   -- 'created'|'deprecated'
  superseded_by TEXT,
  uploaded_at DATETIME NOT NULL,
  PRIMARY KEY (profile_id, fs_tree_id))

familysearch_entity_links(       -- relationships + source descriptions (resume bookkeeping)
  local_key TEXT NOT NULL,        -- canonical local identity (rel UUID / citation hash / '<pid>|srcref|<desc>')
  fs_tree_id TEXT NOT NULL,
  kind TEXT NOT NULL,             -- 'couple'|'childAndParents'|'sourceDescription'|'sourceReference'
  fs_id TEXT NOT NULL,
  uploaded_at DATETIME NOT NULL,
  PRIMARY KEY (local_key, fs_tree_id, kind))
```

On person link: also append `ExternalIdentifier(system: "familysearch", value: pid, kind: .primary)` to `Profile.externalIdentifiers` (dual-write per v34 idiom). Upsert idiom `ON CONFLICT DO UPDATE`, `rowFrom(_:)` decoders, feature file `ProjectDatabase+FamilySearchUpload.swift` — all per existing conventions.

## 6. Build slices

- **WL1 — client write surface.** `FamilySearchEndpoints`: groups, trees, treesCurrent, treeUpdate(tid), treePersonsCreate, treeRelationships, sourceDescriptions, personSourceReferences(pid), coupleSourceReferences(rid), childAndParentsSourceReferences(rid). `FamilySearchClient` typed methods (follow `readPerson` shape): `createGroup`, `createTree`, `setCurrentTree`, `createPerson`, `createCoupleRelationship`, `createChildAndParentsRelationship`, `createSourceDescription`, `attachSource…`×3, `updateTree`. Entity-ID extraction: `X-entity-id` header, fallback = last path component of `Location` (contract notes beta may omit X-entity-id on person create). Mock fix: `FSMockURLProtocol` drains `httpBodyStream` so POST bodies are assertable. Tests: URL/method/content-type per op, entity-id fallback, body round-trip.
- **WL2 — encoder.** `FamilySearchTreeEncoder` (pure, `Services/Sources/FamilySearch/`): snapshot → `FSWritePlan { groupBody, treeBody, personBodies[profileID], coupleBodies, childAndParentsBodies, sourceDescriptionBodies, sourceReferencePlans, omitted: [id: reason] }`. Encodable write structs (`FSWrite*` — separate from the Decodable read structs; encode exactly the documented body shapes, nothing optional-sprayed). All §3/§4 rules live here. Tests: golden-JSON against the verbatim doc examples + exclusion/assembly/dedup cases.
- **WL3 — persistence.** §5 migration + `ProjectDatabase+FamilySearchUpload.swift` CRUD + E1 dual-write. Tests: round-trip, resume queries (unuploaded-persons-given-links), idempotent upsert.
- **WL4 — orchestration.** `actor FamilySearchTreeUploadService`: takes plan + db + client + progress closure; executes §2 sequence with D7 resume, context re-assertion per batch, throttle deference (client's bounded 429 handling + inter-call pacing), per-entity error capture (fail-soft: record, continue, summarise), finalize gated on zero person/relationship failures, GLOBAL restore in `defer`. Returns `FSUploadSummary`. Tests: mock-client full-run, resume-after-interrupt, failure summarisation, context-reassert ordering.
- **WL5 — UI.** `Views/FamilySearchUpload/FamilySearchUploadSheet.swift` cloned from `PublishReviewSheet` idiom (`Phase { loading, reviewing, uploading(String), done(FSUploadSummary), failed(String) }`): review shows counts (persons in / living excluded / stubs excluded / relationships / sources), tree name+description fields, starting person (defaults to project root/focus), privacy choice with D4 plain-language consequences, explicit one-way-hidden confirmation checkbox; uploading phase streams progress; done links to the tree on the beta site. Entry: ContentView Actions menu "Upload Tree to FamilySearch…" (`.disabled` when snapshot empty), gated by the existing `familySearchSignInPrompt` idiom. `.sheet(item:)` presentation.
- **WL6 — docs.** ROADMAP entry, `FAMILYSEARCH_SOURCE_SPEC.md` §2.4 → pointer here, `Ancestor Research/CLAUDE.md` migration-count refresh, as-built notes appended to this spec.

## 7. Live-verify runbook (owner, on beta — the "go back to Tiffany" gate)

1. Sign in (Settings → FamilySearch Beta). 2. Actions → Upload Tree to FamilySearch… on a SMALL test project first (import `samples/` GEDCOM → a dozen persons), not Tree-2. 3. Wizard: name "Ancestor Research compatibility test", private=true, confirm. 4. Verify on beta site: tree visible, persons/relationships/sources correct, living absent. 5. Re-run upload → expect "nothing to do" (D7 proof). 6. Then Tree-2 (967 profiles) if desired. Live probe resolves the §3 D3 access-enum wire value and the update-tree content type (WL4 logs both attempts: bare enum first, URI fallback on 400).
Known-unresolved list to watch: `FS_WRITE_WIRE_CONTRACTS.md` §unresolved (access enums, update-tree media type, current-tree session lifetime, X-entity-id on person create).

## 8. Sequenced follow-ups (roadmap, in order — not parked)

**WF-A** change-history sync (Tree Change History feed → conflict strategy per compatibility checklist). **WF-B** FS→local user-tree import. **WF-C** hint source attach-back (Source Linker flow). **WF-D** production environment flip + embedded production key (post-certification). WF-A/B complete the remaining User-Tree compatibility checklist rows; schedule after Tiffany confirms the beta records index situation.

## 9. As-built record (2026-07-30, #WL0–#WL6)

All six slices SHIPPED in one session, every slice gated on green `xcodebuild test`; full suite at close: **3,412 tests / 362 suites, all passing.**

- **WL1** `6f30b9d` — client write surface. `FamilySearchClient+Writes.swift` (creates return entity IDs; attaches tolerate missing IDs; 400-with-body surfaces as `unexpectedStatus(status, snippet)`), 10 endpoint builders, `FamilySearchResponse.createdEntityID` (X-entity-id → Location fallback), mock `httpBodyStream` drain. 14 tests.
- **WL2** `4fb33d4` — `FamilySearchTreeEncoder` (pure). D1–D12 policy encoded + tested; `FSUploadPlan` with persons encoded at plan time and relationship/source-ref SPECS rendered post-pid; citation keys are FNV-1a (NOT `Hasher` — process-seeded, would break resume). 17 tests.
- **WL3** `d78ed4e` — migration `v52_familysearch_upload` (3 tables per §5) + `ProjectDatabase+FamilySearchUpload.swift` (upsert CRUD, E1 dual-write via `mergingLegacyMap` in the same write txn, `familySearchRelationshipCitations()` for D9). 5 tests.
- **WL4** `b55b19e` — `FamilySearchTreeUploadService` actor. Full §2 sequence; context re-asserted before every batch; fail-soft per-entity capture; finalize gated on zero person/relationship failures (one-way flip protected); finalize media-type 400/415 → fs-v1 fallback (contracts §unresolved); GLOBAL restore on success AND error paths; interrupted runs saved as phase `uploading` for resume. 3 tests (full-run / resume-skips-everything / fail-soft-withholds-finalize) over mock transport + real temp DB.
- **WL5** `ae9276d` — `FamilySearchUploadSheet` + Actions-menu entry ("Upload Tree to FamilySearch…", sign-in-gated, `.sheet(item:)`). Review shows include/exclude counts; privacy toggle explains the hints trade-off in plain language; explicit one-way consent checkbox gates Upload; done view shows honest per-stage counts + failures + finalize note.
- **WL6** — this record; ROADMAP §2a entry updated; `FAMILYSEARCH_SOURCE_SPEC.md` §2.4 marked superseded-in-part; app CLAUDE.md migration count 41→52.

**§7 LIVE-VERIFIED 2026-07-30 (owner, on beta — COMPLETE).** Project "Cauldwell Discovery" (87 profiles): first run created group `9M9J-9QZ` + tree `9NMM-98CV`, 47 persons / 5 relationships (deceased-only subgraph of 93 edges) / 0 sources (project carries no formal citations), finalized private in **16 seconds**, zero failures. Verified three ways: FS web UI (Manage Trees → tree settings shows 47 people, starting person Tudor BM8L-RS8), raw API readback (tree: hidden=false, private=true, all access fields echoed as bare `AnyApps`; person BM8L-RS8: correct name/gender/living=false/Birth 1831), and v52 bookkeeping (pids `BM8L-…` linked + E1 dual-write). **All four §unresolved wire questions settled**: bare `AnyApps` accepted+echoed; finalize succeeded with default gedcomx-v1 media type; person IDs captured; session tree-context held across batches. **Re-run (after fix `42dfc12`) converged on the same tree: 0 created, +47/+5 skipped, no /groups or /trees creates — resume/idempotency proven live.** Live lessons fixed same-day: (1) resume rule originally treated `finalized` as terminal and began minting a duplicate tree on re-run — only a beta gateway 503 stopped it; rule is now converge-on-latest-run-always (regression test pins zero create calls); (2) beta gateway intermittently answers "503 upstream" — client now retries 502/503 twice with backoff (duplicate-safe: gateway-level failure never reached the service); (3) wizard pre-flights the FS session on open (server-arbitrated expiry means a stale session otherwise passes the local token gate) and failure text is now human (`friendlyText`), not a bridged NSError code. FS web-UI note: uploaded trees appear under **Manage Trees**, listed by the access-GROUP name (encoder names it "<tree> — access group"; rename in place on FS or adjust the encoder if desired). REVIEW MATCHES button exists on the tree — hints-for-owner may work even on private trees (records-index question with Tiffany governs its usefulness).

- **WL7** `86cf9f9` + `86b8a58` (2026-07-30, post-close addendum) — **MCP exposure.** Migration `v53_fs_action_requests` (staging table, status index); `RunRequestWatcher` claims FS actions only when the research queue is idle and executes them with the APP's auth (headless twin of `fetchFamilySearchHints`; upload path passes `performFinalize: false` — request-driven uploads stop at uploaded-but-HIDDEN, finalize stays a wizard consent, pinned by test `requestDrivenUploadNeverReachesFinalize`). Six MCP tools: reads `get_fs_upload_status` / `get_fs_person_links` / `get_fs_hints` (leads ⋈ evidence_records on `'lead_' || source_record_id` + `source_id='familysearch'`) / `get_fs_request_status`; staging `request_fs_hints` (profile-validated, deduped) / `request_fs_upload` (deduped, states the hidden cap). Pre-migration DBs get a friendly `schema_out_of_date` payload. MCP suite 123/123 (incl. pre-existing DisputeSurfaceTests fixture fix: missing `is_deleted` column); app suite green. NOTE: a running MCP server needs a reconnect (and the app a rebuild/relaunch) to pick up the new tools + v53.
