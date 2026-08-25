# SURFACE_CONSOLIDATION_SPEC — per-profile is the review surface

**Status:** IMPLEMENTED · 2026-08-25 — all nine changes shipped. SC-1/2/3/6
landed as individual commits; SC-7/8/9 landed together as `3356bbb` (the three
retirements are one code change: ResearchView hosts all of them). Change 4
shipped early as #36 (`6cd3f4e`); Change 5 was satisfied by the existing
narrative block. This document is now the as-built record.
**Supersedes:** task #38 (watermark) entirely; absorbs task #36 (relationship
proposals) as Change 5; relocates task #37's sibling rules into Change 2.

## Owner rulings (2026-08-24, decision log)

1. **Per-profile won.** Research results surfaced per-profile are the usable
   form — full context is visible. Research is most useful *targeted and
   per-profile*.
2. **Retire the Research tab** and **retire the Triage tab** as workspaces.
3. **Cross-profile routing lives in the Workbench** — not a new Inbox surface.
   Workbench is already the "what am I working on" home.
4. **Possible People is retired outright** — it never earned its place.
5. **No whole-tree runs.** Results are overwhelming and the sweep throttles
   volunteer sources. (Also consistent with the standing volunteer-source
   restraint posture.)

**Session evidence:** the entire 2026-08-24 Beresford/Wheeldon apply run was
actioned per-profile and worked. Triage obstructed twice (sibling leads with no
add-path; the mark-reviewed watermark hiding four actionable leads). The
Research tab was never needed: recon confirmed there is *no programmatic route
to it anywhere* — every "research this person" entry point already goes through
`researchProfileID`/`researchConfigProfile`, handled centrally by ContentView
with ResearchConfigSheet + ResearchProgressSheet, no tab switch. The tab is
already vestigial.

## North star

One review surface: the profile. One router: the Workbench. Research is
launched per-profile, reviewed per-profile; the Workbench answers "what needs
my attention, anywhere?" with counts and jump-links — it routes, it never
reviews. Nothing is deleted until its only action-path has a per-profile home.

## Architecture facts the plan rests on (recon 2026-08-24)

- Research and Triage are **one view**: `ResearchView` with a `Role` enum,
  instantiated twice in ContentView (lines ~161/163). Retiring both tabs
  orphans `ResearchView`, `BulkReviewView`, `PossiblePeopleView`,
  `PendingFactsReviewView` (needs a new host), and `WholeTreeResearchViewModel`.
- `ClusterReviewView` + `ResearchProgressView` survive independently via the
  detached `record-review` window (`ReviewWindowRoot`) — but that window's only
  opener today is ResearchView's Open-in-Window button.
- **MCP `kick_off_research` is fully independent** of campaign machinery:
  MCPServer inserts `research_run_requests`; `RunRequestWatcher` (owned by
  AppState) executes via `ResearchRunService` and bridges facts into
  `pending_facts`. `RunRequestWatcher`, `ResearchRunService`,
  `RunResumeCoordinator`, `HypothesisSeedService` **must survive**.
- The campaign watermark (`project_meta.campaign_review_high_water`) and
  `campaignEntries`/`campaignLeads` are used **only** by BulkReviewView.
  `CampaignReviewService.reconstructResult` has one outside consumer: the
  detached window's no-handoff fallback.
- **`pending_relationships` is an orphaned queue**: MCP writes it "for human
  review" but *no app view reads it at all*. Relationship proposals currently
  have no review surface anywhere. (Discovered when five approved-in-good-faith
  proposals turned out never to have been reviewable.)
- **`narrative_findings` has no accept verb** anywhere — display (profile
  Notes block, read-only cards in PendingFactsReviewView) and hard delete only.
  Per-profile narrative review already exists de facto.
- `LeadKind` is **not** used by Triage's add buttons (CampaignReviewService has
  its own narrower parser) — it deletes cleanly with Possible People.
- `IdentityConstraints`, `LeadContradictionCheck`,
  `ResearchViewModel.startResearch(lead:)`, `ProjectDatabase+PromoteLead`,
  `CampaignReviewService`'s pure lead-policy helpers (`addAction`, `mayAttach`,
  `parentRole`, `leadGroupKey`), and `LocalInferenceService` all have consumers
  outside the retired surfaces and **must survive**.
- `FrictionTier`/`ReviewFriction` are defined file-level inside
  BulkReviewView.swift but are a tested routing seam (GPSConflictReportingTests)
  — they move to Services, not to the bin.

## Changes

Ordering is load-bearing: Changes 1–5 build the per-profile homes, Change 6
builds the router, Changes 7–9 retire. **Never remove the only path to an
action.**

