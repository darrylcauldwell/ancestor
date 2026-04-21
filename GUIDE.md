# User Guide

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    SESSION HARNESS                       │
│                     (session.py)                         │
│                                                         │
│  start() ──→ load twin ──→ create working copy          │
│     │                                                   │
│  research() ──→ pipeline ──→ integrate ──→ working copy │
│     │              │              │                      │
│     │          sources/       agent/                     │
│     │         (FreeBMD,     (rules,                      │
│     │          CWGC, ...)   scorer,                      │
│     │                       analyser)                    │
│     │                                                   │
│  review() ──→ diff(twin, working copy) ──→ changes      │
│     │                                                   │
│  apply() ──→ for each change: approve? ──→ WikiTree     │
│     │                                                   │
│  end() ──→ save twin ──→ session summary                │
└─────────────────────────────────────────────────────────┘
```

### Data Flow

**Twin** (read-only mirror): Exact copy of WikiTree profiles and relationships, stored as a NetworkX directed graph. Nodes are profiles (keyed by WikiTree ID), edges are relationships (parent, spouse, sibling). Persisted to `.wikitree-twin.json`. Synced from WikiTree API at start of session.

**Working copy** (session workspace): Deep copy of the twin graph. Research findings are written here — new dates, new profiles, new relationships, bio drafts, research metadata. Discarded at session end (changes either applied to WikiTree or lost).

**Research pipeline** (`agent/pipeline.py`): Searches free sources (FreeBMD, CWGC, probate, etc.), scores results against deterministic rules, suggests follow-up searches. Produces a `state` dict with confirmed facts, rejected records, household members.

**Integration** (`agent/integrate.py`): Translates pipeline `state` into working copy updates. Maps fact types to WikiTree fields (birth date, death date), stores census/military/probate data as research metadata, drafts bios, adds household members as proposed profiles/relationships.

**Diff** (`agent/diff.py`): Compares working copy against read-only twin. Produces a list of Change objects: new profiles, new relationships, field updates, bio updates. Only real changes — ignores research metadata and unchanged fields.

**Apply**: Walks through each Change with human approval. On "yes", pushes to WikiTree (via local tooling) and updates the twin. On "no", skips.

### Key Principles

1. **Twin is always a clean mirror** — never modified during research, only updated after confirmed pushes to WikiTree
2. **Working copy is disposable** — all speculative data lives here, discarded at session end
3. **Research metadata (`_research`) is separate from WikiTree fields** — occupations, addresses, military details go in `_research`, not in WikiTree structured fields (which have no occupation field)
4. **Every change needs approval** — no auto-push, no silent modifications
5. **Rules are deterministic** — parent age gaps, marriage age, temporal impossibilities are Python code, not LLM judgement
6. **Save incrementally** — research state saved to `agent-research/` after each person, so crashes don't lose work

## Daily Workflow

A typical research session:

1. **Sync** — refresh the local twin from WikiTree (one API call)
2. **Find gaps** — check which profiles need work
3. **Research** — run the agent on a person
4. **Review** — check the agent's findings and draft bio
5. **Push** — approve to write to WikiTree
6. **Commit** — save research notes

```bash
source .env
python -m wikitree.twin sync
python -m wikitree.twin gaps
python research_agent.py "John Cauldwell" --birth-year 1861 --gender M
git add research/ && git commit -m "research: John Cauldwell findings"
```

## The Local Twin

The twin is a NetworkX graph that mirrors your WikiTree tree locally. After syncing, all reads come from the local copy — no API calls, no rate limits.

```bash
# Sync from WikiTree (do once per session)
python -m wikitree.twin sync

# Check status
python -m wikitree.twin status

# Find profiles needing work
python -m wikitree.twin gaps

# View a profile with relationships
python -m wikitree.twin show Cauldwell-171

