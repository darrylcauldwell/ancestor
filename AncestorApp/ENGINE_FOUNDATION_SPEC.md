# Engine Foundation — Specification

**Status:** Draft (2026-05-25). Active spec. All other in-flight
specs (`PROSE_CORPUS`, `FAMILYSEARCH_SOURCE`, `SOURCE_MEDIA`,
`KINSHIP` #Change3–5, `RESEARCH_PIPELINE_SPEC` Part II) are deferred
until this one ships.

> **Cross-link (2026-07-11):** `CONNECTOR_AUDIT_2026-07.md` now covers adjacent territory with verified findings — its T1-01 search-outcome envelope (truncation/availability honesty, shipped 2026-07-11, commit a6e9c6d) and §5.2 persistent negative-search cache (shipped 2026-07-11, commit 08a4912) are now in place and inform #Change5/#Change6 when Phase C+D is picked up. The audit side has landed; Phase C+D remains deferred per §3.

**Scope:** Eight engine-correctness and engine-self-knowledge changes
needed before any output-surface or coverage-extension work is worth
doing. When this spec is shipped, the engine should be:

1. Trustworthy enough to ship to non-developer users (the
   §14.B.1 hallucination gate is closed), and
2. Stable enough to run unattended for multi-day sustained
   enrichment passes (daily budgets, checkpoints, expansion bounds
   are all in place).

**Why now:** The 87-profile cross-day Discovery run
(`AncestorApp/ROADMAP.md` cross-day wrap) demonstrated that the
engine works at the architectural level, then exposed eight concrete
weaknesses that compound when running autonomously across many
profiles. Until these are fixed, layering bio synthesis, more
sources, image capture, or kinship fan-out on top just amplifies the
wobble.

**Out of scope:** New product surfaces, UI work, additional sources,
the V2 hypothesis framework, bio synthesis. All listed deferred
above.

---

## 1. The problem these eight changes solve

Today's failure mode, observed empirically:

1. A thin placeholder (surname-only `@FR_…@` profile) is researched.
2. The 4-gate scorer accepts ~3,000 candidates because the gates pass
   any record with the right surname + a 30-year birth-year window.
3. Most land `.fact`. No single candidate is confident enough to
   *update* the placeholder.
4. The next Discovery hop fires off that still-thin profile,
   compounding the noise downstream.
5. Meanwhile, no dedup runs, so the placeholder may itself be a
   duplicate of an existing rich profile (the Jennifer Holmes bug).
6. The Discovery walk doesn't know when to stop, so budget burns on
   5th-cousin candidates while the core tree still has gaps.
7. When FreeBMD's daily quota hits, the breaker trips and the run
   ladders to 900s waits — clock burned, no progress.
8. If the run dies (process restart, crash, user pauses), partial
   resume is fragile.
9. There's no visibility into *where* on the periphery scorer
   attrition is happening, so we can't tell if the brake is engaged.
10. And before any non-dev shipping, the auto-approval write path
    must re-verify cited URLs (§14.B.1) — currently gated off.

Each change below targets one of those failure modes.

---

## 2. Changes

### #Change1 — Thin-profile verdict cap

The 4-gate scorer (`Services/Research/RecordScorer.swift`) currently
applies its name + date gates against the subject's known fields; when
those fields are absent (`givenName == nil`, no precise birth-year),
the gates silently *skip* the comparison and pass. The result for a
surname-only HOLMES placeholder with a 30-year derived birth-year
window: every "HOLMES" record in the window passes all gates and lands
`.fact`. ~3,000 of them. They're then treated as confirmed facts
downstream.

The harm isn't candidate volume (that's the dispatcher's concern); it's
that the scorer asserts *truth* for records it cannot meaningfully
discriminate.

**Rule:** Define `InformationDensity` derived from the subject's known
facts at search time. When density is `.thin`, the scorer **caps the
verdict at `.lead`** — no record from this scoring pass can land
`.fact`. Records can still land `.impossible` for hard fails (death
before birth, married before age 16, foreign-country location, etc.).
The dispatcher continues to generate candidates as before; the scorer
refuses to assert *truth* without enough subject-side anchoring to
make the assertion meaningful.

**Density classification:**
- **`.thin`** if subject `givenName` is nil/empty — the load-bearing
  signal. Without it, the name gate cannot discriminate.
- **`.thin`** if subject has `givenName` but the birth-year window is
  wider than 25 years (the derived-from-children fallback produces a
  27-year window — by definition thin).
- **`.rich`** otherwise — gates run as today.

**Acceptance:**
- Test: surname-only subject (`givenName = nil`, surname = "Holmes",
  birth window 1926–1956) — every passing record lands `.lead`,
  never `.fact`. Hard fails still land `.impossible`.
- Test: rich subject (Ernest Cauldwell — full name + precise birth
  year) — verdicts unchanged from current behaviour; no record
  previously emitting `.fact` is downgraded.
- Test: wide-window subject (given name present, 27-year birth window
  from oldest-child fallback) — also `.thin` → `.fact` capped at
  `.lead`.
- Existing scorer test suite passes unchanged (no rich-subject
  regression).

**Rationale for verdict-cap over threshold-tightening:** Tightening
gate thresholds proportionally (the original draft) doesn't actually
help when the gates are *skipping* comparisons due to absent subject
data — a tighter Levenshtein floor on surname only kicks in when both
sides have a surname, and the date gate's tolerance is irrelevant if
there's no subject birth-year to compare against. Verdict-cap is the
surgical move that addresses the *false-fact* failure mode directly.
Candidate-count reduction (≤50 from ~3,000) belongs in dispatcher
work, not the scorer.

**Files:**
- `Ancestor Research/Services/Research/RecordScorer.swift` —
  density computation + verdict-cap branch.
- `Ancestor Research/Models/Research/InformationDensity.swift` (new)
  — `enum InformationDensity { case thin, rich }` + factory.
- `Ancestor Research Tests/Research/ThinProfileScorerTests.swift`
  (new) — density classification + verdict-cap behaviour.

**Out of scope for this change (deferred to #Change1b if needed):**
exposing density classification rules + cap behaviour via
`config.yaml`. In-code constants for now, with clear naming so the
move is mechanical when (or if) it becomes load-bearing.

### #Change2 — Round-1 best-candidate write-back to placeholder

After the first research round on a thin `@FR_…@` placeholder
completes, if the scorer emits **exactly one** `.supported` candidate
above the (now-raised, per #Change1) threshold, write that
candidate's `givenName` + tightened `birthYear` back to the
placeholder before the next research cycle. Subsequent searches
operate on a now-rich profile and use the tighter rich-profile gates.

This is the **thin → rich pipeline** that emerged from yesterday's
empirical finding #3.

**Rule:** Write-back fires only when:
- Scorer emits exactly one `.supported` candidate, AND
- That candidate's confidence exceeds a threshold pinned in
  `config.yaml`, AND
- The placeholder is still thin (write-back doesn't overwrite
  existing rich data — memory `feedback_check_before_overwrite.md`).

**Acceptance:**
- Thin HOLMES + single high-confidence FreeBMD candidate →
  placeholder updated with `givenName = "Jennifer"`, `birthYear`
  refined.
- Thin HOLMES + multiple candidates above threshold → no write-back;
  placeholder stays thin (split-don't-merge invariant).
- Thin HOLMES + zero candidates above threshold → no write-back.
- Write-back goes through the normal field-change audit path; the
  change is queryable in the audit log.

**Files:**
- `Ancestor Research/Services/Research/PlaceholderWriteback.swift`
  (new) — encapsulates the rule.
- `Ancestor Research/Services/Research/RunRequestWatcher.swift` —
  call site after first round.
- `Ancestor Research Tests/Research/PlaceholderWritebackTests.swift`
  (new).

**Depends on:** #Change1 (without it, "single high-confidence
candidate" is not well-defined).

### #Change3 — Profile dedup at promote-time

`promote_lead` currently INSERTs unconditionally. When the lead
matches a profile already present in the tree (the Jennifer Holmes
case from yesterday — already at `@I50100815@`, but
`promote_lead` created `@FR_2F7D…@`), the result is tree bloat and
research duplication.

**Rule:** Before INSERT, `promote_lead` searches the tree for a
matching profile. Match criteria:
- **Strict match:** lead and candidate profile both carry
  `givenName` → exact `surname` + `givenName` (case-insensitive)
  AND `birthYear` within ±2 of candidate → dedup. If exactly one
  strict match exists → return its `profileID`, no INSERT. If
  multiple strict matches exist → INSERT new (split-don't-merge).
- **Asymmetric soft match:** either the lead or the candidate
  profile lacks `givenName` (the empirical Jennifer Holmes case —
  surname-only lead vs. rich tree profile) → match on `surname` +
  birth-year overlap (within ±2). Dedup **only if exactly one**
  candidate matches; multiple matches → INSERT new
  (split-don't-merge per CLAUDE.md).
- **No match:** INSERT as today.

The decision (matched-existing vs new-insert) is logged in the audit
trail. When matched, the relationship edge (parent/spouse) is also
not duplicated — if `(from_id, to_id, type, role)` already exists,
no edge INSERT; otherwise insert the missing edge (the asserted
relationship from the lead may genuinely be new evidence).

**Acceptance:**
- Test: `promote_lead` for surname-only lead matching one existing
  rich profile (Jennifer Holmes case — lead lacks `givenName`,
  `@I50100815@` has `firstName="Jennifer"`, year matches) →
  returns existing `@I50100815@`, no profile INSERT.
- Test: surname-only lead matching two existing profiles (e.g.,
  two `Holmes` with overlapping years) → INSERT new (split).
- Test: strict match — lead with `givenName="Jennifer"` matching
  existing Jennifer Holmes → returns existing, no INSERT.
- Test: `promote_lead` for a name+date not present → INSERTs as
  today.
- Test: matched profile, edge already present → no edge INSERT.
- Test: matched profile, edge not present → edge INSERT.
- Audit log shows the dedup decision per call.

**Files:**
- `FieldResearcherMCP/Sources/FieldResearcherMCP/Tools/PromoteLead.swift`
- `FieldResearcherMCPTests/PromoteLeadDedupTests.swift` (new)

**Independent of #Change1 and #Change2** — can ship in parallel.

### #Change4 — Scorer-attrition logging at the periphery

There's no visibility into where Discovery expansion is tapering.
Without it, we can't tell if the natural brake (scorer rejection at
the periphery) is engaged or if the engine is silently producing
nonsense.

**Rule:** For each Discovery hop, the engine emits per-gate attrition
counts:
- Candidates entered
- Candidates cleared name gate
- Candidates cleared date gate
- Candidates cleared geography gate
- Candidates cleared kinship gate
- Final verdict distribution (`.supported` / `.inconclusive` /
  `.contradicted`)

Attrition is recorded in `ResearchResult` and surfaced on the
ActivityBus so the UI (or eval harness) can show "the brake is
engaged" or "this hop accepted everything, investigate."

**Acceptance:**
- `ResearchResult.attrition` populated for every hop.
- `AttritionEvent` flows on ActivityBus.
- Test: known thin-subject hop produces attrition counts that match
  the scorer's actual decisions.
- Persisted in the run snapshot so multi-day runs retain visibility.

**Files:**
- `Ancestor Research/Models/Research/ResearchResult.swift` — new
  `attrition` field.
- `Ancestor Research/Services/Research/RecordScorer.swift` — emit
  attrition data.
- `Ancestor Research/Services/Research/ActivityBus.swift` —
  `AttritionEvent`.

### #Change5 — Daily-budget awareness

Today, when FreeBMD's daily quota is exhausted, the source
circuit-breaker trips and the engine ladders 60s/300s/900s waits,
burning clock with zero progress. (Memory:
`reference_freebmd_circuit_breaker.md`,
`feedback_volunteer_sources_rate_limits.md`.)

**Rule:** Per-source daily-quota state is tracked explicitly. When
quota is exhausted:
- That source is marked `.pausedUntilTomorrow` (with `tomorrow`
  derived from the source's documented reset time, falling back to
  UTC midnight).
- The engine continues with non-paused sources — some progress beats
  no progress.
- ActivityBus emits `DailyBudgetExhausted` with the resume time.
- No 900s circuit-breaker laddering for budget-exhausted sources.

**Acceptance:**
- Simulate FreeBMD quota exhaustion → source pauses, FreeREG + CWGC
  + others continue.
- Resume time is queryable.
- Quota counters persist across process restart (#Change6 depends on
  this for multi-day runs).

**Files:**
- `Ancestor Research/Models/Research/SourceBudgetState.swift` (new).
- `Ancestor Research/Services/Sources/SourcePluginProtocol.swift` —
  new `pauseUntil` property.
- Each source plugin in `Services/Sources/` — wire up its known
  quota (FreeBMD has a documented daily limit; others are observed).

### #Change6 — Checkpoint/resume hardening

Snapshot exists in partial form. For multi-day sustained runs, it
must survive an overnight pause + process restart end-to-end without
reprocessing or losing facts.

**Rule:** The run snapshot captures enough state to resume at the
exact same `(profile, source)` pair where it left off. Resume is
idempotent — no double-fact-emission, no duplicate lead creation.

**Acceptance:**
- Test: kill mid-run after N profiles, restart, verify resume state
  matches the pre-kill state.
- Test: 6-hour wall-clock pause + restart, verify resume.
- Test: idempotency — resume the same checkpoint twice; second resume
  is a no-op.
- Snapshot is human-readable enough to debug a stuck run.

**Files:**
- `Ancestor Research/Services/Research/RunSnapshot.swift` — likely
  needs hardening.
- `Ancestor Research/Services/Research/RunRequestWatcher.swift` —
  resume logic.
- `Ancestor Research Tests/Research/RunSnapshotResumeTests.swift`
  (new).

### #Change7 — "Stop digging here" expansion bound

Without bounds, Discovery breadth-firsts into the entire reachable
tree, burning budget on peripheral 5th cousins while the core tree
still has gaps.

**Rule:** Expansion is bounded by one of two configurable policies:
- **Collateral depth** — `≤N` collateral hops from any proband
  (default: 2). Stops the walk from wandering down sibling-of-sibling
  branches.
- **Generational distance** — `≤M` generations from any seed
  (default: 4). Stops the walk from extending too deep at the
  periphery.

Both are queryable: "why didn't this lead promote?" returns either
"outside collateral bound" or "outside generational bound."

**Acceptance:**
- Synthetic tree with 5 generations → expansion halts at gen-4.
- Collateral-only expansion at depth 3 → halts at depth 2 from
  nearest proband.
- Bound is overridable in `config.yaml` per project.

**Files:**
- `Ancestor Research/Services/Research/ExpansionBounds.swift` (new).
- `Ancestor Research/Models/Research/ExpansionPolicy.swift` (new).
- `FieldResearcherMCP/Sources/FieldResearcherMCP/Tools/PromoteLead.swift`
  — bound check before INSERT.

**Depends on:** #Change2 + #Change3 (otherwise the bound is being
applied to work that's still drifting / duplicating).

### #Change8 — §14.B.1 defensive hallucination re-check

Currently, the MCP auto-approval write path refuses by default
(memory: `feedback_auto_approval_gated_off.md`). Before any
non-developer Discovery run is safe to ship, the engine must
re-fetch the cited URL and verify the source actually contains the
claimed evidence. Implements the §14.B.1 gate from
`RESEARCH_PIPELINE_SPEC.md` Part I.

**Rule:** Each auto-approval candidate triggers:
1. Re-fetch of the cited URL (using the existing page-cache; polite,
   no extra rate cost on cached pages).
2. Re-extraction of the specific claim from the re-fetched page.
3. If re-extraction matches the original claim → approve.
4. Else → bounce back to `pending_facts` with a hallucination flag.

**Acceptance:**
- Planted hallucination (MLX claims a fact that doesn't exist on
  the cited page) → bounce fires.
- Real claim → approve fires.
- Re-fetch hits the page cache when available; no double-fetching.
- Audit log records the re-check decision per claim.

**Files:**
- `Ancestor Research/Services/Research/EvidenceFirewall.swift`.
- `Ancestor Research/Services/Research/HallucinationRecheck.swift`
  (new).
- `Ancestor Research Tests/Research/HallucinationRecheckTests.swift`
  (new).

**Independent of all of the above.** Required before any non-dev
Discovery shipping.

---

## 3. Sequencing

| Phase | Changes | Why this order |
|---|---|---|
| **A — Placeholder rehabilitation** | #Change1, #Change3 (parallel), then #Change2 | Engine correctness first. #Change2 depends on #Change1's tightened gates. #Change3 is independent — can ship alongside. |
| **B — Engine self-knowledge** | #Change4 | Cheap. Builds trust in the changes from Phase A. |
| **C — Sustained-run infrastructure** | #Change5, #Change6 (parallel), then #Change7 | All needed for multi-day runs. #Change7 should land after A+B so it bounds clean work, not drifting work. |
| **D — Shipping gate** | #Change8 | Independent of all above. Required before non-dev shipping; can ship alongside any phase. |

Estimated total: 6–8 focused sessions.

---

## 4. Acceptance for the spec as a whole

When this spec is shipped:

1. **Re-running the 87-profile Discovery** produces a dedup'd tree
   with rich (not surname-only) profiles for any subject the engine
   can resolve confidently — the Jennifer Holmes case no longer
   creates an `@FR_*HOLMES@` placeholder.
2. **A sustained-enrichment run** survives an overnight pause +
   process restart with no double-fact-emission.
3. **A planted hallucination** is caught by §14.B.1 re-check and
   bounced to `pending_facts` for human review.
4. **Scorer attrition** is visible per-hop in the run snapshot,
   showing where on the periphery expansion is tapering.

When all four hold, the engine is ready for the deferred work in
`PROSE_CORPUS_SPEC` Phase B, `FAMILYSEARCH_SOURCE_SPEC` content
surface, `SOURCE_MEDIA_SPEC`, `KINSHIP_SPEC` #Change3–5, and
`RESEARCH_PIPELINE_SPEC` Part II — and for non-developer Discovery
shipping.

---

## 5. Non-changes

To prevent scope creep, the following are explicitly **not** in this
spec:

- New source plugins.
- UI / wizard work.
- Bio synthesis or narrative generation.
- Image / media capture.
- Kinship fan-out (`find_spouses`, `discover_kin`,
  `verify_relationship`).
- Hypothesis-framework V2 architecture (T7/T8/T9/T11/T12/T23/T31).
- Anything that requires MLX behaviour changes beyond what
  #Change8's re-check needs.

Anything that doesn't fit in the eight changes above is out of
scope. Adding a ninth change requires a spec amendment.
