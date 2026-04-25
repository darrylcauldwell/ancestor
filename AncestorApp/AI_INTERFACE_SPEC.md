# AI Interface Specification

**Date:** 2026-04-25 (v1)  
**Depends on:** RESEARCH_PIPELINE_SPEC.md (governing spec for the research pipeline)  
**Status:** Design — not yet implemented

---

## 1. Purpose

The Ancestor Research app was built for a human user who selects profiles, reviews clusters, and approves facts flowing into the tree. This spec extends the app so that AI tools — Claude Code, custom agents, RAG pipelines, OCR systems — can programmatically drive the same research pipeline and contribute evidence.

The human remains the final approver. The AI handles volume, triage, and evidence gathering. The determinism boundary from §2 of the governing spec is unchanged: the 4-gate scorer, convergence engine, and discrepancy severity table are never overridden by any external agent.

---

## 2. Architecture

```
┌─────────────────────────────────────────────┐
│              Ancestor Research App           │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ SwiftUI  │  │   MCP    │  │  HTTP    │  │
│  │   Views  │  │  Server  │  │  API     │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
│       │              │              │        │
│       └──────────────┼──────────────┘        │
│                      │                       │
│              ┌───────▼────────┐              │
│              │  Service Layer │              │
│              │  (Pipeline,    │              │
│              │   Clustering,  │              │
│              │   Scoring)     │              │
│              └───────┬────────┘              │
│                      │                       │
│              ┌───────▼────────┐              │
│              │  GRDB/SQLite   │              │
│              └────────────────┘              │
└─────────────────────────────────────────────┘
         ▲              ▲              ▲
         │              │              │
     Human User    Claude Code    Other AI Tools
```

Three access paths to the same service layer:
1. **SwiftUI Views** — existing human interface (unchanged)
2. **MCP Server** — Model Context Protocol for Claude Code and compatible agents
3. **HTTP API** — lightweight local REST server for any tool

Both MCP and HTTP share the same underlying service calls. No logic is duplicated.

---

## 3. Design Principles

### 3.1 Same Pipeline, Different Driver

The AI uses exactly the same `ResearchPipeline`, `RecordScorer`, `ClusteringEngine`, and `ConvergenceEngine` as the human UI. No separate "AI pipeline" exists. This means:

- AI-triggered research produces the same `ResearchResult` as human-triggered
- Clusters have the same confidence scores
- GPS criteria are evaluated identically
- Discrepancies are detected by the same engine

### 3.2 Propose, Don't Commit

An AI never writes directly to the tree. All AI contributions enter as **proposals** that flow through existing review mechanisms:

| AI action | Lands in | Human sees |
|-----------|----------|------------|
| Research a profile | `ResearchResult` with clusters | Cluster review UI |
| Contribute evidence | `pending_facts` table | Pending facts queue |
| Report a discrepancy | `research_discrepancies` table | Discrepancy resolution UI |
| Suggest a correction | `pending_facts` with correction flag | Individual review tier |
| Create a lead | `leads` table | Lead list view |

### 3.3 Trust Tier for External AI

External AI contributions are classified as:
- **Trust tier:** `community` (same as Find a Grave — compiled, not primary)
- **Evidence directness:** `derivative` (AI synthesised from other sources)
- **Convergence cap:** `.possible` maximum when AI is the only source
- **Source lineage:** `derivedFrom(Set<String>)` — AI must declare what sources it used

This means an AI finding alone never produces a "confirmed" fact. It adds to the evidence pool. When it corroborates something FreeBMD already found, the convergence score rises.

### 3.4 Audit Trail

Every AI action is logged with:
- Agent identifier (e.g. "claude-code", "ocr-pipeline")
- Timestamp
- Action taken
- Input parameters
- Result summary

This is the same transaction model the app already uses for human actions.

---

## 4. MCP Server

### 4.1 Transport

The MCP server uses **stdio transport** — launched as a subprocess by Claude Code. No network port, no authentication for the local case.

Configuration in Claude Code's MCP settings:
```json
{
  "mcpServers": {
    "ancestor-research": {
      "command": "/path/to/AncestorResearchMCP",
      "args": ["--project", "/path/to/project.db"]
    }
  }
}
```

The MCP binary is a separate executable that links the same service layer as the app. It opens the project database read-write and exposes tools via JSON-RPC over stdio.

### 4.2 Resources (Read-Only Context)

MCP resources let the agent understand the current state before acting.

