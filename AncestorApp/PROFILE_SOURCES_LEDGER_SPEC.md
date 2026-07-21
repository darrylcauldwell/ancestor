# Profile Sources & Records Ledger

**Status: Changes 1+2+3+4 SHIPPED. Change 5 (muddle deep-links) remains.**
- **Change 2 (read-only ledger)** — `ProfileSourcesLedger` + `ProfileDetailView` "Sources & Records" section (`03cf0d3`; reads `evidence_records`, no migration).
- **Change 4's rejection-memory goal** first shipped as a pipeline fix (`3433f46`): the main research pass was re-clustering DISCARDED records every run (`excludingRejected` was wired only into the §5.15 hunch path). `ResearchPipeline.clusterInput` now filters through the rejection memory, so a discarded record stays gone across re-runs.
- **Changes 1+3+4 (per-record removal / directional revert + rejection on removal)** — SHIPPED 2026-07-21 (`e17b6dd`). NOT built as the spec's Change-1 "map record → its revert transaction" (that link is impossible: one apply fans into MANY unlinked `.manualEdit` transactions, `field_sources` has no record-id column, citation attach + life events run outside any transaction). Instead removal is **plan-guided** — it re-walks the record's `absorptionPlan` (the same enumeration the write path executes) and inverts each item against CURRENT state, in one audited transaction: delete `field_sources` keyed (profile, field, origin, raw) unless a sibling kept record of the same source corroborates the value; revert the column ONLY when it still equals the record's value AND a `field_changes` row proves this origin set it (else drop the row and keep the value — an alternative-only landing never owned the column); delete life events by recomputed deterministic ids; clear the marriage-edge date/location on exact match; delete open fieldValue disputes on the four sweep-re-derived fields (birth/death date+location) + open spouseIdentity disputes for marriage records, with `ConflictSweep` now excluding user-discarded evidence so removed disputes can't resurrect; feed rejection memory (`user_status='discarded'` + `record_rejections`). Reversible by re-applying from research. `Services/ProjectDatabase+RecordRemoval.swift` + `RecordRemovalTests.swift` (12 tests). **UI: a trash button on each ledger row → confirmationDialog → `AppState.removeAppliedRecord` (rebuild snapshot + force sweep + audit).**
- **Change 5 (muddle-detector deep links)** — UNBUILT. `MuddledIdentityRule`/kin findings gain a "Review records" action opening the ledger for the flagged profile. Small nav wiring, no new persistence.

