"""Kinship primitives — find_siblings, find_children, find_spouses.

Implementation of KINSHIP_SPEC §4 (acceptance criteria #Change1–#Change3).

- `find_siblings` (#Change1): FreeBMD mother's-maiden-name (MMN), Sep 1911+.
- `find_children` (#Change2): FreeBMD MMN strategy from the parents' side
  — caller resolves the gender-asymmetry of §4.2 by passing the father's
  surname (= children's surname) and the mother's maiden name.

These primitives are deliberately stateless — they take query inputs,
hit live sources, and return structured candidates. The pipeline /
fan-out walker (KINSHIP_SPEC §5, #Change4) composes them.
"""

from __future__ import annotations

# FreeBMD's `s_surname` field carries the mother's maiden name (MMN)
# for births. The field is only indexed from September 1911 onward —
# pre-1911 birth registrations leave it blank, so queries that
# constrain `s_surname` will silently return nothing for earlier
# years. KINSHIP_SPEC §4.1 documents this asymmetry.
FREEBMD_MMN_INDEX_START_YEAR = 1911

# Biological fertility window for `find_children`. Anchored on the
# mother's birth year so the FreeBMD search is bounded to plausible
# birth years of her children. Endpoints chosen wide enough to catch
# real edge cases (teenage first births; mid-40s last births) without
# producing a flood of cross-generation false positives.
FERTILITY_START_AGE = 17
FERTILITY_END_AGE = 45


def find_siblings(
    subject_surname: str,
    mothers_maiden_name: str,
    subject_birth_year: int | None = None,
    sibling_window: int = 25,
) -> list[dict]:
    """Find candidate siblings via FreeBMD's mother's-maiden-name field.

    Args:
        subject_surname: Subject's surname (typically the father's
            surname for the standard pre-WWII case). Used as the
            FreeBMD `surname` query parameter.
        mothers_maiden_name: Mother's surname at birth — the
            `s_surname` query parameter. Required; without it the
            search would return every birth of that surname, which
            isn't a sibling search.
        subject_birth_year: Subject's birth year. Used to bound the
            search to a plausible sibling window. Without it the
            function can't safely scope the query and returns empty.
        sibling_window: Years either side of subject_birth_year to
            search. Default 25 covers the realistic span of mother's
            fertile years (subject's older + younger siblings).

    Returns:
        List of candidate-sibling dicts, each with:
          - name, birth_year, quarter, district, vol, page
          - source: "freebmd_mmn"
          - confidence: "supported" (FreeBMD MMN match is high-trust;
            same surname + same MMN + same window is strong evidence)
        Empty list when MMN is missing, birth year is missing, or
        FreeBMD returns no results.

    Note (KINSHIP_SPEC §4.1, strategy 1 of 4): this is the FreeBMD-MMN
    strategy. Census-household, FreeREG-baptism, and WikiTree-twin
    strategies are #Change2+ in the spec.
    """
    if not subject_surname or not mothers_maiden_name:
        return []
    if subject_birth_year is None:
        return []

    start = max(subject_birth_year - sibling_window, FREEBMD_MMN_INDEX_START_YEAR)
    end = subject_birth_year + sibling_window
    if start > end:
        # Window pushed entirely below the MMN-index start — nothing
        # to query. Subject was born so far before 1911 that any
        # plausible sibling is also pre-1911.
        return []

    from sources.freebmd import search
    candidates = search(
        "Births", subject_surname,
        start=start, end=end,
        district="",  # all districts — siblings could live anywhere
        s_surname=mothers_maiden_name,
    )

    if not isinstance(candidates, list):
        return []

    siblings: list[dict] = []
    for r in candidates:
        firstname = (r.get("firstname") or "").strip()
        surname = (r.get("surname") or "").strip()
        if not firstname:
            # Skip rows where the parser couldn't recover a given name
            # — shouldn't happen post-sparse-encoding fix, defensive.
            continue
        siblings.append({
            "name": f"{firstname} {surname}".strip(),
            "given_name": firstname,
            "surname": surname,
            "birth_year": r.get("year"),
            "quarter": r.get("quarter"),
            "district": r.get("district"),
            "vol": r.get("vol"),
            "page": r.get("page"),
            "mothers_maiden_name": mothers_maiden_name,
            "source": "freebmd_mmn",
            "confidence": "supported",
        })

    return siblings


