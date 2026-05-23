"""Kinship primitives — find_siblings, find_children, find_spouses.

Implementation of KINSHIP_SPEC §4 (acceptance criteria #Change1–#Change3).
First primitive: `find_siblings` via FreeBMD's mother's-maiden-name
(MMN) field, indexed from Sep 1911.

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
