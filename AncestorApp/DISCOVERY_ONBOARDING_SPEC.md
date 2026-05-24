# Discovery Onboarding — "Build me a tree" Specification

Status: drafting · Author: 2026-05-25, session-end after the four-cluster validation + tonight's overnight bring-up

This document specifies a new onboarding mode in which the app's
deterministic research pipeline grows a tree outward from a single
named ancestor while the user sleeps, then presents the results for
review. It also names the architectural pattern that tonight's work
exposed — **MCP-as-agent-surface** — and re-frames the May 2026
decision to remove the in-app Claude API "Field Researcher" against
that pattern.

---

## 1. Why this matters now

Three observations from tonight's session forced this spec into
existence rather than letting it sit as a roadmap line item.

1. **The MVP already runs.** With clusters #1 + #2 landed (commits
   `0b75b5f`, `514ad20`, `6bc5c5e`) and `promote_lead` added to the
   MCP surface (commit `aece608`), an external Python driver
   (`overnight_discovery.py`) successfully BFS-walks a 15-person
   seed, auto-approves trust-tier evidence, and promotes
   father/mother/spouse leads to real profiles + edges — all
   autonomously, with no human in the loop overnight. Tonight is
   the proof of concept; the question is whether to surface it as a
   first-class product.

2. **It's a meaningfully different pitch.** Every existing genealogy
   product (Ancestry, MyHeritage, FamilySearch) requires the user to
   build the tree themselves; "hints" then surface matches against
   what they've manually entered. Discovery Onboarding inverts this:
   the user names one deceased ancestor, the engine builds the tree
   it thinks is right, the user reviews. Nothing else in the market
   does this with a local pipeline + audit trail.

3. **The MCP surface reframes the SaaS-AI question.** The in-app
   Field Researcher (Claude API embedded in the shipped app) was
   removed in May 2026 (per `CLAUDE.md`) to make App Store
   submission cleaner and keep all inference local. But what we
   built tonight is *not* an embedded AI — it's an **external
   orchestrator** speaking to the app through a constrained MCP tool
   surface. The app stays local-only and shipping-ready; the
   coordinator AI (Claude Code in our case, but trivially
   substitutable for any LLM that speaks MCP) sees only what tools
   explicitly expose. That's a different security/privacy posture
   from what the prior decision rejected. Section 5 below treats
   the implications.

---

## 2. The product flow

### 2.1 Seeding

A new user opens the app, picks "Start a discovery" (vs the existing
"Import GEDCOM" / "Start from yourself" options). The wizard asks
for **one named deceased ancestor**:

- Given + surname (required)
- Approximate birth year (required, ±10y tolerance)
- Approximate death year (optional)
- Home county / region (required, picks UK county; default = the
  current `home_chapman_code` config)
- Gender (required — drives the dispatcher's source axis)

**Why deceased.** The engine's `livingPrivate` gate
(commit `4b0dd4b`) correctly refuses to research living people —
records under living-privacy embargoes aren't available in any
public source. The wizard must coach the user toward a known
deceased ancestor (typical: a grandparent or great-grandparent),
explaining that the user themselves can be added later by linking
through their researched ancestors.

### 2.2 The night-time run

Once seeded, the wizard offers two run shapes:

- **"Build now"** — runs synchronously while the user watches a
  progress view, capped at e.g. 30 minutes / 25 profiles. Useful
  for the curious; useful for marketing demos.
- **"Build overnight"** — kicks off the same driver as tonight's
  proof-of-concept, capped at 8 hours / 200 profiles. User can
  close the laptop lid? No: needs `caffeinate -s` per tonight's
  experience. The wizard explains and offers a one-click "keep
  awake" toggle that triggers `caffeinate` internally.

Per-profile workflow (mirrors `overnight_discovery.py`):
1. `kick_off_research(profile_id, mode='extend')` via MCP.
2. Watcher runs the deterministic pipeline (same 4-gate scorer,
   same source plugins).
3. After completion, pending facts whose `source_url` host is in
   `APPROVE_HOSTS` get auto-approved via `approve_pending_fact`.
4. Leads with `relationship ∈ {father, mother, spouse}` and
   non-trivial evidence get promoted via `promote_lead`,
   creating new `@FR_…@` profile IDs and edges.
5. Promoted IDs enqueue for BFS expansion.

### 2.3 The validation morning

The user wakes up to a tree with N new profiles and M new facts.
The validation UX is **the load-bearing piece** of this spec — without
it the auto-approved evidence is opaque and trust collapses.

Three layers, each existing in the app today but scattered:

1. **Cluster review** (`ClusterReviewView`) — already gates
   over-split / over-merge candidates. Discovery-mode result: a
   cluster of similar-shaped profile candidates the engine
   couldn't disambiguate by itself.
2. **Pending facts review** (`PendingFactsReviewView`) — already
   shows pending evidence. Discovery-mode result: the residue of
   tier-3 sources (FamilySearch, FAG) that didn't auto-approve.
3. **Lead list** (`LeadListView`) — already shows non-promoted
   leads. Discovery-mode result: sibling / cousin / child leads
   the engine flagged but couldn't promote (because they were
   `child` or `sibling` relationships, or had thin evidence).

