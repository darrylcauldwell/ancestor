# Field Researcher Specification (DEPRECATED)

**Status:** DEPRECATED — the in-app Claude API integration was removed in May 2026 ahead of App Store submission. The local MLX reasoning model (DeepSeek-R1) is now the sole AI tier, handling disambiguation, next-search suggestion, narrative synthesis, and free-text evidence extraction. The deterministic pipeline (4-gate scorer, clustering, convergence, hypothesis engine) is unchanged and remains the primary engine.

The historical spec below is preserved for reference but does not describe shipping code. The `FieldResearcherMCP` Swift package in this repo is unrelated — it's a developer-only MCP server (no outbound API calls) used to pair-program against the project database from Claude Code.

**Date:** 2026-04-25 (v5 — post-critique revision)  
**Depends on:** RESEARCH_PIPELINE_SPEC.md (governing spec for the research pipeline)

---

## 1. The Problem

The Ancestor Research app searches 7 structured genealogical sources (FreeBMD, FreeCen, CWGC, Probate, Wirksworth, FreeREG, Find a Grave). These cover civil registration indexes, census transcriptions, military casualties, probate grants, and parish register transcriptions. They are excellent for what they contain.

But they cover a fraction of the evidence that exists. Parish register photographs, newspaper archives, local history websites, family history forums, emigration manifests, trade directories, workhouse records, Poor Law records, wills, land records, apprenticeship indentures, poll books, school records — the real evidence is scattered across the internet in unstructured forms that no structured API covers.

A human genealogist finds this evidence by browsing, reading, reasoning, and following leads. That takes hours per profile. A frontier reasoning model can do the same work — read unstructured pages, interpret historical documents, cross-reference findings across sites — and bring evidence back for evaluation.

---

## 2. The Proposal

Add a **Field Researcher** capability. The Field Researcher is a frontier AI model (Claude) that reads the full tree context, reasons about what evidence is missing, searches the web for unstructured sources, and contributes findings back to the app for evaluation and human review.

The name comes from professional genealogy. A field researcher is someone hired to visit archives, read original documents, and report findings. Our Field Researcher does the same work — in the digital landscape. It is not "smarter pipeline." It is an external researcher who must produce citations. The same trust framework you apply to FreeBMD applies to the model — except that the trust tier is determined by what it cited, not by the fact that an AI surfaced it.

---

## 3. Three Layers of Intelligence

| Aspect | Deterministic Pipeline | Internal Advisor (MLX) | Field Researcher (Claude) |
|--------|----------------------|----------------------|--------------------------|
| **What it does** | Searches structured sources, scores records | Suggests between iterations | Searches the internet, reads documents |
| **Operates** | Inside the pipeline | Inside the deterministic sandwich | Outside the pipeline entirely |
| **Can see** | Records from 7 sources | Same records + pipeline state | Full tree + the entire internet |
| **Can change** | Nothing — produces results for review | Nothing — produces suggestions | Nothing — contributes evidence for review |
| **Constrained by** | Its own deterministic rules | The deterministic sandwich | The Evidence Firewall (§4) |
| **Cost** | Free (local HTTP to sources) | Free (local inference) | API usage (user pays) |
| **Trust tier** | Varies per source | N/A (not a source) | Determined by cited URL (§5) |

---

## 4. The Evidence Firewall

The hard boundary between AI output and the family tree. Applies identically whether the Field Researcher runs externally (MCP, Phase 1) or inside the app (Phase 2).

### 4.1 The Boundary