### Change 1 — Pending-fact review hosts on the profile

`PendingFactsReviewView` is already `profileID`-scoped. Re-host it from the
profile card: the pending-facts badge (SharedProfileLayout ~1848) presents it
directly (sheet or inline expansion) instead of deep-linking to Triage
(`requestPendingReviewProfileID` + tab switch). The host must supply the exit
affordance (today ResearchView supplies "Done"). The capped pending-records
expander's "review all in Triage" overflow (SharedProfileLayout ~1498)
becomes "review all" opening the same host.

*Accept:* clicking the orange "N pending" badge opens the cards in place; the
two-part deep-link protocol (`requestSidebarTab` + payload mailbox) has no
remaining pending-facts consumer.

### Change 2 — Lead review hosts on the profile

Today a profile shows only a lead *count*; promote/dismiss live exclusively in
Triage. Build a leads section on the profile card (SharedProfileLayout):

- Rows use the existing pure policy: `CampaignReviewService.addAction`
  (contextual **Add as mother/father/child/spouse**), `mayAttach`
  (attach-vs-create guard), `leadGroupKey` (identity collapse),
  `LeadContradictionCheck` (contradicted fold), dismissed fold with restore.
- **#37 lands here:** a sibling lead whose generator has both parents in the
  tree renders "Add as child of X × Y" (build the parent edge(s) at
  promotion); with parents missing, the row says *why* there is no Add
  ("siblings are added as children of shared parents — add the parents
  first").
- Promotion that creates one edge SHOULD offer the second (mother) edge when
  the household evidence names both parents — the 2026-08-24 run left four
  mother edges dangling behind proposals nobody could review.
- The store-wide guarantee moves to the Workbench router (Change 6) — the
  profile section shows *this* profile's leads, all of them, no watermark.

*Accept:* every lead action possible in BulkReviewView today is possible from
the generating profile's card; the 2026-08-24 walkthrough (promote spouse +
two children on Walter Beresford b.1882) completes without leaving the profile.

### Change 3 — Post-run review opens per-profile

A completed run currently hands off to Triage (ResearchProgressSheet onDismiss
→ `.triage`). Instead: "Review results" opens `ClusterReviewView` for that
profile — in the detached `record-review` window (which already hosts it with
a fresh VM and project-identity guard) or as a sheet from the profile. The
Re-research/Thorough menu moves with the review header. `ReviewWindowRoot`'s
no-handoff fallback (`reconstructResult`) already covers reopen-later.

*Accept:* kick off research from a profile, review every cluster, apply/discard
— without the Triage tab existing. Open-in-Window gains a non-ResearchView
opener (the profile review host).

### Change 4 — Relationship-proposal review exists (absorbs #36)

Build the missing consumer of `pending_relationships`: a review block on BOTH
endpoint profiles (same card pattern as pending facts — evidence text,
reasoning, citation link, Approve/Reject). Approve creates the edge (and, per
#36, `submit_relationship_proposal` gains `marriage_date`/`marriage_location`
carriage and may enrich an existing spouse edge rather than requiring a new
one). Reject records the verdict; nothing silently expires.

*Accept:* an MCP-submitted spouse/parent proposal is visible on the affected
profiles, approvable, and the approved edge (with marriage date/location when
carried) appears in the tree. The five stranded Wheeldon proposals from
2026-08-24 become the live test specimens.

### Change 5 — Narrative verbs get honest

Narratives already review per-profile (display + delete). Add the missing
half-verb: a "keep" acknowledgement is unnecessary, but REJECT should be a
first-class action (today it is a bare hard-delete with no record). Minimum:
delete stays; the block links each narrative's citation; stale duplicates
(superseded citation URLs) are flagged. No new queue.

*Accept:* the 2026-08-24 case — reject an old generic-URL marriage narrative,
keep its information.pl successor — is achievable and comprehensible on the
profile card.

### Change 6 — Workbench router ("Needs attention")

A new Workbench section, top position: store-wide counts with jump-links —
"N pending facts on <profile> →", "N leads on <profile> →", "N relationship
proposals →", "N open disputes →", "run in progress / awaiting review →".
Each link opens the profile (Changes 1–4 hosts). No review actions in the
router itself. No watermark: the queues are the truth; a row disappears when
its queue empties. This preserves the store-wide guarantee that Triage's
store-wide lead gathering provided (the 2026-08-21 lesson: findings must never
be reachable only by knowing which profile to open).

*Accept:* with all tabs retired, MCP-submitted leads/facts/proposals on any
profile are discoverable from the Workbench in ≤2 clicks.

### Change 7 — Retire Possible People

