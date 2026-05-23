# Kinship Spec — fan-out tree-building and relationship verification

**Status:** Draft (2026-05-23). Not implemented.

## 1. Why this spec exists

The existing research pipeline (`agent/pipeline.py:research_person`) is
*linear-ascending*: pick a subject, find their parents, recurse upward.
Lateral and downward expansion is incidental — it falls out of census
household extraction. Two real user needs are not served by this shape:

- **Find cousins.** Cousins live on collateral lines (uncle's children,
  great-uncle's grandchildren). Ascending research never reaches them
  unless they happen to co-reside with a direct ancestor in some
  census.
- **Verify the tree.** When the twin claims X is the user's great-aunt,
  the pipeline can validate `X's parents == user's great-grandparents`
  but only if the chain happens to have been built. Today there's no
  primitive for "given these two profiles, are they related as
  claimed?".

These needs share underlying capabilities — both require traversing
parent→child links with independent record support. This spec defines
those capabilities, names the new primitives, and pins how the §5.8
eval harness measures the new behaviour.

## 2. Scope

**In scope:**
- New search primitives: `find_siblings`, `find_children`, plus
  generalised `find_spouses`.
- A structured fan-out walker that systematically expands a kinship
  graph (up + lateral + down) within a depth budget.
- A relationship-verification primitive that takes two profile IDs and
  decides whether the claimed relationship is supported.
- Harness extensions: new corpus schema fields, new measurement modes,
  new per-relationship verdicts.

**Out of scope (deferred):**
- Adoptive / step-parent relationships beyond what FreeBMD's
  `spouse_or_mother` field signals directly.
- Visual tree-rendering — this spec is engine-side only; the Swift app
  already has pedigree/descendant views.
- Cross-tree merge (linking the user's tree to another user's tree).
- Living-person enrichment via paid sources (GRO certificates,
  Ancestry, MyHeritage). Coverage limits for the public-source-only
  envelope are documented in §8.

## 3. Three operating modes

Mode A is what exists today. Modes B and C are new.

### 3.1 Mode A — Linear ascending (current)

`research_person(subject) → state` with optional `--branch` for BFS
through household members. Used for direct-ancestor research. No
change.

### 3.2 Mode B — Kinship discovery (new)

`discover_kin(subject, depth_up=3, depth_down=3) → KinshipGraph`

Systematically fan out from the subject:

1. Recurse upward `depth_up` generations finding parents at each step.
2. At each ancestor, run `find_siblings` to enumerate the subject's
   aunts/uncles, great-aunts/uncles, etc.
3. From each lateral kin discovered, recurse downward `depth_down`
   generations via `find_children`.
4. At every node, record the supporting record IDs and the relationship
   chain back to the subject.

Result: a graph rooted at the subject with edge labels (relationship
kind: parent, sibling, child, spouse) and per-edge evidence
(citations).

### 3.3 Mode C — Kinship verification (new)

`verify_relationship(profile_a, profile_b, claimed_relationship) → KinshipVerdict`

Given two profiles and a claim ("X is Y's grandfather", "A and B are
2nd cousins"), trace the chain through the tree and verify each step
with independent records.

- `claimed_relationship` is a structured form: parent / child /
  sibling / spouse / `nth_cousin_mth_removed(n, m)` / aunt-or-uncle /
  niece-or-nephew / great_N + relation.
- Per-link verdict: `verified` (independent record found),
  `inconclusive` (claimed but no record), `contradicted` (record
  asserts a different relationship).
- Overall verdict: weakest link in the chain.

This is what the Mabel cluster_b case in `eval/certified/
I50113395_mabel_cauldwell_g5_cluster.yaml` actually wants. The
harness's current `identity_disambiguation.cluster_b: contradicted`
expectation can be re-expressed as `verify_relationship(@I50113395@,
@I50113448@, "same_person") → contradicted`.

## 4. New search primitives

Each primitive returns a list of candidate matches with per-candidate
evidence and a per-candidate confidence verdict (`supported` /
`inconclusive`).

### 4.1 `find_siblings(subject)`

Find people sharing both parents with the subject.

**Inputs the primitive can use:**
- Subject's parents (names + birth years if known)
- Subject's birth year (sibling window: ±25 years typical)
- Subject's birth location (siblings often share parish)

**Search strategies, in priority order:**
1. **FreeBMD births where `s_surname = mother's maiden name`** (post-Sep
   1911 — the field is only indexed from then). Filter by surname =
   father's, year window.
2. **Census household enumeration where parents are heads.** All
   members listed as `Son` / `Dau` of the heads, excluding the
   subject. Cross-check ages against birth-year windows.
3. **FreeREG baptism records** where parents match. Useful pre-1837.
4. **WikiTree twin** — sibling edges already recorded in the tree; the
   primitive should surface what's claimed AND what new records support
   each claim.

Result deduplicated across sources. Confidence is `supported` only
when at least one independent record (not just the twin) supports the
sibling claim.

### 4.2 `find_children(subject)`

Find people whose parent is the subject.

**Asymmetric by subject gender** because FreeBMD indexes by mother's
maiden name:

- **Subject is female (pre-marriage surname known):** FreeBMD births
  where `s_surname = subject's pre-marriage surname`, post-Sep 1911.
- **Subject is female (only married surname known):** use census
  household where subject is `Wife`; iterate co-resident `Son` / `Dau`.
- **Subject is male:** FreeBMD doesn't index father by name. Fall back
  to census household where subject is `Head`; FreeREG baptisms where
  subject is named father (post-1837 parish).

This asymmetry is real and documented; not a bug.

### 4.3 `find_spouses(subject)`

Find people the subject married. Already mostly present in the
existing pipeline (`_expand_post_marriage_searches` extracts one
spouse surname). Generalise to:

- Return *all* spouses (post-divorce remarriage, widowhood remarriage).
- Per-spouse evidence: marriage record + post-marriage census co-
  residence.
- Cross-reference WikiTree twin's spouse edges.

## 5. Fan-out walker algorithm

```
discover_kin(subject, depth_up, depth_down):
    graph = KinshipGraph(root = subject)
    frontier_up = [subject]
    for gen_up in 1 .. depth_up:
        next_frontier = []
        for node in frontier_up:
            parents = find_parents(node)
            for p in parents:
                graph.add_edge(node, p, kind="parent")
                next_frontier.append(p)

                # At each ancestor, enumerate their other children
                # (subject's aunts/uncles at this remove).
                siblings_of_subject_ancestor = find_siblings(p)
                for s in siblings_of_subject_ancestor:
                    graph.add_edge(p, s, kind="sibling")
                    # Descend each sibling's line.
                    descend(s, depth_down, graph)
        frontier_up = next_frontier
    return graph

descend(node, depth_remaining, graph):
    if depth_remaining <= 0: return
    children = find_children(node)
    for c in children:
        graph.add_edge(node, c, kind="child")
        descend(c, depth_remaining - 1, graph)
```

Budget controls:
- `depth_up`: how many ancestral generations to climb. Default 3
  (great-grandparents).
- `depth_down`: how many descendant generations from each lateral
  ancestor. Default 3 (yields 2nd-cousins via great-grandparent
  siblings).
- `max_nodes`: hard stop on graph size to bound runtime. Default 200.

A fan with depth_up=3 / depth_down=3 typically yields all 1st cousins,
1st-cousins-once-removed, and 2nd cousins of the subject, modulo source
coverage.

## 6. Harness measurement

### 6.1 Corpus schema extension

Add to each subject's YAML:

```yaml
expected_relatives:
  parents:
    - { id: "@I...@", name: "...", verified_by: "FreeBMD birth Q4 1887 ..." }
  siblings:
    - { id: "@I...@", name: "...", verified_by: "census 1891 same household, same parents" }
  spouses:
    - { id: "@I...@", name: "...", verified_by: "FreeBMD marriage Mar 1915 Ashbourne" }
  children:
    - { id: "@I...@", name: "...", verified_by: "FreeBMD birth Q3 1919 with mother's-maiden-name MMN" }

expected_verifications:
  - { a: "@I...@", b: "@I...@", relationship: "1st_cousin", expected: "verified" }
  - { a: "@I50113395@", b: "@I50113448@", relationship: "same_person", expected: "contradicted" }
```

### 6.2 New metrics

- **Kin-discovery recall**: of the `expected_relatives` entries, what
  fraction did `discover_kin(subject)` surface (with at least
  `inconclusive` confidence)?
- **Kin-discovery precision**: of the relatives surfaced, what
  fraction was correct (matches an `expected_relatives` entry, or is
  consistent with the tree)?
- **Verification accuracy**: of the `expected_verifications` entries,
  what fraction agree on the verdict?

These layer on top of the existing per-kind metrics; they don't
replace them.

### 6.3 New harness modes

```
python eval/run_harness.py --mode ascending     # current default
python eval/run_harness.py --mode discovery     # runs discover_kin
python eval/run_harness.py --mode verification  # runs verify_relationship
```

Per-mode reports keep the same envelope shape so downstream tooling
keeps working.

## 7. Privacy & the hallucination guardrail

Living-person handling:

- **Birth year ≥ 1925**: presumed living. `find_children` / fan-out
  may *include* the person if the twin records them, but must NOT
  search public sources for them — the existing `_is_unsearchable`
  guard already implements this for the main pipeline; carry the same
  rule into all new primitives.
- **Anyone explicitly marked living in the twin**: same.
- **Output marking**: every node in a `KinshipGraph` carries a
  `presumed_living: bool` flag, downstream UI can render differently.
- **Guardrail extension**: the existing hallucination_guardrail axis
  (Lily Margaret Cauldwell b.2012) gets a new `expected_relatives`
  block declaring her parents (Darryl, Helen) but nothing else; if
  `discover_kin` surfaces siblings or children for her from any source,
  that's a guardrail violation.

## 8. Source coverage and limits

Public-source-only envelope:

| Need | Source | Coverage cliff |
|---|---|---|
| Births pre-1925 | FreeBMD | 100-year closure: births after ~1925 not indexed |
| Marriages pre-1925 | FreeBMD | 100-year closure |
| Deaths pre-current | FreeBMD | Lags by ~5 years |
| Census | FreeCen + FamilySearch | Last released: 1921; 1931 destroyed; 1939 register restricted |
| Parish | FreeREG | Patchy; non-Anglican typically absent |
| Modern probate | Probate Search Service | Covers ~1996 onward, plus WWI/WWII soldier wills |
| War deaths | CWGC | WW1+WW2 only |

**Implication for "find my living cousins":** the 1925–1996 gap is a
hard wall for public-source-only. A 2nd cousin born in 1950 has:
- No FreeBMD birth (closed)
- No 1921 census (born after)
- Maybe a 1939 register entry (restricted)
- Probate only if deceased post-1996

The fan-out walker will trace such cousins through their *parents'*
records (a 1921-census child of an uncle) but cannot confirm the
cousin themselves from public sources. Output flags them
`source_coverage_cliff: true`.

This is a documented limit, not a bug. The spec calls it out so the
harness's expected_relatives blocks for living-cousin cases can use
`expected: inconclusive_source_cliff` honestly.

## 9. Acceptance criteria

Numbered changes, in suggested implementation order.

**#Change1 — `find_siblings` primitive.** New function in
`agent/discover.py` or a new `agent/kinship.py`. Returns
`list[dict]` with per-candidate evidence. Unit-tested against the
Cauldwell family corpus subjects (Ernest's siblings via the 1891
census + post-1911 FreeBMD; Robert's siblings via same).

**#Change2 — `find_children` primitive.** Gender-asymmetric as
documented in §4.2. Unit-tested against Ernest's 3 children (all
post-1911 births — full coverage).

**#Change3 — Generalise `find_spouses`.** Lift from
`_expand_post_marriage_searches` (which only tracks one surname) into
a primitive returning all spouses with per-spouse evidence.

**#Change4 — Fan-out walker.** `discover_kin(subject, depth_up,
depth_down) → KinshipGraph` per §5.

**#Change5 — Verification primitive.** `verify_relationship(a, b,
claimed) → KinshipVerdict` per §3.3.

**#Change6 — Corpus YAML extensions.** Add `expected_relatives` and
`expected_verifications` blocks. Backfill Ernest, Robert, Mabel cluster
(both halves) with explicit verification expectations.

**#Change7 — Harness `--mode` flag** with three modes per §6.3. New
metrics per §6.2.

**#Change8 — Living-person guard extension** per §7. Update the
hallucination_guardrail subject's YAML to use the new
`expected_relatives` shape.

**#Change9 — Spec-driven port to Swift** of #Change1–#Change5 once
the Python primitives are stable, per the project's "Port from Python
faithfully" convention.

## 10. What this spec deliberately defers

- **DNA matching** — `find_dna_matches(subject)` against AncestryDNA /
  23andMe / MyHeritage. Different problem domain, paid services,
  out of public-source-only scope.
- **Lateral search through marriages** — finding the user's in-laws
  (spouse's siblings, spouse's parents, etc.). Same primitives could
  walk that direction but the *value* is lower than blood kin.
- **Tree de-duplication** — discovering that two different profiles
  in the tree are actually the same person. Related to but distinct
  from verification.
- **Adoption / step-parent edges** — modelled today only by what
  FreeBMD's spouse_or_mother field happens to record.

These are real eventual needs but bundling them into V1 makes the
scope unbounded.

---

End of draft. Next steps after review:
1. Pin acceptance-test cases against the existing 12-subject corpus.
2. Implement #Change1 (`find_siblings`) — smallest scope, most
   reusable.
3. Backfill Ernest's `expected_relatives` block as the first
   measurement target.