```
                    ┌─────────────────────┐
                    │  EVIDENCE FIREWALL   │
                    │                     │
   AI SIDE          │                     │    TREE SIDE
   (free-thinking)  │                     │    (deterministic)
                    │                     │
   Web searching    │   pending_facts ────┼──→ hallucination checks
   Document reading │   leads ────────────┼──→ 4-gate scorer
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

### 4.2 Eight Rules

**Rule 1: Nothing enters without scoring.**  
Every finding passes through hallucination checks (§4.3) then `RecordScorer.classify()`. The model's self-assessed confidence is logged but ignored for scoring. If the scorer says impossible, the finding is rejected.

**Rule 2: Source URL required and verified.**  
A finding without a verifiable source URL is discarded before scoring. Verification is a full GET (not HEAD) of the URL, confirming:
- HTTP 200 response
- Page content contains the `evidence_text` (normalised string match with whitespace/punctuation tolerance)
- URL is not a blocked pattern (AI content generators, user's own tree, social media)

The fetched page is cached locally for provenance. If the page later changes or disappears, the cached version proves the citation was valid at submission time.

**Rule 3: Structured submission only.**  
The AI submits findings through typed tools with required fields. Free text is not inserted anywhere. If a field name is invalid or a value can't be parsed, the finding is rejected at the interface before scoring.

**Rule 4: No manufactured convergence.**  
Two findings citing the same underlying URL are one lineage, enforced by `SourceLineage.derivedFrom`. The model cannot boost convergence by submitting the same finding twice with different wording, or by citing a secondary source that itself cites the primary. URL deduplication across all findings per profile.

**Rule 5: Trust tier derived from cited source, not from the AI.**  
The AI itself is not a source. The URL it cites is the source. Trust tier and evidence directness are determined by looking up the cited URL's domain in the Source Tier Registry (§5). A parish register transcription on freereg.org.uk is transcription tier. A forum post on rootschat.com is community tier. An unknown domain defaults to community/derivative.

When the Field Researcher is the only source for a fact (no corroboration from structured sources), convergence caps at `.possible` regardless of the URL's tier. With structured source corroboration, the finding contributes to convergence normally based on its URL's tier.

**Rule 6: Hallucination detection before scoring.**  
Heuristic checks run before the 4-gate scorer:

| Check | Rejects if |
|-------|-----------|
| Date sanity | Year < 1500 or > current year |
| Name plausibility | Non-alphabetic characters, suspiciously long, or empty |
| Location consistency | Location not in gazetteer (when checkable) |
| Self-contradiction | Contradicts another finding from the same session |
| Temporal impossibility | Married at 3, died before birth, etc. |
| Source recycling | URL already cited for a different person in same session |
| Content mismatch | evidence_text not found in fetched page content (Rule 2) |

**Rule 7: Human always decides.**  
No finding enters the tree without human approval. Review friction is `individualReview` minimum. The human sees: evidence text (capped at 200 characters, with link to cached full source), 4-gate score, convergence assessment, any discrepancy with existing data, and the model's reasoning (collapsible).

**Rule 8: Session isolation with exceptions.**  
Each session is independent. The model cannot access:
- Its own previous session findings (prevents hallucination reinforcement)
- Rejected findings from any session (prevents rewording rejected claims)

The model CAN access:
- Negative search history from prior sessions (prevents wasting effort re-searching dead ends)
- URL citation history from prior sessions (enables source-recycling detection in Rule 6)
- The current tree state (including facts added from prior sessions that the human accepted)

### 4.3 Discrepancy Handling

Field Researcher findings pass through the same discrepancy detection as structured source findings. When a finding contradicts existing tree data:

1. `DiscrepancySeverityTable.severity()` computes severity based on the URL's trust tier (from Source Tier Registry), the delta, and current convergence
2. The finding enters `pending_facts` tagged with the discrepancy
3. The review UI shows: "This contradicts existing data. Tree says X (source: FreeBMD). Finding says Y (source: parish register transcription). Severity: conflict."
4. The human resolves: accept new value, keep existing, or defer

This is identical to how the pipeline handles structured source discrepancies. The Field Researcher gets no special treatment.

---

## 5. Source Tier Registry

A mapping from URL domains to trust tiers. This is what makes Rule 5 work — the AI's contribution is trusted as much as the source it cited, not more and not less.

### 5.1 Registry Structure

```swift
struct SourceTierEntry {
    let domainPattern: String           // "freereg.org.uk", "*.archive.org"
    let trustTier: SourceTrustTier
    let evidenceDirectness: EvidenceDirectness
    let description: String
    let category: SourceCategory
}

