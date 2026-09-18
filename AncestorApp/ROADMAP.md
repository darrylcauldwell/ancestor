# Roadmap — routing document

**Forward-looking only** — shipped work is removed; git history is the archive, and a shipped item whose spec is gone is normal. This file routes what is *still to do*, in what order, and behind which gate. Per-spec change lists stay authoritative on design (see `AncestorApp/README.md` for the document index).

**This file owns sequence and gates. `BACKLOG.md` owns actionable items.** An item lives here while a gate holds it shut; when the gate opens it graduates to `BACKLOG.md` with an acceptance test, keeping its ID. Neither file records status — derive it with `git log --oneline --grep='#<ID>' --all`, or invoke the `backlog` skill. Do not write "shipped" or an "updated" date into this file; both must be maintained by hand and both went stale before (README and this file drifted 6–8 weeks).

Commit refs that appear below mark *prior art* — which half of a partly-done item already landed — for work that predates the ID scheme. New work references its ID instead.

## Where things stand

Phases 1–4 (pipeline consolidation, AncestorKit extraction, CloudKit publisher, viewer apps) are shipped. The **release ceremony is deferred until every phase is complete** (user decision 2026-07-10).

**Declared priority (user, 2026-07-10): core research capability before polish.**

Dogfood hardening (`#DF1`–`#DF9`) and the ungated Stage 1 items (`#S1-1`, `#S1-3`, `#S1-4a`, `#S1-6a`) graduated to `BACKLOG.md` on 2026-09-18, keeping their IDs. What remains in Stage 1 is genuinely gated or compound.

## Stage 1 — residual (open)

- `#S1-2` **§7.5 `DeficitQueryResult` 3-state** *(compound — split on pickup: the 9-file refactor is ungated, the T8a pairing is not)* — a careful 9-file contract refactor whose only consumer, T8a, is NEEDS-DARRYL; pair the two. — `RESEARCH_PIPELINE_SPEC.md`
- `#S1-4b` **FT-21 witness-probes** — gate: a `SourceRecord` record-role model. — `CONNECTOR_AUDIT_2026-07.md`
- `#S1-4c` **T1-C1 dead Cloudflare subsystem** — delete-vs-wire. — gate: owner decision (NEEDS-DARRYL). — `CONNECTOR_AUDIT_2026-07.md`
  *(FT-19 parish place-scoping was ungated and graduated to `BACKLOG.md` as `#S1-4a`.)*
- `#S1-5` **RESEARCH_PIPELINE Part II tail** *(compound — a bundle of 8+ items with different gates; split into one ID each on pickup. NB T9 also appears as `#RC4`)* — eval-harness Swift/MCP backend (§5.8.8), §5.9 incrementality refactor, §5.10 button collapse, §5.11 hypothesis investigation, T8a/T9/T31/T23, §5.12 five UX passes. — `RESEARCH_PIPELINE_SPEC.md`
- `#S1-6b` **Location Stage 4** — village→registration-district `parentID`. — gate: a village→district data source. — `LOCATION_MODEL_SPEC.md`
  *(Stage 3, the geography-gate rebuild, was ungated and graduated to `BACKLOG.md` as `#S1-6a`.)*


## Stage 2 — forward, sequenced (gate: core declared solid)

Cross-stage rule: DOSSIER (2c) ≥ PROSE_CORPUS Phase B — build the shared `GroundedProseVerifier` once.

### 2a. FamilySearch — Family Tree read/write integration only

**Scope pivot 2026-08-07 (see memory `project_familysearch_beta_program`).** FamilySearch Developer Support confirmed (2026-08-05) that historical-records collection access is **permanently unavailable** to third-party applications through the API — a legal constraint, not a certifiable tier. FamilySearch is therefore a **Family Tree read/write** integration, **not a records source**. The records source + record-hint ingestion were removed from the app on 2026-08-07 (OAuth + tree write leg retained). **All records-enrichment work is struck** (formerly: ARK/persona detail lookup, record-by-ARK, collection metadata caching, collection-level trust tiering, attribution tiering, change-history volatility scoring, negative-search completeness weighting, place-authority enrichment via FS, new records `RecordType` cases, and the FS records/hint follow-ups). Record hinting is likewise dropped — FS surfaces matches only via browser redirect and recommends against building it.