| Resource URI | Returns |
|-------------|---------|
| `ancestor://profiles` | All profiles with completeness scores |
| `ancestor://profile/{id}` | Full profile detail + audit + GPS |
| `ancestor://profile/{id}/research` | Latest research results for a profile |
| `ancestor://profile/{id}/leads` | Leads generated from this profile |
| `ancestor://profile/{id}/narrative` | Biography and timeline |
| `ancestor://tree/stats` | Tree-wide statistics (count, completeness, GPS distribution) |
| `ancestor://tree/gaps` | Profiles sorted by incompleteness |
| `ancestor://sources` | Registered sources with status and coverage |

### 4.3 Tools (Actions)

Tools let the agent drive the research pipeline.

#### Query Tools

| Tool | Parameters | Returns |
|------|-----------|---------|
| `search_profiles` | `query: string` | Matching profiles with scores |
| `get_audit` | `profile_id: string` | Audit results for a profile |
| `get_discrepancies` | `profile_id: string` | Active discrepancies |
| `search_source` | `source_id, surname, given_name, year_from, year_to` | Raw source records (scored) |

#### Research Tools

| Tool | Parameters | Returns |
|------|-----------|---------|
| `research_profile` | `profile_id, mode: verify\|extend\|discover` | ResearchResult (clusters, facts, leads, discrepancies, GPS) |
| `investigate_lead` | `lead_id` | ResearchResult for the lead subject |
| `research_batch` | `profile_ids: [string], mode` | Array of ResearchResults |

#### Decision Tools

| Tool | Parameters | Returns |
|------|-----------|---------|
| `accept_cluster` | `cluster_id` | Confirmation + fields updated |
| `reject_cluster` | `cluster_id` | Confirmation + records rejected |
| `dismiss_lead` | `lead_id` | Confirmation |

#### Contribution Tools

| Tool | Parameters | Returns |
|------|-----------|---------|
| `propose_fact` | `profile_id, field, value, evidence, source_urls: [string]` | pending_fact ID |
| `propose_correction` | `profile_id, field, old_value, new_value, evidence, source_urls` | pending_fact ID |
| `report_discrepancy` | `profile_id, field, values: [{source, value}], reasoning` | discrepancy ID |
| `create_lead` | `name, birth_year?, death_year?, relationship?, evidence` | lead ID |

### 4.4 Prompts (Agent Guidance)

MCP prompts provide structured templates the agent can use.

| Prompt | Purpose |
|--------|---------|
| `research_strategy` | Given tree stats and gaps, suggest which profiles to research and in what order |
| `evaluate_cluster` | Given a cluster's records, reason about whether to accept or reject |
| `resolve_discrepancy` | Given conflicting values from different sources, reason about which is correct |
| `draft_narrative` | Given confirmed facts, draft a biographical summary |

---

## 5. HTTP API

### 5.1 Transport

Lightweight HTTP server bound to `localhost:9274` (mnemonic: 9=research, 274=ancestor). Enabled in Settings with a toggle. No auth for localhost — same trust model as the app itself.

### 5.2 Endpoints

Mirror the MCP tools as REST endpoints:

```
GET  /api/profiles
GET  /api/profiles/{id}
GET  /api/profiles/{id}/research
POST /api/profiles/{id}/research        { mode: "extend" }
GET  /api/profiles/{id}/leads
GET  /api/profiles/{id}/narrative
POST /api/profiles/{id}/propose-fact    { field, value, evidence, sources }
GET  /api/tree/stats
GET  /api/tree/gaps
GET  /api/sources
POST /api/sources/{id}/search           { surname, given_name, year_from, year_to }
POST /api/clusters/{id}/accept
POST /api/clusters/{id}/reject
POST /api/leads/{id}/dismiss
POST /api/leads/{id}/investigate
```

### 5.3 Response Format

All responses are JSON with consistent envelope:

```json
{
  "ok": true,
  "data": { ... },
  "meta": {
    "timestamp": "2026-04-25T14:30:00Z",
    "duration_ms": 1234
  }
}
```

Error responses:

```json
{
  "ok": false,
  "error": {
    "code": "PROFILE_NOT_FOUND",
    "message": "No profile with id 'xyz'"
  }
}
```

---

## 6. External AI as a Record Source

When an AI contributes evidence (via `propose_fact` or `propose_correction`), the contribution is wrapped as a `SourceRecord` from a virtual source:

```swift
struct ExternalAISource: RecordSource {
    nonisolated let sourceID: String           // e.g. "claude-code"
    nonisolated let displayName: String        // e.g. "Claude Code Research"
    nonisolated let trustTier: SourceTrustTier = .community
    nonisolated let evidenceDirectness: EvidenceDirectness = .derivative
    nonisolated let dataLineage: SourceLineage  // .derivedFrom(sourceURLs)
}
```

