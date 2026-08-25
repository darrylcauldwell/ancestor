# HEALTH_RECATEGORISATION_SPEC — Health shows defects, not research prompts

**Status:** IMPLEMENTED · 2026-08-25 — HR1 `1f65c78`, HR2 `8213812`,
HR3 `f7d6b68`, plus review fixes `cfcddfc` (empty-state gate switched to
displayRows so synthetic dispute/backfill/contradiction rows survive an
otherwise-clean audit; import toast now uses `AuditSummary.actionableTotal`).
Owner walk-through owed: Health should show ~176 actionable rows, chips no
longer led by Completeness/Missing-bio, Workbench suggestions list reasons.
**Owner ruling (2026-08-25):** completeness score, missing bio, missing
birth/death fields etc. "are not really record Health — these types are just
research. Health should focus on actionable: census is added but there are
gaps on how it is applied, duplicate, phantom spouse etc."

## The problem

The Health tab renders all 48 audit rule types. On the live tree, ~1,319 of
1,495 rows are "go research this person" prompts (Completeness score 364,
Missing bio 361, Missing birth location 159, …). They bury the ~176 rows that
are actually actionable, inflate the severity badges, and dominate the
count-ordered rule chips. The existing `AuditCategory.issue`/`.gap` binary
does not capture the wanted split: several `.gap` rules (censusUnabsorbed,
censusParentUnlock, missingCoParent-style absorption gaps) are exactly the
actionable kind Health is for.

## The model: three categories

| Category | Meaning | Rendered in Health? |
|---|---|---|
| `.issue` | data is wrong (contradiction, impossibility, cruft) | yes |
| `.gap` | evidence is in the project but incompletely applied | yes |
| `.research` (new) | person is under-researched — a research prompt | **no** |

`.research` rules **keep running** in the engine. Their findings stay in
`AuditSummary` and the persisted `audit_findings` snapshot — the MCP
`get_audit_findings` tool keeps its who-needs-research signal (the table never
persisted category, so external consumers see no change). Only rendering
changes: the Health tab and the profile card's Health strip exclude
`.research`.

## Changes

### HR1 — AncestorKit: `.research` category + rule assignments

`AuditCategory` gains `case research`. Recategorised `.gap → .research`:
`incompleteName`, `completenessScore`, `missingParents`, `missingBirthDate`,
`missingDeathDate`, `missingBirthLocation`, `missingBio`,
`missingDeathLocation`, `ancestorExtension`, `fertilityGap`.

`fertilityGap` splits per-finding: the children-born-alive shortfall is
`.research` (search FreeBMD for the missing children); the 1911
years-married vs recorded-marriage-year mismatch is a contradiction with
applied evidence → `.issue`.

Stay `.gap` (applied-evidence gaps, remain in Health):
`datelessReadsAsLiving` (absence with a behavioural consequence — the person
wrongly reads as living), `unlinkedSpouseForFemaleSubject` (marriage applied,
no spouse edge), `censusRelationship`'s missing-relatives finding, and the
injected DB-derived sweeps (`censusUnabsorbed`, `censusParentUnlock`,
`parishFamilyUnabsorbed`, `parishKinUnreadable`, `freebmdLinkMissing`).

`AuditEngine`'s placeholder de-noise skip (nameless/unknown/placeholder
profiles) covers `.research` exactly as it covered `.gap`.

### HR2 — Health tab + profile Health strip exclude `.research`

`AuditViewModel.searchedResults` filters out `.research` — the single choke
point through which the category/severity pills, rule chips, badges and rows
all deflate together. The "Gaps" pill is relabelled **"Apply gaps"**. The
profile card's Health strip (`SharedProfileLayout.reloadFactRecords`) applies
the same exclusion. The dead `GapsPlaceholderView` (unreachable since the
Gaps tab was absorbed into Health) is deleted.

`AuditFixButton.researchResolvableGapRuleIDs` keeps its entries: the rules
still exist, and any future surface that renders `.research` findings gets
the Research launch buttons back for free.

### HR3 — Workbench research suggestions carry the reasons

The "Research suggestions" section (Workbench › Attention) is the visible
home for the research-prompt signal. Each suggested profile now lists why it
ranks: `ProfileCompleteness.missing` short labels — "Missing: birth date,
parents". No audit findings are consumed; the completeness engine already
carries the reasons.

## Not changed

- MCP `get_audit_findings`, the `audit_findings` v55 snapshot, and
  `ANCESTOR_MCP_PROFILE=reader` — untouched.
- Settings › Audit Rules toggle list and count line — all rules still listed
  and toggleable; counts are engine-wide by design.
- `ProfileCompleteness` engine and its non-audit consumers (tree rings,
  publish, ResearchConfigSheet smart mode) — untouched.
- Promote-to-question flows and stored `QuestionOrigin` provenance.

## Acceptance

1. Health shows only `.issue` + `.gap` rows; with the live tree that is
   ~176 rows, every one carrying a defect or an apply-gap.
2. Severity badges and rule chips count only what the list can show.
3. Profile Health strip never shows missing-X/completeness rows.
4. `get_audit_findings` output for a profile with only research gaps is
   unchanged before/after.
5. Workbench suggestions list missing-check reasons.
6. Category assignments are pinned by tests (registry walk + fertilityGap
   per-finding split).
