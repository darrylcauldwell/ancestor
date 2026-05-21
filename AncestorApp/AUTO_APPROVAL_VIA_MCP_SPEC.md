# Auto-Approval via MCP Spec

Expose **rule-based fact approval** through the MCP server so the
deterministic scoring system can commit pending facts that pass an
unambiguous-confidence gate, without requiring a human keystroke per
fact.

The Evidence Firewall is not removed by this — it is **narrowed**. AI
still cannot decide what is true; rules still decide what is true; the
change is that rules now have *authority to commit* their verdict when
the verdict is unambiguous. Humans become supervisors of the rules,
not gatekeepers of every fact.

## Mission

The scoring system has matured to the point where, for many incoming
facts, the human review step is a rubber stamp. After an overnight
research run, the user faces a backlog of 47 pending facts of which
maybe 35 are obvious confirms of what the structured pipeline already
established with multiple independent sources. Asking the user to
click "Accept" 35 times costs attention without adding judgement.

This spec defines the conditions under which a fact can be committed
**by the rules acting through MCP**, leaving the user to focus on the
12 facts that genuinely need a human eye.

## Doctrine

The deterministic-sandwich principle has been:

> AI proposes. Rules decide.

This spec extends it to:

> AI proposes. Rules decide. **For unambiguous decisions, rules commit;
> for ambiguous ones, rules escalate to human review.**

The firewall is unchanged in shape — AI still does not write to
profiles directly. The MCP tool that performs auto-approval is not AI
deciding to commit; it is the rules acting on the rules' own verdict,
exposed through MCP so the harness can drive it.

## Hard principles

1. **Rules' authority extends to commit on unambiguous decisions
   only.** "Unambiguous" is defined precisely below; ambiguous facts
   stay in `pending_facts` for human review exactly as today.
2. **Every auto-approval is reversible, visible, and audit-traceable.**
   The user must be able to see what was committed without their
   keystroke and undo any of it without consequence.
3. **The user is supervisor, not gatekeeper.** They no longer touch
   every fact, but they retain final authority — they can disable
   auto-approval, narrow its scope, undo decisions, and investigate
   the rule trail behind any committed fact.
4. **Geography independence preserved.** The auto-approval gate
   derives its decisions from convergence + trust-tier + dispute
   criteria, never from hard-coded region knowledge.
5. **Conservative by construction.** Where the criteria are uncertain,
   default to human review. A fact that *might* qualify but doesn't
   clearly qualify stays in `pending_facts`. False auto-approvals are
   the failure mode to avoid; missed auto-approvals are merely
   throughput loss.
6. **MCP-side criteria are a subset of in-app review.** The MCP gate
   is simpler than the full app's review surface. Anything the MCP
   tool refuses can still be human-reviewed; nothing the MCP tool
   approves bypasses any check the human-review path would have run.

## The auto-approval gate

A pending fact qualifies for auto-approval **only if all** of the
following hold. Failure of any single condition routes the fact to
normal human review.

### 1. Source trust

The fact's source (from `pending_facts.source_url`, classified via
`SourceTierRegistry`) must be of tier **`primary`** or **`secondary`**.
Tertiary, derivative, and community-curated sources are *insufficient*
for auto-approval — they can still be accepted by a human, but the
rules will not act on them unilaterally.

### 2. Convergence with the existing tree

The fact must reach **at least `.confirmed`** convergence when its
proposed value is combined with whatever the profile already has for
the same field:

- If the profile already has the same value from an independent source
  in `field_sources`, the pending fact is corroborating — `.confirmed`
  if combined independence count ≥ 3, `.probable` if 2 with high
  trust, falling through otherwise.
- If the profile has *no* existing value for this field, the pending
  fact alone must reach `.confirmed` from its sources to qualify. In
  practice this requires the fact to have been submitted with multiple
  independent corroborating source URLs (an unusual but possible case
  for high-quality MCP-supplied evidence).

The `ConvergenceEngine` computes this; the MCP-side evaluator
re-implements the same lineage / trust / directness math
(deliberately conservative) since the FieldResearcherMCP package can't
import the app's research module today.

### 3. No dispute would be created

The fact's proposed value must not contradict an existing value on the
profile. If the profile has `birthDate = 1820` and the pending fact
proposes `birthDate = 1822`, auto-approval is **blocked** — committing
would create (or extend) a `FieldDispute`, which is exactly the kind
of judgement call a human must make.

Detection: query `field_sources` for the same `(entity_id, field)`
and check whether any existing `raw` value is meaningfully different
from the proposed value. The comparator is field-aware:

- **Dates** — different to the `GenealogicalDate.parsePreview`-canonical
  level (1820 ≠ 1822, but "21 Dec 1820" == "December 21, 1820").
- **Locations** — different at the canonical-place-code level when
  available, otherwise fall back to trimmed string comparison.
