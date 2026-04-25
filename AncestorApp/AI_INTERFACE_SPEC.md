# Field Researcher Specification

**Date:** 2026-04-25 (v3)  
**Depends on:** RESEARCH_PIPELINE_SPEC.md (governing spec for the research pipeline)  
**Status:** Design — not yet implemented

---

## 1. Purpose

The Ancestor Research app holds a family tree and searches structured genealogical sources (FreeBMD, FreeCen, CWGC, Probate, Wirksworth, FreeREG). These are excellent for civil registration, census, and military records — but genealogical research extends far beyond structured databases.

Parish register scans, newspaper archives, local history websites, family history forums, emigration manifests, cemetery photographs, wills, land records, trade directories, probate documents, workhouse records, Poor Law records — the real evidence is scattered across the internet in unstructured forms that no API covers.

The **Field Researcher** is an in-app feature that uses a frontier reasoning model (Claude API) to do what the structured sources can't: read the full tree context, reason about what's missing, crawl the web, interpret documents, and bring evidence back to the vault for evaluation.

The name is deliberate. In genealogy, a field researcher is someone who travels to archives, reads original documents, and reports findings. Our Field Researcher does the same thing — in the digital landscape.

---

## 2. Two AI Roles in the App

| | Internal Advisor | Field Researcher |
|---|---|---|
| **Model** | DeepSeek-R1 7B/14B (MLX, local) | Claude API (frontier, cloud) |
| **Role** | Constrained advisor within pipeline | Independent researcher outside pipeline |
| **Access** | Records returned by structured sources | Full tree context + the entire internet |
| **Constraint** | Deterministic sandwich — cannot override scorer | Only the evidence vault — cannot write to tree |
| **Output** | Suggestions between pipeline iterations | Evidence, leads, discoveries from anywhere |
| **Cost** | Free (runs on local hardware) | API usage (user provides credentials) |
| **Speed** | Fast (local inference) | Variable (API calls + web crawling) |
| **Enabled** | Settings → Reasoning Model → Load | Settings → Field Researcher → Enable + API key |

They complement each other. The internal advisor helps the deterministic pipeline make better decisions about structured records. The Field Researcher goes beyond structured records to find evidence the pipeline can't reach.

---

## 3. Design Principles

### 3.1 The App Drives the Conversation

The Field Researcher is not an external agent connecting to the app. The app itself calls the Claude API with carefully crafted prompts that include full tree context. The app controls:

- What context to send (relevant profiles, gaps, existing evidence)
- What to ask for (specific research tasks, not open-ended generation)
- How to interpret responses (structured evidence extraction)
- When to stop (cost limits, research completed)

### 3.2 Evidence, Not Facts

The Field Researcher contributes **evidence** — findings with source citations that enter the same evaluation pipeline as any other source:

- 4-gate scorer evaluates name, date, geography, family context
- Convergence engine checks independence from other sources
- Discrepancy severity table handles conflicts
- Review friction tiers determine how the human sees it

### 3.3 Source Provenance Required

Every finding must include:
- **What was found** — the specific claim
- **Where it was found** — URL or document reference
- **The relevant text** — the actual passage supporting the claim
- **How it was interpreted** — the reasoning chain connecting source to person

A claim without provenance is discarded.

### 3.4 Cost Transparency

Every Field Researcher session shows:
- API calls made and tokens used
- Estimated cost
- Evidence submitted vs evidence scored as useful
- Research efficiency (useful findings per API call)

The user sets a per-session budget in Settings.

---

## 4. Architecture

### 4.1 FieldResearcherService

```swift
actor FieldResearcherService {
    private let apiKey: String
    private let projectDB: ProjectDatabase
    private let snapshot: FamilyGraphSnapshot
    private let sourceInfoMap: [String: SourceInfo]
    
    /// Research a specific profile — the primary operation.
    func research(profileID: String) async -> FieldResearchResult
    
    /// Investigate a lead.
    func investigateLead(_ lead: Lead) async -> FieldResearchResult
    
    /// Resolve a discrepancy by finding additional evidence.
    func resolveDiscrepancy(_ discrepancy: ResearchDiscrepancy) async -> FieldResearchResult
    
    /// Find a missing ancestor (ghost node).
    func findAncestor(childProfileID: String, role: GhostRole) async -> FieldResearchResult
}
```

### 4.2 Conversation Flow

Each research task is a multi-turn conversation with the Claude API:

