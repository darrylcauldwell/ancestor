# Research Coverage & Data Cleanse — Specification

**Status:** Change 3 implemented (parent inference). Changes 1, 2, 4 awaiting implementation.
**Scope:** SwiftUI `Ancestor Research` app (`/Users/darrylcauldwell/Development/ancestor/Ancestor Research/`)
**Date:** 2026-05-13
**Author context:** Drafted in a session where the user added themselves as a single starting profile (born 1976, Derbyshire) and discovered Research could not run for them. Investigation surfaced four distinct gaps — captured here as Changes 1–4.

---

## 1. Problem statement

The Research feature currently has four compounding limitations that together prevent the natural starting workflow ("add yourself, research, discover parents from your birth record, expand tree upward"):

1. **Region-locked dispatch.** `SearchDispatcher` fans out one FreeBMD query per district in `RegionConfig.derbyshire.districts` (7 districts). Anyone born outside Derbyshire gets zero FreeBMD results — not "weighted lower", but zero. The multi-region scaffold (`RegionConfig.load(named:)`, generic `RegionConfig` struct) exists but is unwired; only the Derbyshire constant is used.
   - Hardcoded call sites: `ResearchViewModel.swift:91`, `WholeTreeResearchViewModel.swift:92`, `ScoringRules.swift:391/396/401/406`, `FieldResearcherService.swift:209`.

2. **No structured location data.** `Profile.birthLocation: String?` is freeform. There is no Chapman code, no county, no parish — so even if we wanted to derive a home region per-profile, we can't. Existing data (GEDCOM imports, e.g. `Cauldwell Family Tree.ged`) contains entries ranging from clean ("Crich") to ambiguous ("Newport") to genuinely unresolvable ("near Crich farmhouse", "Madeira (born at sea)").

3. **Pipeline ignores discovered parents.** FreeBMD post-1911 birth records contain `mothersMaidenName`, which `FreeBMDSource.swift:234` correctly parses into `BirthRecord.mothersMaidenName`. The pipeline (`ResearchPipeline.swift`) uses this only for refining the subject's birth year — never for proposing parent profiles. A confirmed birth record could yield: mother (surname = maiden name, female, birth window subject−18..45) and father (surname = subject's surname, male, same birth window). Currently these inferences are dropped on the floor.

4. **No data cleanse path.** Once data is in the tree (whether from GEDCOM, WikiTree, or manual entry), there is no per-profile or per-tree workflow to walk through ambiguities and upgrade data quality. Audit findings surface gaps but there is no resolution wizard.

The earlier (now-superseded) global `birthYear > 1930` cutoff has already been removed (commit prior to this spec) in favour of per-source coverage filtering at `SearchDispatcher.buildAllQueries`. That fix is *necessary* for the workflow but not *sufficient* — the four issues above remain.

---

## 2. Design decisions made during planning

These were decided during the planning conversation and are *not* open questions for the implementation phase:

| Decision | Choice | Rationale |
|---|---|---|
| Search behaviour outside home region | **National with home-region weighting**, not exclusion | User design intent: region biases scoring, never silences results |
| Location field at entry time | **Freeform stays permissible**; structured code added alongside | GEDCOM imports and edge cases ("born at sea") must survive |
| Disambiguation timing | **Per-profile cleanse wizard**, not at-save-time prompt | Existing imports must not generate a flood of save-time prompts |
| Typeahead at manual entry | **Yes, optional** — narrows new entries to gazetteer matches when possible, but doesn't block freeform fallback | Best of both: clean data when possible, permissive when not |
| "Unresolvable" state | **First-class persisted flag** per field | "Madeira (born at sea)" must never re-prompt after being marked unresolvable |
| Parent inference output | **Both** auto-propose during research (cluster review) **and** surface as a cleanse step for profiles that were never researched | One mechanism for research-time, one for retrospective upgrades |
| RegionConfig role after refactor | **Scoring/weighting only**, no dispatch filtering | `isLocalDistrict` / `nonLocalLocation` stay; dispatch fans out independently |
| Spec authority | **This document supersedes** any conflicting design assumptions about region filtering | Aligns with user's "region was always a weighting" intent |

---

## 3. Change 1 — National FreeBMD search with home-region prioritisation

