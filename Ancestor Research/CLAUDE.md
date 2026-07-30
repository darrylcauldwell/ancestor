# Ancestor Research — Project Guide

## What This Is

A macOS SwiftUI genealogy research app. Digital twin of a family tree with automated research pipeline, 7 structured sources (FreeBMD, FreeCen, FreeREG, CWGC, FindAGrave, Probate, FamilySearch) + prose corpus, and a user-selected local reasoning model (MLX; default Qwen3.5-4B with thinking disabled) for bounded advisory work: next-search suggestion, focused-query strategy, candidate-comparison prose, and prose-fact extraction. The in-app Claude API "Field Researcher" was removed in May 2026 ahead of App Store submission — MLX is the sole reasoning tier, and every AI path has a deterministic fallback (the app is fully functional with no model loaded).

## Tech Stack

- **Swift 6.2+**, macOS 26, SwiftUI with Liquid Glass
- **GRDB** for SQLite persistence
- **MLX Swift** (mlx-swift-lm) for the local reasoning model (sole AI tier — no third-party API)
- Build with: `xcodebuild -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research" -destination "platform=macOS" build -skipMacroValidation`
- Test with: `xcodebuild -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research Tests" -destination "platform=macOS" test -skipMacroValidation`

## Database Location

Projects are SQLite files at (sandboxed):
```
~/Library/Containers/dev.dreamfold.Ancestor-Research/Data/Library/Application Support/AncestorResearch/projects/*.sqlite
```

Each `.sqlite` file is one project (one family tree). The database must exist before the MCP server or any tooling can connect — created by launching the app and importing a GEDCOM or connecting to WikiTree.

**Security note:** The database file is not encrypted. Any process with filesystem access can read it directly with `sqlite3`, bypassing the Evidence Firewall. All external access should go through the MCP server which enforces write restrictions (pending_facts and leads only).

## Database Schema

52 in-code migrations (v1_create_tables … v52_familysearch_upload) in
`Services/ProjectDatabase.swift` — that file is the schema's source of truth;
each migration carries a rationale comment. ~33 tables + 1 FTS5 virtual table
in four families:
- **Core graph**: profiles, relationships, field_sources, field_changes, field_disputes, transactions, project_meta, life_events, attachments
- **Research pipeline**: research_records, scored_records, evidence_records, research_runs, research_run_requests, research_hypotheses, research_discrepancies, negative_searches, record_rejections (legacy, superseded by evidence_records.user_status), name_equivalences
- **Firewall queues**: pending_facts, pending_relationships, leads, narrative_findings
- **Workbench**: focus_sets, open_questions, hypotheses, workbench_notes (+FTS5), sessions, research_goals
- (field_researcher_sessions is a legacy table from the removed Claude tier — unused)

## MCP Server (developer tooling)

Standalone Swift Package at `FieldResearcherMCP/`. Connects Claude Code (CLI) to the project database for pair-programming and research. **Not shipped with the app** — makes no outbound network calls, exists only as a development surface. The "FieldResearcher" name is legacy; the package is unrelated to the in-app Field Researcher service that was removed in May 2026.

**Build:**
```bash
cd FieldResearcherMCP && swift build
```

**Connect from Claude Code** (add to MCP settings):
```json
{
  "mcpServers": {
    "ancestor-research": {
      "command": "/path/to/ancestor/FieldResearcherMCP/.build/debug/FieldResearcherMCP",
      "args": ["/path/to/Library/Application Support/AncestorResearch/projects/YOUR_PROJECT.sqlite"]
    }
  }
}
```

**Available resources:** `ancestor://tree/summary`, `ancestor://tree/gaps`, `ancestor://profiles`, `ancestor://profile/{id}`, `ancestor://profile/{id}/disputes`

