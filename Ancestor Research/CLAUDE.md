# Ancestor Research — Project Guide

## What This Is

A macOS SwiftUI genealogy research app. Digital twin of a family tree with automated research pipeline, 7 structured sources, and a local reasoning model (MLX/DeepSeek-R1) for probabilistic work (hypothesis generation, disambiguation, narrative synthesis). The in-app Claude API "Field Researcher" was removed in May 2026 ahead of App Store submission — MLX is now the sole reasoning tier.

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

5 migrations (v1-v5):
- **v1**: profiles, relationships, field_sources, field_changes, field_disputes, transactions, project_meta
- **v2**: research_records, record_rejections, name_equivalences, negative_searches, research_runs
- **v3**: leads
- **v4**: scored_records, research_discrepancies, pending_facts
- **v5**: narrative_findings, page_cache, field_researcher_sessions + pending_facts columns

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

**Available resources:** `ancestor://tree/summary`, `ancestor://tree/gaps`, `ancestor://profiles`, `ancestor://profile/{id}`

**Available tools:** `submit_evidence`, `submit_narrative_finding`, `submit_lead`, `get_profile`, `search_profiles`

## Architecture

```
Services/Research/     — pipeline, scorer, clustering, convergence, firewall
Services/Sources/      — 7 source plugins (FreeBMD, FreeCen, CWGC, FindAGrave, Probate, Wirksworth, FreeREG)
Models/Research/       — foundation types (Region, SourceTrustTier, ConvergenceLevel, etc.)
ViewModels/            — AppState, ResearchViewModel, WholeTreeResearchViewModel
Views/Research/        — ResearchView, ClusterReviewView, PendingFactsReviewView, LeadListView
```

## Key Design Decisions

- **Deterministic sandwich**: 4-gate scorer + convergence engine are never overridden by any AI
- **Evidence Firewall**: External findings (MCP `submit_evidence`, MLX-extracted facts) enter through `pending_facts` → hallucination checks → scorer → human review. AI cannot write to profiles directly.
- **Source trust from URL, not from AI**: SourceTierRegistry maps cited URLs to trust tiers
- **When in doubt, split**: Clustering prefers over-splitting (user can merge) over over-merging (hard to undo)

## Test Coverage

168 tests across 17 files. Key test suites:
- `ClusteringEngineTests` (11) — 5-step algorithm
- `DeterminismBoundaryTests` (5) — AI cannot override scorer
- `EvidenceFirewallTests` (14) — hallucination checks, URL verification, source tiers
- `ConvergenceEngineTests` (9) — lineage independence, directness caps
- `AuditEngineTests` (39) — 18 audit rules

## Specs

- `AncestorApp/RESEARCH_PIPELINE_SPEC.md` — governing architectural spec. Part I = as-built (incl. §14 MCP-driven auto-approval, MVP shipped); Part II = V2 hypothesis-framework pivot (not yet implemented).
- `AncestorApp/PROSE_CORPUS_SPEC.md` — unified prose-corpus + bio-synthesis spec (queued).
- `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md` — FamilySearch source-plugin coverage.
