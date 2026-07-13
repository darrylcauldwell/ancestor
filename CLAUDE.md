# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Two co-located systems

This repo holds two related-but-independent codebases that share the genealogy domain model:

1. **Python research agent** (root: `sources/`, `agent/`, `wikitree/`, `compare_*.py`, `research_agent.py`) — original deterministic CLI that researches a WikiTree profile against 7 free sources. Reference implementation for genealogical rules.
2. **Swift macOS app** (`Ancestor Research/`, `Ancestor Research.xcodeproj`, `FieldResearcherMCP/`) — the productised SwiftUI app. Ports the Python rules and adds an MLX local reasoning model. This is the active product surface. (The in-app Claude API "Field Researcher" was removed in May 2026 ahead of App Store submission; the `FieldResearcherMCP` Swift package is unrelated — it's a developer-only MCP server with no outbound network calls.)

When working in the Swift app, also read `Ancestor Research/CLAUDE.md` — it has app-specific architecture, schema, and MCP wiring.

## Build, test, ship

### Swift app

```bash
xcodebuild -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research" \
  -destination "platform=macOS" build -skipMacroValidation

xcodebuild -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research Tests" \
  -destination "platform=macOS" test -skipMacroValidation
```

Run a single Swift test:
```bash
xcodebuild test -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research Tests" \
  -destination "platform=macOS" -skipMacroValidation \
  -only-testing:"Ancestor Research Tests/ClusteringEngineTests/testFiveStepAlgorithm"
```

There is **no `Scripts/preflight.sh`** and **no GitHub Actions CI** on this project — `xcodebuild test` is the gate. The `Scripts/` directory only contains `capture_screenshots.sh`. Do not invoke `/preflight` or `/ship` (which expect a preflight script); ship via fastlane lanes directly: `bundle exec fastlane mac beta` / `mac promote` / `mac metadata`. See `feedback_ship_fastlane_gaps.md` in memory.

### FieldResearcherMCP (standalone MCP server)

```bash
cd FieldResearcherMCP && swift build
```
Binary at `.build/debug/FieldResearcherMCP`, takes the project `.sqlite` path as argv[1].

### Python agent

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt   # requests, networkx, pyyaml, beautifulsoup4
# README also lists: playwright, then `playwright install chromium`
source .env                       # WIKITREE_EMAIL / WIKITREE_PASSWORD
python -m wikitree.twin sync      # refresh local mirror
python research_agent.py "Ernest Cauldwell" --birth-year 1887 --gender M
```

Cross-check tools (Python ↔ Swift parity — see memory `feedback_always_compare_python.md`):
```bash
python compare_twins.py     # twin graph parity
python compare_gaps.py      # gap-finder parity
python import_twin_to_app.py    # one-shot import .wikitree-twin.json → app sqlite
```

## Architecture in one screen

```
                     ┌──────────────────────────────────────────┐
                     │  WikiTree (read API + scraped writes)    │
                     └─────────────▲────────────────────────────┘
                                   │ sync / writeback
            ┌──────────────────────┴──────────────────────┐
            │                                             │
   .wikitree-twin.json                            Project SQLite (GRDB)
   (NetworkX graph,                       ~/Library/Containers/dev.dreamfold.
    Python side of fence)                  Ancestor-Research/.../projects/*.sqlite
            ▲                                             ▲
            │                                             │ Evidence Firewall:
   sources/ + agent/                                      │ only `pending_facts`
   (FreeBMD, FreeCen, CWGC,                               │ + `leads` are writable
   FindAGrave, Probate,                                   │ from outside the app
   FreeREG, Wirksworth,                                   │
   FamilySearch)                                          │
   30+ deterministic rules                       FieldResearcherMCP (Swift)
   in agent/rules.py                              exposes resources/tools to
                                                  Claude Code as MCP server
                                                          ▲
                                                          │
                                                  Claude Code (dev tooling —
                                                  not shipped in the app)

   Reasoning tier:                               MLX local model (user-selected;
   in-app probabilistic                          default Qwen3.5-4B, thinking off)
   work uses ONLY the local MLX                  handles next-search suggestion,
   model — no outbound API calls.                candidate comparison, and
                                                 free-text evidence extraction.
```

Inside the Swift app:
- `Services/Research/` — pipeline, 4-gate scorer, clustering, convergence, evidence firewall
- `Services/Sources/` — 7 ported source plugins (FreeBMD, FreeCen, CWGC, FindAGrave, Probate, Wirksworth, FreeREG)
- `Services/Cleanse/` — profile cleanse wizard
- `Models/` — `Profile`, `Relationship`, `Citation`, `LifeEvent`, `Project`, `Research/*` foundation types
- `ViewModels/` — `AppState`, `ResearchViewModel`, `WholeTreeResearchViewModel`
- `Views/` — SwiftUI, organised by feature (`Research/`, `Cleanse/`, `Tree/`, `Audit/`, `Workbench/`, …)

## Load-bearing invariants

These are easy to break and the tests will not always catch them:

- **Deterministic sandwich.** The 4-gate scorer and convergence engine are never overridden by any AI. AI proposes; rules decide.
- **Evidence Firewall.** Anything outside the app writes only to `pending_facts` and `leads`. Never `sqlite3` the project DB directly — go through `FieldResearcherMCP`. (Memory: `feedback_firewall_sqlite.md`.)
- **Source trust is URL-derived.** `SourceTierRegistry` maps cited URLs to trust tiers. Do not let LLM output assert a tier.
- **When in doubt, split.** Clustering prefers over-splitting (user can merge) over over-merging (hard to undo).
- **Port from Python faithfully.** When implementing a rule in Swift, copy the Python algorithm — do not reinvent. Verify with `compare_twins.py`/`compare_gaps.py`. (Memory: `feedback_port_from_python.md`, `feedback_always_compare_python.md`.)
- **No hardcoded regions.** Context (county, parishes, districts) is derived from tree data and `config.yaml`, not from Derbyshire-specific code paths. (Memory: `feedback_no_hardcoded_regions.md`.)
- **Check before overwrite.** Never overwrite precise WikiTree data with estimates. (Memory: `feedback_check_before_overwrite.md`.)

## Specs (read these before non-trivial Swift work)

- `AncestorApp/RESEARCH_PIPELINE_SPEC.md` — governing architectural spec. Part I describes the as-built engine (incl. §14 MCP-driven auto-approval); Part II is the accepted V2 hypothesis-framework pivot (T7/T8/T9/T11/T12/T23/T31).
- `AncestorApp/PROSE_CORPUS_SPEC.md` — unified prose-corpus + bio-synthesis spec (queued; not started).
- `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md` — FamilySearch source-plugin coverage.
- `AncestorApp/CONFLICT_LAYER_SPEC.md` — evidence-conflict layer (GPS element 4), as-built (CL1–CL6 shipped 2026-07-13).
- `AncestorApp/SANDWICH_AUDIT_2026-07.md` — adversarial audit of the decision core; gate repairs awaiting triage.
- `DESIGN.md` (root, 2536 lines) — end-state product design.
- `GUIDE.md` — Python agent's user guide and session model.

Per this project's spec-driven convention (and memory `no_github_issues.md`), planned work is driven by spec docs in `AncestorApp/` (and previously `*_SPEC.md` files in the repo root, now archived). Do **not** open GitHub issues for in-flight work; commit messages reference spec change numbers (`feat: ... #Change1`) or, for bug fixes, an issue number.

## Gotchas

- **Xcode synchronized groups** miss new JSON/asset files until Xcode is quit and reopened; `xcodebuild` from CLI sees them fine. (Memory: `feedback_xcode_synchronized_group_resources.md`.)
- **After an Xcode update, mlx-swift may fail to build** with "cannot execute tool 'metal'" — the Metal Toolchain is a separately-downloaded component: `xcodebuild -downloadComponent MetalToolchain`.
- **`BackupServiceTests`** has a known intermittent flake under parallel execution; re-run in isolation before treating as a real failure. (Memory: `feedback_backupservice_flake.md`.)
- **`.sheet(isPresented:) + if let`** renders an EmptyView rectangle — use `.sheet(item:)` with an Identifiable wrapper. (Memory: `feedback_sheet_isPresented_race.md`.)
- **MLX models** are multi-GB and ignored by git (`models/`). They must be downloaded locally; the app handles this on first run.
- **Personal data is everywhere** — `*.sqlite`, `*.ged` (except `samples/`), `.wikitree-*.json`, `.familysearch-*`, `agent-research/`, `page-cache/` are all gitignored. Don't `git add -A` these by accident.
