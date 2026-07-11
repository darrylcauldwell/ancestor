# MODEL_EVOLUTION_SPEC — Closed Four-Item Model Evolution Programme

**Status: Proposed — awaiting review.** Drafted overnight 2026-07-11 from the R2 research corpus; no changes started, nothing here is committed until Darryl reviews.

**Governing decision:** ADR-004 — *Model evolution is a closed four-item list* (R3 ADR set, drafted alongside this spec; decision basis in `r2-conclusions.md` §3/§5). **This list is closed: additions require a new decision record, not an amendment to this spec.** Anything pitched as "GEDCOM X alignment" beyond these four items is out of scope by prior decision (ADR-001/ADR-003: our model stays canonical; GEDCOM X is vocabulary, never schema).

**Ordering is load-bearing:** E1 → E2 → E3 → E4. E1 (typed external identifiers) is the prerequisite for *any* FamilySearch person linkage — the FS demo read leg cannot safely cache a single FS PID without a deprecation lifecycle (301 merge-forwarding, §Change 1). E2–E4 are independently valuable and independently shippable, but the execution order stands unless a review reorders it explicitly.

**What this programme is:** four bounded evolutions of the AncestorKit/App domain model, each convicted by our own roadmap (WikiTree ingest, GENUKI gazetteer expansion, publisher symmetry) with FS raising priority rather than creating the need (`r2-conclusions.md` §1.2). None violates an invariant; E4 *strengthens* one (evidence-backed trees).

**What this programme is not:** conclusion-objects for profile fields (would dissolve typed-column decidability — the deterministic sandwich rests on it), GEDCOM X as serialisation or interchange target, an FS sync feature, or a schema driven by the FS source spec (`r2-conclusions.md` §6: "a source spec never drives schema").

---

## Decision log

1. **Change numbers, not GitHub issues** — per repo convention; commits reference `#Change1`…`#Change4` of this spec.
2. **E2 keeps `displayName` as the projection** — the publisher materialises `displayName` as a string on `Person_v1` (`Ancestor Research/Services/Publish/PublishedTree.swift:50, 325, 339`), so viewers never recompute names. Containing E2 behind that projection makes the publisher/viewer blast radius zero.
3. **E3 rides the GENUKI expansion** — the ~12k-parish gazetteer import was already planned (`Ancestor Research/Services/Sources/LocationGazetteer.swift:31-36`); doing E3 first means the import lands into a hierarchy instead of a flat list that would then need re-migrating.
4. **E4 writes provenance forward-only** — no retroactive synthesis of existence sources for historical edges. Backfilling provenance that was never captured would fabricate evidence (violates check-before-overwrite / never-fabricate).
5. **Unverified-claim discipline** — carried from `_contradictions.md`: the FS 301 merge-forwarding behaviour is verified (direct fetch of the primary resource doc); the `ChildAndParentsRelationship` ternary wire shape is **unverified** (prose-sourced only) and nothing in this spec designs against it.

---

## Change 1 — E1: typed external-identifier records with deprecation lifecycle (S)

### Motivation

