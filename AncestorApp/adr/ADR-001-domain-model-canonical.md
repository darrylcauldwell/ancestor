# ADR-001 — The Ancestor domain model is canonical; no external standard becomes the internal schema

**Status:** Accepted 2026-07-11 (Darryl)
**Source analysis:** R2 canonical-model decision (fs-research corpus, 2026-07-10)

## Context

Eight facts, each independently sufficient to steer the decision the same way:

- **F1 — The agreement constraint dominates.** Current FamilySearch access is Non-Production only; the signed agreement bans end-user availability at this tier (ground truth from the agreement itself — the public docs confirm only that Beta access "should not convey that solutions will be approved": <https://developers.familysearch.org/main/docs/app-approval-considerations>). The only sanctioned deliverable is a bounded demo of auth + read + write on Beta.
- **F2 — The FS API is not pure GEDCOM X.** FamilySearch's own SDK README: "an implementation of the GEDCOM X RS Specification, plus some custom FamilySearch extensions" (<https://github.com/FamilySearch/gedcomx-csharp/blob/master/FamilySearch.Api/README.md>) — ternary `ChildAndParentsRelationship`, hints/match-scores, Discussions, Memories, HTTP 450. Adopting GEDCOM X internally does not eliminate the adapter; it only changes what the adapter maps to.
- **F3 — GEDCOM X is a dormant standard.** No other vendor adopted it; no spec cadence since ~2016 (<https://www.tamurajones.net/GEDCOMXNoIndustryStandard.xhtml>). GEDCOM 7 is the live interchange format (7.0.18, Feb 2026: <https://gedcom.io/changelog/>) but is a *file* format with thin adoption. (Repo-activity nuance: `gedcomx-java` still receives pushes; whether substantive is unverified — see `_contradictions.md`.)
- **F4 — No ecosystem player uses GEDCOM X as its internal model**, including FamilySearch's deepest certified partners. RootsMagic and Ancestral Quest keep proprietary local models and sync via adapters with mandatory human review (<https://community.rootsmagic.com/t/using-rootsmagic-with-family-search/14596>, <https://www.ancquest.com/FamSearch/FAQS.htm>). "Own model canonical + adapter at the boundary" is the industry's unanimous convergent answer.
- **F5 — A local FS mirror can never be authoritative.** Person IDs soften to 301 redirects on merge, relationship IDs are destroyed and recreated, and the Tree Change feed silently omits Source/Memory/Discussion edits — FS's own guidance is re-fetch and diff (<https://developers.familysearch.org/main/docs/syncing-family-trees>, <https://developers.familysearch.org/main/docs/merging>).
- **F6 — Two invariants are incompatible with FS-as-truth.** The deterministic sandwich requires conclusions made by our rules over stable local state; the Evidence Firewall requires all external writers to pass through `pending_facts`/`leads` (CLAUDE.md, load-bearing invariants). A canonical store editable by any FS contributor bypasses both by definition.
- **F7 — AncestorKit is a shipped contract.** The 48-file domain core is the compiled dependency of the publisher and both viewers (Phase 4 accepted 2026-07-10, live participant sharing); churn multiplies across four shipped surfaces, ~1,687 tests, and the Python parity harness (`compare_twins.py`/`compare_gaps.py`).
- **F8 — The provider landscape is mostly closed.** Ancestry and MyHeritage have no public API; Findmypast's Hints API docs are archived (<https://github.com/findmypast/public_docs>); WikiTree is read-API + our bespoke twin. FamilySearch is the only documented live third-party tree API — and it is certification-gated.

The empirical vindication is already in-house: when WikiTree blocked our account for writes (2026-05-22), the local canonical model kept the product alive.

## Decision

**AncestorKit types remain the single internal representation — permanently.** GEDCOM X and GEDCOM 7 are boundary formats only: parsed at adapters, exported at adapters, never stored as the schema. **Option A ("adopt GEDCOM X as the internal schema") is formally rejected** so the question does not reopen each time a new platform appears.

**The steelman of Option A, stated fairly:** GEDCOM X's persona/Conclusion/EvidenceReference split is the GENTECH-lineage *mature formalisation of our own philosophy* — we independently rebuilt the same evidence-vs-conclusion architecture it codifies (<https://github.com/FamilySearch/gedcomx/blob/master/specifications/conceptual-model-specification.md>). Adopting its types would fix all four known expressiveness gaps in one stroke, thin the FS wire mapping, and present compatibility reviewers with a model in their own vocabulary. We would not be surrendering our beliefs; we would be inheriting their most-reviewed expression.

**Why it still loses:** (a) lossless FS round-trip is impossible under *any* internal model — the change feed omits source edits, merges destroy relationship IDs, open-edit means staleness on fetch (F5) — so the steelman's premise is unachievable; (b) the thin-mapping claim is false — the live API diverges from GEDCOM X exactly where it matters (F2), so the adapter survives the rewrite; (c) our differentiating machinery — trust tiers, 4-gate verdicts, convergence, negative searches, the append-only field journal — has no GEDCOM X slot and would become nonstandard extensions on a dormant standard (worst of both worlds), while a year-class rewrite freezes four shipped surfaces (F7). The one surviving asset — vocabulary — is harvested by ADR-003 at ~2% of the cost.

## Consequences

**Positive:** invariants hold trivially; zero risk to shipped surfaces; shortest path to the FS demo; matches the unanimous industry pattern; fully reversible posture (nothing forecloses).

**Negative:** we own every boundary mapping forever; the four real expressiveness gaps (names, foreign-ID lifecycle, place authority, edge provenance) must be fixed by our own hand — ADR-004 exists precisely so "canonical" is not read as "finished"; without the ADR-003 mapping document, external reviewers meet an unfamiliar model.

## Reversal conditions

Revisit this decision if any of the following occurs:

1. FamilySearch grants production write certification **and** the iOS-authoring pivot makes FS round-tripping the product's centre of gravity (weakens F1).
2. GEDCOM X receives a genuine multi-vendor revival with a maintenance cadence (weakens F3/F4).
3. Ancestry or MyHeritage opens a documented public tree API (weakens F8 — triggers the ADR-006 TreeProvider re-evaluation, **not** Option A).
4. The ADR-003 mapping document reveals sustained, painful impedance in ≥2 of the four ADR-004 evolution areas (argues for deeper targeted evolution, still not Option A).
