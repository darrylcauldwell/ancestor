# Profile Lifecycle & UX Coherence

**Status: PROPOSED 2026-07-18.** One design tying together three UX papercuts that
share a single root cause: the app *knows* a person's state internally but presents
it **inconsistently**, so a non-expert can't tell where they are or what to do next.
The north star (owner, 2026-07-18): **carry a person all the way from a raw GEDCOM
import to a verified, evidence-backed profile — and make that journey legible at
every step.** Commits reference `#LIFECYCLE-Change1`…`#LIFECYCLE-Change3`.

The three papercuts (all real, all found by the owner):
1. **"Applied" vs "selected" wear the same green tick.** In the review, "Will apply"
   and "Already applied" both render as `.iconOnly` green checkmarks (differing only
   by `checkmark.circle.fill` vs `checkmark.seal.fill`, with the words hidden behind
   a hover tooltip). An expert read it as "already done." → Change 2.
2. **Two action vocabularies.** Right-clicking a tree node offers {Focus Here,
   Compare, Set as Home}; opening the profile card offers {Edit, Timeline,
   Relationship, Research, Cleanse, Focus Here}. They overlap on **only** "Focus
   Here" — so half the actions vanish depending on how you reached the person. →
   Change 1.
3. **No visible lifecycle.** Nothing tells a person "you are at stage X; the next
   step is Y." The stage is inferable from scattered counts + green ticks + the GPS
   badge, but never stated. → Change 3.

## The lifecycle (the model everything hangs off)

Per person, derived from data already present — never a stored/authored field:

```
Imported          research_history empty; all field_sources origin == gedcom
  → Researched    a research run exists; candidates/findings await review
  → Reviewing     findings pending (Triage "N to review" > 0)
  → Evidenced     ≥1 research record applied (evidence_records.user_status
                  = savedAsLead that also wrote a field, i.e. non-gedcom
                  field_sources exist) — evidence is on the profile
  → Verified      GPS "Strong" (≥4/5) AND nothing pending to review
```

Stage is a pure function of (research_history, pending review count, applied
records, GPS). No migration.

## Change 1 — One canonical profile-action set (S–M)

**Scope:** a single source of truth for "what you can do to a person", rendered in
**both** the tree right-click menu and the profile card, so they can never drift.

- Define `ProfileAction` (an enum/list) with the union: **Research, Compare, Edit,
  Timeline, Relationship, Cleanse, Focus Here, Set as Home Person** — plus each
  action's availability rule (e.g. Set-as-Home disabled when already home; Compare
  needs a second profile).
- A shared `profileActionMenu(for:)` builder both surfaces call. Actions route
  through intents both views can reach (AppState-level where possible; view-local
  state — edit mode, compare picker — via a small callback the host supplies).

**Acceptance:**
1. Right-clicking a node and opening the profile card expose the **same** actions
   (modulo context-legal disabling).
2. Adding a new action is a one-line change to the canonical list; both surfaces
   pick it up.
3. "Focus Here" / "Set as Home" honour their existing disabled rules in both.

**Blast radius:** `TreeGraphView` context menu + `ProfileDetailView` action row →
both consume the shared builder. No data change.

## Change 2 — Applied vs selected, legible at a glance (S)

**Scope:** in the cluster-review row, make the three states unmistakable **without
hovering**, and break the colour tie (green = done, only):

- **Applied** (`userStatus == savedAsLead` and it wrote a field) → **green** filled
  seal + the visible word **"Applied"**; row dimmed (already is, 0.55).
- **Will apply** (selected, not yet written) → a **distinct pending look** — blue,
  or an *outline* check — + the visible words **"Will apply"**. NOT green.
- **Skipped** → unchanged (dashed circle, tertiary).
- Show the label text, not `.iconOnly`, at least as a compact pill.
- Consider a per-record **"Apply this one"** so the batch "Apply N" isn't the only
  path (optional).

**Acceptance:**
1. A freshly-scored, not-yet-applied record shows a non-green "Will apply" with
   visible text; an applied one shows green "Applied". They are never the same
   colour/icon.
2. No hover needed to tell them apart.
3. Wording carries no jargon.

**Blast radius:** `ClusterReviewView` row rendering. No data change.

## Change 3 — Per-person lifecycle status + next step (M)

**Scope:** surface the derived stage (above) as a small **status chip** on the
profile card (and optionally the tree node / Triage list), with a one-line
**next-step** prompt and a button that does it:

- Imported → "Not yet researched" · **[Research]**
- Reviewing → "N records to review" · **[Review]** (deep-links to Triage)
- Evidenced → "Evidence applied; keep going" · **[Research]** / **[Review]**
- Verified → "Verified — GPS strong" · (calm, done state)

**Acceptance:**
1. A GEDCOM-only profile reads "Imported · not yet researched" with a Research
   action; George (post-apply) reads toward "Evidenced/Verified".
2. The stage is computed, never stored; it updates as evidence is applied / reviewed.
3. The next-step button performs the obvious action for that stage.

**Blast radius:** a `ProfileLifecycle` pure helper (stage from data) + a chip view
in `ProfileDetailView`. No migration.

## Build order

Change 2 (green-tick — smallest, most-felt, self-contained) → Change 1 (unify
actions) → Change 3 (lifecycle status — depends on the derived-stage helper). Each
ships with tests where there's pure logic (`ProfileLifecycle` stage function; the
canonical action list's availability rules).

## Non-goals

1. **No stored lifecycle field** — stage is always derived, so it can't go stale.
2. **Not an onboarding wizard** — that's `PROJECT_ONBOARDING_SPEC`; this is the
   per-person journey, complementary.
3. **No new research behaviour** — this is presentation + action consistency only.
