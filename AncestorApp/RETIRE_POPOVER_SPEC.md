# Retire the Tree Popover — unify profile actions

## Problem

Three surfaces expose profile actions with **divergent** sets, which is
incoherent and has caused real user error (couldn't add a spouse from Full
Detail; no clean remove/unlink anywhere; a spouse got mis-linked as parent then
child):

| Action | Context menu | Full Detail | Popover |
|---|---|---|---|
| Focus / Research | ✓ | ✓ | ✓ |
| Edit / Timeline / Relationship / Cleanse / Compare / Set-Home | ✓ | ✓ | ✗ |
| **Add relative** (spouse/parent/child/sibling, connect-existing) | ✗ | ✗ | ✓ only |
| **Remove person / branch** | ✗ | ✗ | ✓ only |
| Off-canvas relatives nav, marriage switcher, vitals glance | ✗ | ✗ | ✓ only |

The context menu and Full Detail already share one consistent action set; the
popover is the odd surface, and it *uniquely* holds the two most-needed actions.

## Decision (owner, 2026-07-20)

**Retire the popover entirely.** Interaction model becomes:
- **Single-click** a node → just selects it (no popover).
- **Right-click** → the full, consistent action set.
- **Double-click** (or the ⓘ icon) → Full Detail, which holds edit + the full
  action set + the popover's former navigation/context content as sections.

## Invariants
- The on-canvas marriage-switch chips (Stage 2, `81e1e72`) keep working — they
  hit-test independently of the popover. Only the *labelled* marriage selector
  moves from popover → Full Detail.
- No profile action is lost; every one is reachable from **both** the right-click
  menu and Full Detail after this work.
- Relationship-add gets a plain-English "X will be recorded as <anchor>'s ___"
  confirmation (already in `AddRelationshipView`) so direction/type mistakes
  (the Geoff-as-parent-then-child class) stop recurring.

## Staging (each stage ships independently; stop-anywhere-safe)

### Change 1 — Fill the action gaps (non-destructive)
Add **Add relative** (Spouse/Parent/Child/Sibling + Connect-to-existing) and
**Remove person / Remove branch** to BOTH the right-click context menu
(`TreeGraphView`) and Full Detail (`ProfileDetailView`), reusing the same
callbacks/sheets the popover uses. After this, every action is reachable from
the two surfaces we're keeping — popover still present but no longer unique.

### Change 2 — Move non-action content into Full Detail
Add to `ProfileDetailView`: off-canvas relatives navigation (tap to recenter),
the marriage switcher (the labelled selector), and confirm the vitals/missing-
facts glance is covered (Full Detail already shows missing facts + fields).

### Change 3 — Retire the popover
- Single-click → select only (drop the "click selected node again → popover").
- ⓘ icon → open Full Detail (or remove the icon).
- Remove the popover presentation + `ProfilePopoverView` usage from
  `TreeGraphView`. Delete `ProfilePopoverView.swift` once nothing references it.

## Out of scope (follow-ups)
- Per-edge unlink / change-relationship-type (a mis-typed link becomes a
  one-click fix instead of delete-and-recreate). Noted; separate spec.
- The "3rd+ parent never rendered" tree-layout display gap.
