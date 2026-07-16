# Triage UX + Data Quality

**Status: PROPOSED 2026-07-16.** Origin: finding Abraham Twyford's "Alport" birthplace lead
required manually scrolling the whole Research Findings list. Darryl: add search to Triage, a
per-profile "Leads" deep-link, and address the duplicates visible in the findings/leads lists.

## Changes

**Change 1 — search within Triage (S).** A search field in `BulkReviewView` filtering findings,
leads, and failures by name (profile name + lead name). Type "Abraham" → only his items. The
whole rabbit hole started here: you shouldn't have to eyeball a long list to find one profile's
lead. Prerequisite for Change 2.

**Change 2 — per-profile "Leads" deep-link (S/M).** A "Leads (n)" affordance on the profile that
switches to the Triage tab with the search pre-seeded to that profile, reusing Change 1's filter
and the existing pending-review deep-link mechanism.

**Change 3 — data-quality / dedup.** INVESTIGATED against real data 2026-07-16 (Cauldwell Family
Tree-2, via MCP `get_profile`). The screenshot-level "duplicates" were mostly NOT duplicates:
- **"Annie Cauldwell" vs "Annie E Cauldwell" — GENUINELY DIFFERENT people.** Annie (d.1978,
  parents John Cauldwell/Elizabeth, married R Smith) vs Annie E (b.1909, parents Robert
  Cauldwell/Ellen Ward, married Frank Fry). No merge — distinct. Screenshot guess was wrong.
- **"George Eric Vaughn Cauldwell" ×2 — ONE profile** (`@I_1564736174@`), TWO separate conflict
  findings. Not a data dup; a findings-DISPLAY issue. → optionally group findings per profile.
- **Leads ARE the real issue, but not as storage dups.** Ida Louisa Land's lead list holds
  "Ida L Land 1885" ×3, "Ida Land 1884" ×4, plus variants (Mathews/Matthews, Ida/Ada). Lead ids
  are deterministic per SOURCE (`lead_<scoredID>` etc.), so INSERT OR IGNORE already prevents
  true row dups — these are the SAME candidate identity surfaced from MANY source records, shown
  one-row-per-source. → **group leads by candidate identity (name + year) into one row ("N
  records/sources"); keep genuinely-competing candidates (Kasnowitz vs Land) separate.** This is
  display-side (safe), applied to BOTH the Triage leads section and the profile Leads list.

  Sub-item: fold transcription variants (Mathews/Matthews, Ida/Ada) — fuzzier, do after the
  exact (name,year) grouping proves out.

## Change 3 — leads triage rework (create-on-accept). DECIDED 2026-07-16.

**Model (Darryl):** a lead is a candidate, not something to blind-add. Today "Promote" calls
`promoteLeadToProfile` and mints a profile from thin data (often a one-record surname) with NO
research — backwards. Instead: **research the lead → review the evidence → accept**, and accept
is the only thing that touches the tree — attaching to an existing profile OR (create-on-accept)
materialising a new one. This REUSES the existing profile flow rather than a parallel path — the
same principle that made `ApplyEngine` one shared accept path (the 2026-05 accept-flow bug class
came from divergent paths). Investigation confirms the reuse surface is large: the pipeline
already researches leads (`ResearchSubject.fromLead`, `RunRequestWatcher.execute` lead branch,
`research_run_requests.lead_id`), and the review UI + accept path are subject-agnostic.

**Recon (2026-07-16, Explore agent):** the flow was ~85% already built — `startResearch(lead:)`,
`promoteLeadToProfile(into:)`, and the in-review "Promote to profile" button all exist; results
route to review automatically via `currentResult`; `research_run_requests` already has `lead_id`.
So 3c/3d needed no new machinery — just the 3b entry point to reach them.

**Slices:**
- **3a — reversible Dismiss. SHIPPED `8adb202`.** Collapsible "Dismissed leads (n)" section with
  Restore.
- **3b — Research action. SHIPPED `0afc06d`.** "Research" button on the Triage lead row →
  `AppState.researchLeadRequest` → ContentView trigger → `startResearch(lead:)` (discover mode).
  Mirrors the profile trigger; the interactive (not enqueued) path.
- **3c — route lead-run results to review. DONE (reused).** `startResearch(lead:)` sets
  `currentResult`, so ResearchView switches to `ClusterReviewView` exactly as for a profile.
- **3d — create-on-accept. DONE (reused).** In `ClusterReviewView`, a lead subject shows
  "Promote to profile" → `promoteLeadToProfile` materialises the ghost + attaches evidence, then
  the cluster Apply buttons write facts. Two labelled steps in-review = evidence-before-commit.
  (Optional future polish: collapse to a single "accept materialises" click.)
- **3e — retire blind Promote. SHIPPED `d7dbdd0`.** Blind Promote removed entirely (it minted
  incomplete profiles from one-record inferences — the risk this rework exists to kill; leaving
  it even demoted was wrong once Research shipped). Lead actions are now **Research** + **Dismiss**
  only; "add to tree" happens solely via the reviewed post-research promote-in-review.
  *Follow-up:* bare parent-surname leads ("[mother] /Mathews/") now have only a (weak) Research +
  Dismiss. If wanted, add a deliberate, clearly-labelled "add placeholder parent" affordance for
  those — distinct from the old blind Promote, and a smaller reviewed tree change.
- **3f — identity-grouping of leads (M).** Group leads by (surname+given+year) into one row
  ("N records"); competing candidates stay separate. Applied to Triage + profile Leads list.

**Order:** 3a → 3b → 3c → 3d → 3e → 3f. 3a ships independently; 3b–3d are the core flow; then
retire Promote and group.

**Note:** "Research" pays off for identity leads ("Ida L Land b.1885") but not bare parent-surname
leads ("[mother] /Mathews/"), whose meaningful accept is "add inferred placeholder parent" — a
smaller reviewed tree change. Both route through accept; the affordance may differ by lead kind.

## Order & gate
1 → 2, then 3 after a data investigation defines its exact scope. Each gated by full
`xcodebuild test`.

## Non-goals
Auto-merging profiles (surface candidates, user decides — firewall/"when in doubt split" hold).