### Motivation
Searches for anyone not in `RegionConfig.derbyshire.districts` return zero results because FreeBMD's API requires a district code per query and the dispatcher only fans out across the 7 Derbyshire districts.

### Behaviour
- FreeBMD dispatch fans out across **all UK registration districts** (~620 codes for England & Wales).
- Search is **staged** to avoid hammering FreeBMD (community-tier source):
  - **Iteration 1 — home-first**: districts in the subject's home region (derived from `Profile.birthLocationCode` after Change 2 lands, or from user's stored home region setting). Typically 5–15 districts.
  - **Iteration 2+ — national**: all remaining districts, fired only if iteration 1 produced no high-confidence (≥ `.moderate`) results.
- Concurrent FreeBMD requests capped at **10 in flight**, with a 100ms gap between batches.
- The national district code table lives at `Ancestor Research/Resources/Regions/freebmd-districts.json`. Schema: `[{"name": "Belper", "code": "722", "chapmanCode": "DBY"}, ...]`.
- `RegionConfig.derbyshire.districts` is preserved as scoring metadata (which districts count as "local" for `isLocalDistrict`), but is no longer consulted by `SearchDispatcher`.

### Acceptance criteria
1. **AC1.1** Searching a profile with `birthLocationCode = "LEI"` (Leicestershire) dispatches at least one FreeBMD query against a Leicestershire district code in iteration 1.
2. **AC1.2** Searching a profile with no birth location and no home region setting dispatches the national district set in iteration 1.
3. **AC1.3** A FreeBMD search that returns 0 results in iteration 1 (home-region only) automatically widens to national in iteration 2, provided `maxIterations` permits.
4. **AC1.4** A FreeBMD search that returns a `.moderate`+ scored record in iteration 1 does **not** automatically widen to national (saves the network round trip).
5. **AC1.5** Concurrent in-flight FreeBMD requests never exceed 10; verified via instrumentation or test seam.
6. **AC1.6** `RegionConfig.derbyshire.isLocalDistrict("Belper")` still returns `true` and continues to drive scoring weight; no behavioural change in `ScoringRules.swift`.

### Implementation notes
- New type `FreeBMDDistrictCatalogue` (in `Services/Sources/`) loads `freebmd-districts.json` once and exposes `districtCodes(forChapmanCode: String) -> [String]` and `allDistrictCodes() -> [String]`.
- `SearchDispatcher` gains a `mode: DispatchMode` field — `.homeFirst(chapmanCode: String)` or `.national`. The mode is set per iteration by `ResearchPipeline`.
- Throttle implemented via a single `Semaphore`-like async actor; FreeBMD source acquires before each request.
- Data source for the district table: FreeBMD's published registration district list. **This is a data-engineering task in its own right** — fetch, normalise to schema, commit. Allocate ~half a day in the Change 1 session.

### Files affected
- New: `Ancestor Research/Resources/Regions/freebmd-districts.json`
- New: `Ancestor Research/Services/Sources/FreeBMDDistrictCatalogue.swift`
- Modified: `Services/Research/SearchDispatcher.swift` (dispatch mode, no more `regionConfig.districts` loop)
- Modified: `Services/Sources/FreeBMDSource.swift` (throttle integration)
- Modified: `ViewModels/ResearchViewModel.swift`, `ViewModels/WholeTreeResearchViewModel.swift` (no longer pass `RegionConfig.derbyshire` to dispatcher)
- Modified: `Services/Research/ResearchPipeline.swift` (iteration logic for home-first → national widening)

---

## 4. Change 2 — Bundled UK gazetteer + structured `birthLocationCode`

### Motivation
Freeform `birthLocation` strings can't drive any geographic logic. We need structured place data on profiles so Change 1's home-first dispatch works and Change 4's location cleanse step has something to match against.

