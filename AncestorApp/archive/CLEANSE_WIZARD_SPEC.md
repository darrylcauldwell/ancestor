# Profile Cleanse Wizard — Specification

**Status:** Implemented 2026-05-15. CleanseEngine + ProfileCleanseWizard + per-finding step view shipped; v22 `cleanse_unresolvable_flags` migration live; Cleanse button on profile detail and "Cleanse all profiles" entry in Settings wired; 6 acceptance tests in `CleanseEngineTests.swift` pass. Full test suite green.
**Scope:** SwiftUI `Ancestor Research` app (`/Users/darrylcauldwell/Development/ancestor/Ancestor Research/`)
**Date:** 2026-05-15
**Provenance:** Extracted from the now-archived `RESEARCH_AND_CLEANSE_SPEC.md` (Change 4). Changes 1–3 of that spec shipped; the cleanse wizard did not. This document is its standalone re-statement.

---

## 1. Problem statement

Once data is in the tree (GEDCOM import, WikiTree sync, manual entry, or Research acceptance), there is no guided path to upgrade quality. The audit screen surfaces gaps; this spec adds the *resolution* workflow.

Concrete cases the wizard must handle, drawn from real tree state:

- `birthLocation = "Newport"` — ambiguous; could be Isle of Wight, Monmouthshire, Shropshire, etc.
- `birthLocation = "Madeira (born at sea)"` — genuinely unresolvable; must not re-prompt.
- `birthLocation = "Crich"` but `birthLocationCode = nil` — single-match in gazetteer, just never confirmed.
- Profile has a confirmed FreeBMD birth record with `mothersMaidenName = "Holmes"` but no linked parents (because it was imported before the parent-inference pipeline existed).
- `birthDate` set to bare year "1850" with no quarter — common for older GEDCOM imports.

---

## 2. Design decisions

These are settled, not open questions:

| Decision | Choice | Rationale |
|---|---|---|
| Wizard timing | On-demand from profile detail screen, plus a "Cleanse all" tree-wide entry | No prompts at save-time; user-initiated only |
| Unresolvable state | Persistent per-(profile, field) flag | "Madeira (born at sea)" must never re-prompt after being marked |
| Finding generation | On-demand, not cached | Opening the wizard runs the rule engine fresh; avoids stale-state bugs |
| Wizard flow | Sequential, no branching | Resolving a finding never triggers a new one mid-flight; next run picks it up |
| Cleanse-all order | Depth-first (all findings for profile N before N+1) | Matches single-profile mental model |
| UI surface | SwiftUI sheet, single column, large action buttons | Matches existing audit UI styling |

---

## 3. Behaviour

- New "Cleanse" button on the profile detail view (top-right, next to existing action menu). Opens a modal `ProfileCleanseWizard`.
- Wizard iterates ordered `CleanseFinding` instances for the profile. One finding per screen, with: title, description, proposed resolution(s), and three actions:
  - **Apply** — apply the proposed change, advance.
  - **Skip** — leave unchanged, advance; may reappear next time wizard runs.
  - **Mark unresolvable** — set a persistent flag on the field; this finding will not reappear for this profile until the user explicitly clears it via Settings.

### Finding types