Delete outright (recon-verified no other production consumers):
`PossiblePeopleView`, `LeadDiscoveryEngine` (+`EmergentCluster`/`Coherence`),
`LeadKind`, `ClusterContext`, `ClusterAdjudicator`, `LeadEmbedding.swift`
(TextEmbedder/DeterministicTextEmbedder/VectorMath), `MLXTextEmbedder`,
`AppState.requestPossiblePeopleProfileID`,
`ProfileDetailView.possiblePeopleSection` + `reloadSurfacedLeadCount`,
ResearchView's `TriageMode.people` branch + scope plumbing; tests
`LeadDiscoveryEngineTests`, `ClusterContextTests`, `ClusterAdjudicatorTests`,
`LeadKindTests`; excise MLXTextEmbedder assertions from
`LocalAIEnablementTests`. **Must go in the same change** (or they dangle):
`Ancestor_ResearchApp.autoLoadEmbedderIfEnabledAndPresent`, the onboarding
wizard's embedder download-consent step, SettingsPlaceholderView's Local AI
embedder toggle, and the `semanticEmbedderEnabled` @AppStorage key.
KEEP: `IdentityConstraints`, `LeadContradictionCheck`, `startResearch(lead:)`,
`PromoteLead`, `LocalInferenceService`, `Lead` + `upsertLead` dismissal path.

### Change 8 — Retire whole-tree runs

Delete `WholeTreeResearchViewModel` (its restoreProgress was already a stub),
the "Research All" confirmation flow, whole-tree progress rendering, **and the
"Backfill FreeBMD links (N)" button** (owner ruling 2026-08-24: never used —
delete; its job is covered by per-profile re-research, which captures entry
links, and the #27 citation-correction-on-re-accept machinery). The
`freeBMDCitationGapFindings` audit scan may stay as a Health finding without a
sweep button.

### Change 9 — Retire the tabs; navigation cleanup

Remove `.research` and `.triage` from `SidebarTab` (declared at the bottom of
ContentView.swift). Touch list (recon-verified): SidebarView `visibleTabs` +
icon switch (fallback-to-.tree already handles a vanished selection);
ContentView's two ResearchView instantiations + shared-VM wiring + Cmd+3
shortcut (remap: Cmd+2 tasks, Cmd+3 workbench?); ResearchProgressSheet
onDismiss handoff (→ Change 3 host); UnifiedTasksView leads banner
`onOpenTriage` (→ Workbench router or profile); GettingStartedView entries
(lines ~31/33) + copy; `ScreenshotScreen` `.research`→`.triage` mapping (new
target: the profile card or Workbench — screenshots must still capture a
review surface); `ReviewWindowRoot`/app placeholder copy ("Pop a review out
from Triage or the Research tab"); dead modifiers in ResearchView 241-245 die
with the file. Move `FrictionTier`/`ReviewFriction` from BulkReviewView.swift
into Services (tested seam; the Workbench router may reuse `route` for row
severity). Campaign leftovers deleted with BulkReviewView: the watermark
accessors (+ its `project_meta` key via migration note, not a schema change),
`campaignEntries`, `campaignLeads`, `CampaignReviewServiceTests` watermark
cases, `CampaignLeadVisibilityTests` (their *policy* cases move alongside the
helpers they test). `reconstructResult` stays (detached-window fallback).

## Explicitly NOT retired

MCP surface (all 34 tools), `RunRequestWatcher` + run-request pipeline,
`ResearchRunService`, `ClusterReviewView`, `ResearchProgressView`/Sheet,
detached record-review window, `PendingFactsReviewView` (re-hosted), the
Evidence Firewall queues themselves, per-profile research kick-off, the
deterministic sandwich. The Findings *queue* retires but findings do not:
MCP-run facts already bridge into `pending_facts` (per-profile cards), and
evidence records review through the profile evidence expander — which is how
the owner actually works.

## Open questions (owner)

None — all resolved below.

## Resolved

- Cmd+3 → **Workbench** after Triage retires (owner, 2026-08-25).
- Screenshot "research" scene → **profile card with review work** (owner,
  2026-08-25).
- The gap-ranked research launcher → **compact "Research suggestions"
  section in the Workbench router** (owner, 2026-08-25); the full
  Research-tab launcher dies with the tab.
- Change 4 shipped early as task #36 (`6cd3f4e`, 2026-08-25) — the
  relationship-proposal review surface with marriage carriage.

- FreeBMD backfill sweep: **delete** with whole-tree runs (owner, 2026-08-24 —
  "no one has ever used it"); per-profile re-research + #27 citation
  correction cover the repair path.
