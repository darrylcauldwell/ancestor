# Subject Self-Narrowing — Specification

**Status:** Shipped 2026-05-27 — Slices A, B and C all delivered. As-built reference (archived 2026-07-11).
behind a `logger.notice` line; this spec governs Slice B (surfacing
the consensus as a reviewable profile-update proposal) and the
guards Slice B must carry.

**Scope:** Close the chicken-and-egg loop in which a wide subject
birth-window prevents any single BMD record from anchoring as a
`.fact`, which in turn keeps the window wide forever. Surface
cross-source consensus on a single birth (or death) year as a
proposed profile update, routed through the existing Evidence
Firewall so it gets the same human review every other externally-
sourced fact does.

**Out of scope:** Promoting individual records to `.fact` (still the
4-gate scorer's job). Modifying `refineSubject` (still works only
on records the scorer already promoted). Pause-and-ask mid-run UX —
the user picked "non-blocking post-run card" over "blocking dialog"
explicitly during slice design discussion.

---

## 1. The problem this spec solves

A subject lacking a precise birth date — common for any profile
imported from a thin GEDCOM, or a `@FR_…@` placeholder — gets
`birthYearFrom`/`To` derived from the oldest known child via
`ResearchSubject.fromProfile`'s fallback (`childYear-45 … childYear-18`).
For George H Brooks (oldest child 1914): subject window becomes
**1869–1896**, a 27-year span.

Downstream consequences observed empirically over the slice 13
verification runs against this subject:

1. The 4-gate scorer's date gate is permissive — a BMD record citing
   birth 1883 passes (1883 ∈ 1869–1896) but doesn't strongly
   *confirm* the subject's identity over the other 27 candidate years.
2. None of the 458 scored records reaches `.fact` verdict.
3. `refineSubject` only runs over `confirmedFacts`, which is empty.
4. The wide subject window persists across iterations.
5. The Level-2 strategist (slice 13) generates queries against the
   wide window — picking 1891 census with rationale "subject ~22"
   when the subject is actually ~8 — because its prompt math anchors
   on `birthYearFrom` (the bottom of the window), not the precise
   birth year.

The deterministic engine has all the evidence needed to anchor
1883 (5+ records cluster on it) but cannot promote any single one
on its own.

---

## 2. Design summary

A post-run review card surfaces a proposed birth/death year update
when:

- The subject's existing window for that field is wide (>5-year span).
- Scored records cluster on a single year with ≥3 supporters.
- The cluster satisfies the source-diversity and locality-alignment
  guards (§3).

The proposal flows through `pending_facts` — the same path used by
the MCP `submit_evidence` tool and by prose-corpus extraction.
Approval applies the date to the profile via the existing pending-
fact approval surface; rejection withdraws cleanly.

---

## 3. Design requirements (guards)

These five guards distinguish slice B from a naive "engine spotted
a number, click to apply" pattern. Every guard is MUST.

### 3.1 Source-diversity requirement

The consensus cluster MUST span ≥2 distinct `sourceID`s. Multiple
records from the same source (e.g. 4 FreeCen census ages) often
trace back to a single underlying birth registration and count as
one piece of evidence retold, not independent confirmation.

Rationale: most common false-positive mode in censuses. Census
takers transcribe ages from prior censuses, household memory, or
the same birth certificate the household has on hand.

### 3.2 Locality alignment requirement

At least one supporting record MUST share a district/region with
the subject's known birth or death location. A FreeBMD birth in
Belper for "George Brooks 1883" supports a Belper-born subject;
one in Northumberland doesn't even if it has the right name and
year.

Rationale: name + year alone is insufficient identity anchoring.
Adding location closes the "wrong George Brooks elsewhere" gap.

### 3.3 Evidence Firewall routing

The proposal MUST be written to the `pending_facts` table, not
applied directly to the profile. Identifies as a slice B
proposal via a stable `source` discriminator (e.g.
`"subject-self-narrowing"`) so the approval UI can render it with
its supporting-evidence list.

