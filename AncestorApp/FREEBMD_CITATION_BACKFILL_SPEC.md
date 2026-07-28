# FreeBMD Citation Link + MMN Backfill

Status: **Change 1 shipped** (forward parser fix, commit `c194066`); Changes 2–4 queued.

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

## Non-goals

- Upgrading `r=&d=` links to the "official permanent" `cite=` token form (only
  on the detail page) — deferred; the `d=bmd_<dbVersion>` link is durable.
- Backfilling non-FreeBMD sources — FindAGrave/CWGC/FamilySearch already carry
  their own detail URLs.
