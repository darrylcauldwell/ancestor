# SANDWICH_AUDIT_2026-07 — gate-repair backlog (OPEN findings)

**Status: OPEN gate-repair backlog awaiting triage (Darryl).** This doc has been thinned to the
still-open scorer/gate-repair findings only. The conflict-evidence cluster (DS-03/07/08/09/13/14/20/
24/25/26, plus the DS-02/12/15 conflict halves) was resolved by the conflict layer (CL1–CL6, shipped
2026-07-13, git-only) and its finding bodies have been removed — see git history for the full
verifier trail. The findings below are the OPEN half: Swift-side scorer/gate repairs in
`Services/Research/`, produced by the original 2026-07-13 five-lens adversarial audit and confirmed
against the code. IDs are DS-nn; commits reference `#DS-nn`. Severity = impact on tree correctness.

Suggested repair sequence (Part B 1.3): **(1st)** DS-01 + DS-17 · **(2nd)** shared name-gate ladder
rework covering DS-16/DS-05/DS-06 · **(3rd)** FP/FN residues DS-02/DS-12/DS-15/DS-10/DS-11 · **(4th)**
GPS reporting honesty DS-19/DS-18/DS-21/DS-22/DS-23 · **(5th)** DS-27 dead-code cleanup. DS-04 is an
independent false-negative (middle-name gate).

## OPEN findings

### DS-01 · high · (false-positive) No-age death/burial records auto-promote to .fact on a bare [15,100] plausibility band

**Claim:** When the subject has no known death year (deathYearFrom nil, RecordScorer.swift:399) and the record carries no recorded age (recordedAge nil at :428-433 — true for ALL burial records and every FreeBMD death index row before 1866), the date gate passes iff the implied age-at-death range intersects [15,100] (:441-447). Name pass + local district + familyContext skip (:954) = .fact with zero softFails, and wouldApply writes the death year. For a subject with an exact birth year this accepts ~85 years of registrations of any in-district namesake (father/son case). The burial arm scores .fact the same way but routes to LifeEvent projection, not deathDate.

**Code:** `RecordScorer.swift:399-411,428-447,566-572,954,93-94`

**Residue:** The gate that lets a no-age death/burial reach .fact is unrepaired; the conflict layer only surfaces the collision *after* apply, it doesn't tighten the gate.

### DS-02 · high · (false-positive, gate residual) Census wrong-household: ±5 tolerance + spouse-forename household match endorses the neighbour's family as .fact

**Claim:** Census date gate accepts implied birth in window±5 (tolerance(.census)=5, ScoringRules.swift:119). familyContext then passes if ANY wife/husband-relation member scores ≥0.7 against the known spouse name (RecordScorer.swift:843-851) — common Victorian forenames + shared surname make the wrong John Smith's household match 1.0. All gates pass → .fact with the family gate actively endorsing the error.

**Code:** `RecordScorer.swift:471-485,843-851`; `ScoringRules.swift:115-124`; `ClusteringEngine.swift:353-359`

**Residue:** CL2 ⟨G13⟩ added a same-enumeration-year split so two same-year census records no longer fuse/corroborate; the OPEN gate half is the ±5 tolerance + spouse-forename endorsement that grades the wrong household .fact in the first place.

### DS-04 · high · (false-negative) Person known by their middle name is classified .impossible — given-name gate compares only the first token, no given/middle swap

**Claim:** checkName compares the record's first given token against subject.givenName's first token only (RecordScorer.swift:255-265; effective-given at :188-202 splits 'Ernest Victor' into given=ERNEST/middle=VICTOR). There is no swap against the subject's middle name and the name gate has no softFail — score < 0.7 hard-fails → .impossible (:97-98). A census 'Victor Cauldwell' for Ernest Victor Cauldwell scores 0.0 → .impossible, excluded from clustering/convergence/consensus. The learned-equivalence rescue is dormant (no production writer). Partial recovery only: ClusterReviewView surfaces .impossible records in a "Scorer rejected" section with "Save as lead anyway", but the record never re-enters the automated pools.

**Code:** `RecordScorer.swift:188-202,255-265,97-98`; `ScoringRules.swift:207-238`; `BirthYearConsensusDetector.swift:225`

**Residue:** No given/middle swap attempt anywhere; needs a scorer-side middle-name match arm.

### DS-05 · high · (false-negative) Standard period abbreviations (Wm, Jno, Thos, Chas, Jas) and Latin forms score 0.0 → .impossible