The Discovery Onboarding wraps these in a guided "review what we
found" tour: cluster decisions first (highest-impact, fewest
items), then pending facts (medium volume), then leads queue
(highest volume, lowest individual stakes). Each step shows the
exact evidence and lets the user accept/reject in batches.

---

## 2.5 Tonight's empirical finding — the actual blocker

The PoC overnight run (2026-05-24, log
`eval/runs/overnight-2026-05-24T22-08-54Z.jsonl`) demonstrated that
the architectural plumbing works end-to-end — `kick_off_research` →
`approve_pending_fact` → `promote_lead` chain executes against a
fresh project — but tree expansion did **not** happen. Root cause
isolated:

`LeadStore.createFromScoredRecord` (in
`Ancestor Research/Services/Research/Lead.swift:77`) always sets
`relationship: nil`. This is the path every scored-record-derived
lead takes during research, called from `RunRequestWatcher` and
`ResearchViewModel`. Of the 90 leads emitted during tonight's run
across 7 researched seeds, every single one had
`relationship = nil`. The `promote_lead` gate refuses
empty-relationship leads (no way to derive gender or edge
direction safely), so the driver's promotion loop ran 0 times.

The fix is small but contested between two approaches:

**Approach A — Pass relationship through existing callers.**
Add an optional `relationship: String?` parameter to
`createFromScoredRecord`. Update the two real callers
(`ResearchViewModel.swift:307`, `RunRequestWatcher.swift:395`) to
pass it when they know — e.g. a marriage-record dispatcher knows
bride vs groom; a parent-inference path knows father/mother.
Generic "scored record I couldn't merge" leads stay nil-relationship
(no false certainty).

