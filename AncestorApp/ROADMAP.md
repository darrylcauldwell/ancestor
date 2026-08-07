# Roadmap — routing document

**Status:** Living (updated 2026-08-07). **Forward-looking only** — shipped work is removed (git history is the archive; a shipped item whose spec is gone is normal, the commits are the pointer). This file routes what's *still to do* and which document owns each next step. Per-spec change lists stay authoritative on design (see `AncestorApp/README.md` for the full document index).

## Where things stand

Phases 1–4 (pipeline consolidation, AncestorKit extraction, CloudKit publisher, viewer apps) are **shipped**. The **release ceremony is deferred until every phase is complete** (user decision 2026-07-10). Stage 1 (core-solid) is essentially done bar the open items below.

**Declared priority (user, 2026-07-10): core research capability before polish.**

## Stage 1 — residual (open)

- **SOURCE_WEIGHTING live verification** — the one hard NEEDS-DARRYL live run (driven app session): set project Home county, enter Elsie Twyford's known facts + re-run (anchored + married-name burial hunt), one anchored run + one Kenneth-class ladder run, dispatch-log query-count comparison. — `SOURCE_WEIGHTING_SPEC.md`
- **§7.5 `DeficitQueryResult` 3-state** — a careful 9-file contract refactor whose only consumer, T8a, is NEEDS-DARRYL; pair the two. — `RESEARCH_PIPELINE_SPEC.md`
- **§14.B.2–6 MCP auto-approval Phase 2 (transaction/undo keystone)** — load-bearing cross-package build (app + standalone MCP raw-SQL); auto-approval stays off until the undo lands. First concrete customer: cross-profile corroboration Change 5 (needs the keystone extended to relationship entities). — `RESEARCH_PIPELINE_SPEC.md`
- **CONNECTOR tail** — FT-19 (FreeREG parish place-scoping — live connector work again since FreeREG was restored to free-trio parity), FT-21 (witness-probes, blocked on a SourceRecord record-role model), T1-C1 (dead Cloudflare subsystem — delete-vs-wire, NEEDS-DARRYL). — `CONNECTOR_AUDIT_2026-07.md`
- **RESEARCH_PIPELINE Part II tail** — eval-harness Swift/MCP backend (§5.8.8), §5.9 incrementality refactor, §5.10 button collapse, §5.11 hypothesis investigation, T8a/T9/T31/T23, §5.12 five UX passes. — `RESEARCH_PIPELINE_SPEC.md`
- **Location Stage 3** — decision-core geography-gate rebuild (substring → hierarchy + validity walk); the `PlaceResolver` primitive is ready. **Location Stage 4** (village→district `parentID`) gated on a village→district data source. — `LOCATION_MODEL_SPEC.md`

## Near-term — dogfood hardening (surfaced 2026-08-06/07)

Core-correctness fixes from live-tree dogfooding (full repro cases in memory `project_dogfood_2026_08_06`). "Core research before polish" ranks these ahead of Stage 2. FS-records-flavoured items from that session (FS 404 citation host, FS persona-household Head+Wife lift, FS US-census template) are **dropped** with the FamilySearch scope pivot.

**Decision core (scorer / gates):**
- **Married-surname — unmarried-child-of-same-surname-head negative** — the *temporal* half shipped (`f4c9ab9`: a married surname matches only records dated on/after the marriage). Remaining: for a post-marriage-dated census, an unmarried Dau of a *same-surname* head is a strong negative (a born-Holmes daughter, not the subject who married into Holmes) — needs household-role analysis, so census-only.
- **Cross-record birthplace-consistency** — applied-fact birthplace vs a candidate/household target birthplace: mismatch demotes in ranking/verdicts AND gates the census-absorb capsule (George Ward Derby-vs-Ashbourne, Brooks/Ward salvages, Florida-1945). *The capsule now DISPLAYS the roster + target birthplace (shipped `c717fef`); the consistency GATE is still to build.*
- **Geography gate — registration-district gap** — the gate doesn't know registration districts (Ellen Brooks' own "Duffield" household row soft-failed "unknown district" while namesakes passed); reinforces the deferred location Stage 3 rebuild. Worst case on record: a US Florida 1945 state census accepted as a "childhood census" (hemisphere breach).

**Census absorption (`addCensusFamily`):**
- **Parent-unlock guards** — verify the Health Apply-childhood-census path enforces `CensusFamilyLinker`'s guards: a "Grnson" subject must not lift grandparents as parents; a "Son/Dau" row whose surname ≠ Head's (stepchild) must not propose the Head as biological father.
- **Absorption-residue cascade-delete** — trace `addCensusFamily`-created profiles to their source record so backing out a namesake census offers to delete the now-orphaned creations (the Ann Brooks island).