**Claim:** The similarity ladder only rescues contiguous substrings ('GEO' in 'GEORGE') and equal-length single-char diffs (ScoringRules.swift:226,232-235). Canonical register contractions are neither — 'WM'⊄'WILLIAM', 'JNO'⊄'JOHN', 'THOS'⊄'THOMAS' → 0.0 → name-gate hard fail → .impossible. The nickname table (:241-257) has no scribal contractions or Latin forms. The same contractions also break the middle-name guard (THOS is not a prefix of THOMAS, :315-316), and nicknames are never consulted for middles (ANN vs HANNAH fails at :313). Faithful port of the Python ladder — a shared gap, but real.

**Code:** `ScoringRules.swift:226,232-235,241-257`; `RecordScorer.swift:277-281,303-321`

**Residue:** Needs a scribal-contraction/Latin-form equivalence table (part of the shared name-gate ladder rework).

### DS-06 · high · (false-negative) Unequal-length surname variants (Brookes/Brooks, Simms/Sims, Greenhough/Greenhow) score 0.0 → .impossible

**Claim:** The transcription-error branch fires only when a.count == b.count (ScoringRules.swift:232-235), so a single-char insertion/deletion — the most common UK surname variant class — scores 0.0 unless it's a containment or AU/OU normalisation. 'BROOKES' vs 'BROOKS' → 0.0 → surname-gate fail → .impossible. No edit-distance, no Soundex/Metaphone; the dispatcher-side variant fan-out (SurnameVariants, 30 entries) lacks these families AND the scorer's acceptance side never consults the variants dictionary. George Herbert Brooks — the canonical test profile — loses his 'BROOKES'-transcribed marriage row.

**Code:** `ScoringRules.swift:219-235`; `RecordScorer.swift:222-228,97-98`; `ResearchSubject.swift:253-305`

**Residue:** Needs edit-distance/soundex in the name gate (part of the shared name-gate ladder rework).

### DS-10 · high · (python-parity) Parish/christening parent-name cross-check unported — FreeREG baptism father/mother names fetched but never scored

**Claim:** Python's validate_enrichment_parents (agent/rules.py:525-555) rejects a christening whose named parents match neither linked parent. Swift's checkFamilyContext handles only `.birth` MMN (RecordScorer.swift:929-952); `.parish` records fall through to `.skip` (:954). FreeREGSource deliberately populates ParishRecord.fatherName/motherName (FreeREGSource.swift:759-793) claiming the scorer reads them — no scorer/hypothesis consumer exists (only human-facing ClusterReviewView). A namesake-cousin baptism naming contradicting parents scores .fact and is apply-eligible.

**Code:** `agent/rules.py:525-555`; `RecordScorer.swift:929-954`; `FreeREGSource.swift:380,759-793`; `RecordTypes.swift:303-304`

