# Source Access Compliance Review — 2026-07-15

**Status: evidence gathered overnight 2026-07-14/15; decisions pending ADR-008.**
Trigger: Darryl challenged the FreeBMD daily-budget numbers ("trial and error rather than
looking at details and specifications"). Reading the actual published terms surfaced a
compliance picture materially worse than the tuning question: several connectors' in-code
`tosStatus` claims are false. This document is the verbatim evidence base; ADR-008 proposes
the posture; nothing changes behaviour until Darryl accepts it.

## Method

Each source's published terms fetched 2026-07-14/15 and quoted verbatim below. Where a fetch
was blocked, the source is marked UNVERIFIED — presumptions are labelled as such and are not
classification. In-code claims (`tosStatus`, budget comments) compared against the quotes.

## Matrix

| Source | Published terms say | Class | In-code claim (before fix) | Claim accurate? |
|---|---|---|---|---|
| FreeBMD | "Access… only permitted manually via the search page. The use of front end programs or sites to enter search parameters is **strictly forbidden**" (freebmd.org.uk/terms.html) | 🔴 forbidden | "no prohibition of programmatic access"; budget comment claimed a "documented daily quota" (none exists — 200/day is our invention) | **FALSE ×2** |
| FreeCEN | Identical wording (freecen.org.uk/terms-and-conditions) + "Data extracted from FreeCEN must not be reproduced in any form." | 🔴 forbidden | "no prohibition of programmatic access" | **FALSE** |
| FreeREG | Identical wording (freereg.org.uk/terms-and-conditions) + no-reproduction clause | 🔴 forbidden | "no explicit prohibition" | **FALSE** |
| CWGC | "You may not conduct… any text o[r] data mining or web scraping"; bans "any 'robot', 'bot' 'spider' 'scraper' or other automated device… to access, obtain, copy, monitor or re-publish any portion of the site" (cwgc.org/terms-and-conditions/) | 🔴 forbidden | `level: .open`, "Public CSV export endpoint — official government records" | **MISLEADING** (endpoint is public-facing; automated use of it is banned by ToS) |
| FindAGrave | Terms pages refuse automated fetchers (403) — text unread | ⚠️ unverified (presumption 🔴: Ancestry-owned, edge-blocks bots) | "ToS restricts automated access — uses internal AJAX API, not a documented public API" | Honest ✓ |
| Probate (gov.uk Find a Will) | No wording found on automated access/reuse on fetched pages; Crown-service defaults | 🟡 silent (pending manual footer/help check) | `.open`, "Public Nuxeo JSON API" | Overstated ("public API" is the service's own backend, undocumented) |
| Wirksworth (John Palmer) | Fetch blocked (legacy TLS); terms unread | ⚠️ unverified | "Volunteer-contributed pedigrees…" (vague, not false) | — |
| FamilySearch | Already verified (FAMILYSEARCH_SOURCE_SPEC §§14–16): cookie transport prohibited once FSI agreement executes (pending); official API = person-info only | governed by ADR-002/spec | `.restricted` (honest) | ✓ |

## Key observations

1. **One charity, three red sources.** Free UK Genealogy operates FreeBMD, FreeCEN and
   FreeREG under identical terms. Its umbrella site simultaneously champions "Open Data and
   Open Source" with CC0 ambitions — the prohibition reads as a defence against abusive
   commercial scrapers, not against the class of use Ancestor represents. One permission
   email addresses all three (draft prepared for Darryl).
2. **The empirically-tuned constraints answered the wrong question.** The 200/day budget and
   60/300/900s ladder measure *what the server tolerates*, not *what the terms permit*. They
   remain useful as a politeness layer UNDER any sanctioned access, but they are not a
   compliance posture (memory: `feedback_verify_source_terms_first`).
3. **CWGC has an ask-route** (licensing/commercial team) and Darryl's family holds verified
   ground truth (Robert Cauldwell at Lijssenthoek; William Holmes possibly Hollybrook) — a
   sincere personal-research request has substance behind it.
4. **The precedent that works: ask.** FamilySearch beta access was granted because Darryl
   asked. WikiTree aside, every operator contacted so far has engaged constructively.

## Actions (pending ADR-008 acceptance)

- Correct the false `tosStatus` lines + FreeBMD budget comment (factual fixes — done with
  this review; behaviour unchanged).
- Darryl reviews/sends the Free UK Genealogy email (drafts in session scratchpad
  `overnight/drafts/`); CWGC email second.
- Morning manual checks: FindAGrave terms text, Probate footer/help terms, Wirksworth
  conditions + John Palmer contact.
- Connector gating (off-by-default for 🔴 without sanction, etc.) implemented only per the
  accepted ADR-008 option.
