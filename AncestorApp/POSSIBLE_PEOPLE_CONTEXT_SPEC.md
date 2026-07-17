# POSSIBLE_PEOPLE_CONTEXT_SPEC

**Status:** accepted-direction 2026-07-17 (owner). Building now.
**Motivation:** a cluster is only assessable once you can see the tree person it
hangs off. The Possible People panel today shows *what* cohered (a candidate
identity) but not *how it connects to your tree* — and that connection (who
surfaced it, and their dates) is the frame needed to judge "real relative vs.
namesake the search dragged in". Owner example: a cluster from an 1850-born
subject whose records sit in the 1950s is probably a namesake.

Decisions (owner, 2026-07-17):
- **Both surfaces** — the full panel gains person-organisation, AND each profile
  gets its own Possible People section.
- **Multi-origin clusters appear under EACH contributing relative** — a cluster
  connecting to several tree people is the strongest "really family" signal; do
  not collapse it to one owner.
- **Temporal distance is a soft FLAG, never an auto-dismiss.** Later-generation
  relatives are real; the human decides. Conservative window — fire only on
  egregious cases, tune once seen on real data.

## 1. Cluster → tree context (shared, pure)

`ClusterContext` (nonisolated, testable) derives, from a cluster + the
`FamilyGraphSnapshot`:
- **Origins**: the distinct tree profiles whose research surfaced the cluster's
  leads (each lead carries `profileID`), resolved to `{name, birthYear?,
  deathYear?}`. This is the assessment frame.
- **Temporal flag**: `nil` normally; a short "likely a namesake" string only when
  the cluster's era sits beyond *every* origin's generous relative window
  (origin `birth − W … death + W`, W conservative ≈ 100y so it never fires on a
  plausible great-grandchild). Requires a cluster birth year and ≥1 dated origin.

## 2. Cards show the frame (both the panel and anywhere cards render)

Each cluster card gains a context line — **"Surfaced by Ernest Cauldwell
(1850–1920)"**, listing each origin when several, and the temporal flag as a
subtle badge when present. Pure formatting off §1; no new interaction.

## 3. Panel — person organisation

The Possible People panel gains a grouping control:
- **By coherence** (today's flat, size-sorted list) — default.
- **By person** — sections keyed by origin tree-person (with dates); each cluster
  rendered under every relative that surfaced it (multi-origin duplication is
  intentional per the decision). Clusters with no resolvable origin fall into an
  "Unattached" section.
The panel also accepts a **scope**: `.all` (default) or `.profile(id)` — the
latter shows only clusters that person surfaced, and is what the profile
deep-link opens.

## 4. Profile surface + deep-link

- Each profile detail gains a lightweight **"Possible People (N)"** section: the
  count plus a few candidate names — a *summary*, NOT a second copy of the
  interactive cards (avoids nested scroll views and card-sync drift; the
  interactive cards live in ONE place, the panel).
- Its action opens the panel **scoped to that person** (Triage tab → Possible
  People → `scope = .profile(id)`), via an `AppState` request signal mirroring
  the existing `requestOpenProfileDetail` / pending-review pattern.

## 5. Invariants

- Read-only-to-the-tree still holds: context is derived from the snapshot; the
  only mutations remain the existing firewall lead actions.
- The interactive cluster card exists in exactly ONE view (the panel); the
  profile section is a distinct summary widget — so there is nothing to keep in
  sync between two card implementations.

## 6. Tests

- `ClusterContext.origins` resolves lead `profileID`s to dated profiles; a
  multi-origin cluster yields multiple origins.
- Temporal flag fires for an egregious gap (cluster b~1950 vs origin 1810–1870),
  stays silent for a plausible one (cluster b~1920 vs origin 1850–1920) and when
  dates are missing.
- Panel `scope = .profile(id)` filters to that person's clusters; `.all` shows
  everything.
- By-person grouping places a multi-origin cluster under each contributing
  relative.