**Residue:** Add a `.parish` parent-name cross-check arm to checkFamilyContext. (Python reference is itself uncalled, but the project's own §21.1 audit flagged this as a critical must-port.)

### DS-11 · high · (python-parity) NON_ENGLAND_MARKERS unported + enrichment-location guard is dead code — no live location validation on apply/firewall, bare US-state/Canadian-province places evade the foreign check

**Claim:** Three linked gaps. (1) Python's NON_ENGLAND_MARKERS (all 50 US states + provinces + countries, agent/rules.py:491-519) is absent — Swift's validateEnrichmentLocation (ScoringRules.swift:339-366) ports only the English-county cross-check and returns nil for places naming no English county. (2) That function plus validateEnrichmentDate have ZERO call sites; EvidenceFirewall does no location validation, and location pending facts skip the 4-gate scorer entirely (PendingFactsProcessor returns nil for location fields) — birthLocation is auto-approvable with no geography check. (3) foreignCountryTokens (RecordScorer.swift:810-817) lists countries only, so 'Charleston, South Carolina' isn't foreign → softFail → .lead, not the intended .impossible.

**Code:** `agent/rules.py:439-522`; `ScoringRules.swift:339-366`; `EvidenceFirewall.swift:17-58`; `RecordScorer.swift:576-584,810-831`

**Residue:** Port NON_ENGLAND_MARKERS and wire a live location guard onto the apply/firewall path.

### DS-12 · high · (conflict-evidence, scorer half) Marriage record naming a DIFFERENT spouse scores .fact instead of softFailing familyContext

**Claim:** A marriage record whose spouseName mismatches the known spouse falls through every familyContext clause and returns .skip (RecordScorer.swift:954) — the skip is dropped, so the verdict sees zero fails → .fact. Contrast the census clause, which correctly softFails a missing member. The strongest wrong-person signal (record names a different spouse) is treated as no-information.

**Code:** `RecordScorer.swift:873-918,954,73-76,91-103,29-31`

**Residue:** CL1/CL6 handle the apply half (ApplyEngine.swift:94 no-op now opens an F4b spouseIdentity dispute); the OPEN scorer half is that a spouse-surname contradiction should `.softFail` familyContext rather than skip to .fact.

### DS-15 · high · (conflict-evidence, prevention half) Scorer accepts death records the tree's own alive-evidence already contradicts — subject.aliveAsOf never derived from LifeEvents

**Claim:** The census-after-death and death-window checks both depend on subject.deathYearFrom being populated at scoring time; ResearchSubject derives death only from profile.deathDate (:545-546) — accepted census LifeEvents ('alive in 1911') are never consulted, and already-scored records are never re-scored. A subject with an accepted 1911 census but no death date accepts a namesake 'Q1 1905, age 20' death as .fact.

**Code:** `RecordScorer.swift:368-377,399-447`; `ResearchSubject.swift:545-546`; `ResearchPipeline.swift:2462-2485`; `ClusteringEngine.swift:311-411`; `AuditRule.swift:58-78`

**Residue:** CL2's retroactive F3 + RecordAfterDeathRule catch the damage *after* apply; the OPEN prevention half is deriving `subject.aliveAsOf` from accepted LifeEvents so the scorer stops accepting contradicted death records up front.

### DS-16 · medium · (false-positive) Surname containment 0.8 / single-char-diff 0.7 pass distinct families (Harris/Harrison, Wood/Woodward, Dale/Gale)

**Claim:** nameSimilarity returns 0.8 for containment (ScoringRules.swift:226) and 0.7 for equal-length single-char diff (:232-235); the name gate passes at ≥0.7 and is binary with no softFail. Containment is applied identically to surnames, where Harris/Harrison etc. are different families co-occurring in the same districts. A wrong-surname record proceeds to .fact with an audit reason reading a healthy 'surname=0.80'.

**Code:** `ScoringRules.swift:226,232-235`; `RecordScorer.swift:222-228,255-265`

**Residue:** Needs a given-vs-surname-aware containment rule and/or a softFail band (part of the shared name-gate ladder rework).

### DS-17 · medium · (false-positive, invariant breach) Hardcoded 'derby' substring passes geography for West Derby (Liverpool) and for Derbyshire records regardless of the subject's home county

**Claim:** In the empty-district path the gate passes outright when the fallback place field merely CONTAINS 'derby' (RecordScorer.swift:606-608), before the parameterised parish lookup; probate has a second literal on subject.deathLocation (:655-657). Neither reads subject.homeChapmanCode, so (a) any non-Derbyshire user gets Derbyshire records passing geography, and (b) 'West Derby, Liverpool, Lancashire' and any 'Derby Road' address match. Burial/probate always take this path (no district extraction, :566-572). Directly violates the No-Hardcoded-Regions invariant.

**Code:** `RecordScorer.swift:606-608,655-657,585-594,566-572`

**Residue:** Replace both literals with chapman-parameterised parish/district checks.

### DS-18 · medium · (false-negative, residual) Name-gate widening still reads a single married surname

**Residue only:** The marriage-switcher work shipped the plural `ResearchSubject.marriedSurnames: [String]` (populated from all spouses, fanned out on the death/burial/probate/census wire), so the original twice-married-women data loss is largely resolved. The remaining OPEN residue: the name-gate widening at `RecordScorer.swift:151` still reads the single `subject.marriedSurname`, so a swept-in second-married-surname record can still fail the name gate. One-line fix: widen acceptableSurnames from the plural set.

### DS-19 · medium · (false-negative) Foreign-place hard-fail is unconditional — never consults the subject's own locations, so colonial-born/emigrant records are lost as .impossible

**Claim:** The foreign-metadata short-circuit (RecordScorer.swift:548-562) and county foreign check (:603-605) fail geography whenever any place matches foreignCountryTokens, regardless of subject.homeChapmanCode/region/deathLocation — contradicting the code's own comment (:595-598). In Verify/Extend/Discover this maps to .impossible. A subject whose tree itself records 'Bombay, India' birth loses the FamilySearch record corroborating that very birthplace; a 'Toronto, Canada' emigrant loses the matching FindAGrave burial.

**Code:** `RecordScorer.swift:548-562,595-605,810-831,99-100`

**Residue:** Consult the subject's own locations before hard-failing foreign places.

### DS-21 · medium · (gps-standard, reporting) GPS Criterion 2 checks only that sourceID is non-empty — effectively 'has any confirmed fact'

**Claim:** criterion2Citations' doc comment promises 'sourceID + detailURL or raw fields' but checks only !sourceID.isEmpty (GPSScorer.swift:119-121). Every plugin stamps its own non-empty sourceID, so the filter passes by construction and the criterion degenerates to 'confirmedFacts non-empty' — no check of detailURL or volume/page/district. A FreeBMD hit missing volume/page still reports 'All N facts have source citations'. Reporting-only (GPS is an audit surface, not an apply gate).

**Code:** `GPSScorer.swift:112-130`

**Residue:** Check citation completeness (detailURL / vol-page-district), not just presence.

### DS-22 · medium · (gps-standard, reporting) GPS Criterion 1 is a flat min(3, total) source count, blind to subject relevance

**Claim:** criterion1ExhaustiveSearch is met when searched >= min(3, total) (GPSScorer.swift:101-102). With 8 sources, any 3 conclusive sources satisfy it regardless of relevance. The deterministic relevance signals exist (WW1/WW2 eligibility, census years, pre-registration flags in ScoringRules.swift:132-158) but criterion 1 uses none. A WW1-eligible male whose CWGC search was throttled meets criterion 1 without the single most probative source. Reporting-only.

**Code:** `GPSScorer.swift:94-110`; `ScoringRules.swift:132-158`

**Residue:** Make criterion 1 relevance-driven using the existing eligibility signals.

### DS-23 · medium · (python-parity) Birth-record date gate tightened Python ±2 → Swift ±1 — a genuine 2-yr-off registration is demoted to .lead

**Claim:** Python passes a birth record within ±2 (agent/rules.py:113-115, rationale covers both registration-quarter slip AND census-age rounding). Swift uses tolerance(.birth)=1 (ScoringRules.swift:117), covering only the quarter slip. The compound 2-year case Python deliberately tolerated now fails → .lead. Conservative (never .impossible), and bites only when a census-derived approximate year is stored as a bare exact (span-0) year, but the divergence is unacknowledged in the Swift comment and leaves the genuine registration in Triage.

**Code:** `agent/scorer.py:208-215`; `agent/rules.py:113-115`; `RecordScorer.swift:487-508`; `ScoringRules.swift:115-124`

**Residue:** Decide whether to restore ±2 for the census-derived-year cause, or document the deliberate re-tiering.

### DS-27 · low · (python-parity, dead-code) Missing-from-census follow-up unported; three dead ScoringRules functions

**Claim:** Python's analyser generates research questions when household children present in one census would be adults by later ones (agent/analyser.py:164-208, live). Swift has no counterpart — absentFromCensusSuggests (ScoringRules.swift:293-305) has zero call sites, as do childGapSuggestsDeath (:279-290) and militaryDeathNotInCivilRegister (:153-158). DiscoveryExtractor fires on census presence, never absence. (The Robert/CWGC "expected-negative death" half of the original claim was refuted — military records are death-shape and the T1-05 carve-out + eval harness satisfy the death axis via CWGC; militaryDeathNotInCivilRegister is equally dead in Python.)

**Code:** `agent/analyser.py:164-208`; `ScoringRules.swift:153-158,279-305`; `ResearchPipeline.swift:1318-1326`; `Discovery.swift:14-26`

**Residue:** (a) delete or wire the three dead functions; (b) port `_check_missing_from_census` (advisory follow-up question only).

## Refuted — do not re-find

Kept one-line so future audits don't rediscover them:

- **Spouse-less marriage → .fact with no spouse verification** — verdict-inflation is real as a UI label, but the marriage apply path requires an existing surname-matched spouse edge, so nothing is written to the tree.
- **Same-name cousin births pre-1911 both .fact** — per-record verdicts aren't the identity layer; SubjectIdentityResolver returns .ambiguous on ≥2 fact-grade same-district births and blocks auto-accept + downstream inference.
- **wouldApply carve-out lets a geography-demoted marriage write on a 0.7 surname-only match** — the carve-out is fill-only on an existing surname-matched spouse edge; pre-1912 no-spouse records apply as a no-op.
- **Elderly remarriage (>70 .impossible, 61–70 hard-fail) blocks a common record class** — demoted from the automated path only; .lead records survive clustering and can be force-applied; the >70 threshold is faithful Python parity.
- **Age-at-death ±2 mismatch hard-fails even when the death year matches** — mechanically true but .lead is retention, not discard; the record + citation apply via the per-record button; exact Python parity.
- **DiscrepancySeverityTable convergence-upgrade path is dead code** — latent-but-correct: every production call grades one record, for which .singleSource is correct by definition; §10.2 prescribes .conflict for a single community hit.
- **Census date gate widened Python ±2 → ±5 lets wrong-person census reach .fact** — spec-sanctioned calibration; precise-birth subjects get a familyContext softFail to .lead and there is no path to overwrite a precise birth year.
- **EvidenceFirewall marriage-age floor 14 vs rules.py 16** — cosmetic constant only; PendingFactsProcessor Step 4 re-scores through the 4-gate scorer, which applies the correct ≥16 rule and rejects.