**Approach B — Separate emitter for inference-aware leads.**
Leave `createFromScoredRecord` alone (it's correctly "generic
candidate person, no kin context"). Add a parallel
`createFromParentInferredHypothesis` that's only called from
`HypothesisEngine+ParentInferred` when a `.parentInferred(gender,
surname)` hypothesis grades `.supported` and has an associated
best-evidence record. Emits a lead with `relationship` =
`gender == .male ? "father" : "mother"`. Tree expansion comes from
THIS path; the existing scored-record leads remain the "manual
review" pile.

Approach B is cleaner — it doesn't muddy the generic emitter and
it makes the autonomous-promotion path explicit. Recommendation:
land approach B as the very first concrete step of #Change3 below.

## 3. Required precursors

Three pieces of work must land before Discovery Onboarding can ship
to non-developer users.

### 3.1 §14.B.1 — Defensive hallucination re-check

The current `approve_pending_fact` gate (and the new `promote_lead`
gate) validate rule compliance — source trust tier, no would-be
dispute, etc. They do **not** validate that the `evidence_text` the
submitter cited actually appears in the source URL. For tonight's
session this is acceptable because the submitter is the deterministic
Swift research pipeline reading actual source HTML; for a shipping
product where any MCP client might submit evidence, the gate must
re-fetch the URL at approve-time and verify the cited text exists.

Memory `feedback_auto_approval_gated_off.md` already names this gap.
The fix is well-scoped: add a URL-fetch step to `evaluateApproval`,
hash the relevant content region, compare against the submitter's
evidence text. Refuses with `defensive_recheck_failed` if mismatched.
~M-sized work.

### 3.2 Living-person seed handling

The wizard must detect when the user is seeding themselves (or
someone clearly living — birth year > current_year - 90) and steer
them toward a known deceased ancestor instead. Two paths:

- **Hard guard**: refuse to start research, explain via copy.
- **Soft pivot**: ask "do you know a grandparent who has passed?"
  and re-seed.

Soft pivot is friendlier but adds a wizard branch. Hard guard ships
faster.

### 3.3 Throttle-aware pacing

Tonight's driver detects FreeBMD's circuit breaker (1300s+ runtime
with zero supported hypotheses) and sleeps 2 hours. For a shipping
product this is too crude — the engine needs to surface throttle
state to the wizard ("FreeBMD is rate-limited, we'll resume in
~21 minutes") and the driver needs a more sophisticated back-off
ladder. Also: the wizard should warn before starting a Discovery
that exceeds the day's volunteer-source budget, particularly for
trees that fan out wide (e.g. cousins from a 19th-century
yeoman-farmer ancestor).

---

## 4. Change list

Per the project's spec-driven convention, work attributes to numbered
changes referenced in commit messages.

- **#Change1 (S):** wizard UI for seeding (one deceased ancestor with
  county, gender, year ranges). Lives under `Views/Onboarding/`. The
  existing onboarding wizard is the pattern.
- **#Change2 (S):** living-person seed guard. Implements §3.2 hard
  guard. Living = birth_year > current_year - 90 OR death_year not
  set.
- **#Change3 (M):** in-app driver. Ports `overnight_discovery.py` to
  Swift as `DiscoveryService`, wires it to the MCP write paths
  (`approve_pending_fact`, `promote_lead`) but called in-process
  rather than via stdio. Keeps the same caps + state persistence.
- **#Change4 (M):** §14.B.1 defensive hallucination re-check —
  prerequisite for ungating the auto-approve env var by default.
- **#Change5 (S):** wizard "keep awake" toggle that wraps the
  driver in a `caffeinate -s` assertion lifetime.
- **#Change6 (M):** Discovery-mode validation tour (the guided
  cluster → pending facts → lead review walk). Re-uses existing
  views.
- **#Change7 (S):** throttle-state surfacing to the wizard.
- **#Change8 (M):** synchronous "Build now" mode (capped run with
  progress UI).
- **#Change9 (S):** copywriting + empty-state for the seeding UI.
  Coach the user toward "name a grandparent who has passed."

Estimated S/M sizing per project convention (one commit / half-day).

---

## 5. MCP-as-agent-surface — architectural implications