enum SourceCategory {
    case officialArchive        // National Archives, county record offices
    case volunteerTranscription // FreeREG, FreeBMD, FreeCen
    case communityCompilation   // Find a Grave, WikiTree, family forums
    case commercialProvider     // Ancestry, FindMyPast (if accessible)
    case academicResource       // university archives, history societies
    case unknown                // default for unrecognised domains
}
```

### 5.2 Initial Registry (Hand-Curated)

| Domain | Trust Tier | Directness | Category | Rationale |
|--------|-----------|------------|----------|-----------|
| freereg.org.uk | transcription | directTranscription | volunteerTranscription | Volunteer transcriptions of parish registers |
| freebmd.org.uk | transcription | directTranscription | volunteerTranscription | Volunteer transcriptions of GRO indexes |
| freecen.org.uk | transcription | directTranscription | volunteerTranscription | Volunteer transcriptions of census returns |
| cwgc.org | primary | primary | officialArchive | Official government military records |
| probatesearch.service.gov.uk | primary | primary | officialArchive | Official HMCTS probate records |
| nationalarchives.gov.uk | primary | primary | officialArchive | UK National Archives |
| findagrave.com | community | derivative | communityCompilation | Volunteer-submitted memorials |
| wirksworth.org.uk | transcription | directTranscription | volunteerTranscription | Parish register transcriptions |
| genuki.org.uk | transcription | directTranscription | academicResource | County-level genealogical information |
| familysearch.org | community | derivative | communityCompilation | Community-edited tree + record images |
| ancestry.co.uk | transcription | directTranscription | commercialProvider | Commercial transcriptions (if accessible) |
| findmypast.co.uk | transcription | directTranscription | commercialProvider | Commercial transcriptions (if accessible) |
| archive.org | transcription | directTranscription | academicResource | Digitised historical documents |
| britishnewspaperarchive.co.uk | transcription | directTranscription | commercialProvider | Newspaper archive (restricted — see §5.3) |
| rootschat.com | community | derivative | communityCompilation | Forum discussions |
| wikitree.com | community | derivative | communityCompilation | Community-edited tree |
| geni.com | community | derivative | communityCompilation | Community-edited tree |

**Default for unknown domains:** `community` / `derivative` / `unknown`.

The registry starts with ~50 entries covering major UK genealogy sites and grows as the Field Researcher encounters new domains. New entries can be proposed by the user or auto-suggested when the app encounters an unrecognised domain with multiple findings.

### 5.3 Restricted Sources

Some sources have copyright or licence restrictions on their content:

| Domain | Restriction | Handling |
|--------|------------|---------|
| britishnewspaperarchive.co.uk | Paywalled, licence-restricted | evidence_text replaced with "[restricted source — verify at URL]" |
| ancestry.co.uk | Subscription required | Same treatment |
| findmypast.co.uk | Subscription required | Same treatment |

For restricted sources: the finding is still scored (name, date, geography gates can evaluate from the value), but the evidence_text stored is a pointer, not a quote. The human must verify the claim by visiting the source directly.

### 5.4 Evidence Text Handling

`evidence_text` is capped at **200 characters**. This is:
- Sufficient for genealogical citation ("Thomas son of William and Mary Land, bpt 6 April 1834, Wirksworth")
- Within fair-use limits for copyrighted material
- Small enough for efficient storage

For the full source text, the cached page (Rule 2) serves as the reference. The human can view the cached page or follow the URL.

Normalisation: evidence_text is stored as plain text. HTML tags stripped. Whitespace collapsed. Unicode normalised to NFC.

---

## 6. Submission Interface

### 6.1 submit_evidence — Structured Facts

For evidence that maps to a specific profile field.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `profile_id` | string | yes | Which profile this evidence is about |
| `field` | string | yes | See field vocabulary below |
| `value` | string | yes | The proposed value |
| `source_url` | string | yes | URL where found |
| `source_title` | string | yes | Human-readable source name |
| `evidence_text` | string | yes | Exact text from source (max 200 chars, plain text) |
| `reasoning` | string | yes | How this was connected to this profile |
| `confidence` | string | yes | `high`, `medium`, or `low` |

**Field vocabulary** (extensible — unknown fields rejected with clear error):

| Field | Example value | Notes |
|-------|-------------|-------|
| `birthDate` | "6 April 1834" | Full date or year |
| `deathDate` | "1890" | Full date or year |
| `baptismDate` | "6 April 1834" | Parish register baptism |
| `burialDate` | "15 March 1891" | Parish register burial |
| `birthLocation` | "Wirksworth, Derbyshire" | Place of birth |
| `deathLocation` | "Belper, Derbyshire" | Place of death |
| `marriageDate` | "Q3 1858" | Date of marriage |
| `marriageLocation` | "Wirksworth, Derbyshire" | Place of marriage |
| `occupation` | "lead miner" | Census or other source |
| `address` | "High Street, Wirksworth" | Address at a point in time |
| `religion` | "Church of England" | Parish affiliation |

When the Field Researcher submits a field not in this list, the submission is rejected with: "Field 'apprenticeshipMaster' not yet supported. Submit as a narrative finding or as a lead with this evidence."

### 6.2 submit_narrative_finding — Unstructured Biographical Evidence

For evidence that doesn't map to a single field — the things structured sources don't capture.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `profile_id` | string | yes | Which profile this is about |
| `category` | string | yes | See categories below |
| `description` | string | yes | What was found (plain text, max 500 chars) |
| `date_or_period` | string | no | When this applied (e.g. "1845", "1841-1851") |
| `source_url` | string | yes | URL where found |
| `source_title` | string | yes | Source name |
| `evidence_text` | string | yes | Exact text from source (max 200 chars) |
| `reasoning` | string | yes | How connected to this profile |

**Categories** (extensible):

| Category | Example |
|----------|---------|
| `apprenticeship` | "Apprenticed to John Smith, blacksmith, 1845" |
| `will_probate` | "Left £200 to son Thomas, £50 to daughter Mary" |
| `newspaper` | "Thomas Land, bankrupt, Belper — Derby Mercury 1872" |
| `emigration` | "Sailed on SS Great Britain to Melbourne, 1853" |
| `military_service` | "Enlisted 2nd Battalion, Sherwood Foresters, 1915" |
| `education` | "Pupil at Wirksworth Grammar School, 1847" |
| `land_property` | "Tenant of lead mine lease, Middleton, 1860" |
| `poor_law` | "Admitted to Belper Union Workhouse, 1842" |
| `trade_directory` | "Land, Thomas, lead miner, Wirksworth — White's Directory 1857" |
| `inscription` | "Memorial inscription: In loving memory of Thomas Land, 1834-1890" |
| `other` | Anything that doesn't fit above |

Narrative findings are stored in the profile's timeline and displayed alongside structured facts. They are NOT scored through the 4-gate scorer (they don't propose a specific field value) but they ARE subject to hallucination checks (date sanity, URL verification, evidence text content match).

### 6.3 submit_lead — New Person Discovery

For discovering a person not yet in the tree.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `source_profile_id` | string | yes | The profile this lead relates to |
| `name` | string | yes | Full name of the discovered person |
| `relationship` | string | no | `father`, `mother`, `spouse`, `child`, `sibling` |
| `birth_year` | integer | no | Approximate birth year |
| `death_year` | integer | no | Approximate death year |
| `evidence` | string | yes | Why this person is believed to exist |
| `source_url` | string | yes | URL where found |

**Lead-to-existing-profile resolution:** When a lead is submitted, the app checks for existing profiles with matching name and dates (±5 years). If a strong match exists:
- The lead is flagged as "possible match to existing profile [name]"
- The human decides: merge (lead becomes evidence on existing profile), keep as separate lead, or dismiss
- No auto-merge — this is a personal tree app where wrong merges are expensive to undo

**Parent name handling:** When a finding names a parent (e.g. "Thomas son of William and Mary Land"), it should be submitted as a lead (`submit_lead` with `relationship: "father"`) NOT as `submit_evidence` with field `fatherName`. A parent is a person, not a string field. The lead creation path triggers proper investigation.

---

## 7. MCP Server — Profile Context

### 7.1 What the Agent Sees

The profile resource (`ancestor://profile/{id}`) returns rich context, not just counts. For each profile:

