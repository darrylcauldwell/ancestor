# SUBJECT_PLACE_MODEL_SPEC

**Status:** DRAFT — consumer inventory pending (mapping run 2026-08-19).
**Origin:** owner observation, 2026-08-19: *"The goal was a singular location
format and approach used consistently."*

## Problem

**Storage is already uniform.** Every location in the model is a `(text, code)`
pair:

| | text | code |
|---|---|---|
| Profile birth | `birthLocation` | `birthLocationCode` |
| Profile death | `deathLocation` | `deathLocationCode` |
| Life event — incl. **census** and **residence** | `location` | `locationCode` |
| Relationship marriage | `marriageLocation` | `marriageLocationCode` |

Plus `Profile.birthRegistrationDistrict` (Slice C) — a *derived* district id,
written only by `ApplyEngine` from an applied birth record.

**`ResearchSubject` then flattens that one shape into five ad-hoc ones**
(`Services/Research/ResearchSubject.swift`):

```
region: Region?                                   :187
deathLocation: String?                            :194   text only — no code
homeChapmanCode: String                           :213   a derived county, as a bare string
residenceAxes: [ResidenceAxis]                    :231   (place, chapmanCode, yearFrom, yearTo)
burialPlace: String? / burialChapmanCode: String? :236/:239
```

Nothing on the subject says *"here are all the places we know about this person,
with their codes and their years."* So every consumer reads whichever flattened
field someone remembered to wire to it, and the gaps are arbitrary rather than
designed.

### The evidence that this is the actual defect

Four separate "additive arm" special cases have grown, one per source, each with
its own comment explaining the same underlying idea — that the events which
matter most are the ones that happened away from where a person was born:

1. **FreeCen** merges residence counties into its residence axis
   (`SearchDispatcher.swift:1058-1075`).
2. **FreeREG** appends a burial county for burial-shaped records
   (`SearchDispatcher.swift:1146-1155`).
3. **FreeBMD** got a death/burial county arm on 2026-08-18 (`d58d542`) — the
   third implementation of the same idea.
4. **Census and residence counties still never reach FreeBMD at all**, so a
   profile whose only locations are census residences is searched in the
   *project default* county. It could appear in five Staffordshire censuses and
   FreeBMD would still search Derbyshire.

Adding a fifth special case (a residence arm on FreeBMD) would have been the
obvious next move. It is the wrong one.

## Decision

One value type, carried as a collection.

```swift
nonisolated struct PlaceRef: Sendable, Equatable {
    let text: String            // what the tree says, verbatim
    let code: String?           // PlaceAuthority id when known
    let kind: PlaceKind         // birth | death | marriage | residence | census | burial
    let yearFrom: Int?          // event window; nil bounds are OPEN
    let yearTo: Int?
    let sensitive: Bool         // carried, never silently dropped
}
```

`ResearchSubject` carries `places: [PlaceRef]`. A consumer asks *"places of kind
X covering year Y"* rather than reading a bespoke field. County, district and
parish are derived **uniformly** by resolving `code` through `PlaceAuthority`,
falling back to text resolution — instead of each site re-parsing text its own
way.

### What this collapses

- The anchor becomes "resolve the best-evidenced ref", not a hand-written
  fallback chain.
- The four additive arms become **one rule**, stated once.
- A new source cannot miss an axis, because there is only one collection to read.
- Place decisions and census parish/district flow in as codes on the same refs.

## Invariants (must survive the refactor)

- **The gate must not move.** More place data may widen what is SEARCHED; it must
  never widen what the 4-gate scorer ACCEPTS. `checkGeography` and
  `acceptedChapmanCodes` are behaviour-preserving, pinned by characterization
  tests written BEFORE any change.
- **An absent anchor stays absent.** `homeChapmanCode == ""` currently triggers a
  visible scope-skip ("no home county to anchor … widen to National"). A richer
  model must not manufacture an anchor where none should exist.
- **Sensitive events stay filtered.** `residenceAxes` filters `!event.sensitive`
  (`ResearchSubject.swift:852`). A generic collection must carry that, not lose it.
- **Request volume must not multiply.** Today one `homeChapmanCode`; a collection
  may yield several counties. Volunteer sources are not stress-test targets —
  any fan-out is bounded and stated, never emergent.
- **Precedence is explicit and tested.** Today: birth code → birth text → death
  code → death text → project default. Any "best evidenced" rule must reproduce
  that ordering or justify each change.

## Slices

*(sequence to be finalised from the consumer map)*

- **Slice 1 — characterization.** Pin today's behaviour first: the anchor
  derivation table, every source's emitted axes for a set of fixture subjects,
  and the gate's accept/reject decisions. The refactor is judged against these.
- **Slice 2 — the type.** `PlaceRef` + `ResearchSubject.places`, populated
  alongside the existing fields. Nothing reads it yet. Zero behaviour change.
- **Slice 3 — one consumer at a time.** Move each reader to `places`, proving the
  characterization tests still pass at each step. The additive arms collapse here.
- **Slice 4 — delete the flattened fields.** Only once every reader has moved.
- **Slice 5 — the gap that started this.** Census and residence counties reach
  every source that can use them, by the single rule rather than a fifth arm.

## Acceptance

- A profile whose only locations are census residences is searched in **those
  counties**, on every source that can scope, not in the project default.
- The four additive-arm comments in `SearchDispatcher` are replaced by one rule.
- Characterization tests from Slice 1 pass unchanged throughout.
- No increase in request count for any subject that has a birth place today.

## Open questions

*(to be filled from the mapping run)*