Tonight's session exposed something that wasn't obvious when the
in-app Field Researcher was removed in May 2026: the
`FieldResearcherMCP` package, originally framed as developer-only
tooling (per `CLAUDE.md`: "Standalone Swift Package … exposes
resources/tools to Claude Code as MCP server. Not shipped in the
app, makes no outbound network calls"), is in fact a **constrained
agent surface** that any LLM speaking MCP can drive.

The previous mental model was:

> Embedded AI = SaaS dependency in shipped app = privacy risk +
> App Store complication. Conclusion: ship local-only.

The actual architecture this enables is:

> App stays local-only (no embedded AI). External coordinator AI
> (run by the user, opt-in, never bundled) drives the app via MCP
> tools. App sees only what the tools accept; AI sees only what
> the tools return. Evidence Firewall stays intact.

This is a **different decision** from the original Field Researcher
removal. The Field Researcher embedded Claude in the app's process
space with access to in-memory state. The MCP coordinator pattern
isolates the AI to a tool-call interface; the same firewall that
protects against malicious or hallucinating MCP clients (the §14
gate, the §14.B.1 re-check) protects against any coordinator AI.

### 5.1 What this enables

- **Discovery Onboarding** (this spec) — primary use case.
- **Audit drill-down explainer** — a coordinator AI reads the audit
  output, calls `get_profile` + `find_path` + `search_profiles` to
  build context, narrates "your audit flagged X because Y, here's
  what to do about Z" in plain prose. Doesn't need to write
  anything.
- **Research assistant** — user asks "fill in missing details for
  this profile," coordinator AI fires `kick_off_research`,
  monitors `get_run_status`, calls `approve_pending_fact` for
  defensible hits, narrates the result.
- **Hypothesis chaser** — given a `.parentInferred` hypothesis the
  engine couldn't resolve deterministically, the coordinator AI
  proposes additional searches via `submit_lead` /
  `submit_evidence` for the user to review.

### 5.2 What this does *not* re-enable

- **Embedded Claude in the shipped app** — still off-limits for
  App Store reasons + privacy posture.
- **Auto-approval of AI-submitted evidence without §14.B.1** —
  the URL-refetch verifier is the load-bearing safety, not the
  fact that the submitter is an AI vs the deterministic pipeline.
- **Direct DB writes by the coordinator AI** — the MCP surface
  funnels everything through pending_facts / leads /
  pending_relationships review queues by design. No tool today
  bypasses this; none should.

### 5.3 Distribution model

A sophisticated user could connect their own Claude / GPT / local
LLM to the shipped app's MCP server. The app would expose the same
tools to any MCP client. This is the **"genealogy tools as an
agent surface"** framing — and it's already true; tonight's
session was just the first time we used it that way.

The product question (vs the architectural one) is whether the app
ships with a default coordinator (e.g. a hosted Claude-backed
Discovery service) or stays BYO-LLM. The first sells better; the
second is a cleaner privacy story. They're not mutually exclusive
— the MCP server doesn't care who connects.

---

## 6. Non-goals (this spec, this round)

- Building a hosted coordinator service. The Python driver from
  tonight is enough proof; productising the hosted side is a
  separate spec.
- Auto-creating `child` or `sibling` profiles via `promote_lead` —
  the gender / edge-direction ambiguity makes these high-risk for
  autonomous promotion. Stays manual via the leads queue.
- MLX coordinator integration. The local MLX model serves a
  different role (in-pipeline reasoning per Tiered Architecture
  memory). Putting it in the coordinator seat is conceivable but
  out of scope here.
- Replacing the existing onboarding wizard. Discovery is a third
  option alongside "Import GEDCOM" + "Start from yourself" —
  additive, not a replacement.

---

## 7. Open questions

- **Pricing model.** If a hosted coordinator service ships, who
  pays for the LLM call budget? Per-tree-grown? Subscription?
  This is a business question not a technical one but informs
  the distribution-model decision in §5.3.
- **Validation-tour skip semantics.** A user who declines to
  review the morning results — does the tree they wake up to
  still contain the auto-approved facts? Probably yes (they
  passed the deterministic gates) but the cluster decisions
  and pending facts may need a default ("auto-defer until
  reviewed" vs "auto-accept after N days").
- **Privacy on the seed.** A seed of "John Smith, b.~1850,
  Belper" is genealogically benign. A seed of "[living user
  full name], b.1992" is PII. The wizard's living-person guard
  in §3.2 covers the engine side; copy + storage of the seed
  itself need explicit handling.
- **Failure-mode disclosure.** Engine emits 38/31 supported
  cells on a 12-subject corpus today (post-tonight). For a new
  user that means the engine is approximately right but
  over-claims on some kinds. The wizard copy must set
  expectations: this is not Ancestry's polished consumer
  product, it's a deterministic-first research tool that shows
  its working.

---

## 8. Proof points captured tonight

Concrete artefacts to reference when this spec lands as work:

- `extract_discovery_seed.py` — 15-person seed extraction from
  twin-export GEDCOM. Demonstrates the seed-shape input.
- `populate_discovery_project.py` — direct sqlite seeding with
  derived `married_surname`. Demonstrates the project bootstrap.
- `overnight_discovery.py` — BFS driver. Demonstrates the
  coordinator pattern end-to-end.
- `FieldResearcherMCP/Sources/MCPServer.swift` `promote_lead` —
  the lead-to-profile promotion tool that closed the autonomous-
  expansion gap.
- `eval/runs/overnight-2026-05-24T22-08-54Z.jsonl` — tonight's
  run log, which the morning post-mortem will use to grade
  whether the MVP is real.

These all exist on `main` as of 2026-05-25. If this spec is
adopted, they become the seed for the in-app implementation
under #Change3.