### Behaviour
- New field on `Profile`: `birthLocationCode: String?`. When set, holds a stable place identifier (recommended: GENUKI place ID, or a `chapmanCode:parish` composite). Authoritative when present.
- `Profile.birthLocation: String?` stays for display and unmatched freeform — the structured code never replaces the user's typed text.
- Bundled gazetteer at `Ancestor Research/Resources/Regions/uk-places.json`. Schema per entry: `{"id": "DBY:Crich", "name": "Crich", "county": "Derbyshire", "chapmanCode": "DBY", "parish": "Crich", "aliases": ["Crich Town"]}`. Target ~12k parish-level entries from GENUKI.
- New `LocationGazetteer` actor loads the file once and exposes `match(_ text: String) -> [GazetteerEntry]`, returning 0 / 1 / many matches.
- New typeahead `LocationPicker` SwiftUI component replaces the freeform TextField on the profile edit screen:
  - As user types, dropdown shows top N matches (limit 10).
  - User picks one → both `birthLocation` (display text "Crich, Derbyshire") and `birthLocationCode` ("DBY:Crich") are set.
  - User types something unmatched and tabs away → `birthLocation` set to raw text, `birthLocationCode` stays nil. This is supported and must not be lost.
- GEDCOM import does **silent bulk-match**:
  - Exact 1-match → both fields populated.
  - Ambiguous or no-match → `birthLocation` populated as imported, `birthLocationCode` stays nil. Surfaces in cleanse wizard later.

### Acceptance criteria
1. **AC2.1** Manually creating a profile and typing "Crich" in the location picker shows "Crich, Derbyshire" in the dropdown after ≤5 keystrokes.
2. **AC2.2** Selecting it from the dropdown sets `birthLocation = "Crich, Derbyshire"` and `birthLocationCode = "DBY:Crich"` (or equivalent stable ID).
3. **AC2.3** Typing "Madeira" with no match and tabbing away saves `birthLocation = "Madeira"`, `birthLocationCode = nil`. Profile persists. No error.
4. **AC2.4** Importing a GEDCOM with a clean Derbyshire place name populates both fields silently.
5. **AC2.5** Importing a GEDCOM with "Newport" (ambiguous) populates `birthLocation = "Newport"`, `birthLocationCode = nil`. Profile loads without error.
6. **AC2.6** Gazetteer lookup is < 50ms for a 3-character query against ~12k entries (in-memory linear scan is fine at that size; test under release config).

### Implementation notes
- Core Data migration: `birthLocationCode` is a new optional attribute. Lightweight migration with default value `nil`. Verify CloudKit sync compatibility (no `@Attribute(.unique)`, etc., per project rules).
- Gazetteer data source: GENUKI provides parish-level place lookups by Chapman code. Scrape or use their bulk export if available. **Data-engineering task — allocate at least one session for this alone.** Acceptable scope reduction for the first commit: ship England & Wales parishes only, omit Scotland/Ireland/Channel Islands, mark as known limitation in spec follow-up.
- Aliases: include common historical variants ("Crich Town" → "Crich"; "St Albans" with/without "St."). Where alias resolves to a single match, treat as 1-match. Where alias is itself ambiguous, treat as ambiguous.

### Files affected
- New: `Ancestor Research/Resources/Regions/uk-places.json`
- New: `Ancestor Research/Services/Research/LocationGazetteer.swift`
- New: `Ancestor Research/Views/Components/LocationPicker.swift`
- Modified: `Ancestor Research/Models/Profile.swift` (add `birthLocationCode`)
- Modified: Core Data model file (xcdatamodeld) — add `birthLocationCode` attribute
- Modified: Profile edit / create views (use `LocationPicker` instead of freeform TextField)
- Modified: GEDCOM importer (silent bulk-match on import)

---

## 5. Change 3 — Pipeline parent inference from birth records

### Motivation
A confirmed birth record with `mothersMaidenName` is concrete evidence of two parent identities. The pipeline currently uses it only to refine the subject's own birth year. This change closes that gap.

### Behaviour
- New type `ProposedRelative` (in `Services/Research/`):
  ```swift
  struct ProposedRelative: Sendable, Identifiable {
      let id: UUID
      let proposedSurname: String?
      let proposedGivenName: String?         // nil for parent inferences from BMD index
      let gender: Gender?
      let birthYearLow: Int?
      let birthYearHigh: Int?
      let relationship: ProposedRelationship  // .parentOf(subjectID)
      let evidence: [ScoredRecord]            // records that suggested this
      let confidence: Confidence
  }
  ```