- `#FS1` **Certification path** (FamilySearch's stated sequence, in progress): reply confirming our tree read/write direction → FamilySearch sends Beta test instructions → run them (re-verify write **and** read live) → new electronic Solutions Provider Agreement (**read the commercial-use terms against monetisation BEFORE signing**) → production key → Solutions Gallery listing. Gallery listing is the main strategic payoff (targeted discovery channel).
- `#FS2` **Live re-verify the write leg post-decouple** — against a small throwaway test project (not Tree-2); also exercise the tree **read** (person search), which hasn't had a substantive live test. Rides the Beta test instructions. — `FAMILYSEARCH_TREES_WRITE_SPEC.md`
- `#FS3` **WF-A change-history sync** — reconcile local ↔ FS user tree via change history + conflict-resolution UI. — `FAMILYSEARCH_TREES_WRITE_SPEC.md` §8
- `#FS4` **WF-B tree import** — read an FS user tree into the local DB. Prereqs (research): FS ternary `ChildAndParentsRelationship` wire shape, a normalised `source_descriptions` table, a gedcomx-date parser port. — `FAMILYSEARCH_TREES_WRITE_SPEC.md` §8 · `GEDCOMX_CONCEPT_MAPPING.md`

### 2b. Source access compliance (gates FreeCEN scoping + red-source connectors)

- `#TOS1` **ADR-008 decision** — owner accepts a compliance posture for the 3 red charity sources + CWGC (gates the rest of 2b + FreeCEN scoping). — `SOURCE_ACCESS_COMPLIANCE_2026-07.md` / `ADR-008`
- `#TOS2` **Free UK Genealogy permission email** (one email covering FreeBMD/FreeCEN/FreeREG). — owner
- `#TOS3` **CWGC licensing email** — after the Free UK Genealogy email. — owner
- `#TOS4` **Manual terms checks** — FindAGrave terms, Probate gov.uk footer, Wirksworth conditions + John Palmer contact. — `SOURCE_ACCESS_COMPLIANCE_2026-07.md`
- `#TOS5` **Connector gating** — off-by-default for unsanctioned red sources + the ADR-008 outreach/toggle leg. — `ADR-008`
- `#TOS6` **FreeCEN place scoping (Change 6 / FT-13)** — extend `FreeCenParams` with `place_ids[]`, resolve from subject parish/district, honour `.parish`/`.district` natively (stop silent widening to `.county`). — `SOURCE_WEIGHTING_SPEC.md` · gate: ADR-008 + freecen2 published-API docs

### 2c. Research capability & narrative

- `#RC1` **Cross-profile corroboration — Change 5 (§14 machine-commit carve-out)** — design complete, deferred. — `CROSS_PROFILE_CORROBORATION_SPEC.md` · gate: §14.B undo keystone extended to relationship entities, or corroboration volume that makes the two-click human path a real cost
- `#RC2` **Free-text hunches → targeted probes (§5.15 extension)** — free-text hunch field; local MLX extracts structured directives (death window vs named child's birth, place/occupation discriminators, event kind) into `user_hypothesis_seeds`; deterministic structured-form fallback. Unblocks the parked Harry Marshall acceptance case. — `RESEARCH_PIPELINE_SPEC.md` §5.15
- `#RC3` **Coal-mining accident databases as a source** (Harry Marshall driver) — terms review (fetch+quote cmhrc.co.uk policy/robots; ask operator if silent) → cheap prose-corpus value probe → structured connector ONLY if yield + terms permit. — gate: terms-review + free-text hunches landing
- `#RC4` **DOSSIER — T9 investigation dossier + bounded adversarial challenge** (#T9-Change1..6: deterministic dossier + surfaces → challenge detector → emission/steering → MLX Pass B adversarial selection → MLX Pass A smoothing + `GroundedProseVerifier` + cache → lifecycle + eval harness). Build BEFORE/ALONGSIDE PROSE_CORPUS Phase B — Change1/5 build the shared verifier Phase B reuses. — `DOSSIER_SPEC.md` · gate: none (pure additive read to start)
- `#RC5` **Bio synthesis — PROSE_CORPUS Phase B** (B-1 decouple bio from field-source pipeline; B-2 base-layer templates reusing `PublishBioBuilder`/`NarrativeAssembler`; B-3 corpus context retrieval; B-4 MLX synthesis; B-5 verification via the shared verifier; B-6 inline-citation rendering; B-7 regeneration + staleness). — `PROSE_CORPUS_SPEC.md` · gate: DOSSIER lands first/alongside
- `#RC6` **PROSE_CORPUS Phase C** — cluster fingerprint engine (place×time×occupation); harness candidate-URL discovery; in-app candidate-URL review surface. — `PROSE_CORPUS_SPEC.md` · gate: after Phase B has enough bios
- `#RC7` **PROSE_CORPUS open-question tuning (§43–47)** — pivot-score weighting, page-split threshold, stop-word list, applicability window, verification depth. — gate: real built corpus data
- `#RC8` **Village-level gazetteer expansion** — broad village coverage (GENUKI ~12k) + village→registration-district `parentID` (needs a village→district source; location Stage 4). — `LOCATION_MODEL_SPEC.md`

### 2d. Kinship (Stage-2 first item by ADR-007, but respec-gated, lowest-urgency)

- `#KIN1` **KINSHIP Swift-first respec** — rewrite #Change3–5 as a Swift plan (mandated gate before any build); FIRST — blocks the rest. — `KINSHIP_SPEC.md` · gate: "core declared solid" (ADR-007)
- `#KIN2` **`find_spouses` primitive (Swift)** — all-spouses w/ per-spouse evidence. — gate: respec
- `#KIN3` **`find_siblings` / `find_children` (Swift)** — gender-asymmetric. — gate: respec
- `#KIN4` **`discover_kin` fan-out walker + `KinshipGraph`** — depth caps, per-edge evidence, `presumed_living`. — gate: find_spouses + find_siblings/find_children
- `#KIN5` **`verify_relationship` + `KinshipVerdict`** — chain-tracing verification. — gate: find_siblings/find_children
- `#KIN6` **Living-person guard extension** — into all primitives; hallucination fixture. — gate: alongside discover_kin
- `#KIN7` **Kinship harness** `--mode discovery|verification` + recall/precision metrics. — gate: discover_kin + verify_relationship

### 2e. Media & publisher

- `#MED1` **source_media Option A/B decision** (extend `attachments` vs new firewall-parallel `source_media` table; both lean B). — `SOURCE_MEDIA_SPEC.md`
- `#MED2` **`source_media` migration + `SourceMediaCandidate` model + `ProjectDatabase+SourceMedia.swift`.** — gate: A/B decision
- `#MED3` **Find a Grave headstone/gallery extractor** (URL-only) + **Inspector UI** (disclosure + per-row on-demand Download); highest-yield first cut. — gate: source_media migration
- `#MED4` **Storage lifecycle** — `fetchStatus` urlOnly→cached + auto-cache heuristics + "cache all" toggle. — gate: source_media migration
- `#MED5` **CWGC image extractor** (headstone photo + certificate PDF URL). — gate: FAG extractor
- `#MED6` **FamilySearch image extractor** (decode `links[]` on `GxSourceDescription`, image-waypoint URL + region). — gate: FAG + CWGC extractors + FS session
- `#MED7` **Publisher `convergenceByProfile` feed** — Sourcing verdicts feed the publisher's per-profile convergence badge. — `SOURCE_WEIGHTING_SPEC.md` · independent

### 2f. Assistant surface (MCP consumer)

- `#ASST1` **In-app "Connect to Claude" button** — the MCP server + `.mcpb` Desktop Extension artifact are built (`Scripts/build_mcpb.sh` → `dist/AncestorResearch.mcpb`, reader posture baked in). Remaining: live install-verify in Claude Desktop, then embed the server binary in the app bundle (Xcode Copy Files phase, code-sign-on-copy — do with the project open) so the button stages the same zip at runtime. Claude is the assistant tier for now (owner, 2026-07-31).
- `#FM1` **MLX behind `LanguageModelExecutor`** — `LocalInferenceService` conforms to the SDK 27 protocol so MLX drives a real `LanguageModelSession`: `@Generable` guided decoding, tool calling, streaming, transcripts — all on-device. This is the plumbing `#ASST2` would consume. **`PrivateCloudComputeLanguageModel` is forbidden** (outbound calls breach the no-third-party-API invariant). — gate: `#ASST2` intent-plan design, or adopt early if guided decoding replaces hand-parsing sooner
- `#FM2` **`SystemLanguageModel` fallback tier** — Apple's on-device model so a first run needs no multi-GB MLX download; relevant to App Store first-launch size. — gate: `#FM1`
- `#ASST2` **MLX built-in assistant (bounded)** — the in-app local model drives the SAME reader-posture tool surface in-process: fixed question intents (who-is / evidence-behind / how-related / what's-new / leads-summary) → deterministic tool plans → model narrates returned JSON only (the anti-strategist design). Strategic driver: **iOS — MLX runs on iPhone where desktop MCP clients can't** (iPhone-first market), so this becomes the only assistant tier on mobile; deep investigation stays Claude-over-MCP on Mac. Gate: `.mcpb` packaging + intent-plan design; prereq fix rides along: MLX thinking-off chat-template regression.

## Future (no near-term gate / no owning spec yet)

- `#FUT1` **WikiTree assisted write-back — BUILT, live-verify BLOCKED on account unblock** (`WIKITREE_MERGEEDIT_SPEC.md`, #WT0–#WT4; sanctioned Special:MergeEdit path, human commits on WikiTree's review page). Remaining WT5: Error-2562 unblock (emailed info@wikitree.com) → manual edit proof → Apps Google Group courtesy post → first live MergeEdit → settle spec §7 encoding unknowns.
- `#FUT2` **Collaborative-tree contribute-then-enrich / `TreeProvider` abstraction** (WikiTree primary, FS secondary) — FUTURE; ADR-006 reversal, gated on a 2nd real tree integration. Both write legs now exist (FS User Trees live-verified; WikiTree MergeEdit built) — the abstraction question becomes real once WikiTree live-verifies.
- `#FUT3` **BYO-API-key frontier-model tier** (Claude/Gemini/OpenAI behind the DOSSIER provider seam) — decision-gated; needs privacy-consent UX + living-people redaction on outbound prompts.
- `#FUT4` **Audit bulk-apply for one-click deterministic fixes** — a "Set/apply all in this category" affordance, gated to deterministic + non-destructive + reversible fixes. Two safe first candidates: **married surname from spouse** (writes only the `married_surname` column; caveat: profiles with a mis-parsed maiden `lastName` still owe a maiden-name follow-up) and **given name contains middle** (clean single-first-name rows only — exclude parentheticals/nicknames → route through `nameJunkResolution`, and compound given names like "Mary Ann"). Keep judgement categories (duplicates, phantom spouse) strictly one-per-row.
- `#FUT5` **Audit: unmatched-location (gazetteer) coverage** — a Health finding for profiles whose birth/death locations have not resolved to a place-authority entry (complements `suspectLocation`, which flags *implausible* places; this flags *unresolved* ones). Gated behind location Stage 3 so it reuses the wired resolver and isn't pure noise. Open sub-questions: low-sev Gap not Issue; whether a one-click "resolve location" fix is offered (needs a disambiguation UI); a Health-screen coverage stat. (MCP `get_profile` doesn't yet expose `birthLocationCode`/`deathLocationCode`.)
- `#FUT6` **Audit "Not a duplicate" per-pair dismissal** — the Duplicate-detection tab offers only Compare→Merge; a confirmed-distinct namesake pair re-fires on every recompute forever (`audit_rule_overrides` scopes no finer than `.profile(id:)`). Sketch: a pair-keyed `rejected_duplicates` table + a suppression check in `DuplicateDetectionRule.evaluate` + a "Not a duplicate" button on the audit row and in Compare. Motivating unclearable cases: George Keyworth ×3 (b.1838/1877/1904), the two Ellen Wards, the two George Wards (b.1851 vs son of William b.1870), Gladys/Glays Cauldwell.

## Stage 3 — release (gate: every phase complete — user, 2026-07-10)

First production publish → ASC viewer app records → viewer TestFlight lanes (already written) → family invites → soak items (revocation, unpublish propagation, redaction-as-participant audits).
