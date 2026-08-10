# FreeBMD Citation Link + MMN Backfill

Status: **Changes 1–4 shipped** (`c194066` forward capture, `ee5ccd9` audit,
`803fdd8` enrich-on-re-research, `1f37c54` throttled backfill). Change 4 reuses
the whole-tree engine, so it inherits the breaker-aware harness the gate
required — **pending one live run to confirm end-to-end rate-limit behaviour.**

## Problem

Every FreeBMD evidence record applied to the tree before commit `c194066` was
stored with `detailURL = nil` — the parser read only the `searchData` JS array,
truncated the record reference at the colon (losing the scan suffix a link
needs; a bare `?r=<recordID>` 403s), and never read the page's `var dbId`. So
across **all** record types (birth / marriage / death) the app fell back to a
generic "Search FreeBMD" instead of deep-linking the exact GRO entry. Births
additionally lost the mother's maiden name on any transcription whose
`searchData` row predated capture — the field that unlocks parent inference.

This is systemic: potentially hundreds of applied records, one per FreeBMD
citation in the tree.

## Constraint that shapes everything

FreeBMD is a **volunteer charity source with hard rate limits** (see memory
`feedback_volunteer_sources_rate_limits`, `reference_freebmd_circuit_breaker`).
Backfilling a link means **re-finding the record on FreeBMD** — there is no way
to reconstruct `dbId`/scan-ref from stored data. So backfill must never be a
fast mass-scrape: **1 request at a time, one full pass per session, resumable,
and it must yield the moment the circuit-breaker trips.**

## Change 1 — Forward capture (SHIPPED)

`FreeBMDSource.parseSearchResults` now keeps the full `recordID:scanID` ref,
reads `var dbId = "bmd_<version>"`, and builds
`information.pl?r=<ref>&d=<dbId>` on `RecordCommon` for every record type.
`CitationRenderer` already maps `common.detailURL → Citation.url →
evidence.citation_url → SourceVerifyLink`, so new research deep-links
end-to-end. Mother's maiden name (births, `searchData` col 4) flows to
`HypothesisEngine+ParentInferred`. Tested against the real captured HAR row.

## Change 2 — Audit: "FreeBMD evidence missing its citation link"

A new `AuditRuleDefinition` (category `.gap`, severity `.info` — a missing link
is informational, per the severity-chip work), evaluated over applied evidence,
not the profile graph:

- **Fires** for any `savedAsLead` evidence record whose `sourceID == "freebmd"`
  and whose `citationURL` is nil/empty.
- **Births additionally** fire a companion note when `mothersMaidenName` is
  absent (the parent-inference blocker).
- Message names the record ("George Land — 1891 census, FreeBMD — no direct
  entry link") and carries the profileID + source_record_id so the fix action
  can target it.
- Because evidence isn't in `FamilyGraphSnapshot`, this rule reads the ledger
  (`ProfileSourcesLedger`) rather than `Profile` — new plumbing: the audit
  engine gets a per-profile evidence view, or the rule is evaluated in a
  dedicated evidence-audit pass folded into the existing Health summary.

## Change 3 — Enrich-on-re-research (the cheap backfill)

The elegant path that avoids a *separate* scrape: when a profile is
re-researched, its FreeBMD records return **with** the link + MMN (Change 1).
On save, if an existing evidence record for the same
`(sourceID, recordType, vol, page, recordID)` has an empty `citationURL` /
`mothersMaidenName`, **update it in place** from the freshly-parsed record
rather than inserting a duplicate. No extra FreeBMD traffic — normal research
backfills the tree as profiles are revisited.

Match key: `vol/page/recordID` uniquely identifies a GRO entry, so enrichment
lands on the right record and never a namesake.

## Change 4 — Explicit backfill action (throttled)

For records the user wants filled now without a full re-research:

- **Per-record**: a "Get entry link" button on the audit row / evidence card →
  one FreeBMD search scoped to that record's `(surname, year, district)` →
  match `vol/page/recordID` → enrich in place. One request.
- **Bulk**: "Backfill FreeBMD links (N)" → a **throttled queue** (1 in flight,
  honours the circuit-breaker cooldown ladder, resumable across sessions,
  `log()`s what it dropped) that walks the flagged records. This is the
  connector-campaign pattern, not a fan-out. It must surface progress and stop
  cleanly on breaker trip — never hammer.

## Sequencing & gates

1. **Change 1** — shipped.
2. **Change 2** (audit) — safe, read-only; ship next so the gap is visible and
   counted.
3. **Change 3** (enrich-on-re-research) — no new FreeBMD load; ship before any
   explicit backfill so normal use already heals records.
4. **Change 4** (explicit backfill) — gated on the rate-limit harness being
   demonstrably breaker-aware and resumable. Do not ship a "backfill all" that
   can burn the daily FreeBMD budget in one run.

## Change 5 — Targeted per-item enrichment (queued; supersedes Change 4's approach)

**Live learning (2026-07-28).** Change 4's bulk button (whole-tree re-research
scoped to the flagged profiles) did **14 of 54** before FreeBMD **429-throttled**
and the circuit-breaker walked to **trip #3 (900s pause)**. Root cause: full
re-research **fans out** — ~4 FreeBMD requests per profile (birth/marriage/death +
surname-variant + spouse axes) because it's *discovering* records. That burns the
daily FreeBMD budget in ~14 profiles.

