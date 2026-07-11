# GEDCOMX_CONCEPT_MAPPING — GEDCOM X vocabulary ↔ Ancestor domain model

**Status:** Active — maintained mapping (drafted 2026-07-11; E1–E4 shipped 2026-07-11, migrations v34–v37). Governing ADRs 003/004 Accepted. Update in the same commit as any migration touching a mapped concept (§5).
**Mandate:** ADR-003 *"GEDCOM X is adopted as vocabulary, not schema"* (Accepted 2026-07-11, depends on ADR-001). This file is the maintained concept-mapping document that ADR requires.
**Governing context:** the canonical-model decision (our model stays canonical; FS integrates as RecordSource + FS-specific Tree service; Option A "GEDCOM X as internal schema" formally rejected). GEDCOM X here means the conceptual-model spec family, not the live FS API — the API is "GEDCOM X RS plus custom FamilySearch extensions" ([gedcomx-csharp README](https://github.com/FamilySearch/gedcomx-csharp/blob/master/FamilySearch.Api/README.md)).
**Update rule:** any migration that touches a mapped concept updates this file in the same commit (§5).
**Path abbreviations:** `AK/` = `AncestorKit/Sources/AncestorKit/`, `App/` = `Ancestor Research/`.

---

## 1. Purpose

This document does two jobs:

1. **Boundary contract.** Any adapter that moves data between AncestorKit and a GEDCOM X-shaped surface (the FS RecordSource plugin, the FS Tree service, a future GEDCOM 7 export) implements the correspondences and flow rules below — not its own ad-hoc mapping. Divergences listed here are decisions, not bugs.
2. **Compatibility-review collateral.** FS reviewers meet a genealogy-literate model described in their own vocabulary (Conclusion, Persona, EvidenceReference, SourceDescription). Where we have no standard equivalent, §3 says so explicitly and says why — deliberate extension, not omission.

What this document is **not**: an alignment programme. The model evolutions referenced below are a **closed list of four** (per the canonical-model decision); anything beyond them is a new decision, not "GEDCOM X alignment."

| Label | Evolution (closed list) | ADR |
|---|---|---|
| **E1** | Typed external identifiers with deprecation lifecycle | ADR-004 (Accepted; E1 shipped, migration v34, 628218b) |
| **E2** | Typed, repeatable name forms | ADR-004 (Accepted; E2 shipped, migration v35, edf03ef) |
| **E3** | Place-authority records with jurisdiction + time | ADR-004 (Accepted; E3 shipped, migration v36, 11af547) |
| **E4** | Provenance on relationship-edge existence | ADR-004 (Accepted; E4 shipped, migration v37, ed2927b) |

Spec references throughout: [GEDCOM X conceptual model](https://github.com/FamilySearch/gedcomx/blob/master/specifications/conceptual-model-specification.md) unless noted. Anything the research cross-check flagged as unverified is marked **UNVERIFIED** inline and must not be built against until verified.

---

## 2. Concept map

Shared ancestry first: both models descend from GENTECH's evidence/conclusion split ([GENTECH data model](https://xml.coverpages.org/GENTECH-DataModelV11.pdf)). Ours states it in code: *"Profile typed fields are derived projections from this evidence; the evidence is the ground truth"* (`App/Models/Research/EvidenceRecord.swift:25-26`). The rows below are where the two vocabularies meet.

### 2.1 Primary correspondences

| # | Ours | GEDCOM X | Correspondence and binding divergence |
|---|---|---|---|
| 1 | `Profile` (`AK/Profile.swift:12-67`) | `Person` (Subject → Conclusion) | Same intent, opposite mechanics. Their gender/names/facts are each free-standing Conclusion objects with per-assertion sources and confidence; our fields are typed columns with provenance in a parallel map (`sources: [ProfileField: [FieldSource]]`). Deliberate: typed columns buy the decidability the 4-gate scorer and audit rules run on. **Rule: never adopt conclusion-objects internally** (rejected in ADR-001/-003); the multi-valued world lives in our evidence layer instead. |
| 2 | `evidence_records` (`App/Services/ProjectDatabase.swift:589-608`) | `Persona` + `EvidenceReference` | The deepest alignment. A persona is *"an instance of Person that has been identified as an extracted conclusion"*, constrained to reference exactly **one** SourceDescription — structurally our one-row-per-`(profileID, sourceRecordID)` with the full record kept forever (`EvidenceRecord.swift:27-49`). A tree Person's `evidence` list of personas = a profile's evidence-record set. Their single-source constraint is an invariant we already hold implicitly; codify it as an explicit test when the FS adapter lands. E1 added the typed external-identifier records (shipped, v34); persona/ARK identity linkage now has a typed home rather than collapsing into the `sourceRecordID` string. |
| 3 | `LifeCluster` | A tree Person's persona set | The *grouping* (records believed to be one person, feeding a conclusion Person) maps cleanly. The *grading* does not: cluster verdicts `stronglySupported/supported/weak/contradicted` (`App/Services/Research/LifeCluster.swift:178-194`) have no GEDCOM X analogue — see §3. |
| 4 | `field_sources` (`App/Services/ProjectDatabase.swift:105-115`) | `SourceReference` | Both link an assertion to a source description. Theirs can pinpoint (`Page`, `RectangleRegion` qualifiers — a bounding box on a page image) and reuses one SourceDescription across references; ours embeds a private `Citation` copy per row — no pinpointing, no reuse. Keyed by `(entity_id, entity_kind, field)`, so relationship *fields* already carry sources; edge *existence* now carries provenance too (E4 shipped, v37): an `existence` pseudo-field cites the attesting record. |
| 5 | `Citation` (`AK/Citation.swift:10-17`) + `SourceTierRegistry` (`App/Services/Research/SourceTierRegistry.swift:54-182`) | `SourceDescription` + `SourceCitation` | Their source is a chained first-class entity — record → parent Collection → digital Artifact, with author/mediator/publisher Agents ([Read Record use case](https://www.familysearch.org/en/developers/docs/api/records/Read_Record_usecase)); ours is a flat Mills-shaped 7-field struct (`AK/Citation.swift:3-4`). Both accept citation as human-literary prose with light structure. The registry consumes what their `about`/cited URL carries and derives the trust tier from it — **tier is never taken from any FS-asserted value** (§3 row 1, §4.3). A normalised `source_descriptions` table is a known deferred opportunity — build lazily, only when FS ingestion is real. |
| 6 | `GenealogicalDate` (`AK/GenealogicalDate.swift:16-21`) | `Date.original` + `Date.formal` | Our cleanest mapping. Both keep the verbatim original beside the machine form; both represent approximation and open/closed ranges. Outbound: qualifiers map to the formal grammar (`A` prefix, `start/end`, open ends); the `about`(±5)/`estimated`(±10)/`calculated`(±1) distinction collapses to `A` — accepted, documented loss. Inbound: their grammar also carries durations (`P1Y35D`) and recurrence (`R3/+1900/P1Y`) — **port the reference [gedcomx-date](https://github.com/FamilySearch/gedcomx-java/tree/master/gedcomx-date) parser, never hand-roll**. Our computation stays year-integer by design (`GenealogicalDate.swift:196-208`); sub-year precision stashes per §4.1. |
| 7 | `birthLocation` + `birthLocationCode` (`AK/Profile.swift:53-58`; gazetteer `App/Services/Sources/LocationGazetteer.swift:7-36`) | `PlaceReference` / `PlaceDescription` | Our display-string + nullable flat `COUNTY:Place` code is exactly their `PlaceReference` (`original` + optional `descriptionRef`). We have **no analogue of `PlaceDescription`**: a Subject with recursive `jurisdiction`, `temporalDescription` (a parish that changed county is representable), coordinates, and authority IDs ([Place Authority](https://www.familysearch.org/en/developers/docs/api/places/FamilySearch_Place_Authority_resource)). E3 closed this (shipped, v36): place-authority records with parish/district/county hierarchy and temporal validity, derived from gazetteer + district catalogue. Pre-E3, FS place-authority IDs and jurisdiction chains stashed per §4.1. Their temporal-jurisdiction modelling is what our no-hardcoded-regions rule wants to be when it grows up. |
| 8 | `Relationship` — parent/spouse edge (`AK/Relationship.swift:12-17, 46-62`) | `Couple` / `ParentChild` (+ FS ternary) | Their Relationship extends Subject: the edge itself carries facts, sources, notes, confidence. Ours is a minimal edge with a fixed marriage payload and — until E4 — **no provenance on the edge's existence** (our most consequential admitted gap). Siblings are derived, never stored (`AK/FamilyGraphSnapshot.swift:110-137`) — keep; it is a discipline FS lacks. FS additionally has the proprietary ternary `ChildAndParentsRelationship` (child + both parents, per-parent lineage typing). **UNVERIFIED:** its wire shape has only ever been seen as prose/help-centre description ([use case](https://www.familysearch.org/en/developers/docs/api/tree/Read_Child-and-Parents_Relationship_Sources_usecase)), never as raw JSON — do not design or build the split-into-two-binary-edges adapter until a live GET is captured on Beta. Inbound split loses the per-couple lineage binding; record that loss in the adapter. |
| 9 | Flat name fields — `firstName/middleName/lastName`, single `marriedSurname`, `nickName`, `mothersMaidenName`-on-child (`AK/Profile.swift:43-48`) | `Name` → `NameForm` → `NamePart` | Theirs is a linguistic stack: typed variants (BirthName/MarriedName/Nickname), preference-ordered, BCP-47 language tags, typed parts incl. Prefix/Suffix. Ours is a UK-record **search-key model** — maiden-surname doctrine, death-shape married-surname lookup, the post-1911 GRO mother's-maiden-name column (`AK/Profile.swift:23-48`) — honest about being an index model, and not a name model. **E2 closed this gap** (shipped, v35): repeatable typed name forms as an additive sidecar; flat fields stay the preferred/search-key projection, `displayName` and search axes byte-identical. WikiTree LastNameOther/LastNameCurrent are captured. Outbound: `marriedSurname` → a `MarriedName`-typed Name is a clean gain. |

### 2.2 Secondary correspondences (one line each)

| Ours | GEDCOM X | Note |
|---|---|---|
| `externalIDs: [String: String]` (`AK/Profile.swift:108-111`) | typed `Identifier` list (Primary/Authority/Persistent/Deprecated) | Theirs is the acknowledged best pattern (merge → Deprecated ID, old links resolve forever); we already prove it outbound at `published_ids.superseded_by` (`App/Services/ProjectDatabase.swift:899-911`). E1 ported it inbound (shipped, v34) — the prerequisite for any FS person linkage. |
| `FactConfidence` tentative/standard/wellEvidenced (`AK/FactConfidence.swift:11-14`) | Conclusion confidence Low/Medium/High | Near one-to-one; deterministic outbound mapping. The three-axis `EvidenceConfidence` behind it does not serialise (§3). |
| `PersonAttributes.privacy = livingPrivate` + `PublishPolicyResolver` | `Person.private` | Same posture: privacy is a flag gating export, not data deletion. |
| `field_changes` + `transactions` journal (`App/Services/ProjectDatabase.swift:53-61, 117-128`) | `Attribution` | Not equivalent — theirs records only the *latest* change (§3 row 5). Outbound, our `approval_method`/rule IDs render into a deterministic `changeMessage` template when the FS write path is built (ADR-009). |
| `LifeEvent` (subject-owned, `AK/LifeEvent.swift`) | `Fact` (subject-bound), *not* `Event` | Their free-standing `Event` carries multiple typed participants (witness, officiant) and can imply relationships; everything of ours is subject-owned. Known gap; the bounded fix (optional participants on `LifeEventDetails`) is outside the E1–E4 closed list — a new decision if wanted. |

---

## 3. Deliberate no-equivalents

The epistemic layer is **ours alone, by design**. No slot exists in GEDCOM X, GEDCOM 7, GPS, or Evidence Explained for any row below (the standards research's explicit central finding). In any interchange these are documented extensions and the loss is accepted — never smuggle them into standard slots, never mourn them in review.

| Ours | Nearest standard gesture | Why we exceed the standard (one line) |
|---|---|---|
| `SourceTrustTier` via `SourceTierRegistry` — URL-derived, AI/social domains hard-blocked (`App/Services/Research/SourceTierRegistry.swift:54-182`) | FS hint star-ratings — proprietary, opaque, outside the GEDCOM X spec ([3-star hints blog](https://www.familysearch.org/en/blog/introducing-3-star-record-hints-for-experienced-researchers); **UNVERIFIED currency** — post is undated in a quarterly-churn UI surface) | Trust is *derived from provenance, never asserted* — a number you can audit versus a number you take on faith. |
| 4-gate verdicts, persisted per-gate (`scored_records`; `App/Services/Research/RecordScorer.swift:34-38`) | none | Verdicts are explainable and testable — every fact/lead/impossible answers *why*. |
| `ConvergenceEngine` — lineage independence, surname-rarity demotion, directness caps (`App/Services/Research/ConvergenceEngine.swift:38-48, 116-131`) | recursive sourcing (a SourceDescription may *mediate* another) | GEDCOM X can say sources are related; only we *count* independence — "three derivative sources agreeing is weaker than one primary." |
| `negative_searches` (`App/Services/ProjectDatabase.swift:186-193`) | none, anywhere | GPS component 1 demands reasonably exhaustive research and no standard can record it; this is the most GPS-faithful structure in either model. |
| Append-only `field_changes` journal under `transactions` | `Attribution` — last-editor stamp only, *"singular, not a full audit trail"* | Every field write is replayable and undoable, with `approval_method`/`approval_rule_ids` recording the provenance of the *decision* (`App/Services/ProjectDatabase.swift:854-874`). |

Related but out of scope for this table: three-axis `EvidenceConfidence` collapses to one Low/Medium/High outbound (documented in §2.2); hypotheses, leads, pending_facts and firewall state **never leave the Mac** — research state, not conclusions; boundary, not loss.

---

## 4. Information-flow rules

Preamble, binding on every adapter: **all FS-originated tree data enters through the Evidence Firewall** — `pending_facts` / `pending_relationships` / `leads`, scored by the same 4 gates; nothing from an open-edit shared tree writes conclusions directly (ADR-008, Proposed; invariant per `CLAUDE.md`).

### 4.1 Stash, don't destroy

Any inbound payload field with no typed home in AncestorKit lands verbatim in `rawFields` (`AK/Research/RecordTypes.swift:21`) or the evidence row's `record_json` — never dropped. Known stash categories today: name variants and NameParts (until E2), place-authority IDs and jurisdiction chains (until E3), formal-date sub-year precision, duration/recurring dates, contributor attribution. This is the same conviction as *"never throw away a source response"* (`EvidenceRecord.swift:22-24`): as E1–E4 widened the model (all shipped, v34–v37), the stashes are re-read — nothing is re-fetched, nothing was lost. Name variants (post-E2) and place-authority IDs (post-E3) now have typed homes.

### 4.2 Pointer-only evidence

Third-party apps likely may not display FS historical-record content — a *legal* restriction requiring redirect to FamilySearch.org ([Compatibility Checklist](https://developers.familysearch.org/main/docs/compatibility-checklist)). **UNVERIFIED scope:** this is paraphrase-confirmed only (the page resisted direct fetch); whether it covers record content only, persona detail, or citation text is the single most design-consequential unknown — resolve via direct fetch/devsupport before committing any import architecture. Consequences now:

- Evidence rows must be **valid when a pointer is all we may hold**: ARK + match summary is a legitimate evidence record; the persona *is* the pointer.
- Store the `ark:/61903/…` **path segment**, never the full URL — FS's permanence guarantee covers the path only, not the domain, and excludes query decorations ([Persistent Identifiers](https://developers.familysearch.org/main/docs/persistent-identifiers)).
- UI built against FS record hits designs for a "View on FamilySearch" handoff, not an in-app record viewer, unless review explicitly grants more.

### 4.3 Hint score = lead ordering only

FS match scores / confidence values / star ratings are proprietary API surface with zero GEDCOM X backing and no published semantics. They may do exactly one thing here: **order the leads queue**. They never set a trust tier (tier stays URL-derived, §3 row 1), never enter the 4 gates, never count toward convergence, never appear in a published badge. A well-starred FS hint arrives with precisely the standing of any other lead: a suggestion awaiting our own scoring (ADR-008, Proposed).

---

## 5. How to update this document

- **When:** in the same commit as (a) any AncestorKit/ProjectDatabase migration touching a mapped concept (the E1–E4 migrations v34–v37 already triggered such updates; any future migration touching a mapped concept); (b) any FS adapter change that adds/removes a mapped field; (c) resolution of any **UNVERIFIED** flag (ternary wire shape, record-content restriction scope, hint-UI currency) — replace the flag with the verified fact and a source.
- **What:** amend the affected row(s), refresh the file:line evidence you touched, and append a line to the changelog below. Do not grow the E-list here — a fifth evolution is a new ADR, not an edit.
- **Review cadence:** re-verify file:line citations opportunistically when editing a row; a full citation sweep before any FS compatibility submission.

| Date | Change | Author |
|---|---|---|
| 2026-07-11 | Initial draft from fs-research corpus (r2-mapping-analysis, r2-our-model, standards, records-search-model). Status: Proposed. | Claude (overnight draft) |
| 2026-07-12 | Reconciled ADR cross-refs (E1–E4 all → ADR-004 Accepted; ADR-003 Accepted) and updated E1–E4 tenses to shipped (migrations v34–v37, commits 628218b/edf03ef/11af547/ed2927b). Status → Active. | Claude (tidy pass) |
