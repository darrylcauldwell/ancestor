# Field Researcher Specification

**Date:** 2026-04-25 (v4)  
**Depends on:** RESEARCH_PIPELINE_SPEC.md (governing spec for the research pipeline)  
**Status:** Design

---

## 1. The Problem

The Ancestor Research app searches 7 structured genealogical sources (FreeBMD, FreeCen, CWGC, Probate, Wirksworth, FreeREG, Find a Grave). These cover civil registration indexes, census transcriptions, military casualties, probate grants, and parish register transcriptions. They are excellent for what they contain.

But they cover a fraction of the evidence that exists. Parish register photographs, newspaper archives, local history websites, family history forums, emigration manifests, trade directories, workhouse records, Poor Law records, wills, land records, apprenticeship indentures, poll books, school records — the real evidence is scattered across the internet in unstructured forms that no structured API covers.

A human genealogist finds this evidence by browsing, reading, reasoning, and following leads. That takes hours per profile. A frontier reasoning model can do the same work — read unstructured pages, interpret historical documents, cross-reference findings across sites — and bring evidence back for evaluation.

---

## 2. The Proposal

Add a **Field Researcher** capability to the app. The Field Researcher is a frontier AI model (Claude) that reads the full tree context, reasons about what evidence is missing, searches the web for unstructured sources, and contributes findings back to the app for evaluation and human review.

The name comes from professional genealogy. A field researcher is someone hired to visit archives, read original documents, and report findings. Our Field Researcher does the same work — in the digital landscape.

---

## 3. How It Relates to What Already Exists

The app already has two layers of intelligence:

### Layer 1: Deterministic Pipeline

The research pipeline searches structured sources, scores records through 4 gates (name, date, geography, family context), clusters results into candidate lives, detects discrepancies, and presents findings for human review. This is mechanical and repeatable — the same input always produces the same output.

### Layer 2: Internal Reasoning Model (DeepSeek-R1, local MLX)

A 7B/14B reasoning model runs locally on Apple Silicon. It operates inside the pipeline's deterministic sandwich — it can suggest which source to search next between iterations, evaluate whether records belong together, draft evidence summaries, and help disambiguate conflicts. It cannot override the scorer, cannot change verdicts, cannot write to the tree. It is a constrained advisor.

### Layer 3: Field Researcher (proposed)

A frontier model (Claude) that operates outside the pipeline entirely. It reads the tree context through a defined interface, does independent research using web access, and contributes findings back through the same defined interface. It is an independent researcher, not an advisor within the pipeline.

| Aspect | Deterministic Pipeline | Internal Advisor (MLX) | Field Researcher (Claude) |
|--------|----------------------|----------------------|--------------------------|
| **What it does** | Searches structured sources, scores records | Suggests between iterations | Searches the internet, reads documents |
| **Operates** | Inside the pipeline | Inside the deterministic sandwich | Outside the pipeline entirely |
| **Can see** | Records from 7 sources | Same records + pipeline state | Full tree + the entire internet |
| **Can change** | Nothing — produces results for review | Nothing — produces suggestions | Nothing — contributes evidence for review |
| **Constrained by** | Its own deterministic rules | The deterministic sandwich | The Evidence Firewall (§8) |
| **Cost** | Free (local HTTP to sources) | Free (local inference) | API usage (user pays) |
| **Trust tier** | Varies per source | N/A (not a source) | Community / derivative (always) |

---

## 4. The Evidence Firewall

This is the most important section of this specification.

The Field Researcher has web access and massive reasoning capability. It will confidently produce wrong answers. The Evidence Firewall is the hard boundary between AI output and the family tree. It applies identically regardless of whether the Field Researcher runs inside the app (future) or outside via MCP (phase 1).

### 4.1 The Boundary

