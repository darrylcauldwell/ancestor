# Evidence Absorption — one record, many routed facts

**Status: PROPOSED 2026-07-15.** Direction from Darryl during the Twyford research
session: "why isn't the app holding this detail? … we have fields for where people live and
their occupation — when we find nuggets we seem to silently lose them." The Evidence Firewall
governs what *enters* the tree (pending → review); this spec governs how accepted evidence
*distributes across the profile*. It is the firewall's other half.

## Guiding metaphor — the trusted-advisor researcher

Darryl's framing: *"Every work meeting I go into I have an agenda on what I want to find out.
During the meeting I find out a lot of other things I'd discard. When I'm top of my game I
remember those other facts for future conversations — that builds trust and trusted-advisor
status. What we've discovered here is the exact same thing."*

A research run is a meeting with an agenda: the subject's birth / death / marriage — the
value-groups it came to grade. Along the way a census volunteers an occupation, an address, a
birthplace, a houseful of names — off-agenda, but true. Today the app writes down only the
agenda items and lets the rest fall off the table. A top-of-game researcher **retains the
incidental facts, files them where they belong, and brings them back next time that person
comes up.** The absorption layer is that discipline made into code. The measure of success is
not "did the run answer its question" but "did the app keep everything the record was willing
to tell it."

## Problem (verified in code 2026-07-15)

A source record is a bundle of facts, but absorption is narrow and lossy:

- **Identity fields are written from BMD only.** `ApplyEngine.applyFactToSubject` writes
  birth/death date+place from `.birth/.death`, the spouse edge from `.marriage`; everything
  else (`.census/.burial/.military/.probate/.parish`) `break`s to the LifeEvent projection.
- **A census collapses to one catch-all `.census` event.**
  `SourceRecordProjection` routes census occupation + address + household into a single
  `.census` LifeEvent's `CensusDetails`. The dedicated `LifeEventType.occupation` and
  `.residence` cases EXIST but are **never populated from any record**. So "Abraham,
  electrician, 3 Mill Lane, born Alport" becomes one census entry with the occupation buried
  in details, no occupation fact, no residence fact, and no birth-location update.
- **Nothing materializes for an un-accepted lead.** The projection runs only on
  accept/apply. A census found but left as a lead loses ALL its nuggets — they stay as
  evidence text (live case: Abraham's 1891 census, still a lead, holds his occupation,
  address, and Alport birthplace, none absorbed).
- **The birth-location bug** (owner-hit): a census reveals a birthplace ("Alport"), but
  birth-location is only ever written from `.birth/.baptism`. So the birthplace the engine
  discovered can't reach the field that would anchor the subject — a circular block (the
  record needs the anchor to score Confirmed; the anchor is in the record).

## Design — one record → many routed facts

Replace the hardcoded per-record-type field writes with a **declarative field map**: each
record type declares, for each field it carries, the fact's HOME and the merge POLICY. The
apply engine walks the map; adding a source means declaring its map, not writing bespoke
per-field code.

**Four homes:**

1. **Identity field** (birth/death date & place) → the profile column. Policy:
   *precision-directional* — fill if empty; upgrade vaguer with more-precise (census
   `birthYear 1888` upgrades `BET 1882–1909`); never downgrade (generalises the existing
   date/string overwrite policy to every field). Cited; conflicts → disputes.
2. **Life fact** (occupation, residence, an event) → a *typed* LifeEvent — `.occupation`,
   `.residence`, etc. — NOT a catch-all `.census` blob. One census spawns the events its
   fields imply.
3. **Relationship fact** (spouse surname, household kin, probate executors) → a relationship
   *proposal* (the existing Proposed-Relatives flow).
4. **Narrative fact** (headstone inscription, will wording) → the bio/prose corpus.

