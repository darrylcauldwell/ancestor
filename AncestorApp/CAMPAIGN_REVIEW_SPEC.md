# Campaign Review — persistent evidence chain + DB-backed bulk review

**Status: ALL SIX CHANGES SHIPPED 2026-07-15** — commits: 1 `5e3172e` · 2+3 `02aa57b` ·
4+5 `9dafa80` · 6 `d1edcd7`. Suite 2588 green at close. Remaining: real-data verification
against the 2026-07-14/15 overnight campaign DB (rebuild + open Review Campaign).
**Owner decision (Darryl):** "we should be looking to persistently store the evidence chain
and not only do in memory… fold show convergence level + open-conflict state per finding
into the BulkReviewView design."

## Context (verified 2026-07-15, workflow wf_b9ffe684)

An overnight watcher campaign (31 runs, 2026-07-14/15) left its harvest on disk —
`evidence_records` (full SourceRecord JSON + verdict + user_status), `research_hypotheses`,
`leads`, `research_discrepancies` (+`field_disputes` ≥conflict), `research_run_requests`
(the campaign ledger) — but the review surfaces couldn't show it:

- **Clusters and convergence are memory-only.** `LifeCluster` is never persisted;
  `ConvergenceLevel`/`SourcingStrength` are computed on demand and dropped (zero schema
  hits). `research_runs.result_json` is the watcher eval envelope, not a result snapshot.
- **`ScoredRecord.gates`/`summary` are not persisted** (no Codable conformance; the v4
  `scored_records` table with gate columns was never written). Losses on reconstruction:
  gate chips, rejected-reasons, `LifeCluster.hasKnownSpouseMarriage`, and
  `RecordScorer.wouldApply`'s known-spouse bypass.
- **`state.enrichmentRecordIDs` is memory-only** — a rebuild re-clusters parents'-marriage /
  sibling-candidate records into spurious candidate-life clusters.
- **`BulkReviewView` is an unwired prototype**: no production caller; its Review button
  *starts a new run* (via `appState.researchProfileID` → config sheet); its conflict signal
  is a project-wide count loaded per-card (racy, all-or-nothing tiering); `processedCount`
  never increments; "batch operations" unimplemented.
- **The in-app whole-tree runner persists nothing**: `WholeTreeResearchViewModel.start()`
  calls the pipeline directly and never `ResearchRunService.persist` — no evidence rows, no
  runs, no hypotheses; it creates *unfiltered* scored-record leads only, requires
  interactive per-profile Continue, and its ClusterReviewView hand-off leaves
  `researchVM.selectedProfile/currentResult` unset so applies silently no-op. The MCP
  watcher queue is the only real campaign runner today.
- **Lead status is untrustworthy**: `saveLead` is INSERT-OR-IGNORE, and three production
  status flips call it (in-app promote `.promoted`, UnifiedTasksView dismiss `.dismissed`,
  ResearchRunService finalise `.investigated`) — all silent no-ops for existing rows.
  Separately, MCP `promote_lead` writes `status='resolved'`, not a `LeadStatus` rawValue, so
  promoted leads are silently dropped by `loadLeads`' compactMap and vanish in-app.
- **ClusteringEngine determinism**: pure given input *order* (ordinal `cluster-N` ids —
  never durable keys), with ONE true nondeterminism bug — the same-year-census split picks
  its year via `Dictionary.first(where:)` (hash-seed order).
- Useful precedents already in production: `ConflictSweep` reconstructs from
  `loadEvidenceForProfile` (no gates needed) across all profiles;
  `project_meta.conflict_sweep_high_water` is the watermark pattern; `negative_searches`
  (+v42 result_kind) approximates the searched-surface for GPS criterion 1;
  `SourcingStrength` is already Codable ("persistence-ready"); `PublishedTree` has a
  wired-but-empty `convergence` badge slot awaiting exactly this data.

## Design decisions

1. **The evidence chain is persisted, not recomputed-only.** Per-record: gates + summary
   join the record in `evidence_records` (the row becomes the full ScoredRecord, as the
   model's own doc demands: "the evidence is the ground truth"). Per-fact-value:
   convergence (`ConvergenceLevel` + Codable `SourcingStrength`) is persisted per
   `(profile, value_key)` at run-persist time and refreshed whenever new corroborating
   evidence lands — an audit trail frozen against future registry/tier changes, exactly what
   Darryl asked for ("further research finds same fact in a different source — is the bigger
   evidence chain recorded?" → yes, as accumulated `evidence_records` + field_sources rows
   AND a persisted convergence snapshot that upgrades as lineages accumulate).
2. **Countering evidence** keeps its existing persisted trail (research_discrepancies +
   field_disputes via the CL ladder); the review surface reads **per-profile
   `openDisputes(profileID:)` DisputeRow queries** — never the snapshot's field map (drops
   structural kinds) and never the project-wide count (BulkReview's current all-or-nothing
   signal).
3. **Clusters stay derived** (deterministic re-cluster over persisted records with a
   canonical input sort), never persisted — ordinal ids are not durable keys; decisions
   persist keyed on `record.id`/user_status, which round-trips. The enrichment exclusion
   becomes a persisted per-record flag so the rebuild matches the run.
4. **Campaign scoping** comes from `research_run_requests` windows (`created_at`/
   `started_at`/`completed_at`, incl. failed/reclaimed rows so the surface can show what a
   campaign SKIPPED) + a `campaign_review_high_water` watermark in `project_meta`.