Documented residual losses (rare): the marriage fill journalled nothing, so a wider pre-fill marriage date the record then narrowed is not recoverable; life events moved to another profile by a MERGE keep their loser-derived ids and are not reachable by recompute (but neither is the record's ledger entry post-merge, so the surfaces agree). Commits reference `#LEDGER-Change1`…`#LEDGER-Change5`.

Original proposal follows.

---

A per-profile, read-and-manage surface for the
records that back a person: see every applied record in full (citation, vol/page,
source tier, which fields it established) **without re-running research**, and
**remove a bad record** — reversing its effect and remembering the rejection so a
future run does not re-add it. Commits reference `#LEDGER-Change1`…`#LEDGER-Change5`.

Motivating case: **George Herbert Brooks** (Cauldwell Family Tree 2), 2026-07-18.
Two frustrations surfaced in one session:
1. Applied facts show only as field *values* on the profile — the underlying
   records (FreeBMD birth index, vol 7a/631, etc.) are visible only in the
   Research/Triage screens, so **the only way to re-see records is to re-run
   research**.
2. Re-running research **re-clustered George's records into a worse grouping**
   (a Basford 1882 namesake birth stapled to his real 1937 death) — so the
   workaround for (1) actively risks corrupting the picture, and namesake
   records keep re-appearing.

The ledger fixes both: records are visible without a re-run, and removing a bad
one is remembered so it stays gone.

## The gap, in one sentence

The app has everything needed to *retain* an applied record's full detail
(`field_sources.citation_json`, `evidence_records`, the `created_by_transaction_id`
link, `record_rejections`) but **no per-profile surface that displays that detail
or lets a human prune a wrong record** — so users re-run research to see records,
and re-running re-muddles.

## Two-layer model (the why, for context)

- **Profile layer** — canonical field *values* (birth `1884`) + lightweight
  provenance (`field_sources`: which origin set each field, optional
  `citation_json`). Rendered by `ProfileDetailView`, but only as an edit-oriented
  per-field source *picker* — never as a records list.
- **Evidence layer** — the full record corpus (`evidence_records` /
  `scored_records`): complete citation, vol/page, scoring gates, verdict.
  Displayed *only* in Research / Triage / SourceExplorer.

Applying a fact copies the value + citation across the firewall onto the profile,
but the two layers are never joined in a read-and-manage view. This spec builds
that join, scoped to one profile.

## Decision log

1. **Read AND manage, not read-only.** The ledger displays applied records *and*
   removes bad ones. A read-only view would still leave the user with no clean way
   to undo a wrongly-applied record.
2. **Removal reverses the whole absorption, not one field.** One record can set a
   birth date *and* add a residence life event *and* corroborate a death (the
   `absorptionPlan` fan-out). Removal must undo everything that record
   contributed — implemented as reverting the record's apply *transaction*, which
   already deletes all `field_sources`/`relationships`/`life_events` it created.
3. **Field-value revert is directional.** If the removed record was the *sole*
   source of a value, revert to the prior value (or empty); if it merely
   corroborated an existing value, drop the corroboration and keep the value. The
   inverse of `ApplyDateOverwritePolicy` / `ApplyStringOverwritePolicy`.
4. **Removal feeds rejection memory.** Removing a record marks it rejected
   (`record_rejections` + `evidence_records.user_status='discarded'`), so the next
   research run does not re-propose or re-apply it. This is the part that closes
   the "bad records keep coming back" loop — without it, remove → re-run → it
   returns.
5. **Reversible and audited.** A removal is itself a transaction recorded in
   `field_changes`; nothing is silently destroyed. Consistent with the firewall's
   undo-compatible posture (`ProfileMergeEngine`, transaction revert).
6. **Scope = applied records only.** The ledger manages records that are *on* the
   profile (facts). Un-applied candidates remain the job of the Triage review
   queue. (A future extension may show "also available, not applied" — a non-goal
   here.)
7. **The muddle detectors deep-link here.** A `MuddledIdentityRule` two-birth-date
   finding, or a future two-source-conflict, links *into* this panel where the
   offending record is removed. The ledger is the evidence-side counterpart to the
   phantom-spouse card (structural-duplicate cleanup).

## Conceptual model

```
LedgerEntry = (record: applied evidence record,
               citation, sourceTier, recordType,
               establishes: [ProfileField | LifeEvent],   // what it contributed
               transactionID,                              // revert handle
               isSoleSourceOf: [ProfileField])             // for directional revert

Profile ledger = every field_source on the profile whose origin is a research
                 record (has an evidence_record_id / source_record_id), grouped
                 by originating record so one row = one record = one revert unit.
```

## Change 1 — Applied-record ↔ transaction ↔ evidence link (data foundation) (S–M)

**Scope:** guarantee every applied research fact records enough to (a) list it and
(b) revert exactly it. Audit the apply path (`ApplyEngine.applyFactToSubject`):
each apply already runs in a transaction (`created_by_transaction_id` on the
written `field_sources`) and walks `absorptionPlan`. Confirm the originating
record's identifier (`evidence_record_id` / `source_record_id`) is persisted on
the field_source (or a side table) so the ledger can group field_sources by record
and map a record → its revert transaction.

- If the link is missing, add it: smallest change is a nullable
  `evidence_record_id` column on `field_sources` (one migration), populated by the
  apply path. Back-fill is best-effort (older applied facts may show as
  "record detail unavailable" — surface honestly, never fabricate).

**Acceptance:**
1. For a freshly applied FreeBMD record, the ledger query returns one entry with
   its citation, the fields it set, and a transaction id that reverts *only* that
   record's writes.
2. Reverting that transaction removes exactly the field_sources/life-events the
   record added and nothing else (existing revert primitive, exercised by test).

**Blast radius:** possibly one migration + a few lines in the apply path. No
change to scoring or the firewall posture.

## Change 2 — Read-only "Sources & Records" section on the profile (M)

**Scope:** a new collapsible section in `ProfileDetailView` (or a Sourcing tab
scoped to the profile) listing every applied record: source badge + tier,
record type, the full citation, vol/page, and "established: birth date, birth
place" (from `absorptionPlan`). Read straight from `field_sources` +
`evidence_records` — **no research run**.

**Acceptance:**
1. Open George Herbert Brooks after applying his Belper birth/marriage/death →
   the three records show with full FreeBMD citations and what each set, with the
   app *not* having run research.
2. A profile with only GEDCOM data shows its GEDCOM provenance, no research rows.
3. Ordering deterministic (by record type, then date).

**Blast radius:** `ProfileDetailView` + a read-only ledger query service. No writes.

## Change 3 — Remove a record (revert + directional value handling) (M)

**Scope:** a "Remove this record" action per ledger entry → confirm → revert the
record's transaction. Directional per decision #3: sole-source fields revert to
prior/empty; corroborating fields keep their value, drop the citation. Life
events / relationships the record created are removed. All in one audited
transaction.

**Acceptance:**
1. Remove a wrongly-applied birth record → the birth field reverts (to prior value
   or empty) and its life events vanish; other records on the profile untouched.
2. Removing a corroborating-only record leaves the field value intact, removes the
   extra citation.
3. The removal appears in `field_changes` and is itself reversible.

**Blast radius:** the ledger service + a confirm sheet. Uses the existing
transaction-revert primitive; the directional-value logic is the new code.

## Change 4 — Rejection memory on removal (S)

**Scope:** removing a record also writes it to `record_rejections` /
`evidence_records.user_status='discarded'` (the same memory the pipeline already
consults), keyed by `source_record_id`, so a subsequent run does not re-propose or
re-apply it.

**Acceptance:**
1. Remove the "George Brooks, Mar 1884, Belper" namesake birth → re-run research →
   it does **not** return as a fact (it is filtered by rejection memory, or shows
   only as an explicitly-dismissed row).
2. The rejection is visible/reversible (un-reject re-enables it) — never a silent
   permanent ban.

**Blast radius:** one write in the removal path + reuse of existing rejection
filtering. No pipeline change.

## Change 5 — Muddle-detector deep links (S)

**Scope:** `MuddledIdentityRule` (and kin) findings gain a "Review records" action
that opens this ledger for the flagged profile, so the flag and its remedy are one
click apart.

**Acceptance:**
1. A two-birth-date muddle finding deep-links into the ledger with the conflicting
   records visible.

**Blast radius:** the audit-result action wiring + navigation. No new persistence.

## Worked example — George Herbert Brooks (the test)

Current state (verified via MCP 2026-07-18): profile fields are all GEDCOM
(`birthDate '1884'`); research found, in the latest run, Belper `fact` records —
birth Dec 1883 (7a/631, "George **Herbert**"), birth Mar 1884 (7a/602, "George"),
marriage Dec 1911 (7b/1397), death Mar 1937 (7b/923) — plus out-of-district
namesake leads.

The ledger's role in fixing George:
1. Apply the correct Belper records; the ledger shows them **without a re-run**
   (removing the pressure that caused the re-cluster muddle).
2. If the **Mar 1884 "George" namesake** birth is ever applied, remove it via the
   ledger; **rejection memory** stops it re-appearing on the next run.
3. The **@234/@539 father-son structural tangle** is *out of scope* here — that is
   relationship-edge repair (a separate fix). The ledger addresses the *evidence*
   dimension; the tangle addresses the *structure* dimension.

## Non-goals

1. **Not a candidate browser.** Un-applied candidates stay in Triage; the ledger
   shows what is *on* the profile.
2. **Not relationship-edge repair.** The @234/@539 tangle and reversed parentage
   are a separate structural-repair track.
3. **No silent permanent bans.** Every rejection is visible and reversible.
4. **No re-scoring here.** Removing a record does not re-run the scorer; it reverts
   an application and records a rejection.

## Build order / gate

Change 1 (link) → Change 2 (read-only ledger — immediately useful for George,
lets us *see* his records without a re-run) → Change 3 (remove) → Change 4
(rejection memory — closes the re-appearance loop) → Change 5 (deep links). Each
change ships with tests; Change 2 is the first testable slice on George.