**Evidence at the point of the click:**
- **Parent-unlock findings are evidence-blind** — render the ranked census inline (fields + roster + in-tree badges + subject row highlighted) with Apply/Dismiss beside the evidence, like the reconciliation panels and the census-absorb capsule now do. (0/11 one-click-correct in the live sweep because every trap was invisible at the click.)
- **Relationship-picker disambiguation** — the Add-Relationship "other person" dropdown shows only the display name, so two same-name profiles (wife-via-married-surname vs descendant-via-maiden: two "Lydia Twyford", two "Mary Keyworth") are indistinguishable — a real risk of linking a man to his own daughter. Picker rows need a birth year + top relation.

**Data-quality ops / audits:**
- **Safe child↔spouse role-change op** — a "change relationship role" that preserves the profile + its records (Herbert Brewell's research was destroyed because the only repair was rename-phantom + delete-real). Plus a missing **parent-younger-than-child** audit.
- **Parent-age-gap severity / midpoint display** — the census-derived false ERRORs are gone now that `addCensusFamily` writes ±1 dates (`2657ff4`); a midpoint/severity view is still worth it for genuinely-approximate imports that carry wide "abt" windows.

## Stage 2 — forward, sequenced (gate: core declared solid)

Cross-stage rule: DOSSIER (2c) ≥ PROSE_CORPUS Phase B — build the shared `GroundedProseVerifier` once.

### 2a. FamilySearch — Family Tree read/write integration only

**Scope pivot 2026-08-07 (see memory `project_familysearch_beta_program`).** FamilySearch Developer Support confirmed (2026-08-05) that historical-records collection access is **permanently unavailable** to third-party applications through the API — a legal constraint, not a certifiable tier. FamilySearch is therefore a **Family Tree read/write** integration, **not a records source**. The records source + record-hint ingestion were removed from the app on 2026-08-07 (OAuth + tree write leg retained). **All records-enrichment work is struck** (formerly: ARK/persona detail lookup, record-by-ARK, collection metadata caching, collection-level trust tiering, attribution tiering, change-history volatility scoring, negative-search completeness weighting, place-authority enrichment via FS, new records `RecordType` cases, and the FS records/hint follow-ups). Record hinting is likewise dropped — FS surfaces matches only via browser redirect and recommends against building it.

- **Certification path** (FamilySearch's stated sequence, in progress): reply confirming our tree read/write direction → FamilySearch sends Beta test instructions → run them (re-verify write **and** read live) → new electronic Solutions Provider Agreement (**read the commercial-use terms against monetisation BEFORE signing**) → production key → Solutions Gallery listing. Gallery listing is the main strategic payoff (targeted discovery channel).
- **Live re-verify the write leg post-decouple** — against a small throwaway test project (not Tree-2); also exercise the tree **read** (person search), which hasn't had a substantive live test. Rides the Beta test instructions. — `FAMILYSEARCH_TREES_WRITE_SPEC.md`
- **WF-A change-history sync** — reconcile local ↔ FS user tree via change history + conflict-resolution UI. — `FAMILYSEARCH_TREES_WRITE_SPEC.md` §8
- **WF-B tree import** — read an FS user tree into the local DB. Prereqs (research): FS ternary `ChildAndParentsRelationship` wire shape, a normalised `source_descriptions` table, a gedcomx-date parser port. — `FAMILYSEARCH_TREES_WRITE_SPEC.md` §8 · `GEDCOMX_CONCEPT_MAPPING.md`

### 2b. Source access compliance (gates FreeCEN scoping + red-source connectors)

- **ADR-008 decision** — owner accepts a compliance posture for the 3 red charity sources + CWGC (gates the rest of 2b + FreeCEN scoping). — `SOURCE_ACCESS_COMPLIANCE_2026-07.md` / `ADR-008`
- **Free UK Genealogy permission email** (one email covering FreeBMD/FreeCEN/FreeREG). — owner
- **CWGC licensing email** — after the Free UK Genealogy email. — owner
- **Manual terms checks** — FindAGrave terms, Probate gov.uk footer, Wirksworth conditions + John Palmer contact. — `SOURCE_ACCESS_COMPLIANCE_2026-07.md`
- **Connector gating** — off-by-default for unsanctioned red sources + the ADR-008 outreach/toggle leg. — `ADR-008`
- **FreeCEN place scoping (Change 6 / FT-13)** — extend `FreeCenParams` with `place_ids[]`, resolve from subject parish/district, honour `.parish`/`.district` natively (stop silent widening to `.county`). — `SOURCE_WEIGHTING_SPEC.md` · gate: ADR-008 + freecen2 published-API docs

### 2c. Research capability & narrative

- **Cross-profile corroboration — Change 5 (§14 machine-commit carve-out)** — design complete, deferred. — `CROSS_PROFILE_CORROBORATION_SPEC.md` · gate: §14.B undo keystone extended to relationship entities, or corroboration volume that makes the two-click human path a real cost
- **Free-text hunches → targeted probes (§5.15 extension)** — free-text hunch field; local MLX extracts structured directives (death window vs named child's birth, place/occupation discriminators, event kind) into `user_hypothesis_seeds`; deterministic structured-form fallback. Unblocks the parked Harry Marshall acceptance case. — `RESEARCH_PIPELINE_SPEC.md` §5.15
- **Coal-mining accident databases as a source** (Harry Marshall driver) — terms review (fetch+quote cmhrc.co.uk policy/robots; ask operator if silent) → cheap prose-corpus value probe → structured connector ONLY if yield + terms permit. — gate: terms-review + free-text hunches landing
- **DOSSIER — T9 investigation dossier + bounded adversarial challenge** (#T9-Change1..6: deterministic dossier + surfaces → challenge detector → emission/steering → MLX Pass B adversarial selection → MLX Pass A smoothing + `GroundedProseVerifier` + cache → lifecycle + eval harness). Build BEFORE/ALONGSIDE PROSE_CORPUS Phase B — Change1/5 build the shared verifier Phase B reuses. — `DOSSIER_SPEC.md` · gate: none (pure additive read to start)
- **Bio synthesis — PROSE_CORPUS Phase B** (B-1 decouple bio from field-source pipeline; B-2 base-layer templates reusing `PublishBioBuilder`/`NarrativeAssembler`; B-3 corpus context retrieval; B-4 MLX synthesis; B-5 verification via the shared verifier; B-6 inline-citation rendering; B-7 regeneration + staleness). — `PROSE_CORPUS_SPEC.md` · gate: DOSSIER lands first/alongside
- **PROSE_CORPUS Phase C** — cluster fingerprint engine (place×time×occupation); harness candidate-URL discovery; in-app candidate-URL review surface. — `PROSE_CORPUS_SPEC.md` · gate: after Phase B has enough bios
- **PROSE_CORPUS open-question tuning (§43–47)** — pivot-score weighting, page-split threshold, stop-word list, applicability window, verification depth. — gate: real built corpus data
- **Village-level gazetteer expansion** — broad village coverage (GENUKI ~12k) + village→registration-district `parentID` (needs a village→district source; location Stage 4). — `LOCATION_MODEL_SPEC.md`

### 2d. Kinship (Stage-2 first item by ADR-007, but respec-gated, lowest-urgency)

- **KINSHIP Swift-first respec** — rewrite #Change3–5 as a Swift plan (mandated gate before any build); FIRST — blocks the rest. — `KINSHIP_SPEC.md` · gate: "core declared solid" (ADR-007)
- **`find_spouses` primitive (Swift)** — all-spouses w/ per-spouse evidence. — gate: respec
- **`find_siblings` / `find_children` (Swift)** — gender-asymmetric. — gate: respec
- **`discover_kin` fan-out walker + `KinshipGraph`** — depth caps, per-edge evidence, `presumed_living`. — gate: find_spouses + find_siblings/find_children
- **`verify_relationship` + `KinshipVerdict`** — chain-tracing verification. — gate: find_siblings/find_children
- **Living-person guard extension** — into all primitives; hallucination fixture. — gate: alongside discover_kin
- **Kinship harness** `--mode discovery|verification` + recall/precision metrics. — gate: discover_kin + verify_relationship

### 2e. Media & publisher

- **source_media Option A/B decision** (extend `attachments` vs new firewall-parallel `source_media` table; both lean B). — `SOURCE_MEDIA_SPEC.md`
- **`source_media` migration + `SourceMediaCandidate` model + `ProjectDatabase+SourceMedia.swift`.** — gate: A/B decision
- **Find a Grave headstone/gallery extractor** (URL-only) + **Inspector UI** (disclosure + per-row on-demand Download); highest-yield first cut. — gate: source_media migration
- **Storage lifecycle** — `fetchStatus` urlOnly→cached + auto-cache heuristics + "cache all" toggle. — gate: source_media migration
- **CWGC image extractor** (headstone photo + certificate PDF URL). — gate: FAG extractor
- **FamilySearch image extractor** (decode `links[]` on `GxSourceDescription`, image-waypoint URL + region). — gate: FAG + CWGC extractors + FS session
- **Publisher `convergenceByProfile` feed** — Sourcing verdicts feed the publisher's per-profile convergence badge. — `SOURCE_WEIGHTING_SPEC.md` · independent

### 2f. Assistant surface (MCP consumer)

- **In-app "Connect to Claude" button** — the MCP server + `.mcpb` Desktop Extension artifact are built (`Scripts/build_mcpb.sh` → `dist/AncestorResearch.mcpb`, reader posture baked in). Remaining: live install-verify in Claude Desktop, then embed the server binary in the app bundle (Xcode Copy Files phase, code-sign-on-copy — do with the project open) so the button stages the same zip at runtime. Claude is the assistant tier for now (owner, 2026-07-31).
- **MLX built-in assistant (bounded)** — the in-app local model drives the SAME reader-posture tool surface in-process: fixed question intents (who-is / evidence-behind / how-related / what's-new / leads-summary) → deterministic tool plans → model narrates returned JSON only (the anti-strategist design). Strategic driver: **iOS — MLX runs on iPhone where desktop MCP clients can't** (iPhone-first market), so this becomes the only assistant tier on mobile; deep investigation stays Claude-over-MCP on Mac. Gate: `.mcpb` packaging + intent-plan design; prereq fix rides along: MLX thinking-off chat-template regression.

## Future (no near-term gate / no owning spec yet)

- **WikiTree assisted write-back — BUILT, live-verify BLOCKED on account unblock** (`WIKITREE_MERGEEDIT_SPEC.md`, #WT0–#WT4; sanctioned Special:MergeEdit path, human commits on WikiTree's review page). Remaining WT5: Error-2562 unblock (emailed info@wikitree.com) → manual edit proof → Apps Google Group courtesy post → first live MergeEdit → settle spec §7 encoding unknowns.
- **Collaborative-tree contribute-then-enrich / `TreeProvider` abstraction** (WikiTree primary, FS secondary) — FUTURE; ADR-006 reversal, gated on a 2nd real tree integration. Both write legs now exist (FS User Trees live-verified; WikiTree MergeEdit built) — the abstraction question becomes real once WikiTree live-verifies.
- **BYO-API-key frontier-model tier** (Claude/Gemini/OpenAI behind the DOSSIER provider seam) — decision-gated; needs privacy-consent UX + living-people redaction on outbound prompts.
- **Audit bulk-apply for one-click deterministic fixes** — a "Set/apply all in this category" affordance, gated to deterministic + non-destructive + reversible fixes. Two safe first candidates: **married surname from spouse** (writes only the `married_surname` column; caveat: profiles with a mis-parsed maiden `lastName` still owe a maiden-name follow-up) and **given name contains middle** (clean single-first-name rows only — exclude parentheticals/nicknames → route through `nameJunkResolution`, and compound given names like "Mary Ann"). Keep judgement categories (duplicates, phantom spouse) strictly one-per-row.
- **Audit: unmatched-location (gazetteer) coverage** — a Health finding for profiles whose birth/death locations have not resolved to a place-authority entry (complements `suspectLocation`, which flags *implausible* places; this flags *unresolved* ones). Gated behind location Stage 3 so it reuses the wired resolver and isn't pure noise. Open sub-questions: low-sev Gap not Issue; whether a one-click "resolve location" fix is offered (needs a disambiguation UI); a Health-screen coverage stat. (MCP `get_profile` doesn't yet expose `birthLocationCode`/`deathLocationCode`.)
- **Audit "Not a duplicate" per-pair dismissal** — the Duplicate-detection tab offers only Compare→Merge; a confirmed-distinct namesake pair re-fires on every recompute forever (`audit_rule_overrides` scopes no finer than `.profile(id:)`). Sketch: a pair-keyed `rejected_duplicates` table + a suppression check in `DuplicateDetectionRule.evaluate` + a "Not a duplicate" button on the audit row and in Compare. Motivating unclearable cases: George Keyworth ×3 (b.1838/1877/1904), the two Ellen Wards, the two George Wards (b.1851 vs son of William b.1870), Gladys/Glays Cauldwell.

## Stage 3 — release (gate: every phase complete — user, 2026-07-10)

First production publish → ASC viewer app records → viewer TestFlight lanes (already written) → family invites → soak items (revocation, unpublish propagation, redaction-as-participant audits).