- `Profile.externalIDs` is an untyped single-slot-per-system dict — `[String: String]` (`AncestorKit/Sources/AncestorKit/Profile.swift:13`), persisted as a JSON text column (`Ancestor Research/Services/ProjectDatabase.swift:65`, decode `:969-970`). One ID per system, no type, no lifecycle, no merge forwarding.
- FamilySearch makes deprecated-ID chains mandatory for even a read-only person link: any request on a merged-away person ID returns **HTTP 301 Moved Permanently** with a `Location` header pointing at the survivor — for both reads and writes; 410 Gone is deletion, 301 is merge-forwarding (verified by direct fetch: https://www.familysearch.org/developers/docs/api/tree/Person_Merge_resource and https://developers.familysearch.org/main/docs/merging). A cached FS PID in a single-slot dict silently points at a merged-away person.
- The pattern is already proven **in-house, outbound**: `published_ids.superseded_by` records publish-boundary merges permanently (`ProjectDatabase.swift:899-911` — "rows survive delete/omit/re-add; superseded_by records merges"). E1 ports our own boundary mechanism inward; it has never been applied to inbound identity.
- ARK permanence covers only the `ark:/…` path segment, not the domain (`r2-mapping-analysis.md` §6.1 item 7) — storing full URLs over-trusts the guarantee.

### Schema/type sketch

```swift
// AncestorKit — new type beside Profile
public struct ExternalIdentifier: Codable, Hashable, Sendable {
    public var system: String          // "wikitree" | "familysearch" | "gedcom" | …
    public var value: String           // bare identifier; FS ARKs stored as the ark:/… path segment, never a full URL
    public var kind: IdentifierKind    // primary | persistent | deprecated
    public var supersededBy: String?   // successor value when kind == .deprecated
    public var recordedAt: Date
}
```

- `Profile` gains `externalIdentifiers: [ExternalIdentifier]`; `externalIDs: [String: String]` becomes a **derived projection** (primary per system) so the ~13 call-site files keep compiling, then call sites migrate opportunistically. `wikiTreeID` (`Profile.swift:108-111`) reads through the projection unchanged.
- Migration (next `ProjectDatabase` version): new `external_identifiers` JSON column on `profiles`, backfilled from `external_ids` (every existing entry → `kind: .primary`); the old column freezes in place for one release as rollback insurance. *(Review decision: replace-in-column vs. new-column — new column proposed for bisectability.)*
- Lookup rule: resolving an identifier follows the `supersededBy` chain to the current primary; chains are append-only.

### Blast radius

- **App:** call sites in `WikiTreeClient`, `GEDCOMParser`, `ImportAsCorrectionsEngine`, `ProjectDatabase(+PromoteLead, +ProposedRelative)`, `AppState`, manual-entry views, `DemoDataGenerator`, `OnboardingWizardBuilder` — all compile through the projection on day one.
- **Publisher/viewers:** zero. Canonical IDs never leave the Mac (PUBLISHER_SPEC §4.1); `externalIDs` is not part of `Person_v1`.
- **Python parity:** none — the twin format is untouched; `compare_twins.py` must stay green as the no-op proof.
- **Tests:** Profile Codable round-trip, migration backfill, chain resolution, projection equivalence on existing fixtures.

### Acceptance criteria

1. A profile can carry primary + deprecated identifiers for the same system simultaneously; lookup by a deprecated value resolves to the primary via the chain.
2. Recording the same `(system, value)` twice is idempotent.
3. An FS-style ARK stores as the path segment only; a test rejects full-URL values.
4. Migration converts every existing `external_ids` entry losslessly; `wikiTreeID` behaviour is unchanged on the full test corpus.
5. `compare_twins.py` parity unchanged.

### Non-goals

- No FS HTTP client, no 301-following code — that is the FS Tree service (ADR-002), which *consumes* E1.
- No change to `published_ids` or the publish boundary.
- No identity-resolution/dedup engine changes (`ProposalDedup` untouched).
- No ARK column on `evidence_records` — that is a spec-level item shipping with the FS source spec (Appendix A2).

---

## Change 2 — E2: typed repeatable name forms, `displayName` stays the projection (M)

### Motivation

- The name model is a research-index projection, deliberately: maiden surname in `lastName`, exactly **one** `marriedSurname` (`Profile.swift:37`, doctrine at `:23-37`, migration rationale `ProjectDatabase.swift:830-852`), exactly one `nickName` (`Profile.swift:42`), `mothersMaidenName` on the child (`Profile.swift:48`). Excellent as search keys; it cannot represent a twice-married woman, a deed-poll change, aliases, prefixes/suffixes, or non-Western name structures (`r2-our-model.md` §7 "Names"; `r2-mapping-analysis.md` §4.3).
- **Live data-loss bug, both ingest paths:** WikiTree stores name variants in `LastNameOther`, and both our importers silently drop it.
  - Python reference: the API client requests it (`wikitree/api.py:29`) and the twin models it (`wikitree/_models.py:12`) — the pipeline even *depends* on it for spouse-surname recovery (`agent/pipeline.py:687-700`) — but the app importer maps only `LastNameAtBirth` (`import_twin_to_app.py:56, 218-219`).
  - Swift (the product): `WikiTreeClient.defaultFields` doesn't even request `LastNameOther`, and requests-but-never-maps `LastNameCurrent` (`Ancestor Research/Services/WikiTreeClient.swift:29-36`); `convertProfile` maps only `LastNameAtBirth` (`WikiTreeClient.swift:416-420`). A data-loss bug awaiting its first round-trip.
- Every mature system converged on repeatable typed name lists — GEDCOM X, FS, WikiTree, RootsMagic, Legacy (`r2-conclusions.md` §3 E2). This is also the lossless landing zone FS name conclusions need (L2 stash-don't-destroy, until then).

### Schema/type sketch

Sidecar, not rebuild (`r2-mapping-analysis.md` §7.3):

```swift
// AncestorKit
public struct NameForm: Codable, Hashable, Sendable {
    public var type: NameFormType    // birth | married | alsoKnownAs | nickname | religious | anglicised | other
    public var fullText: String
    public var lang: String?         // BCP-47, optional
    public var given: String?
    public var surname: String?
    public var prefix: String?
    public var suffix: String?
}
```

- `Profile` gains `nameForms: [NameForm]` (default `[]`); one JSON column on `profiles` (same pattern as `attributes`).
- **The flat fields stay canonical search keys.** `firstName/lastName/marriedSurname/nickName/mothersMaidenName` keep their engine semantics untouched — the married-surname doctrine (`Profile.swift:23-37`) and source dispatch (`ProjectDatabase.swift:846-847` "explicit-OR-derived in that order") do not change.
- `displayName` (`Profile.swift:104-106`) remains the *only* name projection consumers see; the publisher ships it materialised (decision log #2), so nothing downstream re-derives names.
- Ingest fix lands in the same change: WikiTree ingest maps `LastNameOther` → `.alsoKnownAs` and `LastNameCurrent` (when ≠ `LastNameAtBirth`) → `.married` name forms. Swift first (Swift is what ships); the Python importer is reference tooling and may follow.
- Matcher integration (consulting `nameForms` via the existing `name_equivalences` path, `ProjectDatabase.swift:177-183`) is **optional follow-on**, not this change.

### Blast radius

- **App:** Profile Codable + one migration; `WikiTreeClient`; `GEDCOMParser` (multiple GEDCOM `NAME` records → forms — currently dropped); profile editor gains a variants section (read/add; minimal).
- **Publisher/viewers:** zero — `Person_v1.displayName` unchanged; no new published fields.
- **Engine:** zero — scorer/dispatch/dedup read the flat fields only.
- **Tests:** round-trip, ingest fixtures with `LastNameOther`, displayName regression across the corpus.

### Acceptance criteria

1. A twice-married woman is representable: two `.married` forms plus the flat `marriedSurname` (which keeps the search-key winner).
2. A WikiTree profile with `LastNameOther` ingests without loss (form present, flat fields unchanged).
3. `displayName` output is byte-identical for every pre-existing profile (regression test over fixtures).
4. Publisher output for a tree with no name forms is unchanged; with name forms, also unchanged (proves containment).
5. Field provenance: `nameForms` is journalled as a single `ProfileField` case (one `field_changes`/`field_sources` granularity — per-form provenance is a non-goal).

### Non-goals

- No engine/search behaviour change; the married-surname and mothers-maiden-name doctrines stand.
- No removal or deprecation of `marriedSurname` / `nickName` / `mothersMaidenName`.
- No per-name-form provenance or confidence.
- No viewer rendering of variants.
- Interim FS handling (stashing FS name conclusions in `rawFields`/evidence JSON) stays with the FS source spec (L2), not here.

---

## Change 3 — E3: place-authority records — hierarchy + temporal validity (M)

### Motivation

- Places today are a display string + flat two-tier `COUNTY:Place` code (`Profile.swift:53-58`; `Relationship.swift:14-16`; migrations v14/v15 `ProjectDatabase.swift:610-632`), backed by a flat ~300-entry `GazetteerEntry { id, name, county, country, aliases, kind }` (`LocationGazetteer.swift:7-14`).
- **The registration district — *the* pivot of UK BMD research — exists only as strings inside hypothesis payloads**: `districtHint` on `.subjectIdentity` (`AncestorKit/Sources/AncestorKit/Research/ResearchHypothesis.swift:149`). It has no entity, no hierarchy position, no identity across runs.
- The planned ~12k-parish GENUKI expansion (`LocationGazetteer.swift:35-36`) will not survive a flat namespace: parish-name collisions within counties, no parish→district→county chain to disambiguate or roll up (the chain the v14 migration rationale already promises: "parish → district → county → national", `ProjectDatabase.swift:612-614`).
- UK jurisdictions move: parishes changed counties; registration districts were reorganised (1837 creation, 1852, 1946). GEDCOM X's `jurisdiction` + `temporalDescription` is the shape our own no-hardcoded-regions rule "wants to be when it grows up" (`r2-mapping-analysis.md` §2.7, §4.4) — E3 is its data-driven fulfilment, not an FS feature.

### Schema/type sketch

(`r2-mapping-analysis.md` §7.4 — profile shape unchanged.)

```swift
// GazetteerEntry gains hierarchy + temporal validity
struct GazetteerEntry {
    let id: String            // unchanged ("DBY:Crich")
    // … existing fields …
    let parentID: String?     // "DBY:Belper-RD" → "DBY"; nil for top level
    let validFrom: Int?       // year bounds on the jurisdictional relationship
    let validTo: Int?
}
```

- New `kind` values: `"registration-district"`, `"parish"` (existing `"county"` unchanged, `LocationGazetteer.swift:13-14`).
- `uk-places.json` schema versioned; the GENUKI import spec targets the new shape directly (decision log #3).
- Optional, additive: nullable `place_authority_id` columns beside the existing `*_location_code` columns (profiles, relationships, life_events) as the future landing slot for external authority IDs (FS Place Authority — stash-don't-destroy per L8 until then). Profile/Relationship Swift shapes unchanged: still string + code.
- A place that changed jurisdiction is two entries or one entry with dated parent links — **decide at implementation against real GENUKI data; both are representable in this shape.**

### Blast radius

- **App:** `LocationGazetteer` (load + resolve through hierarchy), `LocationPicker` typeahead (display district/county path), cleanse-wizard ambiguity detection. Gotcha: new/changed JSON resources need Xcode quit-and-reopen for IDE builds (`feedback_xcode_synchronized_group_resources`).
- **Engine:** geography gate and `Region` overlap **unchanged** — `Region` stays deliberately permissive (`AncestorKit/Sources/AncestorKit/Research/Region.swift:4-11`); E3 gives it better data, never tighter semantics.
- **Publisher/viewers:** zero — location strings publish as-is today; codes are not in the published schema.
- **Tests:** hierarchy resolution, temporal lookup, legacy-code compatibility, JSON schema-version load.

### Acceptance criteria

1. A registration district is a first-class `GazetteerEntry` with parish children and a county parent.
2. Query "parish P in year Y" resolves district and county through the hierarchy, respecting `validFrom/validTo`; a parish that changed jurisdiction resolves differently either side of the boundary year.
3. Every existing `COUNTY:Place` code still resolves (backwards compatible; no stored-code migration needed).
4. `districtHint` strings can be matched against district entries (a lookup helper — the hypothesis payload itself is unchanged).
5. The GENUKI import format is specified and a sample import (≥1 county at parish level) passes the hierarchy tests.

### Non-goals

- No world gazetteer — UK scope only (`Region` already enumerates the corpus's scopes).
- No coordinates requirement (at most an optional field).
- No rewrite of geography-gate scoring or `Region` semantics.
- No change to Profile/Relationship/LifeEvent Swift shapes.
- No FS Place Authority sync — when FS arrives, its place IDs land in `place_authority_id` as enrichment, per the FS source spec.

---

## Change 4 — E4: edge-existence provenance via a `field_sources` `existence` pseudo-field (S)

### Motivation

- "This parent edge exists because of this baptism record" has no home — our own honest inventory admits it (`r2-our-model.md` §7: edges have no FieldSource list for their existence; once accepted, the edge is flat fact). `r2-mapping-analysis.md` §4.2 rates this the single most consequential GEDCOM X advantage over us, because it touches the core value proposition: evidence-backed trees.
- The evidence already exists and is **discarded at accept-time**: `pending_relationships` carries `source_url`, `source_title`, `evidence_text`, `reasoning` (`ProjectDatabase.swift:745-748`), but the accept path creates a bare `Relationship` and inserts it with no provenance row (`Ancestor Research/Services/Research/ApplyEngine.swift:306-330` — `ensureParentEdge` → `addRelationshipIfAbsent`, nothing else).
- The mechanism is already built: `field_sources` is keyed `(entity_id, entity_kind, field)` (`ProjectDatabase.swift:105-115`, insert at `:1770`), `RelationshipField` is a first-class member of the `ChangeField` journal union (`AncestorKit/Sources/AncestorKit/FieldTypes.swift:12-20`), and relationship *fields* (marriageDate…) can carry sources today. Adding an `existence` case is a natural extension, zero new tables.

### Schema/type sketch

```swift
// FieldTypes.swift — one added case
public enum RelationshipField: String, Codable, Hashable, Sendable {
    case marriageDate, marriageLocation, divorceDate, subtype, role
    case existence        // NEW: provenance for the edge existing at all
}
```

- No migration: `field_sources.field` is TEXT; `existence` rows use `entity_kind = 'relationship'` exactly like existing relationship-field rows.
- Write points (every path that materialises an edge):
  1. Pending-relationship accept — FieldSource built from the proposal's `source_url`/`source_title`/`evidence_text` (+ `Citation` where derivable; trust tier stays URL-derived via `SourceTierRegistry`, never asserted).
  2. `ApplyEngine` parent-edge and spouse-edge materialisation (`ApplyEngine.swift:306-330` and the `.parentMarriage`/spouse paths) — FieldSource from the driving evidence record's citation.
  3. Placeholder write-back and lead promotion — same pattern.
  4. Manual UI / import edges — an `existence` row with the appropriate `SourceOrigin` (`userAuthoritative` / `initialImport`), value `raw` = a short human-readable origin note. *(Review decision: whether manual edges write a row or remain bare; proposed: write it — a uniform invariant is testable, "every edge created after E4 has ≥1 existence row".)*
- Journalling: edge creation already flows through `transactions`; the existence FieldSource carries `created_by_transaction_id` like every other row.

### Blast radius

- **AncestorKit:** one enum case (additive raw value — Codable-safe).
- **App:** every edge-creation call site (ApplyEngine, pending-relationship accept, promote-lead, placeholder write-back, manual entry, GEDCOM/WikiTree import). Optional UI: relationship inspector shows "why this edge exists" — data-only in this change is acceptable.
- **Publisher/viewers:** zero — edge provenance is Mac-local evidence-layer data; the published schema is untouched.
- **Tests:** per-path existence-row tests; idempotency (re-accept ⇒ no duplicate rows); journal linkage; `DeterminismBoundaryTests` unaffected (no verdict semantics change).

### Acceptance criteria

1. Accepting a pending relationship writes exactly one `existence` FieldSource whose citation URL is the proposal's `source_url`; tier resolution goes through `SourceTierRegistry`.
2. Every ApplyEngine edge-materialisation path (parent, spouse, placeholder write-back) writes an existence row citing the driving evidence.
3. Idempotent: re-running an accept or `addRelationshipIfAbsent` on an existing edge adds no duplicate existence rows.
4. Edges created before E4 remain bare and render/behave exactly as today (decision log #4 — no backfill).
5. Relationship equality/identity unchanged (`Relationship` struct untouched).

### Non-goals

- No `FactConfidence` on edges, no edge-level dispute mechanism, no edge subtype vocabulary changes.
- No publisher schema change; no viewer rendering requirement.
- No retroactive provenance synthesis (decision log #4).
- No attachment-target extension to relationships (`AttachmentTarget` unchanged).
- No FS `ChildAndParentsRelationship` mapping — wire shape unverified (`_contradictions.md` item on ternary relationships); any FS-import mapping to two binary edges + existence rows is designed only after a live GET on Beta, and lives in the FS modules, not here.

---

## Appendix A — spec-level supporting items (NOT part of the closed list)

Two small items from `r2-conclusions.md` §3 that travel *with* this programme but are deliberately outside the four-item schema list — recording them here so they aren't re-pitched as evolutions later.

### A1. Extracted-conclusion one-source invariant test (S — test only, no schema)

We hold GEDCOM X §4's constraint — *an extracted conclusion must not reference more than one source* — implicitly by construction: `evidence_records` is keyed `"<profile_id>|<source_record_id>"` with a single `source_id` column (`ProjectDatabase.swift:589-601`; doctrine at `Ancestor Research/Models/Research/EvidenceRecord.swift:20-27`). Make it explicit: one test asserting an `EvidenceRecord` binds to exactly one source, so a future refactor (e.g. a `source_descriptions` normalisation) cannot silently break the persona-shaped invariant. Can land any time; suggested alongside Change 1.

### A2. ARK/persona identity column on `evidence_records` (S — ships with the FS source spec, not here)

Persona↔person evidence links currently collapse into the `source_record_id` string (`r2-mapping-analysis.md` §6.1 item 2 — flagged High severity, "cheap to fix"): nullable `external_persona_id` (bare `ark:/…` path segment, per the E1 rule) + `external_record_id` on `evidence_records`. **Cross-reference: this lands with `FAMILYSEARCH_SOURCE_SPEC.md`** (its L3 scope item), because it is FS-boundary receiving shape, not domain-model evolution — a source spec never drives schema, and equally this schema programme doesn't absorb source-spec plumbing. Noted here only so E1 and A2 agree on the ARK-path-segment storage rule.

---

*Evidence base: `r2-conclusions.md` §3 (the list and sizes), `r2-mapping-analysis.md` (per-item conviction), `r2-our-model.md` (as-built shapes), all 2026-07-10; code citations re-verified against the working tree 2026-07-11. Claims flagged unverified in `_contradictions.md` are labelled as such above and nothing is designed against them.*
