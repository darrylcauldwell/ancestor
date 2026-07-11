# ADR-007 — Kinship primitives join the core push, respecced Swift-first

**Status:** Rejected as proposed 2026-07-11 (Darryl) — the stated alternative adopted: kinship stays OUT of the core push and moves to a later roadmap stage. Binding residue: the Swift-first respec requirement and the dissolution of #Change9 stand whenever kinship is picked up.
**Depends on:** the swift-is-what-ships rule (2026-05); the core-capability priority (Darryl, 2026-07-10); ADR-004 (this is NOT a model evolution — it is engine capability, so it needs no ADR-004 exception)

## Context

`KINSHIP_SPEC.md` (May 2026) designs the walk-outward machinery: `find_spouses` (#Change3 — all spouses with per-spouse evidence, covering remarriage and widowhood), `discover_kin` (#Change4 — a bounded walker expanding N generations up/down from a subject, default caps depth 3/3, max 200 nodes), and `verify_relationship` (#Change5 — a claimed kinship such as "second cousin once removed" checked against records), plus corpus/harness extensions (#Change6–8). #Change1–2 (`find_children`) shipped in Python. #Change3–5 were deferred behind `ENGINE_FOUNDATION_SPEC.md`.

Two things changed since May:

1. **The declared priority (2026-07-10) is core research capability** — researching and adding profiles to the tree. Kinship primitives are exactly that: the engine-side machinery for growing the tree outward and *verifying* claimed relationships rather than assuming them.
2. **The swift-is-what-ships rule** (adopted after behaviour was twice built Python-first and back-ported at cost): never iterate new behaviour in Python planning to port later. The May plan builds #Change3–8 in Python with Swift as a final #Change9 — that plan is now doctrinally invalid as written.

The deferral reasoning ("behind engine foundation") is stale: engine foundation Phases C+D are themselves deferred, so the old sequencing leaves kinship doubly stuck behind work that isn't scheduled, while the connector-fix campaign is actively repairing the layer kinship would sit on.

## Decision

**Kinship joins Stage 1 of the roadmap (the core push), respecced Swift-first.** Concretely:

1. A new spec (KINSHIP_SPEC v2, or a fresh `KINSHIP_SWIFT_SPEC.md`) redesigns #Change3–5 as Swift engine capability — `find_spouses`, `discover_kin`, `verify_relationship` — using the shipped Python `find_children` as the faithful-port reference where behaviour overlaps (per `feedback_port_from_python.md`), and the Python designs as *design input*, not as code to port wholesale.
2. **Sequencing: after the connector audit's scorer and evidence-integrity fixes** (top-5 series). Kin discovery multiplies whatever the gates get wrong; it starts from a repaired scorer, not the current one.
3. The May spec's #Change6–8 (Python corpus/harness extensions) are retained for the parity harness only; #Change9 (the wholesale port) is dissolved — superseded by this decision.
4. No code before the v2 spec is reviewed and accepted.

## The alternative, stated fairly (kinship stays out of Stage 1)

The discovery loop already grows the tree: parent-inferred leads, sibling proposals, promote-to-profile. Kinship adds spouse-walking, bounded multi-generation expansion, and relationship verification — valuable, but nothing else in Stage 1 blocks on it, and Stage 1 is already substantial (58 audit findings + model evolutions + pipeline remainder). Deferring costs nothing structural; it can join whenever capacity allows.

**Why the decision still favours "in":** the priority is capability, not fixes — the audit campaign repairs what exists, while kinship is the largest *missing* piece of "research and add profiles to the tree". Verification (`verify_relationship`) in particular has no substitute anywhere in the engine, and the eval corpus already contains the expected-relatives ground truth (#Change6) to measure it against.

## Consequences

**Positive:** the core push delivers new capability, not only repairs; relationship *claims* (from GEDCOM imports, WikiTree, future FS hints) become verifiable against records; the discovery loop gains principled expansion bounds (the "stop digging here" concern gets a natural home).

**Negative:** a spec rewrite before any code (half-day); Stage 1 grows by an M/L implementation; the Python/Swift parity harness needs kinship-mode extensions to keep the compare-with-python discipline meaningful.

## Reversal / exit

If the v2 spec review reveals the scope is larger than the core push can carry, the fallback is explicitly scoped: ship `find_spouses` + `verify_relationship` only (S/M), defer `discover_kin` — verification is the piece with no substitute.