The AI must provide:
- `source_urls` — what it based its finding on (web pages, documents, images)
- `evidence` — a human-readable explanation of how it reached the conclusion
- `reasoning` — the chain of thought (optional, for audit trail)

These go through `RecordScorer.classify()` like any other record. If the name doesn't match, it gets `.impossible`. If the date is implausible, it fails. The AI can't game the scorer.

---

## 7. Workflow Examples

### 7.1 Claude Code Researches the Whole Tree

```
Agent: list profiles sorted by GPS score ascending
App: returns 71 profiles, lowest GPS first

Agent: research_profile("profile-42", mode: "extend")
App: returns 3 clusters, 8 facts, 2 leads, GPS 3/5

Agent: [evaluates cluster confidence]
Agent: accept_cluster("cluster-0")  // Strong confidence, clear match
Agent: accept_cluster("cluster-1")  // Moderate confidence, spouse confirmed
Agent: [leaves cluster-2 for human — ambiguous, two possible people]

Agent: research_profile("profile-43", mode: "verify")
App: returns 1 cluster, 3 facts confirming existing data, GPS 4/5
Agent: accept_cluster("cluster-0")  // All confirmations

Agent: [continues through priority queue...]
Agent: [after 20 profiles, presents summary to human]:
  "Researched 20 profiles. 15 accepted automatically (strong/moderate confidence).
   3 need your review (ambiguous clusters). 2 had no results."
```

### 7.2 OCR Pipeline Contributes Parish Register Scans

```
OCR tool: POST /api/profiles/thomas-land-1834/propose-fact
  { field: "baptismDate", value: "6 April 1834",
    evidence: "OCR of Wirksworth parish register page 47",
    sources: ["file:///scans/wirksworth-1834-p47.tiff"] }

App: creates pending_fact, scores against existing data
  birth year 1834 matches tree — severity: none
  source trust: community, directness: derivative

Human sees in pending facts queue: "Baptism date 6 April 1834
  proposed by OCR pipeline, corroborates FreeBMD birth index."
```

### 7.3 Claude Code Triages Discrepancies

```
Agent: get_discrepancies for all profiles
App: returns 12 discrepancies across 8 profiles

Agent: [for each discrepancy, reads the conflicting sources]
Agent: [for 9 of 12: reasoning concludes one source is clearly right]
Agent: propose_correction("profile-17", "deathYear", "1891", "1890",
  evidence: "FreeBMD death Q4 1890 is registration quarter;
  Find a Grave says 1891 but memorial was user-submitted.
  FreeBMD has higher trust tier (transcription vs community).",
  sources: [])

Agent: [for 3 of 12: genuinely ambiguous]
Agent: [presents to human]:
  "Resolved 9 of 12 discrepancies automatically.
   3 need your judgement — conflicting primary sources."
```

---

## 8. Security and Trust

### 8.1 Localhost Only

Both MCP (stdio) and HTTP (localhost:9274) are local-only. No remote access, no authentication tokens. The threat model is the same as the app itself — if someone has local access to your machine, they already have access to the SQLite file.

### 8.2 Rate Limiting

External source queries (FreeBMD, FreeCen, etc.) are rate-limited by the existing `SourceHTTPClient` regardless of whether the request came from the human UI or the AI interface. An AI requesting 100 searches doesn't bypass the 500ms per-request delay.

### 8.3 Destructive Action Guard

The AI interface does NOT expose:
- Delete profile
- Delete relationship
- Drop table
- Undo transaction
- Direct SQLite access

These remain human-only operations through the SwiftUI interface.

### 8.4 Agent Identification

Every action through the AI interface is tagged with:
```json
{
  "agent_id": "claude-code",
  "session_id": "uuid",
  "action": "accept_cluster",
  "timestamp": "2026-04-25T14:30:00Z"
}
```

This appears in the transaction log alongside human actions. The tree's history shows "accepted by claude-code at 14:30" vs "accepted by user at 14:35".

---

## 9. Decision Boundaries

### 9.1 What the AI Can Do Autonomously

| Action | Condition | Rationale |
|--------|-----------|-----------|
| Accept a cluster | Confidence >= strong | No ambiguity, all gates pass |
| Accept a cluster | Confidence == moderate AND all facts corroborated by 2+ sources | High evidence quality |
| Dismiss a lead | Lead has been investigated and returned 0 results | Nothing to act on |
| Research a profile | Any profile with GPS < 5 | Pure information gathering |
| Search a source | Any query | Read-only |

### 9.2 What Requires Human Review

