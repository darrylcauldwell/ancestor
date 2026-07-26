# Roadmap — routing document

**Status:** Living (updated 2026-07-22). This file routes: where each phase stands and which document owns what happens next. Per-spec change lists stay authoritative on design (see `AncestorApp/README.md` for the full document index).

**Doc convention (2026-07-16):** completed specs are *removed*, not archived — git history is the archive (only the developer + Claude read these, and both have full history). This ROADMAP is the durable record of what shipped (with commit refs); the detailed spec is one `git show` away. A shipped item whose spec is gone is normal — the commits are the pointer.

## Phase state

| Phase / programme | State | Owning doc |
|---|---|---|
| Phase 1 — pipeline consolidation | Complete 2026-07-04 | RESEARCH_PIPELINE_SPEC.md |
| Phase 2 — AncestorKit extraction | Complete 2026-07-04 | (as-built in code) |
| Phase 3 — CloudKit publisher | Shipped (Changes 1–6; first real publish 2026-07-08) | (shipped; git-only) |
| Phase 4 — viewer apps | Delivered + accepted 2026-07-10; parked | (git-only) |
| FamilySearch | OAuth client + historical-records source + on-demand hint enrichment **SHIPPED 2026-07-21** (`e545d66`..`489f2bd`, #Change5); Beta-only until compliance demo. Deferred: WRITE/contribute-then-enrich leg, per-collection tiering, ARK detail-fetch, place/vocab authorities, new RecordType cases + small follow-ups (→ Stage 2). | `FAMILYSEARCH_SOURCE_SPEC.md` (deferred work + §16/§17/§18 reference; client library shipped, git-only) · `GEDCOMX_CONCEPT_MAPPING.md` |
| Release ceremony (all phases) | Deferred until every phase complete — user decision 2026-07-10 | — |

**Declared priority (user, 2026-07-10): core research capability before polish.**

## Stage 1 — residual (core-solid)

**A large close-out landed 2026-07-22** (28 commits, `5f91641`..`882a982`). The SANDWICH campaign is complete, the connector tail is nearly clear, and the FamilySearch foreign-record dilemma is resolved. What remains is one live-run gate (SOURCE_WEIGHTING) and two deliberately-deferred *careful* builds (§7.5, §14.B) — both mapped, neither a blocker.

- **SANDWICH gate-repair campaign** — ✅ **COMPLETE 2026-07-22.** All 14 OPEN DS findings shipped: DS-01/17/18 (no-age death → lead, hardcoded-region geography, all married surnames); the name-gate ladder DS-05/06/16 (scribal contractions + Latin forms; single-indel surname variants; a weak-surname soft-fail band); FP/FN residues DS-02/04/10/12/15 (census wrong-household on a bare forename, middle-name recovery, parish parent cross-check, contradicting-spouse soft-fail, `aliveAsOf` from accepted life events); GPS honesty DS-19/21/22/23; DS-27(a) dead-code. **Only DS-27(b)** (advisory "vanished from a later census" question generator — a new *feature*, not a repair) is carried to Stage 2. — `SANDWICH_AUDIT_2026-07.md`
- **International scope tier (DS-11/DS-19)** — ✅ shipped (`eb08281`). Resolved the foreign-place dilemma as an explicit opt-in `.international` scope (below National): foreign places soft-fail (→ reviewable lead) and Find a Grave lifts its UK pin, only there; National-and-below stay Triage-clean. DS-11 expanded the foreign-marker list (US states / Canadian provinces, UK-colliding names omitted). *Optional follow-up (not built): National-scope corroboration when a record's foreign place matches the subject's own recorded location.*
- **CONNECTOR deferred tail** — mostly ✅ shipped 2026-07-22: UV-01 (marriage window from child births), UV-06/09 (candidate-probe cache threading), UV-08 (free-trio variant re-fire), T1-C2 (FindAGrave browser retry), T1-C3 (FindAGrave URLComponents), T1-C4 (FreeREG apostrophe fixtures). UV-02 (death-floor advance) is delivered by DS-15's `aliveAsOf`; UV-07 shipped earlier (T1-04). **Remaining: FT-19 (place-scoping-L), FT-21 (witness-probes-L, blocked on a SourceRecord record-role model), T1-C1 (dead Cloudflare subsystem — delete-vs-wire, NEEDS-DARRYL).** — `CONNECTOR_AUDIT_2026-07.md`
- **RESEARCH_PIPELINE Part II tail** — §10.3 per-source discrepancy tolerances ✅ (`4a43095`). **Deferred by design (both mapped, neither blocking):** §7.5 `DeficitQueryResult` 3-state — a careful 9-file contract refactor whose only consumer, T8a, is NEEDS-DARRYL; pair the two. §14.B.2–6 MCP auto-approval Phase 2 — the transaction/undo keystone, a load-bearing cross-package build (app + standalone MCP raw-SQL); auto-approval is off by default so its value is gated on the undo (§14.B.4). Still open: eval-harness Swift/MCP backend (§5.8.8), §5.9 incrementality refactor, §5.10 button collapse, §5.11 hypothesis investigation, T8a/T9/T31/T23, §5.12 five UX passes. — `RESEARCH_PIPELINE_SPEC.md`
- **2026-07-15 defect dossier** — (c) leads-lack-IDs-over-MCP ✅ (`e0d90a2`); (f2) housekeeping bulk-dismiss ✅ (`20c1d0c`). (a) CWGC-500 + (b) stale `get_run_status` confirmed already handled; (d) FS junk-persona, (e) FS self-narrowing, (f1) import-inversion correction-tool are stale or NEEDS-DARRYL.
- **SOURCE_WEIGHTING live verification** — the one hard **NEEDS-DARRYL live run** (needs a driven app session): set project Home county, FS re-auth, enter Elsie Twyford's known facts + re-run (anchored + married-name burial hunt), one anchored run + one Kenneth-class ladder run, dispatch-log query-count comparison vs the 2026-07-14/15 campaign. — `SOURCE_WEIGHTING_SPEC.md`

*Everything else in Stage 1 shipped 2026-07-11..22 (connector audit, model evolution E1–E4, engine foundation C+D, conflict layer CL1–CL6, user-seeded hypotheses, evidence absorption + triage rework, muddle/merge data-quality, census-roster enrichment, detached record-review window, married-surname + name-enrichment absorption, tree-popover retirement, life-events research axes, given-name variants, leads-rework tails, RunRequestWatcher off-main, project onboarding + Getting Started, birth ±2 tolerance + spouse-birth "Ethel-class" inference, per-source discrepancy tolerances) → git-only.*

## Stage 2 — forward, sequenced (gate: core declared solid)

Sequenced by dependency + leverage; nothing is parked, later items simply occur later. Cross-stage rule to honour: DOSSIER (2c) ≥ PROSE_CORPUS Phase B (2c) — build the shared `GroundedProseVerifier` once. The FS WRITE leg leads the FS sub-sequence; the ARK/collection endpoints are the read-enrichment depth behind it; the four CLIENT follow-ups are cheap and can slot in any time.

### 2a. FamilySearch — deferred sub-sequence

- **FS Family-Tree WRITE / contribute-then-enrich leg** (§2.4) — push app-built *deceased* persons into the FS shared tree as careful match/merge; harvest returned hints/duplicates back as leads through the firewall. The strategic FS direction; unlocks reliable enrichment. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: App-Store approval + FS compliance demo (auth+read+write on Beta)
- **ARK / persona detail lookup** — `GET /platform/records/personas/{id}` (§6.1); FIRST endpoint addition, unlocks the ARK-deterministic bio-citation matcher. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: records key-grant (granted)
- **Record-by-ARK** — `GET /platform/records/records/{id}` (§6.2), returns whole household. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: same transport as ARK persona lookup
- **Collection metadata caching** — `GET /platform/records/collections` (§6.3), cache ~2000 entries to SQLite, monthly refresh; feeds collection-level tiering. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: none
- **Collection-level trust tiering** — `SourceTierRegistry.tier(for collectionARK:)` (§7.1); replaces the shipped title-pattern heuristic. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: collection metadata cache
- **Attribution-level tiering + `SourceTrustTier.userConcluded` sub-band** (§7.2). — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: collection tiering + Tree-read of per-fact attribution
- **Change-history volatility scoring** — populate the shipped `volatilityScore` column (§7.3/§12.1). — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: change-history endpoint + Tree-read maturity (column exists)
- **Negative-search weighting consumes `collectionCompleteness`** (§7.4). — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: `negative_searches` result_kind/hit_count migration (verify) + collection cache (column exists, only the scorer consumer unbuilt)
- **Place authority enrichment** — `/platform/places/{id}` (§6.7); `placeARK` side-channel done, only integration deferred. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: gazetteer expansion (V3)
- **Vocabulary lookup** — `GET /cv/{vocab-id}` (§6.4), low priority (hard-coded GEDCOMx URIs suffice); refresh-path only. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: none
- **New `RecordType` cases** — immigration/emigration/naturalization/land/property/tax/occupation/education/apprenticeship/court/legalEvent/obituary/adoption/religiousRite; couple divorce/engagement/separation; non-biological `RelationshipKind` (§3 table). — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: eval-corpus evidence of conflation harm (data-driven, opportunistic)
- **Tier-1 secondary metadata endpoints** (§12.1) — Memories deeper handling, source-references cross-query `/persons/{pid}/sources`. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: folds in alongside ARK persona lookup
- **Tier-2** (§12.2) — ancestry/descendancy for G6 family-graph comparison; discussions as reasoning-trail; RecordDescriptor schema-aware parsing. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: Tree-read maturity — later
- **Tier-3** (§12.3, lowest) — person/relationship notes, place-type hierarchies, Genealogies corpus. — `FAMILYSEARCH_SOURCE_SPEC.md` · gate: explicitly deferred
- **FS follow-up: sort lead/triage list by `rawFields["fsMatchScore"]`** (§18 consumer; score already stored — cheapest FS item, completes the S6b §18 story). — `FAMILYSEARCH_SOURCE_SPEC.md` §19 (→ SOURCE) · gate: none
- **FS follow-up: map/skip attribute-only FS personas** (Nationality/Occupation-only facts becoming low-value "parish" leads). — `FAMILYSEARCH_SOURCE_SPEC.md` §19 · gate: after the fsMatchScore sort
- **FS follow-up: live-confirm + firm up the FS Memories response shape.** — `FAMILYSEARCH_SOURCE_SPEC.md` §19 · gate: a Beta call with a memories person (low urgency)
- **FS follow-up: remove the unused `FamilySearchHint`/`recordHints` DTO surface** (superseded by the SourceRecord path). — `FAMILYSEARCH_SOURCE_SPEC.md` §19 · gate: none (opportunistic dead-code cleanup)
- **FreeCEN place scoping (Change 6 / FT-13)** — extend `FreeCenParams` with `place_ids[]`, resolve from subject parish/district via freecen2 API, honour `.parish`/`.district` natively (stop silent widening to `.county`). — `SOURCE_WEIGHTING_SPEC.md` · gate: ADR-008 resolution + freecen2 published-API docs
- **GEDCOM X adapter prerequisites (research, not build)** — resolve 3 UNVERIFIED flags (FS ternary `ChildAndParentsRelationship` wire shape, record-content display-restriction scope, hint-UI star-rating currency) + normalised `source_descriptions` table + single-source-constraint test + gedcomx-date parser port; highest-leverage FS-adapter research, do before any FS import/adapter build. — `GEDCOMX_CONCEPT_MAPPING.md` · gate: FS Beta access (have)

### 2b. Source access compliance (gates FreeCEN scoping + red-source connectors)

- **ADR-008 decision** — owner accepts a compliance posture for the 3 red charity sources + CWGC (gates the rest of 2b + FreeCEN scoping). — `SOURCE_ACCESS_COMPLIANCE_2026-07.md` / ADR-008 · gate: —
- **Free UK Genealogy permission email** (one email covering FreeBMD/FreeCEN/FreeREG). — `SOURCE_ACCESS_COMPLIANCE_2026-07.md` · gate: owner
- **CWGC licensing email.** — `SOURCE_ACCESS_COMPLIANCE_2026-07.md` · gate: owner, after the Free UK Genealogy email
- **Manual terms checks** — FindAGrave terms, Probate gov.uk footer, Wirksworth conditions + John Palmer contact (⚠-unverified rows). — `SOURCE_ACCESS_COMPLIANCE_2026-07.md` · gate: —
- **Connector gating** — off-by-default for 🔴 sources without sanction (per the accepted ADR-008 option) + the ADR-008 outreach/toggle leg. — `SOURCE_ACCESS_COMPLIANCE_2026-07.md` / ADR-008 · gate: ADR-008 accepted

### 2c. Research capability & narrative (accepted forward specs)

- **Cross-profile corroboration — spouse-pair marriage join** (owner-declared next work item, 2026-07-25), sequenced #CPC-Change1..5 (pure corroborator + same-page collision repair → CorroborationSweep + firewall routing + human apply → in-run annotation from spouse's persisted evidence → bounded verdict elevation (§4.2 doctrine amendment) → §14 auto-elevation carve-out, default-OFF). Distinct from G1 cross-profile *dedup* (which stays gated on Decision 7.9). — `CROSS_PROFILE_CORROBORATION_SPEC.md` · gate: none to start (Change 1 is a pure additive joiner)
- **Free-text hunches → targeted probes (§5.15 extension)** — free-text hunch field; LOCAL MLX extracts structured directives (death window vs named child's birth, place/occupation discriminators, event kind) into `user_hypothesis_seeds`; deterministic structured-form fallback. Unblocks the parked Harry Marshall acceptance case. — `RESEARCH_PIPELINE_SPEC.md` §5.15 · gate: existing hunch rails (shipped)
- **Coal-mining accident databases as a source** (Harry Marshall driver) — protocol: terms review (fetch+quote cmhrc.co.uk policy/disclaimer/robots; ask operator if silent), cheap value probe as a prose corpus, structured RecordSource connector ONLY if yield + terms permit. — (no spec) · gate: terms-review gate (`feedback_verify_source_terms_first`) + depends on free-text hunches landing
- **Village-level place gazetteer nit** — `uk-places.json` (261 entries) has no village coverage; parish-level RegionConfig data could fill it (village → county derivation only fires when the user appends ", Derbyshire"). — `RESEARCH_PIPELINE_SPEC.md` (residual) · gate: small, standalone
- **DOSSIER — T9 investigation dossier + bounded adversarial challenge**, sequenced #T9-Change1..6 (deterministic dossier + surfaces → challenge detector + v42 migration → emission/steering → MLX Pass B adversarial selection → MLX Pass A smoothing + `GroundedProseVerifier` + cache → lifecycle + eval harness). Build BEFORE/ALONGSIDE PROSE_CORPUS Phase B — Change1/5 build the shared `GroundedSentence`/`ConfidenceVocabulary`/`GroundedProseVerifier` Phase B-5 reuses. Supersedes the narrow RESEARCH_PIPELINE §5.5 T9. — `DOSSIER_SPEC.md` · gate: none (pure additive read to start)
- **Bio synthesis — PROSE_CORPUS Phase B** (B-1 decouple bio from field-source pipeline; B-2 Stage-A base-layer templates — REUSE `PublishBioBuilder`/`NarrativeAssembler`, don't rebuild; B-3 Stage-B corpus context retrieval; B-4 Stage-C MLX synthesis; B-5 Stage-D verification via the shared `GroundedProseVerifier`; B-6 inline-citation rendering; B-7 regeneration + staleness). — `PROSE_CORPUS_SPEC.md` · gate: Phase A shipped; B-5 shared with DOSSIER — DOSSIER lands first or alongside; "solid core"
- **PROSE_CORPUS Phase C** — C-1 cluster fingerprint engine (place×time×occupation); C-2 harness candidate-URL discovery (MCP + SaaS over public sources); C-3 in-app candidate-URL review surface. — `PROSE_CORPUS_SPEC.md` · gate: after Phase B has enough bios to justify
- **PROSE_CORPUS open-question tuning (§43–47)** — pivot-score weighting, page-split threshold, stop-word list, applicability window, verification depth. — `PROSE_CORPUS_SPEC.md` · gate: real built corpus data

### 2d. Kinship (Stage-2 first item by ADR-007, but respec-gated, lowest-urgency)

- **KINSHIP Swift-first respec** — rewrite #Change3–5 as a Swift plan (the mandated gate before any build); FIRST — blocks the rest. — `KINSHIP_SPEC.md` · gate: "core declared solid" (ADR-007)
- **`find_spouses` primitive (Swift)** — all-spouses w/ per-spouse evidence, lift from `_expand_post_marriage_searches`. — `KINSHIP_SPEC.md` · gate: Swift-first respec
- **`find_siblings` / `find_children` (Swift)** — port the two shipped Python primitives, gender-asymmetric. — `KINSHIP_SPEC.md` · gate: Swift-first respec
- **`discover_kin` fan-out walker + `KinshipGraph` type** — depth caps, per-edge evidence, `presumed_living`. — `KINSHIP_SPEC.md` · gate: `find_spouses` + `find_siblings`/`find_children`
- **`verify_relationship` + `KinshipVerdict`** — chain-tracing verification. — `KINSHIP_SPEC.md` · gate: `find_siblings`/`find_children`
- **Living-person guard extension** — `_is_unsearchable` into all primitives; `presumed_living` on every node; hallucination fixture (Lily Margaret b.2012). — `KINSHIP_SPEC.md` · gate: alongside `discover_kin`
- **Kinship harness `--mode discovery|verification` + recall/precision/verification-accuracy metrics** (Swift test surface). — `KINSHIP_SPEC.md` · gate: `discover_kin` + `verify_relationship`

### 2e. Media & publisher follow-ups

- **source_media Option A/B decision** (extend `attachments` vs new firewall-parallel `source_media` table; both lean B); FIRST of Epic 8. — `SOURCE_MEDIA_SPEC.md` · gate: none
- **`source_media` migration + `SourceMediaCandidate` model + `ProjectDatabase+SourceMedia.swift`** + optional `discoveredMedia` on `RecordCommon`. — `SOURCE_MEDIA_SPEC.md` · gate: Option A/B decision
- **Find a Grave headstone/gallery extractor** (hero photo + gallery cap 20, URL-only) + **Inspector UI** ("Source-discovered images (N)" disclosure + per-row on-demand Download); highest-yield, lowest-risk first cut. — `SOURCE_MEDIA_SPEC.md` · gate: source_media migration
- **Storage lifecycle** — `fetchStatus` urlOnly→cached + auto-cache heuristics + "cache all" toggle. — `SOURCE_MEDIA_SPEC.md` · gate: source_media migration (alongside extractors)
- **CWGC image extractor** (headstone photo + certificate PDF URL). — `SOURCE_MEDIA_SPEC.md` · gate: Find a Grave extractor
- **FamilySearch image extractor** (decode `links[]` on `GxSourceDescription`, image-waypoint URL + `RectangleRegion`); last first-cut source. — `SOURCE_MEDIA_SPEC.md` · gate: FAG + CWGC extractors + FS session
- **Publisher `convergenceByProfile` feed** — Sourcing verdicts feed the publisher's empty per-profile convergence badge. — `SOURCE_WEIGHTING_SPEC.md` · gate: publisher + Sourcing report (both shipped) — independent

### Future (no near-term gate / no owning spec yet)

- **Collaborative-tree contribute-then-enrich / `TreeProvider` abstraction** (WikiTree primary, FS secondary) — FUTURE; ADR-006 reversal, gated on a 2nd real tree integration.
- **BYO-API-key frontier-model tier** (Claude/Gemini/OpenAI behind the DOSSIER provider seam) — decision-gated; needs privacy-consent UX + living-people redaction on outbound prompts.

## Stage 3 — release (gate: every phase complete — user, 2026-07-10)

First production publish → ASC viewer app records → viewer TestFlight lanes (already written) → family invites → soak items (revocation, unpublish propagation, redaction-as-participant audits).
