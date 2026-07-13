# IMPORT_DEDUPE_SPEC — Orphan-Stub Detection on GEDCOM Import

**Status: Proposed — awaiting review (drafted 2026-07-13 from a live worked example: "Cauldwell Family Tree 2").** Commits will reference `#ID-Change1`…`#ID-Change3`.

**Motivation, concretely.** Importing a GEDCOM exported from Ancestry.com produced a 216-profile tree with 4 profiles carrying **no `FAMC`/`FAMS` edges at all** — utterly disconnected from everything. Investigation traced all four to one cause: Ancestry's tree-merge tool ("possible duplicate" hints) left the pre-merge stub behind when it processed a match, stripping its family links but not removing the record. Each stub sits in the file immediately adjacent to a fully-linked twin of the same name:

| Orphan stub | Adjacent linked twin | Evidence |
|---|---|---|
| `/Carter/` (no given name) | `/Carter/`, `FAMS @F48@` (Betsy Cauldwell's husband) | Only 2 bare `/Carter/` records exist in the file; 5 lines apart |
| Mary Ward (no dates) | Mary Ward, `FAMC @F24@` | Only 2 "Mary Ward" records exist; immediately adjacent |
| George Keyworth (no dates) | George Keyworth, b.1904, `FAMC @F11@` | Sits directly after William Henry Keyworth's own birth entry (b.1875, Worksop); F11 is WH Keyworth's family |
| Dorothy Keyworth (no dates) | Dorothy Winnifred Keyworth, b.1901, `FAMC @F11@` | Same family (F11), same generation |

**Why the existing tooling misses this.** `DuplicateDetectionRule` (`AncestorKit/Sources/AncestorKit/AuditRule.swift:467`, DESIGN.md §6.3) needs *birth-year overlap* to reach its 0.7 threshold: surname (0.4) + given name (0.3) + birth-year overlap (0.3). The Carter stub has no given name at all, capping it at 0.4 — **silently missed**. Mary Ward and the Keyworth pair happen to clear 0.7 on name-match alone (0.4+0.3), but that's coincidental, not designed. Ancestry's specific failure mode — *zero family edges* + *near-identical name to an already-linked profile* — is a stronger, cheaper, more specific signal than fuzzy year-overlap matching, and deserves its own rule.

**Ancestry is the motivating case, not the boundary.** The rule is defined on structure (edge-less profile + name-adjacent linked twin), not on the source label — any exporter with the same "leave the pre-merge stub" habit is caught the same way.

---

## Decision log

1. **Detect and flag; never auto-merge.** Consistent with the project's when-in-doubt-split posture — merges are hard to undo, and a bare stub is occasionally a genuine unlinked person, not an artifact. A human confirms every merge.
2. **A new rule, not an extension of `DuplicateDetectionRule`.** The two rules key off different, complementary evidence (fuzzy name+date similarity vs. structural edge-lessness) and should report distinctly so a user can tell "these look similar" from "this one has literally no connections at all."
3. **Reuses the existing `AuditResult.relatedProfileIDs` pattern** (already wired for `DuplicateDetectionRule`'s Compare affordance in the Tasks view) rather than inventing a new UI surface for review.
4. **Extends DESIGN.md §7.5.11's deferred import-reconciliation plan**, not a rival to it. §7.5.11 covers importing a GEDCOM *into an already-populated project* (manual entries vs. incoming collide); this spec covers duplicates *within a single GEDCOM's own export*, imported into an empty project — the case the current importer's `existingCount == 0` guard (`AppState.swift:1190`) actually exercises today. Both eventually want the same merge-execution primitive (Change 3).
5. **No merge-execution engine exists today — this spec builds one.** `MergeEngine.swift` is field-level policy math (given two *values*, corroborate/intersect/dispute) per DESIGN.md §5.7; `CompareProfilesView.swift` is read-only side-by-side comparison with no merge action wired. Flagging orphan stubs is of limited use without something to execute against, so Change 3 builds the minimal whole-profile merge action: redirect edges, apply `MergeEngine`'s per-field policy, hard-delete the loser, one transaction (undo-compatible).

---

## Conceptual model

```
OrphanStubCandidate = (stub: Profile, target: Profile, matchBasis: String)

stub    — zero relationship edges (no parent, no child, no spouse) AND
          near-empty data (name only, or name + sex; no birth/death/location)
target  — a DIFFERENT profile with normalised-identical name components
          (or a name containment match when the stub has no given name)
          AND at least one relationship edge
matchBasis — human-readable reason ("bare surname-only match", "identical
          given+surname, target has family links") — carried into the
          AuditResult message so the review surface explains ITSELF
```

A stub may match zero, one, or multiple targets (the Keyworth cluster had several same-named candidates across generations — see Change 1 AC3). Multiple matches surface as multiple candidates; the rule never guesses which one is "right."

---

## Change 1 — `OrphanStubRule` (detection) (S)

**Scope:** new `AncestorKit/Sources/AncestorKit/AuditRule.swift` rule, `id = "orphanStub"`, category `.issue`, severity `.warning`. Fires when a profile has **zero relationship edges** (checked via the snapshot passed to `evaluate`, same shape `DuplicateDetectionRule` already receives) and its normalised name matches another **edge-bearing** profile:

- **Name normalisation:** reuse `DuplicateDetectionRule`'s `nameSimilarity` helper (nickname table, fuzzy surname swap) — no new matching logic.
- **No-given-name case (Carter):** when the stub's `firstName` is nil/empty, match on surname alone against other edge-bearing profiles whose surname normalises identically. This is the case AC1's table shows `DuplicateDetectionRule` cannot reach — the whole point of this rule.
- **Multiple candidates:** emit one `AuditResult` per candidate target, `relatedProfileIDs: [targetID]`, so each appears as its own reviewable row (mirrors `DuplicateDetectionRule`'s one-row-per-pair convention).

**Acceptance criteria:**
1. A stub with a surname-only name (no given name, no dates, no edges) sitting near an edge-bearing profile of the identical surname fires — the exact case `DuplicateDetectionRule` misses (`0.4 < 0.7`).
2. A stub with full given+surname and no dates, near an edge-bearing profile of the identical name, fires (may ALSO fire `DuplicateDetectionRule` at 0.7 — both may report; deliberate, per decision log #2).
3. A stub with ≥2 same-named edge-bearing candidates (the Keyworth-generations shape) produces one `AuditResult` per candidate, not a single ambiguous row.
4. A profile with edges never fires as a *stub* (it can still be a `target`).
5. A profile with no edges but *no* name-matching target anywhere in the tree does not fire — the rule reports only actionable candidates, never "this profile looks lonely."

**Blast radius:** `AuditRule.swift` only (new rule + `builtIn` registration). No schema change, no scoring/verdict change — this is Audit-tab surfacing, same tier as every other `AuditRuleDefinition`.

---

## Change 2 — Import-time trigger (S)

**Scope:** run `OrphanStubRule` (and the standing `DuplicateDetectionRule`) immediately after GEDCOM import completes, mirroring the existing CL2 T-C pattern (`AppState.importGEDCOM`, `Ancestor Research/ViewModels/AppState.swift` — the conflict-sweep-after-import precedent) rather than waiting for the user to open the Audit tab manually. Findings surface as a **post-import summary** ("4 possible duplicate stubs found — review before continuing") appended to the existing post-import flow, not a blocking modal — import already succeeded; this is guidance, not a gate.

**Acceptance criteria:**
1. Importing a GEDCOM with the Carter/Mary-Ward/Keyworth shape (a synthetic fixture reproducing it — no real family data in the test suite) surfaces exactly the expected candidate count immediately after import, with no manual Audit-tab visit required.
2. Importing a clean GEDCOM (no orphan stubs) surfaces nothing — the summary doesn't appear for a clean import.
3. The findings are the *same* `AuditResult` rows the Audit tab would show on manual re-run — one code path, two triggers (import-time and on-demand), never a parallel detector.

**Blast radius:** `AppState.importGEDCOM` (one call after the existing post-import audit run), a lightweight summary view/banner. No new persistence — findings are recomputed live like every other audit rule, never stored as a stale snapshot.

---

## Change 3 — Merge execution (the missing primitive) (M)

**Scope:** the actual "combine these two profiles" action, callable from the orphan-stub review (Change 2) and from `DuplicateDetectionRule`'s existing Compare affordance alike — today neither has anything to execute against. One transaction:
1. Redirect every relationship edge from the loser profile to the winner (`removeRelationship` + re-add on the winner, or a direct edge repoint — implementer's call, either way one `Transaction` row for undo).
2. For each field where both profiles hold a value, run it through `MergeEngine`'s existing field-level policy (`mergeDateAction`/string equivalent) — corroborate, intersect, or dispute; never silently pick one.
3. Move the loser's `field_sources` rows onto the winner (provenance preserved, never fabricated).
4. `hardDeleteProfile` the loser (`ProjectDatabase+HardDelete.swift:21`).
5. Return a `Transaction` — this is a normal undo-compatible write, not a firewall-bypassing bulk operation (it's entirely human-initiated, in-app).

**Acceptance criteria:**
1. Merging a true zero-data stub (Carter, Mary Ward shape) into its target loses nothing (the stub had nothing to lose) and the target's edges are unchanged.
2. Merging two profiles with a genuinely conflicting field (e.g. both have a birth date, and they disagree) produces a dispute via the existing conflict layer (`ConflictDetector`/`field_disputes`) — merge execution never silently overwrites a disagreement (CONFLICT_LAYER_SPEC's detection-completeness invariant extends here for free, since it's the same field-write path).
3. The merge is a single `Transaction` — undo reverses the whole operation, not a partial state.
4. Available as an action from both `OrphanStubRule` and `DuplicateDetectionRule` review rows — one execution primitive, two detectors feeding it.

**Blast radius:** new `Ancestor Research/Services/Research/ProfileMergeEngine.swift` (whole-profile orchestration; distinct from field-level `MergeEngine.swift`, which it calls into), a "Merge" button wired onto the existing Compare view and the new orphan-stub review rows, one migration if a `merged_from_profile_id` audit column is wanted (optional — `Transaction` history may already suffice for provenance).

---

## Non-goals (explicit)

1. **No silent auto-merge, ever** — every merge is a human click, full stop.
2. **Not scoped to Ancestry specifically** — the detector is structural (edge-less + name-adjacent-to-linked), catching any exporter with the same habit.
3. **Not a replacement for DESIGN.md §7.5.11** (import-into-populated-project reconciliation) — that remains its own deferred item; Change 3's merge primitive is the shared foundation both will eventually use.
4. **No automatic resolution of which candidate is "correct"** when a stub matches multiple targets (the Keyworth-generations case) — surfaced as multiple rows, human decides.

## Python-parity note

None — the GEDCOM importer and audit engine are Swift-native; Python has no equivalent import path.