**Available tools (27):** reads — `get_profile` (now includes a read-only `disputes` array from the conflict layer), `search_profiles`, `find_path`, `get_scored_records`, `get_run_status`, `get_research_result`, `inspect_approval_decision`, `list_projects`; FamilySearch reads (v52/v53 tables) — `get_fs_upload_status`, `get_fs_person_links`, `get_fs_hints`, `get_fs_request_status`; firewall-gated writes — `submit_evidence`, `submit_narrative_finding`, `submit_lead`, `submit_relationship_proposal`, `add_workbench_note`, `flag_audit_override`, `kick_off_research`, `submit_hypothesis`; FamilySearch request staging (the MCP server never talks to FamilySearch — these INSERT `fs_action_requests` rows the app's watcher executes with the app's own auth; request-driven uploads stop at uploaded-but-HIDDEN, finalize is an in-app wizard consent) — `request_fs_hints`, `request_fs_upload`; project admin — `switch_project`, `delete_project`; double-gated writes (refuse unless `ANCESTOR_MCP_AUTO_APPROVE=1` AND the deterministic §14.3 gate passes; the §14.3 gate additionally refuses when the target field has an open dispute, and the commit path runs the §14.B.1 hallucination re-check) — `approve_pending_fact`, `promote_lead`, `dismiss_lead`

## Architecture

```
Services/Research/     — pipeline, scorer, clustering, convergence, firewall
Services/Sources/      — 7 source plugins (FreeBMD, FreeCen, FreeREG, CWGC, FindAGrave, Probate, FamilySearch) + prose corpus  (Wirksworth retired; FamilySearch = official OAuth Platform API records source)
Models/Research/       — foundation types (Region, SourceTrustTier, ConvergenceLevel, etc.)
ViewModels/            — AppState, ResearchViewModel, WholeTreeResearchViewModel
Views/Research/        — ResearchView, ClusterReviewView, PendingFactsReviewView
```

## Key Design Decisions

- **Deterministic sandwich**: 4-gate scorer + convergence engine are never overridden by any AI
- **Evidence Firewall**: External findings (MCP `submit_evidence`, MLX-extracted facts) enter through `pending_facts` → hallucination checks → scorer → human review. AI cannot write to profiles directly.
- **Source trust from URL, not from AI**: SourceTierRegistry maps cited URLs to trust tiers
- **When in doubt, split**: Clustering prefers over-splitting (user can merge) over over-merging (hard to undo)
- **Evidence-conflict layer (detection-completeness)**: every evidence disagreement ends in exactly one of three states — compatible, rule-resolved with a recorded trace, or an open dispute; there is no fourth state where a conflict is silently dropped

## Test Coverage

~1,687 `@Test` functions across 163 files (counts drift — regenerate with
`grep -rE '@Test' "Ancestor Research Tests" --include='*.swift' | wc -l`).
Key suites:
- `ClusteringEngineTests` — 5-step algorithm
- `DeterminismBoundaryTests` — AI cannot override scorer
- `EvidenceFirewallTests` — hallucination checks, URL verification, source tiers
- `ConvergenceEngineTests` — lineage independence, directness caps
- `AuditEngineTests` — audit rules
- `ApplyDateOverwritePolicyTests` / `ApplyStringOverwritePolicyTests` — directional overwrite policy

Known flakes under parallel execution (re-run in isolation before treating as
real): `BackupServiceTests`, `MultiWindowAppStateTests/staticServicesAreThreadSafe`.

## Specs

- `AncestorApp/RESEARCH_PIPELINE_SPEC.md` — governing architectural spec. Part I = as-built (incl. §14 MCP-driven auto-approval); Part II = V2 hypothesis-framework pivot (T7/T8/T11/T12 shipped; T9/T23/T31 + §5.8 eval harness not built).
- `AncestorApp/PROSE_CORPUS_SPEC.md` — unified prose-corpus + bio-synthesis spec (queued).
- `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md` — FamilySearch source-plugin coverage.
- `AncestorApp/ROADMAP.md` — routing document: phase state, live queues, parked list (May session logs retained as appendix). Full doc index at `AncestorApp/README.md`.
