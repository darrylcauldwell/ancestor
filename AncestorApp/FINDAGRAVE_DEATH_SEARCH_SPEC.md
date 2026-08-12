# Find a Grave — death-search birthyear filter + spouse-link recovery

**Status:** Proposed (2026-08-12). Not started.
**Driver (dogfood, Ernest Cauldwell @I_1564810712@):** an existing Find a Grave memorial with a
**perfect death-year match** was never found by the app, because it has no birth date and the app
always sends a hard `birthyear` filter.

## The confirmed failure

Ernest is buried on a **shared headstone** with his wife Mary at Holy Trinity, Kirk Ireton. Both
have memorials, created the same day by the same contributor:

| | Memorial | FAG **Birth** | FAG **Death** | App result |
|---|---|---|---|---|
| Mary Cauldwell | 216193100 | **6 Dec 1889** (present) | 30 May 1962 | **found** ✓ |
| Ernest Cauldwell | **216193076** | **unknown** (blank) | 28 Mar 1959 | **never found** ✗ |

The app's Find a Grave searches for Ernest:
- **16 Jul** (birthyear ≈ 1886, no death year yet) → returned a **US namesake** (memorial 54708175,
  *Ernest W Cauldwell*, Trenton NJ, d.1949 — scored `impossible`). That namesake **has** a birth
  year in range; the Kirk Ireton one does not, so only the namesake came back.
- **19 Jul & 6 Aug** (birthyear ≈ 1886 **+** deathyear ≈ 1959) → **nothing**. The namesake now
  fails the death-year filter; the Kirk Ireton memorial — **whose death year 1959 matches exactly**
  — is *still* excluded.

The only thing that excludes 216193076 from every search, including one where its death year is a
perfect match, is the **`birthyear` filter**: Find a Grave's `birthyearfilter`, once sent, requires
the memorial to carry a birth year within tolerance, and Ernest's carries none ("Aged 71" only).
Verified against the live page (BIRTH = "unknown") and the query builder
(`FindAGraveSource.searchRequestParams`, `:281–292`, which emits `birthyear`+`birthyearfilter`
whenever a birth window exists, on **every** record type including `.burial`).

Most gravestones record **death + age, not a birth date** — so this silently loses a large fraction
of correct burial memorials. The current code comment intends the birth year as "an independent
narrowing that rides along" (`:275–280`), but as implemented it is a **hard exclusion**.

## Fix 1 — drop the birthyear filter on death/burial searches

For `.burial` (the death-shape FAG record type), **do not emit `birthyear`/`birthyearfilter`**. Key
on `deathyear`(+tolerance) and name/location only; let the scorer's date gate reject wrong-year
hits downstream (it already does — the NJ namesake was correctly scored `impossible`).

- **Broadening-only, so it cannot create a false negative** — the source's own doc rationale for
  the nickname/maiden widenings (`:270–273`): extra hits are scored downstream; a wider server
  query "can never manufacture a false negative." Here it *removes* a false negative.
- Birth-shape searches (if any) are unaffected — this is scoped to the death-shape record type.
- **Regression pin:** extend `FindAGraveQueryShapeTests` — a `.burial` query with a known birth
  year and a known death year emits **`deathyear` but no `birthyear`**; the Ernest shape
  (birth ~1886, death 1959) must produce a query that would match a birth-unknown / d.1959 memorial.

## Fix 2 — follow the Find a Grave spouse link

A name+year search can miss a memorial for reasons beyond the birthyear filter (blank fields,
transcription variance, indexing gaps). Find a Grave cross-links a shared grave via
**Family Members → Spouse** (216193076 ↔ 216193100). So when the app **has one partner's memorial
and the tree-linked spouse lacks one**, fetch the known memorial's detail page and follow the
spouse link to recover the partner's memorial.

- This is the Find a Grave twin of the pipeline's existing **same-page-couple / cross-profile
  marriage recovery** (a spouse-held record recovered via the relationship, not a blind search).
- Reuses the existing FAG **detail fetch** (browser-shaped headers already needed for memorial GETs;
  the pipeline already does follow-up FAG detail fetches — `ResearchPipeline.enrichFagBridge`).
  Add a parse of the "Family Members" block for the spouse memorial URL/id, then fetch + score that
  memorial for the spouse profile.
- Firewall-clean: the recovered memorial is scored like any other candidate; nothing auto-applies.
- Trigger: a `.burial`-eligible subject whose spouse edge points at a profile that already carries a
  Find a Grave memorial (or vice-versa). Bounded — one extra detail fetch per known-spouse memorial.

## Acceptance

1. A death/burial FAG query emits **no `birthyear` param** (query-shape test).
2. With Fix 1, a death/burial search for Ernest (birth ~1886, death 1959) **finds memorial
   216193076** (birth-unknown, d.1959) — the regression case — instead of only the NJ namesake.
3. With Fix 2, given Mary's memorial 216193100 on the tree and Ernest as her tree spouse lacking a
   memorial, the spouse-link traversal **recovers 216193076** for Ernest.
4. No auto-apply; recovered memorials enter scoring/review like any candidate. The NJ namesake still
   scores `impossible` (geography gate) — the fix must not launder it into a fact.

## Risk

Low. Fix 1 is a query broadening guarded by the deterministic date/geography gates. Fix 2 is an
additive, bounded detail fetch reusing existing FAG-fetch plumbing. Neither touches the scorer.
Test-first: `FindAGraveQueryShapeTests` (birthyear-drop) + a spouse-link parse test on a saved
memorial fixture.