```
                    ┌─────────────────────┐
                    │  EVIDENCE FIREWALL   │
                    │                     │
   AI SIDE          │                     │    TREE SIDE
   (free-thinking)  │                     │    (deterministic)
                    │                     │
   Web searching    │   pending_facts ────┼──→ 4-gate scorer
   Document reading │   leads ────────────┼──→ investigation
   Reasoning        │                     │    convergence engine
   Evidence finding │                     │    discrepancy detection
                    │                     │    human review
                    │                     │    tree update
                    │                     │
                    │  The AI writes to   │
                    │  pending_facts and  │
                    │  leads ONLY.        │
                    │                     │
                    │  It cannot write to │
                    │  profiles,          │
                    │  relationships, or  │
                    │  any other table.   │
                    └─────────────────────┘
```

The `pending_facts` and `leads` tables are the airlock. Everything on the left side of the firewall can be as creative and free-thinking as it needs to be. Everything on the right side is the same deterministic pipeline that evaluates FreeBMD records. The firewall is two database tables.

### 4.2 Eight Rules of the Firewall

**Rule 1: Nothing enters without scoring.**  
Every finding passes through `RecordScorer.classify()`. The model's self-assessed confidence is logged but ignored for scoring. If the scorer says impossible, the finding is rejected regardless of what the model thinks.

```
Model says "high confidence" + Scorer says impossible → REJECTED
Model says "low confidence"  + Scorer says fact       → PENDING REVIEW
```