**Invariants reused (generalised, not reinvented):** firewall (absorbed values are proposals
you accept, never silent writes — the E-Anna-Marshall protection stays); precision-directional
overwrite; provenance (every absorbed value carries its citation); conflict (disagreements
open disputes via the conflict layer). Absorbed fields then feed the Sourcing report
(Change 8) and the convergence engine with more value-groups to grade and score.

## Changes

**Change 1 — census birthplace → birth-location (S). SHIPPED 2026-07-15 (`40b106b`).**
`ApplyEngine.applyFactToSubject` now handles `.census` instead of falling through: the
birthplace routes to `birthLocation` through the existing directional string-overwrite policy
(fills empty, upgrades lower-tier, never clobbers precise, disputes on clash), county-composed
by `censusBirthLocation` so a bare "Alport" becomes the anchor-able "Alport, Derbyshire".
Closes the anchor loop: the discovered birthplace becomes the anchor that promotes the
subject's own records from anchorless National to Confirmed. Unblocks Abraham (Alport).

**Change 2 — census occupation → `.occupation` event; address → `.residence` event (M).
SHIPPED 2026-07-16 (`b347351`).** Darryl's "nuggets" point. `SourceRecord.projectToLifeEvents`
now fans a census into its `.census` event PLUS a typed `.occupation` event and `.residence`
event (dated to the census year, located at the household address), so those first-class event
types finally populate from records instead of the nugget staying buried in census details.
Idempotent via a discriminated deterministic ID; empty fields spawn no event. All four
LifeEvent-save call sites in `ResearchViewModel` iterate the fan-out. Test
`CensusLifeEventFanOutTests`.

**Change 3 — corroboration fields (S/M). SHIPPED 2026-07-16 (`5f79cc8`).**
`ApplyEngine.impliedBirthDate`/`impliedDeathDate` extract the birth/death signal every record
carries off-agenda — census/death/military age (`birthDateFromAge`, a two-year `.calculated`
span), FindAGrave explicit birth/death dates, probate `ageAtDeath` — and route each through the
SAME `applyDateField` directional policy: fills empty, corroborates a compatible value (lands
in `field_sources`), disputes an incompatible one, never overwrites a precise value. Big net
gain: `.burial`/`.probate`/`.military` previously wrote NOTHING to profile date fields. Plus
probate address → `.residence` event via the projection fan-out. `.birth`/`.death` imply
nothing (their own cases write directly — no double write). Test `EvidenceCorroborationTests`.

**Change 4 — the declarative field-map refactor (M/L).** Extract per-record-type field maps;
`ApplyEngine` + `SourceRecordProjection` walk them. Removes the hardcoded switch; new sources
declare a map.

**Change 5 — surface absorption at review time (M).** The cluster/finding review shows the
FULL set of proposed absorptions per record ("this census will set: birth place Alport ·
occupation electrician · residence 3 Mill Lane · +4 household leads"), so accepting a record
lands every nugget, and a lead's nuggets are visible before acceptance (no silent loss).

## Order & gate
1 → 2 → 3 (SHIPPED), then **4 before 5**, each gated by full `xcodebuild test`. Change 1 first —
smallest, unblocks Abraham, proves the routing.

**Why 4 before 5 (decided 2026-07-16, no time pressure):** Change 5's review preview must
enumerate every fact a record will absorb; Change 4 *is* that enumeration (apply becomes
"compute absorption items → execute"). Build 5 on 4 and the preview computes the same item list
and merely displays it — preview and write cannot drift. Build 5 first and you either duplicate
the enumeration across the three scattered paths (the drift bug this spec exists to prevent) or
write a throwaway dry-run 4 then reworks. 4's refactor target is already complete because 1–3
are shipped, so there's no moving-target reason to defer it. The only thing 4-first costs is
delaying the visible win (5) behind a payoff-free refactor — a cost that only bites under time
pressure. Under pressure, flip to 5→4.

## Non-goals
Auto-apply (firewall unchanged); a profile-level occupation *column* (occupation stays a typed
LifeEvent — richer, dated, multiple); inventing fields the model lacks.