Rationale: matches the existing audit/review path for every other
externally-sourced fact. Approval is reversible, the trail is
visible, and the user reaches for the same muscle memory they
already use for MCP-submitted evidence.

### 3.4 Inline supporting-evidence preview

The review surface MUST render the actual supporting records, not
just a count. Minimum:

```
Proposed: birthDate = "1883" (medium confidence)
Supported by:
  - Birth Q4 1883 Belper 7b/631 (FreeBMD)
  - Census 1891: George Brooks, age 7, Belper (FreeCen)
  - Census 1901: George Brooks, age 17, Belper (FreeCen)
  - Burial: George Brooks, died 1937 age 53 → b.1884 (FindAGrave)
```

Rationale: lets the user spot an off-by-one census drift, an
unrelated record that snuck in, or a same-source cluster the
diversity guard somehow missed. Without this preview, the click
risk profile inverts toward the naive case.

### 3.6 Honor user record rejections

Records the user has explicitly discarded for the subject's profile
MUST be excluded from the consensus evidence pool. Source of truth is
`ProjectDatabase.loadRejections(profileID:)`, which unions the legacy
`record_rejections` table with the modern
`evidence_records.user_status = 'discarded'` rows.

Rationale: closes the "wrong-person cluster" mode observed against
George H Brooks. The pipeline re-fetches BMD records from FreeBMD on
every run, so a known-different-person cluster (e.g. George Brooks
b 1870 d 1871 in Basford, 38 records) keeps re-anchoring slice B's
consensus at the wrong year. The user's `discardRecord(_:)` gesture
in the ClusterReviewView already persists the right signal; this
guard just makes the detector consult it.

Plumbing: `ResearchPipeline` gains an optional
`rejectionLookup: ((String) -> Set<String>)?` mirror of
`pendingFactWriter`, populated by call sites that have a
`ProjectDatabase`. The detector accepts the resolved set as a
parameter so the unit tests can exercise the filter without a
database.

### 3.5 Confidence tiers

The proposal MUST carry a confidence grade visible in the UI.
Minimum two tiers:

- **High** — ≥4 records, ≥2 sources, ≥1 location-aligned. Renders
  prominently with a one-click Apply.
- **Medium** — exactly 3 records OR exactly 2 sources OR no
  location-aligned record (but everything else passes). Renders
  quieter, no Apply button; clicking opens the existing cleanse
  flow for that profile so the user takes the manual path.

Records that don't meet the medium tier are not surfaced. (They
remain in `logger.notice` for audit/eval purposes but produce no
user-visible card.)

Rationale: the user's brain does more work per accepted fact when
the affordance is graded by confidence. Low-confidence proposals
that route to cleanse force the user to look at evidence in
context — which is the status-quo friction we don't want to lose
for the noisy cases.

---

## 4. Determinism contract

Slice B is rule-driven, not MLX-driven. It operates on typed record
fields (`BirthRecord.birthYear`, `CensusRecord.censusYear - age`,
etc.), buckets implied years deterministically, and applies the
guards as boolean filters. No model involvement in the proposal
generation, scoring, or confidence tiering.