def find_children(
    father_surname: str,
    mother_maiden_name: str,
    mother_birth_year: int | None = None,
    fertility_start_age: int = FERTILITY_START_AGE,
    fertility_end_age: int = FERTILITY_END_AGE,
) -> list[dict]:
    """Find candidate children via FreeBMD's mother's-maiden-name field.

    Anchored on the *mother*: every child of a couple is indexed under
    `surname=father_surname` and `s_surname=mother_maiden_name` in
    FreeBMD's births database from Sep 1911 onward. This is the
    FreeBMD-MMN strategy of KINSHIP_SPEC §4.2.

    Gender-asymmetry (§4.2) is resolved by the caller, not here. To
    look up the children of a subject:
        - Female subject: father_surname = husband's surname,
          mother_maiden_name = subject's pre-marriage surname,
          mother_birth_year = subject's birth year.
        - Male subject: father_surname = subject's surname,
          mother_maiden_name = wife's pre-marriage surname,
          mother_birth_year = wife's birth year. Without the wife's
          MMN this strategy can't run; the caller falls back to the
          census/FreeREG strategies (deferred to later changes per
          §4.2).

    Args:
        father_surname: Father's surname (= the child's registered
            surname). Used as the FreeBMD `surname` query parameter.
        mother_maiden_name: Mother's surname at birth — the
            `s_surname` query parameter. Required; without it the
            search degenerates into "every birth of that surname".
        mother_birth_year: Mother's birth year. Used to bound the
            search to a plausible fertility window. Without it the
            function can't safely scope the query and returns empty.
        fertility_start_age: Years after mother's birth at which to
            start the search. Default 17.
        fertility_end_age: Years after mother's birth at which to
            stop. Default 45.

    Returns:
        List of candidate-child dicts (same shape as `find_siblings`):
          - name, given_name, surname, birth_year, quarter, district,
            vol, page
          - source: "freebmd_mmn"
          - confidence: "supported"
        Empty list when MMN is missing, mother's birth year is
        missing, the resulting window falls entirely below the MMN
        index start (1911), or FreeBMD returns no results.

    Note (KINSHIP_SPEC §4.2, FreeBMD-MMN strategy): this is the
    high-trust path. Census-household and FreeREG-baptism fallbacks
    for the male-subject / pre-1911 cases are deferred (see #Change4
    fan-out walker, which composes the strategies).
    """
    if not father_surname or not mother_maiden_name:
        return []
    if mother_birth_year is None:
        return []

    start = max(
        mother_birth_year + fertility_start_age,
        FREEBMD_MMN_INDEX_START_YEAR,
    )
    end = mother_birth_year + fertility_end_age
    if start > end:
        # Mother's fertility window ends before the MMN index begins
        # — every plausible child of hers predates the indexed field.
        return []

    from sources.freebmd import search
    candidates = search(
        "Births", father_surname,
        start=start, end=end,
        district="",  # all districts — family may have moved
        s_surname=mother_maiden_name,
    )

    if not isinstance(candidates, list):
        return []

    children: list[dict] = []
    for r in candidates:
        firstname = (r.get("firstname") or "").strip()
        surname = (r.get("surname") or "").strip()
        if not firstname:
            continue
        children.append({
            "name": f"{firstname} {surname}".strip(),
            "given_name": firstname,
            "surname": surname,
            "birth_year": r.get("year"),
            "quarter": r.get("quarter"),
            "district": r.get("district"),
            "vol": r.get("vol"),
            "page": r.get("page"),
            "mothers_maiden_name": mother_maiden_name,
            "source": "freebmd_mmn",
            "confidence": "supported",
        })

    return children
