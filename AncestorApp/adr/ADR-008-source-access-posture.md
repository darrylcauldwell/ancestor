# ADR-008 — Source access posture: published-terms-first

**Status:** Accepted (tosStatus fixes shipped, commit `9d25875`; outreach/toggle outstanding). Decision (1)'s tosStatus corrections landed as a standalone pre-emptive bug-fix; the ask-first outreach + off-by-default user toggle of Decision (2) remain unbuilt.
**Depends on:** ADR-002 (FS bounded surfaces — FS access is governed there, not here)
**Evidence base:** `AncestorApp/SOURCE_ACCESS_COMPLIANCE_2026-07.md` (verbatim terms quotes, fetched 2026-07-14/15)

## Context

Darryl challenged the FreeBMD request-budget numbers: they were tuned by trial and error
around observed throttling, not derived from anything the source published. Reading the
actual terms surfaced a compliance problem, not a tuning one: **FreeBMD, FreeCEN and FreeREG
all strictly forbid "front end programs or sites to enter search parameters", and CWGC's
terms ban scrapers/bots outright** — while our in-code `tosStatus` lines claimed "no
prohibition of programmatic access" (FreeBMD/FreeCEN/FreeREG) and `.open` (CWGC). Nobody had
read the terms; the constraints answered "what does the server tolerate", never "what did we
agree to".

Countervailing facts: Free UK Genealogy (one charity operating all three Free-trio sources)
publicly champions Open Data with CC0 ambitions; CWGC operates licensing routes; the
FamilySearch precedent shows operators say yes when a respectful non-commercial tool asks
(beta access was granted on request). Ancestor is a personal research assistant: tiny request
volumes, full citation of the transcribers' work, every record linked back to the source
site, no bulk replication (the app stores pointers + derived conclusions, and its FS posture
is already pointer-only).

**Unverified:** FindAGrave terms (fetch blocked at the edge — presumption forbidden, needs a
manual read), Probate/Find-a-Will terms (nothing found; gov.uk Crown-service defaults),
Wirksworth conditions (legacy TLS blocks fetch). These classify after a manual morning check.

## Decision (proposed)

1. **Published-terms-first invariant.** Every connector's `tosStatus` and request constraints
   must cite the source's *fetched, quoted* published terms (kept in the compliance review
   doc). Empirically-tuned limits (budgets, breaker ladders) are retained only as a
   politeness layer *underneath* documented or sanctioned limits — never as the compliance
   story. False claims are corrected the day they are found.
2. **For sources whose terms forbid programmatic access (🔴): ask-first, respectful-interim.**
   Send the operator a personal, honest permission request (drafted for Darryl's review —
   only Darryl sends). While a reply is pending, the connector continues **interim use** at
   the most conservative posture: existing daily caps, existing pacing, no detail-page
   enrichment beyond parity needs, stop-on-objection. On refusal or silence after a
   reasonable follow-up, the connector is gated **off by default** behind an explicit
   user-choice toggle mirroring the FS cookie precedent (informed account-holder's decision,
   surfaced honestly in Settings — never silent).
3. **For silent sources (🟡):** respectful-use posture — conservative caps, honest
   identification (User-Agent with contact address), immediate stop on any objection.
4. **For permitted/sanctioned sources (🟢):** documented limits followed to the letter; any
   granted permission recorded verbatim in the compliance doc.

The interim-use choice in (2) is the same shape as the FamilySearch cookie decision Darryl
already made as account holder: the tool keeps serving its owner while the sanctioned route
is pursued, and the moment a real answer exists (grant or refusal), posture follows it.

## Consequences

**Positive:** the app's ToS surface tells the truth; a single Free UK Genealogy "yes" turns
three core sources green (and their open-data mission makes yes plausible); constraints
become explainable ("their limit" / "our politeness floor") instead of folklore; the
ask-first pattern has already worked once (FamilySearch).

**Negative:** a refusal from Free UK Genealogy would gate the app's records backbone
(FreeBMD) behind an off-by-default toggle — a real product cost Darryl accepts knowingly by
choosing option (2) over ignoring the terms; permission round-trips take weeks; interim use
knowingly continues against written terms for the pending window (mitigated by volume,
non-commercial purpose, and the outreach itself — but not erased; this is precisely what
Darryl is being asked to decide).

**Rejected alternatives:** (a) immediate suspension of 🔴 connectors — guts the product's
core value before the operators have even been asked, and is more caution than the
FS-precedent posture Darryl chose; (b) status quo — knowingly false `tosStatus` lines and
untracked violation; indefensible once the terms have been read.

## Reversal conditions

Per-source reclassification on any operator reply (grant → 🟢 with recorded terms; refusal →
gated off). If Free UK Genealogy publishes an API or bulk-data route (FreeBMD2 era), the
connector migrates to it and this ADR's interim clause for that source expires.