- New step `inferRelatives(from: state.confirmedFacts, subject: state.subject)` runs in `ResearchPipeline.research` after `refineSubject` each iteration.
- For each confirmed `BirthRecord` where `mothersMaidenName != nil` and the source's trust tier ≥ `.transcription`:
  - Propose mother: `proposedSurname = mothersMaidenName`, `gender = .female`, birth window subject's birth `−18..−45` (inclusive at `−18`, exclusive at `−45+1`).
  - Propose father: `proposedSurname = subject.surname`, `gender = .male`, same birth window.
  - Both linked as `.parentOf(subjectID)`.
- Deduplication: if subject already has an existing parent of that gender with matching `lastName` (case-insensitive), do not propose.
- `ResearchResult` gains `proposedRelatives: [ProposedRelative]`.
- `ClusterReviewView` gains a new top section "Proposed Relatives" listing each relative as an accept/reject row.
  - Accept → creates a real `Profile` (ghost-shaped: no first name, surname set, gender set, birth date as estimated range) and a parent-of `Relationship` edge to the subject.
  - Reject → recorded in negative-searches so the same proposal doesn't reappear.

### Acceptance criteria
1. **AC3.1** Researching a profile with `surname = "Cauldwell"`, `birthYear = 1976` and an existing FreeBMD birth record with `mothersMaidenName = "Holmes"` produces exactly two `ProposedRelative` entries in `ResearchResult.proposedRelatives`: one with `(surname: "Holmes", gender: .female)`, one with `(surname: "Cauldwell", gender: .male)`.
2. **AC3.2** If the subject already has a mother profile with `lastName = "Holmes"`, only the father is proposed (mother is deduplicated).
3. **AC3.3** Pre-1911 birth records (no `mothersMaidenName`) produce no proposals from this rule.
4. **AC3.4** Accepting a proposed relative in `ClusterReviewView` creates a new ghost `Profile` with the expected surname, gender, and estimated birth range. A parent-of relationship to the subject exists.
5. **AC3.5** After acceptance, "Research All" in `WholeTreeResearchViewModel` picks up the new ghost profile and attempts to research it.
6. **AC3.6** Rejecting a proposed relative prevents it from being proposed again on subsequent research runs for the same subject (negative-searches honored).

### Implementation notes
- `ProposedRelationship` enum: `case parentOf(String)`, `case spouseOf(String)`, `case childOf(String)`. Only `parentOf` is wired in Change 3; the others are placeholders for future inference rules (e.g. marriage records → spouse).
- The estimated birth range becomes a `GenealogicalDate` with appropriate uncertainty. Reuse existing `GenealogicalDate` constructors.
- Ghost profile creation: the project already supports ghost profiles (`GhostRole`). Reuse — do not invent a new concept.
- Tests: unit test on `ResearchPipeline.inferRelatives` with mocked confirmed facts; integration test that runs the full pipeline against a fixture FreeBMD record.

### Files affected
- New: `Ancestor Research/Services/Research/ProposedRelative.swift`
- Modified: `Services/Research/ResearchPipeline.swift` (new `inferRelatives` step, return value plumbing)
- Modified: `Services/Research/ResearchState.swift` (`ResearchResult.proposedRelatives` field)
- Modified: `Views/Research/ClusterReviewView.swift` (new top section)
- Modified: `ViewModels/ResearchViewModel.swift` (accept/reject actions)
- Modified: relevant Core Data create-profile helper (ghost creation with surname-only)
- New: `Ancestor Research Tests/ResearchPipelineParentInferenceTests.swift`

---

## 6. Change 4 — Per-profile cleanse wizard

### Motivation
Once data is in the tree, the user needs a guided path to upgrade quality — disambiguate locations, accept proposed parents that earlier research surfaced, tighten date imprecision. An audit screen shows gaps; this change adds the *resolution* workflow.

### Behaviour
- New "Cleanse" button on the profile detail view (top-right, next to existing action menu). Opens a modal `ProfileCleanseWizard`.
- Wizard iterates ordered `CleanseFinding` instances for the profile. One finding per screen, with: title, description, proposed resolution(s), and three actions:
  - **Apply** — apply the proposed change, advance.
  - **Skip** — leave unchanged, advance, may reappear next time wizard runs.
  - **Mark unresolvable** — set a persistent flag on the field; this finding will not reappear for this profile until the user explicitly clears it via Settings.
