# Genealogy Research Agent

A deterministic genealogy research tool that searches free online sources, scores results against known rules, and writes findings to WikiTree — with human approval at every step.

Built for English and Welsh family history research. The agent searches 7 sources, applies 30+ genealogical rules to score and filter results, and drafts narrative biographies. The LLM discovered the patterns; Python enforces them.

## Quick Start

### 1. Clone and set up

```bash
git clone <repo-url> ancestor
cd ancestor
python3 -m venv .venv
source .venv/bin/activate
pip install playwright networkx pyyaml requests
playwright install chromium
```

### 2. Configure

**Credentials** — create `.env`:
```bash
export WIKITREE_EMAIL=you@example.com
export WIKITREE_PASSWORD=yourpassword
```

**Personal settings** — create `config.local.yaml`:
```yaml
project:
  name: "Your Family History"
  seed_profile: "YourSurname-100"   # Your WikiTree root profile ID
```

**Region** — edit `config.yaml` if you're not researching Derbyshire. Change county, districts, and parishes to match your area.

### 3. Sync your WikiTree tree

```bash
source .env
python -m wikitree.twin sync
python -m wikitree.twin status
python -m wikitree.twin gaps      # See what needs work
```

### 4. Research a person

```bash
python research_agent.py "Ernest Cauldwell" --birth-year 1887 --gender M
```

The agent will:
1. Check WikiTree for existing data
2. Search all sources (FreeBMD, FreeCen, CWGC, FindAGrave, Probate, FreeREG, Wirksworth)
3. Score and classify results using deterministic rules
4. Suggest follow-up searches
5. Draft a biography
6. Ask for your approval before pushing to WikiTree

## Project Structure

```
ancestor/
├── research_agent.py       — CLI entry point
├── config.yaml             — regional data (districts, parishes)
├── config.local.yaml       — personal settings (gitignored)
├── .env                    — credentials (gitignored)
│
├── sources/                — 8 research source libraries
│   ├── freebmd.py          — civil registration (births, marriages, deaths)
│   ├── cwgc.py             — Commonwealth war graves
│   ├── probate.py          — wills and probate calendar
│   ├── freecen.py          — census transcriptions (1841-1911)
│   ├── findagrave.py       — burial records
│   ├── familysearch.py     — FamilySearch index (requires auth)
│   ├── freereg_search.py   — parish register transcriptions
│   └── wirksworth.py       — wirksworth.org.uk parish records
│
├── agent/                  — research agent pipeline
│   ├── pipeline.py         — main research loop
│   ├── discover.py         — search execution
│   ├── scorer.py           — deterministic record matching
│   ├── analyser.py         — pattern-based strategy (no LLM needed)
│   ├── rules.py            — genealogical rules and knowledge
│   ├── corpus.py           — WikiTree profile matching
│   └── ...                 — render, record, config, etc.
│
├── wikitree/               — WikiTree SDK
│   ├── api.py              — read API (authenticated)
│   ├── twin.py             — local NetworkX graph mirror
│   └── state.py            — tree walker
│
├── research/               — research archives (per family line)
├── SOURCES.md              — master list of genealogical sources
├── TODO.md                 — pending research tasks
└── GUIDE.md                — full user guide
```

## Sources

| Source | Coverage | Auth |
|--------|----------|------|
| FreeBMD | Civil registration 1837-1983 | None (auto tokens) |
| FreeCen | Census 1841-1911 | None (auto tokens) |
| CWGC | WW1 + WW2 casualties | None (public) |
| FindAGrave | Burial records | None (public) |
| Probate | Wills 1858+ | None (public) |
| FreeREG | Parish registers (pre-1837) | None (auto tokens) |
| Wirksworth | Derbyshire parish records | None (public) |
| FamilySearch | Census, parish, BMD indexes | OAuth2 API key |

## The Rules

The agent applies 30+ deterministic genealogical rules — every pattern the LLM demonstrated during development, codified as Python. See `agent/rules.py`.

Hard rules (always enforced): parent age gaps, marriage age, lifespan limits, temporal impossibilities.

Soft rules (scoring): name similarity with nicknames, geographic plausibility, convergence of evidence.

Pattern rules: maiden name from mother-in-law, child gap infant deaths, military eligibility, census absence.

## Background

This project is documented in a three-part blog series:
- Part 1: Building the knowledge base
- Part 2: Seven iterations of failure — discovering that genealogy is deterministic
- Part 3: Model type matters more than model size