**Turn 1: Context + Task**
```
System: You are a genealogical field researcher. You have access to 
web search and can browse URLs. Your job is to find primary and 
secondary evidence about historical people.

User: Research Thomas Land, born about 1834 in Wirksworth, Derbyshire.

Here is everything we know about him:
[full profile detail, relationships, existing sources, gaps, 
 research history, negative searches]

Here is his family context:
[parents, spouse, children, siblings with dates and locations]

Sources already searched:
[FreeBMD: birth Q2 1834 Bakewell, FreeCen: no 1841 result, CWGC: not applicable]

Please search for:
1. Baptism record (parish registers — Wirksworth, Middleton, Cromford)
2. 1841 census (he'd be about 7, probably with parents)
3. Marriage record (children born from 1858, so married ~1855-1858)
4. Death record (unknown — any period)
5. Any other evidence about this person or his family

For each finding, provide:
- The specific claim (date, name, relationship, etc.)
- The source URL
- The relevant text from the source
- Your confidence (high/medium/low)
- How you connected this to Thomas Land specifically
```

**Turn 2-N: Follow-up based on findings**
```
You found a potential baptism record. Can you:
1. Verify the parents named match any other records
2. Check if other children of William and Mary Land appear in registers
3. Look for William Land in the 1841 census with son Thomas age 7
```

**Final Turn: Structured extraction**
```
Please summarise all findings as structured evidence.
For each finding, provide JSON:
{
  "field": "baptismDate",
  "value": "6 April 1834",
  "source_url": "https://...",
  "source_title": "Wirksworth Parish Register",
  "evidence_text": "Thomas son of William and Mary Land, bpt 6 April 1834",
  "confidence": "high",
  "reasoning": "Name, date, and parish match. Parents named."
}
```

### 4.3 Evidence Processing

The app extracts structured findings from the conversation and processes each one:

```swift
struct FieldResearchFinding: Sendable {
    let field: String
    let value: String
    let sourceURL: String
    let sourceTitle: String
    let evidenceText: String
    let confidence: FieldResearchConfidence
    let reasoning: String
}

enum FieldResearchConfidence: String, Sendable {
    case high, medium, low
}
```

Each finding is:
1. Wrapped as a `SourceRecord` from the virtual `FieldResearcherSource`
2. Scored through `RecordScorer.classify()`
3. Checked for convergence with existing evidence
4. Checked for discrepancy with existing tree data
5. Stored in `pending_facts` for human review

### 4.4 FieldResearcherSource

```swift
struct FieldResearcherSource {
    nonisolated let sourceID = "field-researcher"
    nonisolated let displayName = "Field Researcher (Claude)"
    nonisolated let trustTier = SourceTrustTier.community
    nonisolated let evidenceDirectness = EvidenceDirectness.derivative
    
    // Each finding declares its source URLs
    // Two findings from the same URL = one lineage (no manufactured convergence)
    func lineage(for finding: FieldResearchFinding) -> SourceLineage {
        .derivedFrom(Set([finding.sourceURL]))
    }
}
```

---

## 5. User Interface

### 5.1 Settings

```
Field Researcher
  ┌─────────────────────────────────────────────┐
  │ [Toggle] Enable Field Researcher            │
  │                                             │
  │ Claude API Key: [••••••••••••••••••]  [Set] │
  │                                             │
  │ Model: claude-sonnet-4-20250514      [▼]    │
  │                                             │
  │ Per-session budget: $0.50            [▼]    │
  │                                             │
  │ Status: Ready                               │
  │ Last session: 25 Apr 2026, 12 findings      │
  │ Total spend: $2.34 across 8 sessions        │
  └─────────────────────────────────────────────┘
```

### 5.2 Research View Integration

The Field Researcher appears alongside the structured pipeline:

```
Research: Thomas Land (b.1834)
  ┌─────────────────────────────────────────────┐
  │ [Verify]  [Extend]  [Discover]              │
  │                                             │
  │ Structured Sources          Field Researcher │
  │ ──────────────────          ──────────────── │
  │ FreeBMD: 3 results          [Start Research] │
  │ FreeCen: 1 result                           │
  │ CWGC: not applicable        Status: Idle    │
  │ Probate: 0 results          Last: never     │
  │ Wirksworth: 2 results                       │
  │ FreeREG: 1 result                           │
  └─────────────────────────────────────────────┘
```

When Field Researcher runs:

```
  Field Researcher
  ──────────────────
  Searching... (turn 2 of 4)
  
  Findings so far:
  ✓ Baptism 6 Apr 1834, Wirksworth [high]
  ✓ Father: William Land [high]  
  ✓ Mother: Mary Land [high]
  ? 1851 census age 17 [medium]
  
  Tokens: 12,340 / Cost: $0.08
  [Stop]
```

### 5.3 Results Review

Field Researcher findings appear in the same cluster review UI as structured source results, but tagged with the Field Researcher source badge. The human sees:

