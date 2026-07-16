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

## Order & gate
1 → 2, then 3 after a data investigation defines its exact scope. Each gated by full
`xcodebuild test`.

## Non-goals
Auto-merging profiles (surface candidates, user decides — firewall/"when in doubt split" hold).
