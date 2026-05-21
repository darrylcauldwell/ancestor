# Profile View Unification Spec

Unify `ProfileDetailView` (read-only, ~688 lines) and `EditPersonView`
(edit-in-sheet, ~580 lines) so the edit flow inherits the detail view's
"nicer" layout instead of carrying its own.

This spec is the planning output of a session that ran out of context
before implementation. Pick it up cold — no prior conversation context is
required.

## Why

Two pain points the user surfaced in the prior session:

1. **Label visibility bug.** `EditPersonView` uses `TextField(label,
   text:)`, which renders the label only as placeholder. Once a value is
   typed, the user can't see which field is which — birth/death dates
   become indistinguishable at a glance.
2. **Layout duplication.** The detail view's layout is the nicer one.
   Maintaining two parallel layouts means visual drift between read and
   edit is inevitable, and any improvement has to land twice.

The unified view is the structural fix for both. (A "just add persistent
labels" patch was offered as an alternative but rejected — the user
preferred the more complete solution.)

## Current state

### `Views/Tree/ProfileDetailView.swift` (688 lines)

Read-only inspector. Single `ScrollView` containing a `VStack` of sections:

- Header (display name, WikiTree ID, completeness, pending-facts count)
- Missing-facts section (per-gap research buttons)
- Core fields: birth/death date + location, gender — each via
  `fieldRow()` (~lines 456–489) and `hypotheticalLine()` (~lines 425–454)
- Relationships (parents, spouses with marriage metadata, children,
  siblings)
- Disputes (competing-source conflicts)
- Life events (tappable rows opening editor sheet)
- Attachments (photo/PDF gallery with "+ New")
- Notes (workbench notes)
- Action buttons row: Edit, Timeline, Relationship Calculator, Research,
  Cleanse, Show as Root — Edit currently opens `EditPersonView` as a sheet

Composition is modular but not aggressively decomposed: ~8 `@ViewBuilder`
sections inline plus styling helpers (`valueText`, `sourceConfidenceDotColor`,
etc.). No extracted layout base type.

Zero edit machinery — pure read.

### `Views/ManualEntry/EditPersonView.swift` (580 lines)

Sheet-based form. Heavy edit machinery the detail view has none of:

| Concern | Lines | Notes |
|---|---|---|
| Form `@State` (13 columns) | 14–27 | firstName, middleName, lastName, marriedSurname, nickName, mothersMaidenName, gender, birthDateText, birthLocation, birthLocationCode, deathDateText, deathLocation, bio |
| `sourcePerField` dict | 38 | `[ProfileField: SourceOrigin]`. Seeded from `defaultSource` on load; user can override per field via inline picker. |
| `fieldChoice` dict | 54 | `[ProfileField: ChangeMode]` for the Correct-vs-Alternative segmented picker, shown only when a field with an imported source changes. |
| `citation` + `quality` | 48–49 | Single `Citation` + `EvidenceQuality` scoped to the default source, applied to every changed field whose per-field source matches the default. |
| `OriginalSnapshot` | 62, 564–579 | Snapshot of all original values, captured on load (lines 390–403). Used by `fieldChanged()` to detect diffs. |
| `buildChanges()` / `buildDateChanges()` | 433–490 | Construct `(field, old, new)` tuples for save. |
| `save()` | 492–562 | Splits into `correctChanges` (overwrite) + alternative-fact recordings, persists location codes, attaches citation to each changed field's source row. |
| `loadIfNeeded()` | 374–422 | Populates all 13 fields from profile, picks contextual default source via `SourceDefaults.defaultSource(context: .relativeOf(...))`, seeds `sourcePerField`. |

Dependencies the detail view doesn't have:
`SourceDefaults`, `AutoSuggestService.normaliseName`,
`GenealogicalDate.parsePreview`, `AppState.editProfile`,
`AppState.recordAlternativeFact`, `AppState.attachCitation`,
`CitationEntryView`, `CitationSuggestService`.

## Chosen approach

**Option 2: Shared layout + thin edit overlay.**

Considered and rejected:
- *Option 1 — mode-toggled monolith.* `@State var isEditing` on a single
  view. Conditional-hell per field, all edit state lives even in read
  mode. High defect risk.
- *Option 3 — inline Notion-style edits.* Tap each field to edit just
  that field. Heaviest state management; the per-field "Correct vs
  Alternative" picker becomes a sub-modal; loses the "one save" semantic.

### Shape