**Identity and dates:**
```json
{
  "id": "thomas-land-1834",
  "first_name": "Thomas",
  "last_name": "Land",
  "birth_date": "1834",
  "birth_location": "Derbyshire",
  "death_date": null
}
```

**Each existing fact with its source and tier:**
```json
{
  "confirmed_facts": [
    {
      "field": "birthYear",
      "value": "1834",
      "source": "FreeBMD",
      "source_tier": "transcription",
      "citation": "Birth index Q2 1834, Bakewell district"
    }
  ]
}
```

**Each relationship with the related person's key fields:**
```json
{
  "relationships": [
    {
      "type": "parent_child",
      "role": "father",
      "person": "John Land",
      "person_id": "john-land-1858",
      "birth": "1858",
      "death": null
    }
  ]
}
```

**Negative searches with scope:**
```json
{
  "negative_searches": [
    { "source": "freecen", "type": "census", "years_searched": "1841-1911", "date": "2026-04-25" },
    { "source": "cwgc", "type": "death", "note": "not military eligible", "date": "2026-04-25" }
  ]
}
```

**Active leads and their status:**
```json
{
  "leads": [
    { "name": "William Land", "relationship": "father", "status": "new", "evidence": "..." }
  ]
}
```

**URL citation history (for source-recycling detection):**
```json
{
  "cited_urls": [
    "https://freereg.org.uk/...",
    "https://findagrave.com/memorial/..."
  ]
}
```