5. **Drill-down hydrates the existing per-profile review** — set `researchVM.currentResult`
   + `selectedProfile` + `appDatabase` + `appState.currentDatabase` together, then the
   existing ClusterReviewView/apply path works unchanged (and its four silent-no-op session
   dependencies are documented here as the contract).

## Changes

### Change 1 — Lead status integrity (S, prerequisite) — trustworthy review substrate
Fix the three `saveLead` INSERT-OR-IGNORE status flips → `upsertLead`
(ProjectDatabase+PromoteLead promote; UnifiedTasksView dismiss; ResearchRunService
finalise-investigated). Fix MCP `promote_lead` to write `status='promoted'` (resolution
keeps the matched/promoted detail) + one-shot migration UPDATE for legacy `'resolved'` rows
so they reappear in-app. Regression tests for each flip surviving reload.

### Change 2 — Persist the full scorer output + enrichment flag (M)
Codable `GateResult`/`ScoredRecord`. Migration v44: `evidence_records` + `gates_json TEXT`,
`summary TEXT`, `is_enrichment INTEGER NOT NULL DEFAULT 0`, `last_run_id TEXT`.
`ResearchRunService.persist` threads `enrichmentRecordIDs` (new field on ResearchResult,
populated from state) and the run id; `saveEvidence` writes all four;
`loadEvidenceForProfile` round-trips gates/summary (nil-tolerant for legacy rows → empty
gates, as today). Restores gate chips, rejected reasons, known-spouse apply bypass,
`hasKnownSpouseMarriage` for reconstructed records.

### Change 3 — Persist convergence per fact value (M)
New table `evidence_convergence` (profile_id, value_key, level TEXT
(ConvergenceLevel.rawValue), sourcing_json TEXT (Codable SourcingStrength), record_ids_json,
updated_at; PK (profile_id, value_key)). Computed in `ResearchRunService.persist` via
`ConvergenceEngine.scoreValueGroups` over verdict==.fact records (witness-collapsed, per
DS-03), upserted (levels may go UP as corroboration accumulates; a level drop is recorded,
not suppressed — registry changes are legitimate re-audits). Loader + upsert APIs. Feeding
`PublishedTree.convergenceByProfile` from this table is noted as the publish follow-up (slot
exists, stays empty until then).

### Change 4 — Whole-tree runner persists (S)
`WholeTreeResearchViewModel` routes each per-profile result through
`ResearchRunService.persist` (UI options: no parent-inferred leads, no placeholder
writeback, resultJSON '') so "Research All" leaves the same substrate as the watcher, and
its unfiltered direct `LeadStore.createFromScoredRecord` path is replaced by the persist
path's LeadFilter-gated one. (Interactive waitingForReview flow unchanged.)

### Change 5 — CampaignReviewService (M)
`reconstructResult(profileID:) -> ResearchResult`: load evidence (canonical sort by
source_record_id — NOT scored_at DESC; excluding user-discarded is a per-surface choice:
default include, UI dims via user_status, matching live-run parity), decode to ScoredRecords
(persisted gates/summary when present), cluster via ClusteringEngine excluding
`is_enrichment` rows, confirmedFacts/leads split by verdict, hypotheses via
`loadHypotheses`, discrepancies via new full-row `loadRunDiscrepancies(profileID:)`,
searched-surface approximation from negative_searches ∪ evidence source ids (excluding the
`__whole_tree__` sentinel). Campaign enumeration:
`campaignWindow(since:) -> [profileID: RunOutcome]` from research_run_requests (completed +
failed + skipped). Fix the ClusteringEngine census-split nondeterminism (sort years) with a
regression test. Full unit coverage against temp DBs.

### Change 6 — BulkReviewView rebuilt + Triage wiring (M/L)
Near-rewrite behind the kept-and-tested `FrictionTier.route` seam:
- Fed by CampaignReviewService (all profiles with reviewable material; campaign-window
  filter chip via the watermark).
- Per-finding: **convergence badge** (level + independent-witness count from
  evidence_convergence / live compute) and **open-conflict state** from
  `openDisputes(profileID:)` scoped to the finding's profile+field — conflict tier fires
  per-finding, not project-wide.
- **Leads tier**: campaign-window leads as reviewable rows (Promote via the canonical
  in-app flow / Dismiss via upsert — trustworthy after Change 1).
- Working drill-down: hydrate the VM quartet, present per-profile review; return refreshes.
- `processedCount` actually increments; minimal batch op = "Accept all confirmations" per
  the friction model.
- Triage entry: campaign summary header (N profiles researched, N with findings, N failed/
  skipped) + "Review campaign" button in the selector toolbar; pendingCounts badges remain
  the per-profile signal.

## Order
1 → 2 → 3 (+4 anytime after 2) → 5 → 6. Gate: full `xcodebuild test` per change (known
flakes isolation-cleared per memory); real-data verification against the 2026-07-14/15
campaign DB before declaring Change 6 done.

## Non-goals (this spec)
Auto-apply of anything (firewall posture unchanged); persisting WitnessKeys (⟨G9⟩ forbids —
recomputed from record fields); durable cluster ids; MCP lead-id exposure (separate fix on
the morning dossier); publish-side convergence badge rendering (slot fed later).
