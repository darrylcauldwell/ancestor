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

**Change 3 — data-quality / dedup (M, investigate first).** Three distinct phenomena seen in the
list, NOT all the same problem — investigate against real tree data before building:
- **Same profile, multiple findings** (e.g. "George Eric Vaughn Cauldwell" ×2, both Conflict) —
  group findings per profile rather than repeating the profile.
- **Near-duplicate profiles** (e.g. "Annie Cauldwell" vs "Annie E Cauldwell") — the engine's
  deliberate over-split ("when in doubt, split"); surface as merge candidates, don't auto-merge.
- **Near-duplicate leads** (e.g. "[mother] /Mathews/" vs "/Matthews/" for Ida Louisa Land) —
  transcription variants of one value; collapse. (Genuinely-competing candidates like Kasnowitz
  vs Land are NOT dups and must stay separate.)

## Order & gate
1 → 2, then 3 after a data investigation defines its exact scope. Each gated by full
`xcodebuild test`.

## Non-goals
Auto-merging profiles (surface candidates, user decides — firewall/"when in doubt split" hold).