This context lets the model know: what's already confirmed, what's already been tried and failed, what leads exist, and what URLs have already been cited. The model can then focus on the gaps that structured sources didn't cover.

---

## 8. GPS Attribution

Field Researcher findings affect GPS scoring through the underlying sources they cite, not through the Field Researcher itself.

### 8.1 Exhaustive Search (GPS Criterion 1)

"Exhaustive search" means all applicable sources have been searched. The Field Researcher is not a source — it is a researcher who cites sources. When it cites freereg.org.uk, that is equivalent to having searched FreeREG. When it cites a county history society website, that counts as having searched that archive.

GPS criterion 1 counts: structured sources searched (via pipeline) + distinct domains cited by Field Researcher (via Source Tier Registry lookup). If the Field Researcher cited 3 domains not covered by the structured pipeline, that's 3 additional sources searched.

However: the Field Researcher may have cherry-picked results rather than comprehensively searched. A pipeline search of FreeBMD is exhaustive for that source. A Field Researcher session that found one result on freereg.org.uk is not exhaustive for FreeREG. The GPS display should distinguish: "FreeREG: searched via pipeline (exhaustive)" vs "FreeREG: cited by Field Researcher (partial)."

### 8.2 Convergence (GPS Criterion 3)

Convergence works normally. The finding's trust tier comes from the Source Tier Registry based on URL. Two independent lineages (e.g. FreeBMD transcription + Field Researcher citing a parish register transcription) with combined trust score ≥ 4 produce `.probable`.

**Correction from v4 walkthrough:** FreeBMD (transcription, trust 2) + parish register website (transcription via registry, trust 2) = trust score 4, two independent lineages → `.probable`, not `.possible`.

The `.possible` cap applies ONLY when the Field Researcher is the sole source (no structured source corroboration) — regardless of what the URL's tier is. This prevents a single AI session from producing "confirmed" facts, while still allowing AI-found evidence to meaningfully strengthen existing evidence.

---

## 9. Phased Approach

### Phase 1: MCP Server (External, At Arm's Length)

Standalone executable opens the project database. Claude Code connects via MCP. The human drives the research manually through Claude Code and reviews findings in the app.

**What's built:** MCP server binary, resources, tools, prompts. Writes to pending_facts and leads.

**What's still needed:**
1. Source Tier Registry (§5) — hand-curated domain list
2. Pending facts processing in the app — read pending_facts, run hallucination checks, score through pipeline, present for review
3. URL fetch + content verification + caching (Rule 2)
4. Narrative finding support (§6.2) — new table and review UI
5. Lead-to-existing-profile matching (§6.3)
6. Discrepancy detection for Field Researcher findings (§4.3)
7. Rich profile context in MCP resources (§7.1) — include facts with sources, not just counts

**Validation:** Research 5 profiles via Claude Code + MCP. Measure:
- GPS improvement per profile
- Findings that pass scoring vs total submitted
- Findings that corroborate structured sources vs genuinely new evidence
- Cost per useful finding

### Phase 2: In-App Feature (If Phase 1 Proves Useful)

Move the Field Researcher inside the app. Add Claude API client, settings UI, in-app conversation orchestration, live progress, cost tracking.

The firewall is identical. The user experience changes from "two processes" to "one app."

**Decision gate:** Phase 2 starts only after Phase 1 demonstrates measurable GPS improvement on at least 3 of 5 test profiles, with a cost-per-useful-finding below $0.10.

