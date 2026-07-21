# Kinship Spec — fan-out tree-building and relationship verification

> **Status: Swift-first respec stub (Stage 2, ADR-007-gated).** Kinship stays OUT of the
> core push — it is Stage 2, first item after the core is declared solid (`adr/ADR-007`,
> 2026-07-11). Before any build, #Change3–5 get a **Swift-first v2 spec**: this document is
> the *conceptual* design input only, not a build plan. #Change9 (the wholesale Python port)
> is **dissolved** by ADR-007 — do not resurrect it. What follows is the forward model to
> respec against, plus the deliberate deferrals. (Engine foundation shipped 2026-07-13,
> git-only, so kinship's sequencing is now governed solely by ADR-007.)
>
> Two primitives — `find_siblings` and `find_children` — shipped in the Python reference
> (`agent/kinship.py`); each **needs a Swift equivalent** (respec whether to build fresh or
> fold into the framework-native `.siblingExists` hypothesis path — see §4). Everything else
> below is unbuilt in both Python and Swift.

## 1. Why this spec exists

The existing research pipeline is *linear-ascending*: pick a subject, find their parents,
recurse upward. Lateral and downward expansion is incidental — it falls out of census
household extraction. Two real user needs are not served by this shape:

- **Find cousins.** Cousins live on collateral lines (uncle's children, great-uncle's
  grandchildren). Ascending research never reaches them unless they happen to co-reside with
  a direct ancestor in some census.
- **Verify the tree.** When the tree claims X is the user's great-aunt, there is no primitive
  for "given these two profiles, are they related as claimed?".

These needs share underlying capabilities — both require traversing parent→child links with
independent record support. This spec defines those capabilities and names the new primitives.

## 2. Scope

**In scope:**
- New search primitives: `find_siblings`, `find_children`, plus generalised `find_spouses`.
- A structured fan-out walker that systematically expands a kinship graph (up + lateral +
  down) within a depth budget.
- A relationship-verification primitive that takes two profile IDs and decides whether the
  claimed relationship is supported.

**Out of scope (deferred):**
- Adoptive / step-parent relationships beyond what FreeBMD's `spouse_or_mother` field signals
  directly.
- Visual tree-rendering — this spec is engine-side only; the Swift app already has
  pedigree/descendant views.
- Cross-tree merge (linking the user's tree to another user's tree).
- Living-person enrichment via paid sources (GRO certificates, Ancestry, MyHeritage).
  Coverage limits for the public-source-only envelope are documented in §8.

## 3. Two forward operating modes

Linear-ascending research is the current, unchanged shape. Modes B and C are the new kinship
capabilities this spec introduces.

### 3.1 Mode B — Kinship discovery (new)

`discover_kin(subject, depth_up=3, depth_down=3) → KinshipGraph`

Systematically fan out from the subject:

1. Recurse upward `depth_up` generations finding parents at each step.
2. At each ancestor, run `find_siblings` to enumerate the subject's aunts/uncles,
   great-aunts/uncles, etc.
3. From each lateral kin discovered, recurse downward `depth_down` generations via
   `find_children`.
4. At every node, record the supporting record IDs and the relationship chain back to the
   subject.

Result: a graph rooted at the subject with edge labels (relationship kind: parent, sibling,
child, spouse) and per-edge evidence (citations).

### 3.2 Mode C — Kinship verification (new)

`verify_relationship(profile_a, profile_b, claimed_relationship) → KinshipVerdict`

Given two profiles and a claim ("X is Y's grandfather", "A and B are 2nd cousins"), trace the
chain through the tree and verify each step with independent records.

- `claimed_relationship` is a structured form: parent / child / sibling / spouse /
  `nth_cousin_mth_removed(n, m)` / aunt-or-uncle / niece-or-nephew / great_N + relation.
- Per-link verdict: `verified` (independent record found), `inconclusive` (claimed but no
  record), `contradicted` (record asserts a different relationship).
- Overall verdict: weakest link in the chain.

This is what the Mabel cluster_b case wants: a "same_person → contradicted" style verification
expressed as `verify_relationship(a, b, "same_person")`.

## 4. New search primitives

Each primitive returns a list of candidate matches with per-candidate evidence and a
per-candidate confidence verdict (`supported` / `inconclusive`).

- **`find_siblings(subject)`** — find people sharing both parents with the subject. Shipped in
  the Python reference (`agent/kinship.py`, #Change1). **Needs a Swift equivalent.** Respec
  decision: build fresh, or fold into the framework-native `.siblingExists` hypothesis path
  (`HypothesisEngine+SiblingExists.swift`), which is an adjacent T12-sibling search — NOT this
  primitive — and does not by itself satisfy the requirement.

- **`find_children(subject)`** — find people whose parent is the subject. Gender-asymmetric
  because FreeBMD indexes births by mother's maiden name (female subject → search by maiden
  surname where known; male subject → census-head + FreeREG-father fallbacks). This asymmetry
  is real and documented, not a bug. Shipped in the Python reference (`agent/kinship.py`,
  #Change2). **Needs a Swift equivalent** (same respec decision as `find_siblings`).

### 4.3 `find_spouses` (forward)

Find people the subject married. Already partly present in the existing pipeline
(`_expand_post_marriage_searches` extracts one spouse surname). Generalise to:

- Return *all* spouses (post-divorce remarriage, widowhood remarriage).
- Per-spouse evidence: marriage record + post-marriage census co-residence.
- Cross-reference the tree's existing spouse edges.

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
- `depth_up`: how many ancestral generations to climb. Default 3 (great-grandparents).
- `depth_down`: how many descendant generations from each lateral ancestor. Default 3 (yields
  2nd-cousins via great-grandparent siblings).
- `max_nodes`: hard stop on graph size to bound runtime. Default 200.

A fan with depth_up=3 / depth_down=3 typically yields all 1st cousins, 1st-cousins-once-removed,
and 2nd cousins of the subject, modulo source coverage.

## 6. Privacy & the hallucination guardrail

Living-person handling:

- **Birth year ≥ 1925**: presumed living. `find_children` / fan-out may *include* the person
  if the tree records them, but must NOT search public sources for them — the existing
  `_is_unsearchable` guard already implements this for the main pipeline; carry the same rule
  into all new primitives.
- **Anyone explicitly marked living**: same.
- **Output marking**: every node in a `KinshipGraph` carries a `presumed_living: bool` flag;
  downstream UI can render differently.
- **Guardrail extension**: the existing hallucination-guardrail axis (Lily Margaret Cauldwell
  b.2012) gets a relatives fixture declaring her parents (Darryl, Helen) but nothing else; if
  `discover_kin` surfaces siblings or children for her from any source, that's a guardrail
  violation.

## 7. Source coverage and limits

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

**Implication for "find my living cousins":** the 1925–1996 gap is a hard wall for
public-source-only. A 2nd cousin born in 1950 has:
- No FreeBMD birth (closed)
- No 1921 census (born after)
- Maybe a 1939 register entry (restricted)
- Probate only if deceased post-1996

The fan-out walker will trace such cousins through their *parents'* records (a 1921-census
child of an uncle) but cannot confirm the cousin themselves from public sources. Output flags
them `source_coverage_cliff: true`.

This is a documented limit, not a bug. It lets honest expectations be set for living-cousin
cases (`inconclusive_source_cliff`).

## 8. What this spec deliberately defers

- **DNA matching** — `find_dna_matches(subject)` against AncestryDNA / 23andMe / MyHeritage.
  Different problem domain, paid services, out of public-source-only scope.
- **Lateral search through marriages** — finding the user's in-laws (spouse's siblings,
  spouse's parents, etc.). Same primitives could walk that direction but the *value* is lower
  than blood kin.
- **Tree de-duplication** — discovering that two different profiles in the tree are actually
  the same person. Related to but distinct from verification.
- **Adoption / step-parent edges** — modelled today only by what FreeBMD's `spouse_or_mother`
  field happens to record.

These are real eventual needs but bundling them into V1 makes the scope unbounded.

---

**Next step: the Swift-first respec.** Rewrite the forward primitives (`find_spouses`, the
Swift equivalents of `find_siblings` / `find_children`), the `discover_kin` walker +
`KinshipGraph` type, and `verify_relationship` + `KinshipVerdict` as a Swift plan with its own
test surface (per swift-is-what-ships), gated on "core declared solid" per ADR-007. This
document supplies the conceptual model only.