| Action | Always | Rationale |
|--------|--------|-----------|
| Accept an ambiguous cluster | Yes | Could be wrong person |
| Accept a weak cluster | Yes | Insufficient evidence |
| Resolve a discrepancy | Yes | Competing truth claims need judgement |
| Promote a lead to profile | Yes | Creates a new person in the tree |
| Delete or modify existing data | Yes | Destructive action |

### 9.3 Configurable Autonomy

Settings should allow the user to adjust the boundary:

```
AI Autonomy Level:
  [ ] Conservative — AI can only research, never accept
  [x] Standard — AI accepts strong clusters, defers everything else
  [ ] Aggressive — AI accepts strong + moderate, defers weak + ambiguous
```

Default: Standard.

---

## 10. Implementation Plan

### Phase 1: Service Layer Extraction

Extract a `ResearchService` facade that both SwiftUI views and the API layer call. Currently the views call `ResearchPipeline`, `ClusteringEngine`, etc. directly. A facade provides a clean API boundary.

```swift
@MainActor
final class ResearchService {
    func researchProfile(id: String, mode: ResearchMode) async -> ResearchResult
    func acceptCluster(id: String) async throws -> Int  // fields updated
    func rejectCluster(id: String) async throws
    func getProfile(id: String) -> ProfileDetail?
    func getLeads(profileID: String?) -> [Lead]
    func proposeFact(profileID: String, field: String, value: String,
                     evidence: String, sourceURLs: [String]) throws -> String
    // ... etc
}
```

### Phase 2: MCP Server Binary

Separate executable target in the Xcode project. Links the same service layer. Communicates via stdio JSON-RPC.

| Work | Detail |
|------|--------|
| MCP binary target | New executable in Xcode project |
| Resource handlers | Profile listing, detail, research results |
| Tool handlers | Research, accept, reject, propose |
| Prompt templates | Strategy, evaluation, resolution |
| Error mapping | Service errors → MCP error codes |

### Phase 3: HTTP API

Lightweight HTTP server using Swift's built-in `HTTPServer` or a minimal library (Hummingbird or raw NIO). Runs in-process, toggled from Settings.

| Work | Detail |
|------|--------|
| Server lifecycle | Start/stop from Settings toggle |
| Route registration | Mirror MCP tools as REST endpoints |
| JSON serialization | Codable types → JSON responses |
| Error responses | Consistent envelope format |

### Phase 4: Autonomy Engine

The logic that decides whether an AI action can proceed without human review or must be queued for approval.

| Work | Detail |
|------|--------|
| AutonomyPolicy struct | Configurable rules per action type |
| Action queue | Pending AI actions awaiting human approval |
| Notification | Badge on sidebar when AI actions need review |
| Settings UI | Autonomy level selector |

### Phase 5: Validation

| Work | Detail |
|------|--------|
| MCP integration test | Claude Code connects, researches 5 profiles, accepts strong clusters |
| HTTP API test | curl-driven test of all endpoints |
| Autonomy test | Verify AI cannot accept ambiguous clusters in Standard mode |
| Audit trail test | Verify agent actions appear in transaction log |

---

## 11. Open Questions

1. **Should the MCP server run embedded in the app or as a separate process?** Separate process is cleaner (app doesn't need to be running), but embedded shares the same database connection and source registry state.

2. **Should the HTTP API require a bearer token even on localhost?** Adds friction for legitimate use but prevents accidental access from other local processes.

3. **Should AI-accepted facts be visually distinguished in the tree?** E.g. a badge showing "accepted by claude-code" vs "accepted by user". Useful for audit but adds UI complexity.

4. **Should the AI be able to trigger whole-tree research?** The `research_batch` tool allows it, but 71 profiles × 7 sources × rate limiting = potentially hours of source queries. Should there be a global rate limit for AI-initiated research?

5. **Should contributions from different AI agents be tracked as different source lineages?** Claude Code finding + OCR pipeline finding = 2 independent lineages (both derivative), which could boost convergence to `.possible`. Is that appropriate?

---

## 12. What This Enables

With this interface, the research workflow becomes:

1. **Human imports tree** (GEDCOM or WikiTree)
2. **AI researches all 71 profiles overnight** (research_batch)
3. **AI accepts the obvious matches** (strong clusters, confirmations)
4. **AI triages discrepancies** (resolves 80%, flags 20% for human)
5. **Human reviews the 20%** that genuinely need judgement (ambiguous clusters, competing sources)
6. **Human reviews AI proposals** from OCR, document analysis, etc.
7. **Tree is complete** — GPS 4-5/5 across all profiles

The human's time goes from "research 71 profiles manually" to "review 15 decisions the AI couldn't make confidently." That's the value proposition.