---

## 10. Cost Model (Phase 2)

**Unit:** dollars per session, displayed in real-time.

**Budget controls:**
- Per-session budget set in Settings (default: $0.50)
- Soft warning at 75% of budget ("approaching limit — 3 findings remaining")
- Hard stop at 100% — session ends, all findings submitted so far are preserved in pending_facts
- Pre-session estimate: before starting, the app estimates token count for the context and warns if the context alone exceeds 25% of budget

**Tracking:** A `field_researcher_sessions` table records each session with:
- Profile researched
- Tokens used (input + output)
- Cost (computed from model pricing)
- Findings submitted
- Findings that passed scoring
- Duration

This table is inside the firewall (the app writes it, not the AI). It is listed explicitly because the firewall diagram says "pending_facts and leads ONLY" — session tracking is a third write target, but it's app-internal, not AI-writable.

---

## 11. What the Field Researcher Cannot Do

| Operation | Why excluded |
|-----------|-------------|
| Write to `profiles` | Must go through pending_facts → scoring → review |
| Write to `relationships` | Must go through leads → investigation → review |
| Delete any record | Destructive operations are human-only |
| Read rejected findings | Prevents rewording rejected claims |
| Read its own previous findings | Prevents hallucination reinforcement |
| Set trust tier directly | Determined by Source Tier Registry from URL |
| Submit without source URL | Provenance is mandatory |
| Submit evidence_text > 200 chars | Copyright safety + storage hygiene |
| Access other project databases | Scoped to one project |
| Bypass hallucination checks | Checks run before scorer, not optional |
| Bypass 4-gate scorer | Scorer is deterministic and non-negotiable |

---

## 12. Schema Version Compatibility

The MCP server declares its supported schema version range and refuses to start against incompatible databases.

```swift
let supportedSchemaVersions = 3...4  // v3 (leads), v4 (pending_facts, scored_records)
```

On startup, the MCP server reads the migration state from the database. If the schema is too old (no pending_facts table) or too new (unknown migrations), it exits with a clear error: "Database schema version X is not supported. This MCP server requires version 3-4. Update the app or the MCP server."

---

## 13. Idempotency

Each `submit_evidence` and `submit_lead` call includes a deterministic ID derived from the finding's content:

```
evidence_id = SHA256(profile_id + field + value + source_url)
lead_id = SHA256(source_profile_id + name + source_url)
```

If the MCP server crashes mid-session and the agent retries, duplicate submissions are silently deduplicated by the database (INSERT OR IGNORE on the content-derived ID). The agent can safely retry without knowing which submissions succeeded.

---

## 14. Open Questions

1. **Should we cache fetched pages permanently or with TTL?** Permanent cache preserves provenance forever but grows unbounded. A 90-day TTL is more practical but loses provenance for old findings. Compromise: cache permanently but with a storage budget and LRU eviction of pages older than 1 year whose findings were rejected.

2. **Should the Source Tier Registry be user-editable?** A power user might recognise that a specific county history society website is as reliable as FreeREG. Allowing user edits increases flexibility but risks inflating trust tiers. Compromise: user can propose upgrades that are flagged in review ("trust tier upgraded by user from community to transcription").

3. **Multi-profile family sessions in Phase 2?** Researching Thomas Land and his wife Mary together shares context efficiently. But session isolation (Rule 8) prevents cross-profile findings from influencing each other. Resolution: allow family-group sessions with shared tree context but separate finding streams per profile. Each profile's findings are scored independently.

4. **AI-generated content detection for blocked URLs?** The spec blocks AI-generated content sites but detecting them requires a maintained blocklist that will always lag. Practical mitigation: focus on positive signals (domain in Source Tier Registry → trusted) rather than negative signals (blocklist → untrusted). Unknown domains default to community/derivative, which is conservative enough.

5. **Should the Field Researcher cite the structured pipeline's results?** If FreeBMD found a birth record, and the Field Researcher also finds the same record on a different website, should it submit that as corroboration? Or is that redundant? Current answer: yes, submit — the convergence engine handles it correctly (two independent lineages if different URLs, one lineage if same underlying data). But the profile context (§7.1) should clearly show what's already confirmed so the model focuses elsewhere.