# View ancestor/descendant tree
python -m wikitree.twin tree Cauldwell-100
```

## Sources — What Each One Covers

### FreeBMD (freebmd.py)
Civil registration index for England and Wales, 1837-1983. Births, marriages, deaths. The backbone of post-1837 research.

**Limitations:**
- Coverage is volunteer-transcribed and incomplete
- Mother's maiden name on births from Sep 1911 only
- Spouse surname on marriages from Sep 1912 only
- Some districts have major gaps (check `config.yaml` source_gaps)

### FreeCen (freecen.py)
Census transcriptions: 1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911. Can fetch full household details for matched records.

### CWGC (cwgc.py)
Commonwealth War Graves Commission. WW1 and WW2 casualties. Includes regiment, rank, burial location, and next of kin.

### Probate (probate.py)
England and Wales Probate Calendar, 1858 onwards. Wills and administrations. Useful for death dates, addresses, and family connections.

### FindAGrave (findagrave.py)
Gravestone photos and burial records. Good for exact death dates and family plots.

### FreeREG (freereg_search.py)
Parish register transcriptions — baptisms, marriages, burials. Essential for pre-1837 research before civil registration.

### Wirksworth (wirksworth.py)
Local Derbyshire parish records from wirksworth.org.uk. Pedigrees and parish data specific to the Wirksworth area.

### FamilySearch (familysearch.py)
Census images, parish registers, BMD indexes. The most comprehensive single source. Requires OAuth2 API key from developers.familysearch.org (free, nonprofit).

## Understanding the Rules

The agent doesn't guess. It applies deterministic rules from `agent/rules.py`.

### Hard Rules (never broken)
- A parent must be born at least 14 years before their child
- Marriage age must be at least 16
- No one lives beyond 110 years
- Can't marry after death
- Can't appear in census before birth

### Soft Rules (scoring, not rejecting)
- Name similarity: Caldwell/Cauldwell scores 0.95 (AU/A swap)
- Jack/John scores 0.85 (known nickname)
- Same district as expected: 1.0. Different county: 0.1
- Census ages can be ±2 years from actual birth year
- More independent sources confirming = higher confidence

### Pattern Rules (suggest follow-up)
- Mother-in-law with different surname → wife's maiden name
- Gap of 3+ years between children → possible infant deaths
- Males born 1880-1900 → search military records
- Person absent from later census → died, emigrated, or married
- Death found but no will → search probate

## Writing Biographies

The agent drafts bios from confirmed facts. Good bios:

- **Don't repeat structured data** — parents, dates, and locations are in the profile fields
- **Do include narrative** — occupations, places, historical context, family stories
- **Do cite sources** — FreeBMD references, census years, CWGC records
- **Are written for people** — these are real lives, not database entries

Example:
```
== Biography ==

Ernest Cauldwell (b. December 1887, Belper district; d. March 1959,
Ashbourne district, aged 71) grew up in Turnditch, Derbyshire.

He moved approximately 10 miles east to Loscoe, a coal mining village
in the Heanor area. This was a common pattern as agricultural estate
work declined and the Derbyshire coalfields offered employment.

== Sources ==
<references />

* FreeBMD birth Dec 1887 Belper vol7b p559 (mother Barker)
* FreeBMD death Mar 1959 Ashbourne vol3a p14, age 71
```

## Managing Relationships

The write-back module handles family links with approval at every step:

- **Create profile** — new person found in census, not on WikiTree
- **Link existing** — person already on WikiTree, not linked to subject
- **Fix wrong link** — parent age gap violation detected
- **Merge duplicates** — two profiles for the same person

Every action prints what it wants to do and waits for yes/no.

## Adding a New Region

1. Edit `config.yaml`:
   - Change `county`, `chapman_code`, `default_location`
   - Replace `districts` with your FreeBMD district IDs
   - Replace `district_parishes` with your local parishes
   - Replace `non_local_districts` with districts outside your county
   - Update `source_gaps` for any known FreeBMD coverage issues

2. Create `config.local.yaml`:
   ```yaml
   project:
     name: "Your Family History"
     seed_profile: "YourSurname-100"
   ```

3. Create `.env` with your WikiTree credentials

4. Run `python -m wikitree.twin sync` to populate your local twin

No code changes needed. The agent, rules, and sources all read from config.

## Common Tasks

### Research a specific person
```bash
python research_agent.py "Mary Ward" --birth-year 1890 --gender F
```

### Check what needs work
```bash
python -m wikitree.twin gaps
```

### Search a single source manually
```python
from sources.freebmd import search, print_results, BELPER
results = search("Deaths", "Barker", given="Joseph", start=1861, end=1890, district=BELPER)
print_results(results)
```

### View a profile locally
```bash
python -m wikitree.twin show Ward-55432
```

### Run the write-back standalone
```bash
python -m agent.writeback agent-research/ernest_cauldwell_1887.json
```