But a backfill isn't discovery — **we already hold the exact record** (surname,
given, quarter/year, district, vol, page are all in the stored evidence). So we
can **re-locate, not discover**: **one narrow FreeBMD query per link-less record**
(surname + given + exact year + type), match on **vol/page**, take the link + MMN.
No year-windows, no variants, no axes, no clustering — **~1 request/record vs
~4/profile**, the 3–4× saving that clears all 40 in one daily window.

**Surface it in Health, per-item (owner direction 2026-07-28).** The gap is a
data-quality gap and belongs among Health's findings, not buried as a Research
button. List the flagged records as **per-item Health tasks** the user works
through one by one, each with an **"Enrich from FreeBMD"** action that fires the
single targeted query.

**The cascade is the point, not just the link.** Enriching a *birth* captures the
**mother's maiden name**, which feeds `HypothesisEngine+ParentInferred` — so a
one-click enrichment can surface **"/Lees/ → /Beresford/" parent leads → new
relatives → new findings** (the Nora chain). So each Health item is a small
research unlock, not cosmetic link-tidying.

Shape:
- **Pure core** (`FreeBMDCitationAudit.enrichmentUpdates(flagged:results:)`):
  given a profile's link-less applied records and a fresh FreeBMD result set,
  produce the `(evidenceID, url, mmn)` updates by vol/page match. Fully testable,
  no I/O — built now.
- **Live lookup + Health action + cascade trigger**: one narrow `RecordQuery` per
  record via `FreeBMDSource`, apply the updates, then run parent inference on the
  enriched birth. **Built in the FreeBMD window where each query can be verified**
  against a live 200 — blind scraper code is what this whole spec exists to undo.
- Retire Change 4's whole-tree bulk button once this lands (keep the audit).

## Change 6 — Propagate enrich-in-place link onto the applied citation

Status: **Fix 1 + Fix 2 SHIPPED, live-verified on Abraham Twyford.**

- **Fix 1 (propagation)** — `propagateCitationURLToAppliedFacts(profileID:
  citationFull:citationURL:)` in `ProjectDatabase.swift`, wired into both
  enrich-in-place writers (`reconcileFreeBMDCitationLinks` now propagates over
  ALL linked FreeBMD evidence so already-healed rows self-heal;
  `applyFreeBMDEnrichment`). After a live re-research, Abraham's `deathDate`/
  `deathLocation` citations gained `…r=265360753…` in place (added_at unchanged).
- **Fix 2 (audit reads the applied-fact layer)** — `FreeBMDCitationAudit.finding`
  gained an optional `profile:` and now flags link-less applied *fact* citations
  (`FieldSource.origin == .freebmd`, empty `url`) as well as link-less evidence
  rows, deduped by citation-text fingerprint so a registration on two fields (or
  in both layers) counts once. Both Health callers pass the profile. Closes the
  layer-mismatch where a healed evidence row let the audit go falsely green while
  the published citation stayed bare.