**Rule 2: Source URL required.**  
A finding without a verifiable source URL is discarded before scoring. The URL must:
- Respond to an HTTP HEAD request (exists)
- Not be a blocked pattern (AI-generated sites, the user's own tree, social media)
- Not return 404

A claim without provenance is worthless in genealogy. The same standard applies to the AI.

**Rule 3: Structured submission only.**  
The AI does not return free text that gets inserted anywhere. It submits structured findings with typed fields: `field`, `value`, `source_url`, `source_title`, `evidence_text`, `reasoning`. If a field name is invalid or a value can't be parsed, the finding is rejected at the interface before it reaches the scorer.

**Rule 4: No manufactured convergence.**  
Two findings citing the same underlying URL are one lineage, enforced by `SourceLineage.derivedFrom`. The model cannot boost convergence by submitting the same finding twice with different wording, or by citing a secondary source that itself cites the primary. The app tracks URLs per profile and deduplicates at the lineage level.

**Rule 5: Trust ceiling.**  
Field Researcher evidence has hard limits:
- Trust tier: `community` (cannot be promoted to `transcription` or `primary`)
- Evidence directness: `derivative` (always — the model compiled from another source)
- Convergence cap: `.possible` when Field Researcher is the only source
- A Field Researcher finding can corroborate a structured source (raising convergence) but cannot confirm a fact alone

**Rule 6: Hallucination detection.**  
Heuristic checks run before scoring:

| Check | Rejects if |
|-------|-----------|
| Date sanity | Year < 1500 or > current year |
| Name plausibility | Non-alphabetic characters or suspiciously long |
| Location consistency | Location doesn't exist in gazetteers |
| Self-contradiction | Finding contradicts another from the same session |
| Temporal impossibility | Married at 3, died before birth, etc. |
| Source recycling | URL already cited for a different person in same session |

**Rule 7: Human always decides.**  
No Field Researcher finding enters the tree without human approval. Review friction is `individualReview` minimum — never autoStage or batchReview. The human sees: exact source text, clickable source URL, 4-gate score, convergence assessment, any discrepancy, and the model's reasoning.

**Rule 8: Session isolation.**  
Each session is independent. The model cannot access previous sessions' findings, previous sessions' rejections, or findings from other profiles. Fresh tree context each time. This prevents hallucination reinforcement (the model citing its own previous wrong answers).

---

## 5. Phased Approach

The Field Researcher will be built in two phases. Phase 1 is external (MCP server) — at arm's length, proving the concept. Phase 2 is internal (in-app feature) — brought inside if Phase 1 proves genuinely useful.

### Phase 1: MCP Server (External, At Arm's Length)

A standalone executable that opens the project database and exposes it via MCP (Model Context Protocol) over stdio. Claude Code connects to it as an MCP server.

**What the MCP server can read:**
- All profiles with fields, relationships, completeness
- Research history — what's been searched, what was found, what was rejected
- Gaps — which profiles are missing which fields
- Negative searches — which sources returned no results (prevents re-searching)
- Extended family context — grandparents, aunts, cousins (helps disambiguate common names)

**What the MCP server can write:**
- `pending_facts` — evidence submissions awaiting scoring and human review
- `leads` — new people discovered during research

**What the MCP server cannot write:**
- `profiles` — cannot modify the tree directly
- `relationships` — cannot add or remove connections
- `research_records`, `scored_records` — cannot bypass the scoring pipeline
- Any delete operation on any table

**How the human uses it:**
1. Configure MCP server in Claude Code settings
2. Ask Claude Code: "Research Thomas Land, born 1834 Wirksworth"
3. Claude Code reads tree context via MCP resources
4. Claude Code searches the web, finds evidence
5. Claude Code submits findings via MCP tools → `pending_facts`
6. Open the Ancestor Research app
7. Pending facts appear in the review queue, scored by the pipeline
8. Accept or reject each finding

**Advantages of Phase 1:**
- Zero changes to the existing app (reads/writes SQLite only)
- The human drives Claude Code manually — full control
- Easy to validate whether the findings are useful
- Easy to kill if it produces garbage

**Limitations of Phase 1:**
- Two separate processes (app + Claude Code)
- The human has to context-switch between Claude Code and the app
- No live scoring feedback — findings are scored when the app processes the queue
- No cost tracking built into the app

### Phase 2: In-App Feature (If Phase 1 Proves Useful)

If Phase 1 demonstrates that frontier model research genuinely improves GPS scores and finds evidence the structured sources miss, bring it inside the app:

- Settings panel with Claude API key, model selection, per-session budget
- "Field Researcher" button alongside structured source results
- The app crafts prompts with full tree context and sends to Claude API
- Live findings stream with cost tracking
- Findings scored in real-time as they arrive
- Same review UI as structured sources, tagged with Field Researcher badge

**The firewall is identical in both phases.** Whether findings come from an MCP tool call or from an in-app API call, they enter through `pending_facts` and get scored by the same pipeline. Moving from Phase 1 to Phase 2 changes the user experience but not the trust model.

---

## 6. MCP Server Detail (Phase 1)

### 6.1 Configuration

The MCP server is a standalone Swift executable in `FieldResearcherMCP/`. It takes a database path as its only argument.

Claude Code configuration (`.claude/settings.json` or project MCP config):
```json
{
  "mcpServers": {
    "ancestor-research": {
      "command": "/path/to/FieldResearcherMCP/.build/release/FieldResearcherMCP",
      "args": ["/path/to/Ancestor Research/project.db"]
    }
  }
}
```

### 6.2 Resources

Resources provide read-only context. The agent reads these before deciding what to research.

| Resource URI | What it returns | Why the agent needs it |
|-------------|----------------|----------------------|
| `ancestor://tree/summary` | Profile count, relationship count, pending facts count, new leads count | Big picture — how large is the tree, what's outstanding |
| `ancestor://tree/gaps` | Every profile with missing fields, sorted by incompleteness | Prioritise research — most incomplete profiles first |
| `ancestor://profiles` | All profiles with name, dates, location, gender | Full tree roster — the agent needs to know who exists |
| `ancestor://profile/{id}` | Full detail: all fields, all relationships, research history, negative searches | Deep context for a specific person — what's known, what's been tried |

**Profile detail includes:**
- Every field with its value and source
- All relationships (parents, spouses, children, siblings) with their profiles
- Research run history (when, what mode, how many facts/leads/clusters)
- Negative searches (which sources were searched and returned nothing)

This is rich context. The agent knows not just that Thomas Land was born in 1834, but that FreeBMD found the birth, FreeCen found nothing in 1841, CWGC was not applicable, and no death record has been found.

### 6.3 Tools

Tools let the agent take actions. There are four.

#### submit_evidence

The primary tool. Submits a research finding for a specific profile.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `profile_id` | string | yes | Which profile this evidence is about |
| `field` | string | yes | What field: `birthDate`, `deathDate`, `birthLocation`, `deathLocation`, `occupation`, `marriageDate`, `spouseName`, `fatherName`, `motherName` |
| `value` | string | yes | The proposed value (e.g. "6 April 1834") |
| `source_url` | string | yes | URL where the evidence was found |
| `source_title` | string | yes | Human-readable source description (e.g. "Wirksworth Parish Register") |
| `evidence_text` | string | yes | The EXACT relevant text from the source |
| `reasoning` | string | yes | How the agent connected this source to this profile |
| `confidence` | string | yes | The agent's own assessment: `high`, `medium`, or `low` |

**What happens:** The finding is written to `pending_facts` with `review_status = 'pending'`. When the user opens the app, the pipeline scores it and presents it for review.

**What the tool returns:** The finding ID and a confirmation message. The agent does NOT receive the scoring result — that happens later in the app. This prevents the agent from gaming the scorer by adjusting findings based on score feedback.

#### submit_lead

Submits a new person discovered during research.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `source_profile_id` | string | yes | The profile this lead relates to |
| `name` | string | yes | The lead person's full name |
| `relationship` | string | no | Suspected relationship: `father`, `mother`, `spouse`, `child`, `sibling` |
| `birth_year` | integer | no | Approximate birth year |
| `death_year` | integer | no | Approximate death year |
| `evidence` | string | yes | Why the agent thinks this person exists |
| `source_url` | string | yes | URL where found |

**What happens:** The lead is written to the `leads` table with `status = 'new'`. The app shows it in the Leads tab. The user can investigate (run the pipeline for this person) or dismiss.

#### get_profile

Reads full detail for a specific profile. Same data as the `ancestor://profile/{id}` resource, available as a tool for mid-conversation lookup.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `profile_id` | string | yes | The profile to look up |

#### search_profiles

Searches profiles by name. Useful when the agent finds a reference to someone and wants to check if they're already in the tree.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | Name to search for |

### 6.4 Prompts

Prompts give the agent structured starting points for research tasks.

#### research_profile

Given a profile ID, assembles the full context (profile detail, family relationships, research history, negative searches) and presents it with a structured research task:

```
Research this person and find additional evidence.

[full profile context]

Search for:
1. Baptism/birth records in parish registers
2. Census appearances (1841-1921)
3. Marriage record
4. Death/burial record
5. Any other evidence (wills, newspapers, directories)

For each finding, use the submit_evidence tool.
For any new people you discover, use submit_lead.
```

#### find_ancestor

Given a profile ID and a role (father/mother), asks the agent to find the missing parent:

```
This profile has no known [father/mother].

[profile context + children + siblings]

Find candidates for the [father/mother]. Look for:
1. Baptism records naming parents
2. Census records showing family groups
3. Marriage records
4. Pedigree compilations

Submit any candidates as leads using submit_lead.
```

---

## 7. Evidence Flow — Complete Walkthrough

This traces a single finding from discovery to tree, showing every system that touches it.

### Step 1: Agent Reads Context

Claude Code reads `ancestor://profile/thomas-land-1834`:

```json
{
  "id": "thomas-land-1834",
  "first_name": "Thomas",
  "last_name": "Land",
  "birth_date": "1834",
  "birth_year_earliest": 1834,
  "birth_location": "Derbyshire",
  "death_date": null,
  "relationships": [
    { "type": "parent_child", "role": "father", "person": "John Land", "birth": "1858" },
    { "type": "parent_child", "role": "father", "person": "Mary Land", "birth": "1860" }
  ],
  "research_history": [
    { "mode": "extend", "facts": 3, "leads": 2, "gps": 2 }
  ],
  "negative_searches": [
    { "source": "freecen", "type": "census" },
    { "source": "cwgc", "type": "death" }
  ]
}
```

### Step 2: Agent Researches

Claude Code searches the web, finds a parish register transcription website. It reads a page listing baptisms at Wirksworth parish church in 1834. It finds:

> "Thomas son of William and Mary Land, bpt 6 April 1834"

### Step 3: Agent Submits Finding

```
submit_evidence(
  profile_id: "thomas-land-1834",
  field: "baptismDate",
  value: "6 April 1834",
  source_url: "https://example.com/wirksworth-registers/1834",
  source_title: "Wirksworth Parish Register Transcription",
  evidence_text: "Thomas son of William and Mary Land, bpt 6 April 1834",
  reasoning: "Baptism at Wirksworth matches name Thomas Land and year 1834. 
    Parents named as William and Mary Land.",
  confidence: "high"
)
```

### Step 4: MCP Server Writes to Database

The finding is stored in `pending_facts`:

```sql
INSERT INTO pending_facts (id, profile_id, fact_kind, value_json, sources_json, review_status, created_at)
VALUES ('uuid-123', 'thomas-land-1834', 'baptismDate', '6 April 1834', 
  '{"source_url":"https://...","source_title":"Wirksworth Parish Register",
    "evidence_text":"Thomas son of William and Mary Land, bpt 6 April 1834",
    "reasoning":"...","confidence":"high","agent":"field-researcher"}',
  'pending', '2026-04-25T14:30:00Z')
```

### Step 5: Agent Submits Leads

```
submit_lead(
  source_profile_id: "thomas-land-1834",
  name: "William Land",
  relationship: "father",
  evidence: "Named as father in 1834 baptism record at Wirksworth",
  source_url: "https://example.com/wirksworth-registers/1834"
)
```

### Step 6: User Opens App

The app sees new pending_facts. The pipeline processes them:

**Hallucination checks (§4.2 Rule 6):**
- Date sanity: 1834 ✓ (valid year)
- Name plausibility: "Thomas Land" ✓
- URL verification: HEAD request to source URL → 200 OK ✓

**4-gate scorer:**
- Name gate: "THOMAS LAND" vs "THOMAS LAND" → PASS (score 1.0)
- Date gate: 1834 vs birthYearFrom 1834 → PASS (exact match)
- Geography gate: Wirksworth is in Bakewell registration district → PASS
- Family context: no parents in tree to check → SKIP

**Verdict: FACT** (pending human review)

**Convergence check:**
- FreeBMD birth index: transcription, independent lineage (GRO indexes)
- Field Researcher: derivative, independent lineage (parish register website)
- 2 lineages, one transcription + one derivative → POSSIBLE

**Discrepancy check:**
- Birth year 1834 matches existing tree → no discrepancy

### Step 7: Human Reviews

The app shows:

```
Pending Evidence (1 item)

  Thomas Land — baptismDate: 6 April 1834
  ──────────────────────────────────────────
  Source: Wirksworth Parish Register Transcription
  URL: https://example.com/wirksworth-registers/1834
  Text: "Thomas son of William and Mary Land, bpt 6 April 1834"
  
  Score: FACT (name ✓ date ✓ geography ✓ family n/a)
  Convergence: POSSIBLE (corroborates FreeBMD birth index)
  Discrepancy: none
  
  Agent reasoning: "Baptism at Wirksworth matches name and year.
    Parents named as William and Mary Land."
  Agent confidence: high
  
  [Accept]  [Reject]  [Defer]
```

### Step 8: Human Accepts

The finding enters the tree. Thomas Land's profile now shows:

```
Birth: 1834 (FreeBMD) / Baptism: 6 April 1834 (Field Researcher)
GPS: 3/5 (up from 2/5)
```

Two new leads appear in the Leads tab:
- William Land (father) — from baptism record
- Mary Land (mother) — from baptism record

---

## 8. What the Field Researcher Cannot Do

Explicit exclusions to prevent misunderstanding:

| Operation | Why excluded |
|-----------|-------------|
| Write to `profiles` table | Direct tree modification — must go through pending_facts → scoring → review |
| Write to `relationships` table | Direct tree modification — same reason |
| Delete any record | Destructive operations are human-only |
| Read `record_rejections` | Would allow re-submitting rejected findings with different wording |
| Read previous session findings | Would allow hallucination reinforcement |
| Bypass the 4-gate scorer | The scorer is deterministic and non-negotiable |
| Set its own trust tier above `community` | The trust ceiling is hard-coded |
| Submit findings without source URLs | Provenance is mandatory |
| Access other project databases | Scoped to one project |

---

## 9. Implementation Plan

### Already Built

- `FieldResearcherMCP/` — standalone Swift Package executable
- MCP server with resources (tree/summary, tree/gaps, profiles, profile detail)
- MCP tools (submit_evidence, submit_lead, get_profile, search_profiles)
- MCP prompts (research_profile, find_ancestor)
- Writes to `pending_facts` and `leads` tables
- Database tables exist (pending_facts in v4 migration, leads in v3 migration)

### Still Needed for Phase 1

| Step | Work |
|------|------|
| P1.1 | **Pending facts processing in the app.** The app needs to read `pending_facts`, score each through RecordScorer, and present for review. Currently pending_facts table exists but no UI reads it. |
| P1.2 | **Hallucination detection.** Pre-scoring checks (date sanity, URL verification, name plausibility) before findings reach the scorer. |
| P1.3 | **Source badge.** "Field Researcher" badge in the review UI distinguishing AI-contributed evidence from structured source evidence. |
| P1.4 | **Convergence integration.** Field Researcher findings need to participate in convergence scoring alongside structured source findings. |

### Phase 2 (If Phase 1 Proves Useful)

| Step | Work |
|------|------|
| P2.1 | `ClaudeAPIClient` actor with Messages API, tool use, cost tracking |
| P2.2 | Settings UI for API key, model selection, per-session budget, Keychain storage |
| P2.3 | `FieldResearcherService` — context builder + conversation orchestrator |
| P2.4 | In-app Field Researcher panel in ResearchView with live progress |
| P2.5 | System prompts (general research, discrepancy resolution, ancestor discovery) |
| P2.6 | Prompt versioning and quality measurement |

---

## 10. Open Questions

1. **Should the MCP server return scoring results?** Currently it does not — findings are scored when the app processes them. If we returned scores, the agent could refine its search based on what passes. But this also lets it game the scorer. Current decision: no scores returned.

2. **Should we cache source pages?** When the Field Researcher cites a URL, should the app download and cache the page? This would let the human verify the source even if the page later changes. It also creates a local evidence archive. Trade-off: storage vs provenance integrity.

3. **Multi-profile sessions in Phase 2?** A family group (parents + children) shares context. Researching them together would be more efficient — finding one parent's marriage record reveals the other parent. But session isolation (Rule 8) is there for a reason. Resolution: allow family-group sessions with shared context but separate finding streams per profile.

4. **What if the Field Researcher finds something the structured pipeline missed?** For example, a FreeBMD search returned no results, but the Field Researcher finds the same GRO index entry on a different website. Should the app flag this as "your FreeBMD search may have had incorrect parameters"? This would make the Field Researcher a quality check on the structured pipeline.

5. **Cost model for Phase 2?** Claude API pricing changes. Should the budget be in dollars, tokens, or findings? Dollars is simplest for the user but requires maintaining a price table. Tokens is stable but abstract. Findings is meaningful but unpredictable.
