# Census Parent Unlock

Status: **Change 1 (disambiguation core) building.** The era-sibling to
FREEBMD_CITATION_BACKFILL: for **1911+ births** the mother's maiden name unlocks
parents; for **pre-1911 births** — most of a Victorian tree — the unlock is the
**childhood census**.

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

1. **Change 1 — `ChildhoodCensusRanker`** (pure, tested): childhood-window filter
   + county/age ranking. No I/O. Building now.
2. **Change 2 — surfacing**: on the Health "Missing parents" gap for a pre-1911
   person, a **"Find parents from census"** action that runs the ranker over the
   profile's census leads and shows the winner. Era-routed: FreeBMD/MMN for
   1911+, census for pre-1911.
3. **Change 3 — household lift**: promote the winning census's Head+Wife as
   parents + co-children as siblings (live-verified).

## Non-goals
- Gazetteer village-adjacency (county match suffices for v1).
- Confirming the census beyond heuristics — the user reviews the proposed parents
  before they're committed (it proposes, the human decides).