```
  Evidence for Thomas Land
  ────────────────────────
  
  Birth year 1834
    ✓ FreeBMD birth index Q2 1834 Bakewell [transcription]
    ✓ Field Researcher: baptism 6 Apr 1834 Wirksworth [derivative]
    Convergence: POSSIBLE (2 lineages, both transcription/derivative)
  
  Father: William Land  [NEW — Field Researcher only]
    ⚠ Single source (derivative) — needs corroboration
    Suggested action: Search FreeBMD births for siblings to confirm parents
  
  Mother: Mary Land  [NEW — Field Researcher only]
    ⚠ Single source (derivative) — needs corroboration
```

---

## 6. Claude API Integration

### 6.1 API Client

```swift
actor ClaudeAPIClient {
    private let apiKey: String
    private let model: String
    private var tokenCount: Int = 0
    private var estimatedCost: Double = 0
    
    func converse(
        system: String,
        messages: [(role: String, content: String)],
        tools: [ClaudeTool]?
    ) async throws -> ClaudeResponse
}
```

### 6.2 Tool Use

The Claude API supports tool use. The Field Researcher gives the model tools for:

| Tool | Purpose |
|------|---------|
| `web_search` | Search the web (built into Claude) |
| `read_url` | Read a webpage (built into Claude) |
| `submit_finding` | Submit a structured finding back to the app |
| `check_tree` | Query the app's tree for additional context mid-conversation |
| `search_structured_source` | Query FreeBMD/FreeCen/etc. through the app's rate-limited sources |

`submit_finding` and `check_tree` are **app-defined tools** that the Claude API calls back to the app. This creates a tight loop: the model searches, finds something, submits it, asks the app "does this match?", and refines its search based on the score.

### 6.3 Prompt Engineering

System prompts are stored as resources in the app bundle, versioned with the app. They encode:

- Genealogical research methodology (GPS, evidence classification)
- Derbyshire-specific knowledge (parish boundaries, registration districts)
- Common pitfalls (census age rounding, name spelling variations)
- Source reliability hierarchy

The app fills in the profile-specific context dynamically.

---

## 7. Implementation Plan

### Phase 1: ClaudeAPIClient

| Step | Work |
|------|------|
| 1.1 | `ClaudeAPIClient` actor with Messages API |
| 1.2 | Token counting and cost estimation |
| 1.3 | Tool use support (submit_finding, check_tree) |
| 1.4 | Settings UI for API key, model, budget |
| 1.5 | Secure credential storage in Keychain |

### Phase 2: FieldResearcherService

| Step | Work |
|------|------|
| 2.1 | Context builder — assembles full profile + family + research history into prompt |
| 2.2 | Conversation orchestrator — multi-turn with structured extraction |
| 2.3 | Finding processor — wraps findings as SourceRecords, scores through pipeline |
| 2.4 | Lead and discovery creation from findings |
| 2.5 | Session persistence — save conversation + findings to database |

### Phase 3: UI Integration

| Step | Work |
|------|------|
| 3.1 | Field Researcher panel in ResearchView |
| 3.2 | Live progress with findings count and cost |
| 3.3 | Findings appear in ClusterReviewView with FR source badge |
| 3.4 | Session history in profile research tab |

### Phase 4: Prompt Engineering

| Step | Work |
|------|------|
| 4.1 | System prompt for general research |
| 4.2 | System prompt for discrepancy resolution |
| 4.3 | System prompt for ancestor discovery |
| 4.4 | Derbyshire-specific context (parishes, districts, occupations) |
| 4.5 | Prompt versioning and A/B testing framework |

### Phase 5: Validation

| Step | Work |
|------|------|
| 5.1 | Research 5 profiles with Field Researcher, measure GPS improvement |
| 5.2 | Verify evidence scoring — FR findings scored identically to structured sources |
| 5.3 | Verify convergence — FR + FreeBMD corroboration raises convergence correctly |
| 5.4 | Verify cost control — session stops at budget limit |
| 5.5 | Verify provenance — every finding has a clickable source URL |

---

## 8. Open Questions

1. **Which Claude model?** Sonnet for speed/cost, Opus for depth? Or let the user choose per session?

2. **Should the Field Researcher work offline on cached results?** If a previous session found a promising webpage, should it be cached locally so the user can review the original source even if the page later changes?

3. **Multi-profile sessions?** Should the Field Researcher be able to research multiple related profiles in one session (e.g. a whole family unit), sharing context between them?

4. **Should we expose MCP as well?** The Field Researcher covers the primary use case (app-driven research). But an MCP server would also allow Claude Code to drive the app interactively for power users who want direct control. These aren't mutually exclusive.

---

## 9. What This Enables

**Before Field Researcher:**
- Human searches 7 structured sources
- Each source covers specific record types and date ranges
- Gaps remain for records not in any structured database
- GPS typically reaches 3/5 for well-documented profiles