The MLX-influenced records that flow into the detector (e.g.
records found via slice 13's focused query) are flagged via
`searchHistory.searchKey` starting with `focused_…` but the
scorer's verdict on them is deterministic regardless. Slice B
treats them like any other scored record.

The user approves or rejects; the engine never auto-applies.
"Approval is human" stays the firewall invariant.

---

## 5. Data flow

```
[Iteration loop completes]
   │
   ▼
BirthYearConsensusDetector.detect(scored, subject)
   │  (Slice A — already shipped, returns BirthYearConsensus?)
   ▼
[Slice B layer]  Apply guards §3.1, §3.2, §3.5
   │  Reject if any MUST guard fails
   ▼
PendingFactWriter.proposeSubjectNarrowing(
    field: .birthDate,
    value: "1883",
    confidence: .high|.medium,
    supportingRecords: [ScoredRecord],
    source: "subject-self-narrowing"
)
   │
   ▼
pending_facts table  (existing schema)
   │
   ▼
Triage / Pending Facts review surface
   │  (existing UI, extended to render slice B's preview block §3.4)
   ▼
[User approves]                   [User rejects]
   │                                 │
   ▼                                 ▼
Profile.birthDate updated         pending_fact marked rejected
Subject re-builds with narrowed   (no profile change)
window on next research run
```

---

## 6. UI affordances

Surfaced in two places:

1. **Triage / Pending Facts list** — same row pattern as
   MCP-submitted facts. Confidence tier shown as a badge
   ("HIGH" / "MEDIUM"). Tap expands to show the
   supporting-evidence block (§3.4).

2. **Research Complete dialog footer** — when a slice B proposal
   was generated this run, the footer shows a small notice
   ("1 narrowing proposal — review in Triage") so the user
   doesn't miss it. No inline accept/reject in the dialog itself
   — the actual decision happens in Triage where the supporting
   evidence renders properly.

No mid-run dialog. No automatic profile write. The proposal
sits in `pending_facts` indefinitely until the user reviews it.

---

## 7. Implementation slicing

Slice B is implemented as three sub-slices to keep PRs reviewable.

### 7.1 — B1: Guarded consensus output

- Add `BirthYearConsensus.confidenceTier` (high/medium/none)
- Implement guards §3.1, §3.2, §3.5 inside `BirthYearConsensusDetector`
- Detector returns nil (not surfaced) when tier is `.none`
- Test cases: same-source-only cluster (rejected), out-of-region
  cluster (rejected), 5-records-3-sources-aligned (high), 3-records-
  2-sources (medium).

### 7.2 — B2: Wire to pending_facts

- Add `source: "subject-self-narrowing"` to the pending_fact
  enum/string set
- In `ResearchPipeline`, when detector returns a non-nil consensus,
  write a `PendingFact` carrying the proposal + the supporting
  `[ScoredRecord]` IDs
- Schema migration if needed for `supportingRecordIDs: [String]`
  on `PendingFact`

### 7.3 — B3: UI

- Extend the Pending Facts review row to render the slice B
  preview block (§3.4) when `source == "subject-self-narrowing"`
- Footer notice on `ResearchProgressSheet` Complete state
- Confidence-tier badge styling

Ship order is B1 → B2 → B3. B1 alone is testable in isolation
(verify guards work). B2 lands the data but is invisible without
B3. B3 closes the loop.

---

## 8. Open questions

- **Death-year consensus.** The current detector only handles birth.
  Death-year follows the same logic (records carrying deathYear or
  deathYear-derived ages converge similarly). Defer or include in B1?
  Recommendation: include — same code, marginal cost, doubles the
  cases that benefit.

- **Threshold tuning.** ≥3 records and ±1 year fuzziness are the
  current floors. Should we collect logged consensus events across
  a sustained run (e.g. an 87-profile pass) and tune from data
  before B1 ships, or ship with the conservative defaults and tune
  later? Recommendation: ship conservative, tune from data.

- **What about previously-rejected proposals?** If the user rejects
  a 1883 proposal and a later run finds the same cluster again,
  should we re-surface or stay quiet? Recommendation: stay quiet
  for N days then resurface — the user's reasoning may have been
  "I'll come back to this", not "this is wrong forever".

- **Slice 13 prompt update.** Once B is live, the strategist's
  prompt should reflect that the engine can self-narrow — it might
  unlock different query strategies ("propose the parents' marriage
  search because the consensus has anchored the subject's birth
  year"). Out of scope for this spec, but flag for the slice 13
  prompt-iteration backlog.