- Finding types shipped in Change 4:
  1. **Ambiguous location** — `birthLocation` matches >1 gazetteer entry. Resolution: list of candidate `(county, code)` rows; pick one.
  2. **Unmatched location** — `birthLocation` is non-empty, `birthLocationCode` is nil, no gazetteer match. Resolution: show closest fuzzy matches (Levenshtein-style) + free-form re-edit.
  3. **Confirmed unambiguous location with no code** — `birthLocation` matches exactly one entry but `birthLocationCode` is nil. Resolution: "Match to {entry}?" Confirm / pick different / mark unresolvable.
  4. **Birth-record-implied parent missing** — a confirmed FreeBMD birth record exists for this profile with `mothersMaidenName`, but no parents are linked. Resolution: same flow as Change 3's accept path (creates ghost mother/father). Lets the user upgrade profiles that were never run through Research.
  5. **Bare-year date** — `birthDate` or `deathDate` has only a year, no quarter/month/day. Resolution: pick a quarter (Q1–Q4) from the BMD index if present, else skip.
- "Cleanse all" entry point: from the tree view or Settings, walk every profile's findings in sequence. Same wizard, just enqueued across the tree.
- `CleanseUnresolvableFlag` persisted per `(profileID, field)` pair. New table or extension to existing audit-state storage.

### Acceptance criteria
1. **AC4.1** A profile with `birthLocation = "Newport"` and `birthLocationCode = nil` opens the wizard and shows an ambiguous-location finding with at least 3 county candidates.
2. **AC4.2** Selecting "Newport, Isle of Wight" applies, sets `birthLocationCode` to the corresponding ID, advances the wizard.
3. **AC4.3** A profile with `birthLocation = "Madeira (born at sea)"` and no match opens an unmatched-location finding. Marking unresolvable persists the flag. Re-running the wizard does not surface this finding again.
4. **AC4.4** A profile with a confirmed birth record and `mothersMaidenName = "Holmes"` but no parent links shows the "Birth-record-implied parent missing" finding. Applying creates the ghost mother (and father, by surname).
5. **AC4.5** A profile with `birthDate` = bare year "1850" shows a bare-year finding. Apply with Q2 picked updates the date to "Q2 1850".
6. **AC4.6** "Cleanse all" iterates every profile with at least one outstanding finding; profiles with all findings resolved or marked unresolvable are skipped.
7. **AC4.7** Wizard never re-prompts a finding that was previously marked unresolvable, across app restarts (persistence verified).

### Implementation notes
- `CleanseFinding` is a protocol with `title`, `description`, `resolutionOptions`, `apply`, `markUnresolvable`. Concrete types per finding category.
- Finding generation is on-demand, not cached: opening the wizard for a profile runs the rule engine fresh. This avoids stale-state bugs.
- Wizard state machine: simple sequential — no branching. If a finding triggers a downstream finding (e.g. resolving location enables a parent-by-location check), the next-time-the-wizard-runs cycle picks it up. No mid-flight re-evaluation.
- UI: SwiftUI sheet, single column, large action buttons. Matches existing audit UI styling.

### Files affected
- New: `Ancestor Research/Services/Cleanse/CleanseFinding.swift`
- New: concrete finding types: `Services/Cleanse/AmbiguousLocationFinding.swift`, `UnmatchedLocationFinding.swift`, `UnconfirmedLocationFinding.swift`, `MissingParentFromBirthRecordFinding.swift`, `BareYearDateFinding.swift`
- New: `Ancestor Research/Services/Cleanse/CleanseEngine.swift` (finding generation + iteration)
- New: `Ancestor Research/Views/Cleanse/ProfileCleanseWizard.swift`
- New: `Ancestor Research/Views/Cleanse/CleanseFindingStep.swift` (one-finding view component)
- Modified: profile detail view (add Cleanse button)
- Modified: Core Data model — `CleanseUnresolvableFlag` entity or equivalent
- New: `Ancestor Research Tests/CleanseEngineTests.swift`

---

## 7. Implementation order and dependencies

```
Change 3 (parent inference)  ──┬──>  Change 4.finding-types.MissingParent
                                │
Change 2 (gazetteer + Profile field) ──┬──> Change 1 (home-first dispatch)
                                        │
                                        └──> Change 4.finding-types.location-*
```