**After Field Researcher:**
- Structured sources find the records they cover
- Field Researcher fills gaps from parish registers, newspapers, forums, archives
- Evidence from both flows through the same pipeline
- GPS can reach 4-5/5 as the evidence pool deepens
- Human reviews findings from both structured and unstructured sources in one UI

The Field Researcher doesn't replace the structured pipeline — it extends it into the long tail of genealogical evidence that no API can reach.

---

## 10. Evidence Firewall

The Field Researcher's reasoning model has web access and massive capability. It will confidently produce wrong answers. This section defines the hard boundary between the model's output and the tree.

### 10.1 Nothing Enters Without Scoring

Every finding passes through `RecordScorer.classify()`. This is not optional, not bypassable, not configurable. The model's confidence assessment is logged but **ignored for scoring purposes** — the 4-gate scorer makes the determination.

```
Model says: "high confidence"  +  Scorer says: impossible  →  REJECTED
Model says: "low confidence"   +  Scorer says: fact        →  PENDING REVIEW
```

The model's self-assessed confidence is metadata for the human reviewer, not input to the scoring engine.

### 10.2 URL Verification Required

A finding without a verifiable source URL is **discarded, not scored**. The app must be able to:
- Confirm the URL exists (HTTP HEAD request)
- Confirm the URL is a plausible genealogical source (not a random blog, AI-generated page, or circular reference)

Blocked URL patterns:
- AI-generated content sites (known generators)
- The user's own tree on WikiTree/Ancestry (circular evidence)
- Social media (Facebook, Reddit — unreliable sourcing)
- Any URL that returns 404 at verification time

### 10.3 Structured Extraction Only

The Field Researcher does not return free text that gets inserted anywhere. It returns **structured findings** through the `submit_finding` tool, each with typed fields:

```swift
struct FieldResearchFinding {
    let field: String       // Must be a valid ProfileField raw value
    let value: String       // The proposed value
    let sourceURL: String   // Must pass URL verification
    let sourceTitle: String
    let evidenceText: String // The EXACT text from the source (not paraphrased)
    let reasoning: String
}
```

If the model returns a finding with an invalid field name, or a value that can't be parsed as the expected type (e.g. "about 1834" for a year field), the finding is rejected at the interface boundary before it reaches the scorer.

### 10.4 No Manufactured Convergence

Two findings from the same URL are **one lineage**, enforced by `SourceLineage.derivedFrom`. The model cannot boost convergence by:
- Submitting the same information twice with different wording
- Citing a secondary source that itself cites the primary (chain is one lineage)
- Citing its own previous finding as evidence

The app tracks source URLs across all Field Researcher findings for a profile. Duplicate URLs are deduplicated at the lineage level.

### 10.5 Trust Ceiling

Field Researcher evidence has a **hard ceiling**:
- Trust tier: `community` (cannot be promoted to `transcription` or `primary`)
- Evidence directness: `derivative` (always — the model compiled from another source)
- Convergence cap: `.possible` when Field Researcher is the only source for a fact
- A Field Researcher finding can **corroborate** a structured source finding (raising convergence) but can never **confirm** a fact on its own

This means: if the Field Researcher finds a baptism date and FreeBMD also has the birth year, convergence rises to `.possible` or `.probable`. If the Field Researcher is the only source, the fact stays at `.singleSource` with `derivative` directness — the human sees "needs corroboration."

### 10.6 Hallucination Detection

The app applies heuristic checks before scoring:

| Check | Rejects if |
|-------|-----------|
| **Date sanity** | Year < 1500 or year > current year |
| **Name plausibility** | Name contains non-alphabetic characters, or is suspiciously long |
| **Location consistency** | Finding claims a location that doesn't exist in gazetteers |
| **Self-contradiction** | Finding contradicts another finding from the same session |
| **Temporal impossibility** | Finding implies impossible age (married at 3, died before birth) |
| **Source recycling** | URL was already cited for a different person in the same session |

These checks run **before** the 4-gate scorer. Findings that fail are logged (for debugging prompt quality) but not scored.

### 10.7 Human Always Decides

No Field Researcher finding enters the tree without human approval. The review friction tier for ALL Field Researcher findings is **individualReview** (tier 2) at minimum — never autoStage or batchReview. The human sees each finding with:

- The exact source text
- A clickable link to the original source
- The 4-gate score breakdown
- The convergence assessment
- Any discrepancy with existing data
- The model's reasoning (collapsible)

The human can: accept (enters tree), reject (finding discarded + recorded in rejections), or defer (stays in pending).

### 10.8 Session Isolation

Each Field Researcher session is isolated. The model cannot:
- Access findings from other profiles' sessions (prevents cross-contamination)
- Access its own previous sessions (prevents hallucination reinforcement)
- Access the rejection list (prevents it from re-submitting rejected findings with different wording)

The app provides fresh tree context each session. The model starts from what the tree knows, not from what it previously guessed.
