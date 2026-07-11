# Swift MCP Eval Backend Spec

**Status:** Shipped — Epic 1 (#Change1–9) closed 2026-05-24; the swift-mcp eval harness is operational and has run full-corpus parity passes since. As-built reference (archived 2026-07-11).

## 1. Why this spec exists

The §5.8 eval harness measures `agent.pipeline.research_person` —
the *Python reference* implementation per CLAUDE.md. The Swift app
in `Ancestor Research/Services/Research/` is what ships, and it's
where every fix landed in Python this session must ultimately be
ported. Today the harness has no way to measure the Swift pipeline,
so:

- Bug fixes that land in Python don't have validation that the
  Swift port preserved the behaviour.
- Drift between the two implementations can only be caught by ad-hoc
  `compare_twins.py` runs, which check end-state graph parity, not
  per-subject pipeline output.
- The corpus's per-kind agreement metric measures Python only; the
  Swift product has no measured baseline.

This spec defines `--backend swift-mcp` — a harness backend that
drives the Swift pipeline via the existing `FieldResearcherMCP`
server and returns envelopes the harness's existing metric logic
can consume unchanged. The corpus YAMLs, citation matcher, per-kind
metric, and reporting all stay as-is.

## 2. Scope

**In scope:**
- A new `_swift_mcp_pipeline_call(subject) → envelope` in
  `eval/run_harness.py` selected via `--backend swift-mcp`.
- Whatever Swift-side additions are needed to make the existing
  `FieldResearcherMCP` server return envelope-shaped data:
  - Verdict emission (parent_link, identity, spouse) in
    `ResearchResult`, mirroring Python `agent/pipeline.py`'s
    `_emit_*_verdict` helpers.
  - A new `get_research_result(run_id)` MCP tool that returns the
    envelope.
- A bootstrap path for the test SQLite database (the MCP server's
  argv[1]) so the harness can self-provision rather than relying on
  manual app-driven import.

**Out of scope (deferred to follow-ups):**
- App-driven GEDCOM import as a programmatic step. V1 uses a
  pre-provisioned test database stored under a documented path.
- Performance optimisation. V1 polls `get_run_status` every few
  seconds and accepts the latency cost.
- Full parity tooling (auto-diffing Python envelope vs Swift
  envelope for every subject). That's a useful follow-up once both
  backends produce envelopes.
- Multi-subject parallelism inside one MCP server instance. V1 runs
  subjects serially.

## 3. Bridge contract

The harness invokes the backend per subject. The Swift backend needs
to do four things per call:

1. **Enqueue research** — `kick_off_research(profile_id=<id>,
   mode="extend", scope="county")` returns `{ request_id }`.
2. **Poll for completion** — `get_run_status(request_id=<id>)`
   returns `{ status, run_id, ... }`. Poll every 3 seconds until
   `status == "completed"` or a timeout (default 5 min per subject).
3. **Read structured result** — `get_research_result(run_id=<id>)`
   (new tool) returns the envelope:

   ```json
   {
     "supported_hypotheses": [
       { "kind": "...", "value": "...", "sources": [...], "confidence": "..." }
     ],
     "contradicted_hypotheses": [ { "value": "...", "reason": "..." } ],
     "inconclusive_hypotheses": [
       { "kind": "...", "summary": "...", "source": "...", "reasons": [...] }
     ],
     "discovered_citations": [ "..." ],
     "parent_link_verdict": "supported" | "contradicted" | "inconclusive" | null,
     "identity_verdict": "supported" | "contradicted" | "inconclusive" | null,
     "spouse_verdict": "supported" | "contradicted" | "inconclusive" | null
   }
   ```

   This is the exact shape `_state_to_envelope` (Python) already
   produces. The harness's `compute_metrics` consumes it without
   change.

4. **Aggregate across pair/cluster subjects** — same as the Python
   backend: dedupe by `(kind, value)` for supported_hypotheses,
   `_strongest` aggregation for the three verdicts. The aggregation
   logic stays harness-side, called the same way as for
   `_python_pipeline_call`.

## 4. Gaps in the Swift side

Each gap maps to a numbered change in §6.

### 4.1 Verdict fields not emitted

`Ancestor Research/Services/Research/ResearchState.swift` (and
`ResearchResult`) has no fields for `parentLinkVerdict`,
`identityVerdict`, `spouseVerdict`. The Python pipeline emits these
post-loop via `_emit_*_verdict` helpers; the Swift pipeline's
post-loop phase does not. Both the type and the emission step are
missing.

### 4.2 No structured envelope retrieval tool

`get_profile(profile_id)` returns raw profile data (confirmed_facts,
leads, research_history) — not the per-research-run envelope shape
the harness needs. The harness can't reconstruct envelope shape from
profile-level reads alone because:

- Multiple research runs against the same profile would conflate.
- Per-run discovered_citations / contradicted_hypotheses /
  inconclusive_hypotheses aren't queryable from profile-level data.

Needs a new tool keyed on `run_id`.

### 4.3 No persisted per-run result blob

Even if the new tool existed, the data isn't there to return. The
`research_runs` table tracks lifecycle (status, run_id, mode, scope,
counts) but not the full per-run envelope. Either:

- **Option A:** add a `result_json TEXT` column to `research_runs`
  populated when the run completes.
- **Option B:** add a new `research_results` table keyed on
  `run_id` with structured columns.

Option A is simpler (one migration, one JSON column); Option B is
queryable but heavier. V1 picks A — the harness reads the column
and parses it; structured queries are a follow-up if needed.

### 4.4 No programmatic test-database provisioning

The MCP server takes the project SQLite path as `argv[1]`. The
harness has no way to populate one — currently the app's GEDCOM
import flow is the only path. Without provisioning, the harness
can't run against a freshly-built database; with provisioning, every
eval run can start from a known-good state.

V1 uses a hand-prepared test database at a documented path. The
provisioning script becomes a follow-up.

## 5. Lifecycle

### 5.1 Test database

V1: one shared test database, manually provisioned once, reused
across eval runs.

Location: `~/Library/Application Support/AncestorResearchEval/test-corpus.sqlite`
(distinct from the user's real `AncestorResearch/projects/` so test
runs can't pollute live data). The harness reads the path from
`ANCESTOR_EVAL_DB` env var, falling back to the documented default.

Setup (one-time, manual): launch the Ancestor Research app, import
`Cauldwell Family Tree.twin-export.ged` into a project named
`eval-corpus`, copy the resulting SQLite to the documented path.

### 5.2 MCP server lifecycle

The harness spawns the MCP binary as a subprocess per eval run:

```python
proc = subprocess.Popen(
    ["./FieldResearcherMCP/.build/release/FieldResearcherMCP", db_path],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
)
# JSON-RPC over stdin/stdout
```

One server per eval run, not per subject. Subjects are issued
serially through the same server, sharing the same database
connection.

Teardown: send the server EOF on stdin; wait for graceful exit;
SIGKILL on timeout.

### 5.3 Polling cadence

`get_run_status` polled at 3-second intervals (matching the app's
`RunRequestWatcher` cadence). Per-subject timeout 5 minutes.
Aggregate-corpus timeout = sum of per-subject timeouts.

## 6. Acceptance criteria

Numbered changes, smallest first.

**#Change1 — `result_json` column on `research_runs` table.** New
schema migration; default empty string. Populated by `RunRequestWatcher`
when a run completes.

**#Change2 — Verdict types on `ResearchResult`.** Add
`parentLinkVerdict`, `identityVerdict`, `spouseVerdict` as
`String?` properties. Port the Python `_emit_*_verdict` helpers
faithfully (per `feedback_port_from_python.md`).

**#Change3 — Verdict emission post-loop in Swift pipeline.** Call
the three new emit helpers at the end of `ResearchPipeline.research`.
Persist the verdicts into `result_json`.

**#Change4 — `get_research_result(run_id)` MCP tool.** Reads
`result_json`, returns the envelope shape. Errors if the run isn't
complete.

**#Change5 — `_swift_mcp_pipeline_call` in
`eval/run_harness.py`.** Mirrors `_python_pipeline_call`'s
signature: takes a subject dict, returns the harness envelope.
Per-person multi-call aggregation reuses the existing dedupe +
`_strongest` logic.

**#Change6 — `--backend swift-mcp` CLI flag.** Adds the third
backend option alongside `python` and `mock`.

**#Change7 — `--db-path` CLI flag.** Optional; defaults to
`$ANCESTOR_EVAL_DB` then to the documented default path.

**#Change8 — Smoke test: Ernest end-to-end.**
`python eval/run_harness.py --backend swift-mcp --only "@I50113363@"`
returns a non-empty envelope; per-kind agreement table renders;
guardrail subject Lily still produces zero supported hypotheses.

**#Change9 — Full-corpus parity report.** After #Change1–#Change8
land, run both backends on the same 12-subject corpus and compare
the per-kind agreement tables side by side. Drift is a defect in
either Python (regression in reference) or Swift (port bug). Logged
as a comparison report; the harness can stay backend-selectable
rather than enforcing parity in code.

## 7. Implementation order

Total estimated wall-clock from the scoping survey: 2–3 hours for
core (#Change1–#Change6), another 1–2 hours for #Change7–#Change9.
Roughly one solid session.

Suggested ordering:

1. #Change1 + #Change2 + #Change3 — Swift-side persistence and
   verdicts. Single commit, since they're tightly coupled.
2. #Change4 — new MCP tool. Single commit; depends on (1).
3. #Change5 + #Change6 + #Change7 — harness changes. Single commit;
   depends on (2).
4. #Change8 — smoke test commit, documents the first end-to-end
   evidence the path works.
5. #Change9 — parity report. Drives the next session's port-the-
   gaps backlog.

Test-database provisioning (§5.1) and any required GEDCOM bootstrap
script are out of band — done manually first, automated later if
the pain is real.

## 8. Open questions

- Should the test database live in version control as a binary
  blob, or be regenerated from the GEDCOM each time? V1 leans
  manual; consider a `Scripts/provision_eval_db.sh` follow-up.
- Should `--backend swift-mcp` use the same `--mode` knob as the
  kinship-spec `--mode discovery`/`--mode verification`? V1 ignores
  this — the modes are kinship-spec concerns, not backend concerns.
  Both backends should support all modes once kinship lands.
- Should result_json be schema-validated on write, or only on read?
  V1 unvalidated; add JSON-schema validation if drift bugs surface.

## 9. What this spec deliberately defers

- **App-driven GEDCOM import as a programmatic step.** Possible via
  CLI args to the app binary, but adds product surface area for an
  eval-only path. V1 sidesteps with manual provisioning.
- **Parity-enforcing CI.** Once both backends produce envelopes,
  the natural next step is "fail the build when they disagree" —
  but that's a project-organisation decision (which side wins on a
  disagreement?), not a backend-implementation decision.
- **Streaming progress events.** Both backends today are
  request/response. Streaming envelope deltas during a long run
  would be a UX nicety, not a measurement requirement.
- **Multi-database / multi-tree eval.** The corpus is one tree
  today. Cross-tree evaluation (e.g., a separate Holmes corpus) is
  a future need.

---

End of draft. Next step after review: implement #Change1–#Change3
as a single Swift-side commit, then proceed through the numbered
changes.