1. **Ambiguous location** — `birthLocation` matches >1 gazetteer entry. Resolution: list of candidate `(county, code)` rows; pick one.
2. **Unmatched location** — `birthLocation` is non-empty, `birthLocationCode` is nil, no gazetteer match. Resolution: closest fuzzy matches (Levenshtein) + free-form re-edit.
3. **Confirmed unambiguous location with no code** — `birthLocation` matches exactly one entry but `birthLocationCode` is nil. Resolution: "Match to {entry}?" Confirm / pick different / mark unresolvable.
4. **Birth-record-implied parent missing** — a confirmed FreeBMD birth record exists for this profile with `mothersMaidenName`, but no parents are linked. Resolution: same flow as the existing `ProposedRelative` accept path in `ClusterReviewView` — creates ghost mother (surname = maiden name) and father (surname = subject's surname) with estimated birth windows. Lets users upgrade profiles that were imported pre-research.
5. **Bare-year date** — `birthDate` or `deathDate` has only a year, no quarter/month/day. Resolution: pick a quarter (Q1–Q4) from the BMD index if a confirmed record exists, else skip.

### Cleanse-all entry

From the tree view or Settings, walk every profile's findings in sequence. Same wizard, just enqueued across the tree. Depth-first: all findings for profile N before moving to N+1.

### Persistence

`CleanseUnresolvableFlag` persisted per `(profileID, field)` pair. New entity in the GRDB schema, or extension to existing audit-state storage — implementer's choice. Must survive app restart and CloudKit sync (no `@Attribute(.unique)` constraints).

---

## 4. Acceptance criteria

1. **AC1** A profile with `birthLocation = "Newport"` and `birthLocationCode = nil` opens the wizard and shows an ambiguous-location finding with at least 3 county candidates.
2. **AC2** Selecting "Newport, Isle of Wight" applies, sets `birthLocationCode` to the corresponding gazetteer ID, advances the wizard.
3. **AC3** A profile with `birthLocation = "Madeira (born at sea)"` and no match opens an unmatched-location finding. Marking unresolvable persists the flag. Re-running the wizard does not surface this finding again.
4. **AC4** A profile with a confirmed birth record and `mothersMaidenName = "Holmes"` but no parent links shows the "Birth-record-implied parent missing" finding. Applying creates the ghost mother (and father, by surname) using the existing `ProposedRelative` accept path.
5. **AC5** A profile with `birthDate` = bare year "1850" shows a bare-year finding. Apply with Q2 picked updates the date to "Q2 1850".
6. **AC6** "Cleanse all" iterates every profile with at least one outstanding finding; profiles with all findings resolved or marked unresolvable are skipped.
7. **AC7** Wizard never re-prompts a finding that was previously marked unresolvable, across app restarts (persistence verified).

---

## 5. Implementation notes

- `CleanseFinding` is a protocol with `title`, `description`, `resolutionOptions`, `apply`, `markUnresolvable`. Concrete types per finding category.
- Finding generation is on-demand: opening the wizard runs the rule engine fresh against current profile state.
- Wizard state machine: simple sequential — no branching mid-flight.
- Parent-inference finding (type 4) reuses `ProposedRelative` and the existing accept-relative code path. Do **not** reinvent — the engine is already in place from the shipped Change 3 work.
- Location findings (types 1–3) consume the existing `LocationGazetteer` actor — no new lookup infrastructure.
- Bare-year finding (type 5) reads from already-confirmed `BirthRecord` / `DeathRecord` evidence held against the profile.

---

## 6. Files affected

**New**
- `Ancestor Research/Services/Cleanse/CleanseFinding.swift` (protocol)
- `Ancestor Research/Services/Cleanse/CleanseEngine.swift` (generation + iteration)
- Concrete findings: `AmbiguousLocationFinding.swift`, `UnmatchedLocationFinding.swift`, `UnconfirmedLocationFinding.swift`, `MissingParentFromBirthRecordFinding.swift`, `BareYearDateFinding.swift`
- `Ancestor Research/Views/Cleanse/ProfileCleanseWizard.swift` (sheet container)
- `Ancestor Research/Views/Cleanse/CleanseFindingStep.swift` (one-finding view component)
- `Ancestor Research Tests/CleanseEngineTests.swift`

**Modified**
- Profile detail view — add "Cleanse" button
- Tree view / Settings — add "Cleanse all" entry point
- GRDB schema — `CleanseUnresolvableFlag` table (or extension to audit-state)

---

## 7. Out of scope

- **LLM-driven cleanse suggestions** — e.g. asking the Field Researcher AI to guess a county for "Newport, near the docks". Deterministic only in this spec. Future scope.
- **Spouse / sibling inference findings** — the parent inference is wired (Change 3 of the predecessor spec); spouse and sibling would need their own evidence pipeline first.
- **Death-location cleanse** — same patterns apply but `deathLocation` plumbing is shallower than `birthLocation`. Defer to a follow-up.
- **Localisation** — English only, matches the project's overall stance.

---

## 8. Open questions

- **Q1** Should the wizard treat a "Skip" as silent (re-prompts next time) or persist a "snoozed" state that hides the finding for N days? Recommend silent skip in v1; revisit if the prompt-fatigue feedback surfaces.
- **Q2** Should "Mark unresolvable" be reversible from inside the wizard, or only from Settings? Recommend Settings-only — keeps the wizard flow linear.

---

## 9. Verification checklist

- [ ] Every acceptance criterion in §4 has a corresponding test or manually-verified scenario.
- [ ] `xcodebuild -scheme "Ancestor Research" -destination 'platform=macOS' build` succeeds without new warnings.
- [ ] GRDB migration loads existing tree data without loss; new flag table created cleanly.
- [ ] Cleanse-all walks a realistic tree (10+ profiles, mixed finding types) without hanging or duplicate prompts.
- [ ] All new files follow project Swift 6.2 conventions (`@Observable` where applicable, strict concurrency, `nonisolated` where appropriate).

---

*End of specification.*