**Recommended session breakdown:**

1. **Session A — Change 3 in full.** Self-contained, no external data, end-to-end testable. Deliverable: parent inference works in the cluster review for any profile that gets a confirmed birth record.

2. **Session B — Change 2 in full.** Data engineering for the gazetteer (GENUKI extract → JSON), Core Data migration for `birthLocationCode`, `LocationGazetteer` actor, `LocationPicker` view, GEDCOM import bulk-match. Deliverable: new profiles can pick locations from typeahead; imports auto-resolve where unambiguous.

3. **Session C — Change 1 in full.** Data engineering for the national FreeBMD district list, `FreeBMDDistrictCatalogue`, dispatch refactor to home-first + national-expand, throttling. Deliverable: search actually works for anyone in England & Wales.

4. **Session D — Change 4 in full.** Cleanse wizard with all five finding types, `CleanseUnresolvableFlag` persistence, per-profile and "Cleanse all" entry points. Deliverable: retrospective data upgrade workflow.

Each session ends with: clean build, preflight (lint + tests), thorough acceptance-criteria walkthrough against the relevant ACs. Commits within a session reference `#Change<N>` per the repo's spec-driven commit convention.

---

## 8. Out of scope (explicit non-goals)

- **Scotland / Ireland / Channel Islands gazetteer entries** in Change 2's first ship. Add in a follow-up if the user has profiles there.
- **Spouse / sibling inference from marriage and census records.** `ProposedRelationship` has `.spouseOf` and `.childOf` cases but Change 3 only implements `.parentOf` from birth records. Future scope.
- **LLM-driven cleanse suggestions** (e.g. asking the Field Researcher to suggest a county for an ambiguous place). Future scope; the cleanse wizard is deterministic.
- **Multi-region home configuration** (e.g. "I research Derbyshire and Cheshire equally"). One home region per user in Change 1/2. Future scope.
- **Localisation of the cleanse wizard UI.** English only; matches the project's overall localisation stance.

---

## 9. Open questions (resolve during each session, not now)

- **Q2.1** Final gazetteer ID scheme: GENUKI native IDs vs `chapmanCode:parish` composite. Decide at start of Session B based on what GENUKI's data actually looks like when fetched.
- **Q3.1** Should rejected proposed relatives be stored per-profile or per-(profile, evidence-record) pair? Latter is more precise (re-runs with new evidence can re-propose) but more state. Decide at start of Session A; recommend per-(profile, surname, gender) as a pragmatic middle.
- **Q4.1** Should "Cleanse all" run breadth-first (one finding per profile, then move on) or depth-first (resolve all findings for profile N before moving to N+1)? Decide at start of Session D; recommend depth-first because it matches the per-profile wizard's mental model.

---

## 10. Pre-existing change

The earlier per-source coverage refactor (removing the global `birthYear > 1930` cutoff) is a prerequisite for any of the above being useful. That work is already committed and is **not** part of this spec — it's the platform on which Changes 1–4 build.

Relevant fields / methods after that refactor:
- `SearchDispatcher.sourceCovers(_:yearRange:)` — per-source year overlap check, used at query-build time.
- `RecordSource.coverageYearRange: ClosedRange<Int>?` — declared by each source.
- No global birth-year cutoff anywhere.

---

## 11. Verification checklist (run at end of each session)

For the session's Change, after implementation:

- [ ] Every acceptance criterion in §3–§6 for the Change in scope has a corresponding test or a manually-verified scenario noted in the commit message.
- [ ] `xcodebuild -scheme "Ancestor Research" -destination 'platform=macOS' build` succeeds with no warnings introduced by the Change.
- [ ] If the Change touches Core Data: existing tree data still loads, sync still works, no data lost.
- [ ] If the Change touches Research pipeline: run a research session against a known profile, observe expected behaviour matches the Change's spec.
- [ ] All new files have appropriate headers, follow project Swift 6.2 conventions (`@Observable`, `nonisolated` where needed, `async`/`await`), and respect strict concurrency.
- [ ] Spec doc updated at the top with `**Status: Change N implemented** (commit hash)` once each Change is shipped.

---

*End of specification.*