```
SharedProfileLayout                 // pure layout, no logic
  ├─ headerBlock(editable: Bool)
  ├─ namesBlock(editable: Bool)
  ├─ datesBlock(editable: Bool)
  ├─ bioBlock(editable: Bool)
  ├─ relationshipsBlock()           // always read-only
  ├─ lifeEventsBlock()              // always read-only
  ├─ attachmentsBlock()             // always read-only
  └─ notesBlock()                   // always read-only

ProfileDetailView (read-only consumer)
  └─ SharedProfileLayout(editable: false, bindings: nil)

EditPersonView (edit consumer)
  ├─ SharedProfileLayout(editable: true, bindings: ...)
  ├─ sourcePerField / fieldChoice machinery
  ├─ CitationEntryView block
  └─ save() flow
```

Per `editable: Bool` flag at the *block* level (not per field). Each
editable block accepts bindings as a typed parameter struct (so the read-
mode call site doesn't have to fabricate junk bindings).

### What stays inline vs in the edit sheet

- **Inline in unified view (always visible)**: name, dates, gender, bio.
  Edit mode shows `TextField`/`Picker`; read mode shows `Text`.
- **Edit sheet only**: per-field source picker, Correct-vs-Alternative
  toggle, citation entry. These are heavy edit machinery that don't
  belong in a read-mostly view.

This is the hybrid recommended by the prior session's survey — it avoids
trying to lift the citation/source-picker UX into a context where it
makes no sense in read mode.

### Relationships, life events, attachments, notes

**Stay read-only in both modes.** Editing them goes through their
existing flows (life-event editor sheet, "+ New" attachment, etc.). The
unified view's edit mode applies *only* to the editable blocks. The
visual language should make that clear:

- Editable blocks first (name → bio).
- A divider.
- Read-only blocks below (relationships → notes).

The Edit button's label could be reworded to "Edit Details" so the scope
isn't ambiguous.

## Refactor plan (in order)

1. **Extract `SharedProfileLayout`** from `ProfileDetailView`.
   Conservative refactor — move blocks into a new file under
   `Views/Profile/SharedProfileLayout.swift`, parameterise each editable
   block with `editable: Bool` (default false) and an optional bindings
   struct. `ProfileDetailView` becomes a thin caller. No behavioural
   change; visual diff should be zero.
2. **Add persistent leading labels** to the editable blocks. Each field's
   TextField gets a label *outside* the text field (above or to the
   left), so the field's purpose stays visible after typing. This fixes
   the immediate visibility bug for free.
3. **Port `EditPersonView` to wrap `SharedProfileLayout`.** Keep all the
   edit machinery (`@State`, `sourcePerField`, `fieldChoice`, citation,
   save) in `EditPersonView`; just delegate the layout rendering to the
   shared component via bindings. Edit-only sections (per-field source
   picker, Correct/Alternative, CitationEntryView) live below the shared
   layout in the sheet.
4. **Decide on the entry point**: keep the existing sheet-based edit
   flow, or convert to an inline mode-toggle on `ProfileDetailView`.
   Recommend: keep the sheet for now (smallest delta, lowest risk).
   Revisit only if the sheet feels redundant after the merge.
5. **Test in the macOS app** (per `CLAUDE.md`: UI work needs simulator
   validation before claiming done). Specifically:
   - Read mode looks visually identical to current `ProfileDetailView`.
   - Edit mode shows persistent field labels (the original bug).
   - Edit save behaviour (correct + alternative + citation) unchanged.
   - Life events / attachments / notes / relationships unaffected.

## Awkward bits to be aware of

These don't have great answers in any merge shape — accept them, don't
overthink:

1. **Citation entry is not a field-shaped concept.** It's one artifact
   per save, scoped to a default source. Keep it in the edit sheet, not
   in `SharedProfileLayout`.
2. **Mixed editable / read-only sections in the same view** could
   confuse users. Mitigation: explicit visual divider and a button
   labelled "Edit Details" (not just "Edit") so the scope is obvious.
3. **The "Correct vs Alternative" picker** appears below an imported
   field only when that field changes. This is cramped and contextual
   inside a sheet; trying to surface it inline in the unified view makes
   it worse. Keep it in the sheet.

## Effort estimate

The prior session's survey estimated 60–100 hours of focused work split
roughly:

- Extract `SharedProfileLayout` from detail view: ~20h
- Add persistent labels to editable blocks: ~5h (drops out of step 1)
- Port `EditPersonView` to wrap shared layout: ~40–50h
- Integration testing + visual QA in the macOS app: ~10–20h

A week or two of focused work, not a multi-week rewrite.

## Out of scope

- Editing relationships, life events, attachments, or notes through the
  unified view. Those keep their existing flows.
- Inline (Notion-style) per-field editing.
- Changing the data model or save semantics.
- The qualifier-picker / partial-date-hint UI improvements that were
  originally part of task #26's brief — these can be a follow-up to the
  unified-view work once `DateParsePreviewField` is rendering inside the
  shared layout.