- Tests: `ApplyCitationTests` (propagation) + `FreeBMDCitationAuditTests`
  (fact-layer: fires-when-evidence-healed, silent-when-linked, ignores-non-FreeBMD,
  two-fields-count-once) all green.

The optional apply-time "prefer the linked sibling" guard remains queued — not
needed now that both layers heal and the audit sees both.

**Live learning (2026-08-10, dogfood).** The "Freebmd link missing" Health tab
listed 9 profiles. Bucketing them by whether *any* local evidence row already
carries the `information.pl?r=` link splits the tab cleanly:

- **7 of 9 are pre-`c194066` legacy** (every row scored before forward capture) —
  no local link exists, so Change 5's per-item **"Enrich from FreeBMD"** is the
  correct and intended fix. Working as designed. (George Wheeldon, William H
  Cauldwell, Lily Cauldwell, Samuel Cauldwell, Oswald Derbyshire, Ida Land
  [death only — her marriage is already linked], Robert Cauldwell [2 unapplied
  leads].)
- **2 of 9 have the link already local** yet stay flagged — the bug below:
  Abraham Twyford and Mary Ward.

**Root cause — LIVE-VERIFIED 2026-08-10 (Abraham re-researched mid-session).**
A re-research fired on Abraham; the result **disproves** the initial
recordID-match-key theory and **confirms** a propagation gap instead:

- **Enrich-in-place DID heal across sibling recordIDs.** The applied death
  evidence row `freebmd_death_6_40_265353655` (previously no link) now carries
  `citation_url = …r=265360753…` — backfilled from its twin `…_265360753`, a
  *different* recordID for the same `6/40` registration. So healing already
  matches by registration, not strictly `recordID`. The earlier "drop recordID
  from the match key" fix is **moot — retracted.**
- **But the applied `confirmed_facts` citation was NOT re-synced.** Abraham's
  profile-level `deathDate` and `deathLocation` citations (added 2026-08-05)
  still hold only `{title, notes}` with **no `url`**, even though the evidence
  row backing them now has the link. Enrichment updates `evidence_records` but
  does not re-render the already-applied fact citation. **This is the real,
  confirmed bug.**
- **Layer mismatch in the audit.** Change 2's rule fires on link-less *evidence*
  records — now healed — so Abraham likely drops off the "FreeBMD link missing"
  list, while the citation the user actually sees on the profile (and would
  publish to WikiTree / a dossier) is *still* link-less. The audit measures the
  evidence layer, not the applied-fact layer that reaches the end product.

**Fix (revised):**
1. **Propagate enrichment to the applied citation.** When enrich-in-place updates
   an `evidence_record`'s `citationURL`, re-sync the derived `confirmed_facts`
   citation(s) — match by `(field, value, registration)` — so the profile's
   stored/published citation gains the link. Offline, testable.
2. **Point the audit at the applied fact.** The link-missing rule should also (or
   instead) check the `confirmed_facts` citation, since that's the user-facing /
   published artifact; otherwise a healed evidence layer masks a link-less
   profile.
3. *(Optional guard)* apply-time prefer the linked sibling, so a fresh apply
   never binds to a link-less row when a linked one exists.

**Mary Ward = stale-audit false positive.** Both her 1915 marriage evidence rows
carry the link (applied Aug 6). If her confirmed-fact citation also has it, the
finding is a stale count — the audit didn't recompute after the Aug 6 apply
(known open item, memory `project_census_reconciliation_followups`: "Health audit
goes stale after research apply"). Recompute-on-apply clears it.

**Net:** the tab is not 9 things to hand-fix. 7 are the intended Change 5 flow;
2 are the recordID-key bug above; at least 1 of those 2 is also a stale count.

## Non-goals

- Upgrading `r=&d=` links to the "official permanent" `cite=` token form (only
  on the detail page) — deferred; the `d=bmd_<dbVersion>` link is durable.
- Backfilling non-FreeBMD sources — FindAGrave/CWGC/FamilySearch already carry
  their own detail URLs.
