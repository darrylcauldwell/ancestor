# Census Parent Unlock

Status: **Changes 1–3 built + tested (offline path); live household-fetch pending.**
The era-sibling to FREEBMD_CITATION_BACKFILL: for **1911+ births** the mother's
maiden name unlocks parents; for **pre-1911 births** — most of a Victorian tree —
the unlock is the **childhood census**.

## Problem (proven twice on George Keyworth, 1838)

A frontier ancestor with no parents but a birth year and a birthplace. Normal
research **cannot** reach their parents:

- It anchors on the subject's *adult* life (marriage, adult census) and surfaces
  their **own** household — spouse + children, not mother + father.
- The **childhood census** (subject as a child in the parental home) IS found,
  but sits as a low-confidence **lead**, drowned among namesakes, because the
  scorer confirms via a **family match** it can't make — the parents/siblings
  aren't in the tree yet. Chicken-and-egg.
- George's re-research: GPS 2→4, marriage + 1881 census applied, **16 FreeCEN
  census searches** run — and still **0 parents**; his 1851 Halam census stayed
  an un-promoted lead.

So the missing capability is not *discovery* (the record's already found) — it's
**promotion without a family match**, via era-appropriate heuristics.

## The unlock

For a parentless profile with birthYear `Y` and birthplace county `C`:

1. **Childhood-census candidates** = census records for the subject where
   `censusYear − Y ∈ [0, 18]` (subject a child/youth in the parental home).
   `> 18` = adult (their own household) — excluded.
2. **Rank without a family match** (Change 1 — this file's core):
   - **County match** first: census place in the same county as the birthplace
     (Halam/Carrington/Southwell all Notts, like Farnsfield) beats out-of-county
     namesakes (Caistor Lincs, Hampton Wick Middlesex).
   - **Age fit** second: smaller `|censusImpliedBirthYear − Y|` wins
     (Halam b.1835 → 3y from 1838 beats Carrington b.1842 → 4y).
   - (Village-level adjacency, e.g. Halam↔Farnsfield, falls out of county-match;
     a gazetteer refinement is a non-goal for v1.)
3. **Lift the household as parents** (Change 2, live): fetch the winning census's
   household; its **Head + Wife become the subject's parents**, co-children
   become **siblings**, through the same firewall promote path as any relative.
   Verified against a live FreeCEN 200 before shipping (blind scraper code is
   what the sibling spec exists to undo).

## Sequencing

1. **Change 1 — `ChildhoodCensusRanker`** (pure, tested) ✅: childhood-window
   filter + county/age ranking. No I/O. 9 tests, George's Halam case proven.
2. **Change 2 — surfacing** ✅: `CensusParentUnlockAudit.finding` fires a
   **warning** on any parentless profile whose ranked census leads yield a
   childhood candidate; `AppState.censusParentUnlockFindings()` scans the tree and
   folds it into the Health summary (`syncAuditSummary`). 7 tests.
3. **Change 3 — household lift** ✅ (offline path): the Health **"Apply childhood
   census"** button calls `AppState.applyChildhoodCensusForParentUnlock`, which
   applies the ranker's winner as a life-event through the same `ApplyEngine`
   path as any fact. The **shipped** `CensusRelationshipReconciler` "Add census
   relatives" flow then lifts its Head + Wife as the parents (the user reviews
   that step) — so we reuse verified relationship-creation machinery rather than
   writing a new blind writer.

### Live tail (not yet done)
When the winning census lead has **no stored household** (it fell outside the
per-run enrichment cap), applying it lands the birth/citation but surfaces no
parents; the button's message routes the user to **research** the subject so a
run fetches the roster. An on-demand single `fetchDetail` at click-time (one
gentle FreeCEN call) would close this — deferred until it can be **live-verified
against a FreeCEN 200**, per the "no blind scraper" rule.

## Non-goals
- Gazetteer village-adjacency (county match suffices for v1).
- Confirming the census beyond heuristics — the user reviews the proposed parents
  before they're committed (it proposes, the human decides).