- **Strings (occupation, etc.)** — case-insensitive whitespace-trimmed
  comparison.

A value that differs from the existing one but is *less specific*
(e.g. "Derbyshire" when existing is "Cromford, Derbyshire") is treated
as **conflicting** for auto-approval purposes — the user should decide
whether to record the broader value as an alternative or upgrade the
existing one. Auto-approval doesn't make that call.

### 4. Field is in the auto-approvable set

Some fields are higher-stakes than others. Auto-approval applies only
to a defined subset:

**Auto-approvable when the rest of the gate passes:**
- `birthDate`, `birthLocation`
- `deathDate`, `deathLocation`
- `marriageDate`, `marriageLocation`
- `occupation` (as a life-event detail, when the gate criteria apply)
- `address` (likewise)

**Never auto-approved** (always human-reviewed regardless of evidence):
- `firstName`, `middleName`, `lastName`, `marriedSurname`, `nickName`,
  `mothersMaidenName` — name corrections shape identity; even strong
  evidence deserves a human look (transcription errors, conflated
  individuals).
- `gender` — identity-shaping; the upside of automation is not worth
  the downside of an incorrect commit.
- `bio` — narrative, not a fact (see `BIO_SYNTHESIS_SPEC.md`); never
  goes through this pipeline.

The set is small and conservative on purpose. It can expand over time
as confidence in the gate is earned, but expansion is an explicit
design decision per field, not a quiet default.

### 5. Hallucination checks have passed

The Evidence Firewall's existing checks (URL verification, source-tier
plausibility, hallucination rules) must already have passed before the
pending fact reaches the auto-approval gate. The MCP tool re-runs
those checks defensively — failure of any is treated identically to
gate failure (no auto-approval; human review path unchanged).

## MCP tool surface

Three tools, in order of priority:

### `approve_pending_fact(pending_fact_id) → result`

Single-fact primitive. Loads the pending fact, runs the gate
evaluator, and either commits or refuses with reason.

```jsonc
// Request
{ "pending_fact_id": "abc123" }

// Success
{
  "status": "approved",
  "profile_id": "@I1234@",
  "field": "birthDate",
  "value": "1820",
  "criteria_met": {
    "trustTier": "primary",
    "convergence": "confirmed",
    "independentSourceCount": 3,
    "wouldCreateDispute": false,
    "fieldAutoApprovable": true
  },
  "committed_at": "2026-05-21T14:32:00Z"
}

// Refusal
{
  "status": "refused",
  "reason": "convergence_insufficient",
  "detail": "Only 1 independent source lineage; need ≥ 2 for primary or ≥ 3 for non-primary trust tiers.",
  "still_pending": true
}
```

Refusal reasons (enumerated for testability):
- `trust_tier_insufficient` — source not primary/secondary
- `convergence_insufficient` — independence / trust math doesn't reach `.confirmed`
- `would_create_dispute` — existing field value disagrees
- `field_not_auto_approvable` — name / gender / bio
- `hallucination_check_failed` — defensive re-run of firewall
- `pending_fact_not_found`
- `pending_fact_already_processed`

### `inspect_approval_decision(pending_fact_id) → decision`

Dry-run. Same evaluation as `approve_pending_fact` but commits
nothing. Returns the verdict the rules would render. Used by Claude
Code to preview before committing, and as the basis for "what is
queued for auto-approval right now" diagnostics.

### `auto_approve_qualifying(profile_id?, dry_run?) → batch_result`

Bulk operation. Iterates pending facts scoped to a profile (or all if
omitted), runs the gate on each, returns the list of committed +
refused + reason. When `dry_run: true`, returns what *would* commit
without writing.

Useful for clearing a backlog in one harness invocation, and useful
for the user's own audit (run dry-run, see the proposed approvals,
then commit).

## DB schema additions

Migration adds three nullable columns to `pending_facts`:

```sql
ALTER TABLE pending_facts ADD COLUMN approval_method TEXT;       -- 'user' | 'rules'
ALTER TABLE pending_facts ADD COLUMN approval_rule_ids TEXT;     -- JSON array of gate criteria that passed
ALTER TABLE pending_facts ADD COLUMN approved_at DATETIME;       -- distinct from reviewed_at
```

- `approval_method` is `NULL` while the row is pending; set to
  `'user'` or `'rules'` on acceptance. `'rules'` implies committed via
  this spec's MCP tool.
- `approval_rule_ids` records *which* gate criteria the rules
  evaluated to true at commit time — supports retrospective audit and
  the spec's reversibility guarantee.
- `approved_at` is distinct from `reviewed_at` because the latter
  exists today and is documented as "user review timestamp". Keeping
  them separate preserves the existing semantics while letting us
  query auto-approvals cleanly.

`field_sources` also gains a marker. Rather than introducing a new
`SourceOrigin` enum case (which would ripple through every site that
switches on origin), reuse the existing `created_by_transaction_id`
slot: auto-approvals create a minimal `transactions` row of kind
`autoApproveFact` and the `field_sources` row references it.
Distinguishing "user-accepted pending fact" from "rule-accepted
pending fact" then becomes a join on `transactions.kind` — clean,
audit-friendly, no schema bloat.

The existing path that accepts a pending fact via the UI (which today
creates **no** transaction row) should be updated to also create a
transaction, of kind `userAcceptPendingFact`, for symmetry — that way
all acceptances live in `transactions` with a kind discriminator. This
is a small adjacent improvement worth bundling.

## Audit & visibility

The user must be able to answer "what did the rules commit on my
behalf, and why?" without spelunking SQL.

### App-side surfaces (Phase 2 — deferred from MVP)

- **Pending facts review screen** — already shows the inbox. Add a
  secondary tab or filter "Auto-approved" listing facts the rules
  committed since the user last opened the app, with the rule trail
  visible per row.
- **Inspector card source badges** — already render source-origin
  pills (GEDCOM, MANUAL.MEMORY, etc.). Add a subtle "rules"
  decoration on field-source rows whose creating transaction is of
  kind `autoApproveFact`, so the user can see at a glance which
  facts came in without their touch.
- **Undo affordance** — each auto-approved fact can be reverted with
  a single action. Reversal is a normal undo through the existing
  transactions/field_changes machinery — no new undo path is needed
  if we route auto-approval through the transaction system as above.

### MCP-side surfaces (for harness use, MVP)

- `inspect_approval_decision` doubles as audit — Claude Code can
  query "what would have happened" for any pending fact.
- A simple read endpoint `list_recent_auto_approvals(since?)` is
  worth adding so the harness can summarise activity for the user.

## Reversibility

By design, an auto-approved fact is reversed exactly as a
user-accepted fact would be:

1. The acceptance is recorded as a `transactions` row of kind
   `autoApproveFact` linked to the resulting `field_sources` row(s)
   and any `field_changes` rows representing the profile-column
   write.
2. Undo replays the transaction backward (per the existing
   `undo_strategy` field): the field-source row is removed, the
   profile column reverts to its prior value, and the original
   `pending_facts` row returns to `review_status = 'pending'` for
   the user's attention.

No new undo machinery is introduced. The reversibility guarantee
comes from routing auto-approval through the same transaction system
that already supports undo for everything else.

## Implementation order

### MVP (this commit)

1. **Migration** — add the three pending_facts columns and add the
   new `autoApproveFact` and `userAcceptPendingFact` kinds to the
   transactions enum.
2. **MCP evaluator** — Swift code in the FieldResearcherMCP package
   implementing the gate (trust tier check, convergence count,
   dispute detection, field-set check). Conservative subset of the
   app's full convergence engine.
3. **MCP tools** — `approve_pending_fact`, `inspect_approval_decision`,
   `auto_approve_qualifying` registered in `MCPServer.swift`.
4. **Tests** — unit tests over the evaluator covering each refusal
   reason and the happy path; integration test that asserts an
   approved fact lands in both `profiles` and `field_sources` and is
   marked correctly in `pending_facts`.
5. **App-side: update manual acceptance** to create the symmetric
   `userAcceptPendingFact` transaction so all acceptances are
   auditable through the same machinery.

### Phase 2 (separate work, separate commit)

- App-side surfaces (auto-approved tab in pending review, marker on
  source badges, undo affordance for auto-approved facts).
- Harness scripts / Claude Code commands that drive the MCP tools
  with sensible defaults.
- A user-toggleable preference for *whether* auto-approval is
  enabled at all (off by default until trust is earned in real use).

## Out of scope

- Auto-approving relationships, life events, or attachments — these
  carry more structural weight than scalar field values, and their
  approval paths are non-uniform today. Revisit in a separate spec
  once the field-value path has run for a while.
- Auto-rejecting at the other end of the confidence spectrum
  (low-confidence facts auto-discarded) — out of scope here. Failing
  the gate routes to human review, never to rejection.
- Background daemons / scheduled auto-approval runs — there is no
  app-side timer or background task. Auto-approval is invoked
  explicitly via MCP, by the harness, when the user wants to drain
  their backlog.
- AI judgement about *whether* a pending fact qualifies for
  auto-approval. The decision is pure rule application; no LLM is
  asked.

## Cross-references

- `feedback_firewall_sqlite.md` — the firewall this narrows.
- `Ancestor Research/CLAUDE.md` — Evidence Firewall, deterministic
  sandwich principles.
- `RESEARCH_PIPELINE_SPEC.md` — established the pipeline this extends.
- `BIO_SYNTHESIS_SPEC.md` — unaffected; bios remain narrative and
  outside this spec's scope.
- `SOCIAL_HISTORY_CORPUS_SPEC.md` — unaffected; corpus material is
  also outside this spec's scope (it's not field-value evidence).
