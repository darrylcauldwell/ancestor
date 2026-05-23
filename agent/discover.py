"""Discover phase — execute searches based on search plan.

Deterministic: Python translates high-level search intents
(e.g., "birth_registration") into specific API calls using
known dates, location, and era logic. No LLM involved.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from agent.config import (
    CIVIL_REGISTRATION_START,
    CENSUS_YEARS,
    DEFAULT_COUNTY,
)
from project_config import config as _cfg


def _default_location():
    return _cfg.region.default_location or "England"


def _chapman_code():
    return _cfg.region.chapman_code or DEFAULT_COUNTY


def execute_searches(search_plan: list, state: dict) -> dict:
    """Execute a list of search intents and return raw results.

    Args:
        search_plan: ["birth_registration", "census_1891", "military_service", ...]
        state: current knowledge state (for dates, name, location)

    Returns:
        dict mapping search intent to raw results
    """
    person = state["person"]
    name = person.get("name", "")
    parts = name.split()
    surname = parts[-1] if parts else ""
    given = parts[0] if len(parts) > 1 else ""
    birth_year = person.get("birth_year")
    death_year = person.get("death_year")

    # Check confirmed facts for dates we've learned during research
    if not birth_year:
        birth_year = _get_learned_year(state, "birth")
    if not death_year:
        death_year = _get_learned_year(state, "death")

    results = {}
    already_searched = {s["source"] for s in state.get("searched", [])}

    for search_type in search_plan:
        if search_type == "DONE":
            continue

        if search_type in already_searched:
            print(f"    Skipping {search_type} — already searched")
            continue

        print(f"    Searching: {search_type}...")
        try:
            result = _dispatch_search(search_type, surname, given,
                                       birth_year, death_year)
            results[search_type] = result

            # Record what we searched
            has_results = _has_results(result)
            state.setdefault("searched", []).append({
                "source": search_type,
                "status": "found" if has_results else "empty",
            })

        except Exception as e:
            print(f"    ERROR searching {search_type}: {e}")
            results[search_type] = f"error: {e}"
            state.setdefault("searched", []).append({
                "source": search_type,
                "status": "error",
            })

    return results


def _dispatch_search(search_type: str, surname: str, given: str,
                      birth_year: int | None, death_year: int | None) -> list | dict:
    """Route a search intent to the right tool with the right parameters."""

    if search_type == "birth_registration":
        return _search_freebmd_births(surname, given, birth_year)

    if search_type == "death_registration":
        return _search_freebmd_deaths(surname, given, death_year, birth_year)

    if search_type == "marriage":
        return _search_freebmd_marriages(surname, given, birth_year, death_year)

    if search_type.startswith("census_"):
        if search_type == "census_all":
            return _search_census_all(surname, given, birth_year, death_year)
        year = int(search_type.split("_")[1])
        return _search_census_year(surname, given, year)

    if search_type == "military_service":
        return _search_cwgc(surname, given)

    if search_type == "burial_memorial":
        return _search_findagrave(surname, given, birth_year, death_year)

    if search_type == "probate":
        return _search_probate(surname, given, birth_year, death_year)

    if search_type == "parish_registers":
        return _search_freereg(surname, given, birth_year, death_year)

    if search_type == "wirksworth":
        return _search_wirksworth(surname)

    if search_type == "familysearch":
        return _search_familysearch(surname, given, birth_year, death_year)

    print(f"    Unknown search type: {search_type}")
    return []


def _freebmd_national_fallback(record_type, surname, start, end):
    """Cross-county escalation tier (KINSHIP / Lydia path): when the
    home-county pass yields nothing, run one all-districts query
    (`district=""` → FreeBMD's `districtid=""` → no district filter).

    Bounded cost (one extra search per kind when needed). The scorer's
    geography gate still soft-fails out-of-region hits — escalation
    raises *recall*, not noise. Industrial migration, Border-county
    spillover, and registry-of-birth ≠ residence cases (Lydia
    Kenworthy: twin says Stanton DBY, FreeBMD says Huddersfield YKS)
    all live in this tier.
    """
    from sources import freebmd
    print(f"      [SCOPE-ESCALATE] {record_type} {surname} {start}-{end}: home county empty, retrying national")
    r = freebmd.search(record_type, surname, start=start, end=end, district="")
    return r if isinstance(r, list) else []


def _search_freebmd_births(surname, given, birth_year):
    """Search FreeBMD births across configured districts.

    Searches by surname only (not given name) because FreeBMD's given
    name filter is unreliable — it drops valid records. The scorer
    handles name matching downstream.
    """
    from sources import freebmd
    if not birth_year or birth_year < CIVIL_REGISTRATION_START:
        return []
    start, end = birth_year - 2, birth_year + 2
    results = []
    for district_id in _cfg.region.districts.values():
        r = freebmd.search("Births", surname,
                            start=start, end=end,
                            district=district_id)
        if isinstance(r, list):
            results.extend(r)
    if not results:
        results = _freebmd_national_fallback("Births", surname, start, end)
    return results


def _search_freebmd_deaths(surname, given, death_year, birth_year):
    """Search FreeBMD deaths across configured districts."""
    from sources import freebmd
    if death_year and death_year >= CIVIL_REGISTRATION_START:
        start, end = death_year - 1, death_year + 1
    elif birth_year:
        start = max(CIVIL_REGISTRATION_START, birth_year + 15)
        end = birth_year + 95
    else:
        return []
    results = []
    for district_id in _cfg.region.districts.values():
        r = freebmd.search("Deaths", surname,
                            start=start, end=end, district=district_id)
        if isinstance(r, list):
            results.extend(r)
    if not results:
        results = _freebmd_national_fallback("Deaths", surname, start, end)
    return results


def _search_freebmd_marriages(surname, given, birth_year, death_year):
    """Search FreeBMD marriages across configured districts."""
    from sources import freebmd
    if not birth_year:
        return []
    start = max(CIVIL_REGISTRATION_START, birth_year + 16)
    end = death_year or (birth_year + 50)
    results = []
    for district_id in _cfg.region.districts.values():
        r = freebmd.search("Marriages", surname,
                            start=start, end=end, district=district_id)
        if isinstance(r, list):
            results.extend(r)
    if not results:
        results = _freebmd_national_fallback("Marriages", surname, start, end)
    return results


def _search_census_year(surname, given, year):
    """Search FreeCen for a specific census year, then fetch full household for matches."""
    from sources import freecen
    r = freecen.search(surname, first_name=given, year=year,
                        county=DEFAULT_COUNTY)
    if not isinstance(r, list) or not r:
        return r if isinstance(r, list) else []

    # For each hit, fetch the full household so the LLM can see
    # actual family members (not guess them)
    enriched = []
    for match in r[:5]:  # Cap at 5 to avoid excessive requests
        record_url = match.get("record_url")
        if record_url:
            print(f"      Fetching household for {match.get('name', '?')}...")
            try:
                household = freecen.detail(record_url)
                if isinstance(household, dict) and household.get("members"):
                    enriched.append({
                        "search_match": match,
                        "household": household,
                    })
                else:
                    enriched.append({"search_match": match, "household": None})
            except Exception as e:
                print(f"      Household fetch failed: {e}")
                enriched.append({"search_match": match, "household": None})
        else:
            enriched.append({"search_match": match, "household": None})

    return enriched


def _search_census_all(surname, given, birth_year, death_year):
    """Search all plausible census years."""
    from sources import freecen
    results = {}
    for year in CENSUS_YEARS:
        if birth_year and year < birth_year:
            continue
        if death_year and year > death_year:
            continue
        # If no dates, search all
        r = freecen.search(surname, first_name=given, year=year,
                            county=DEFAULT_COUNTY)
        results[str(year)] = r if isinstance(r, list) else []
    return results


def _search_cwgc(surname, given):
    from sources import cwgc
    results = cwgc.search(surname, first_name=given)
    return results if isinstance(results, list) else []


def _search_findagrave(surname, given, birth_year, death_year):
    from sources import findagrave
    results = findagrave.search(surname, first_name=given,
                                 birth_year=birth_year, death_year=death_year,
                                 location=_default_location(), year_range=5)
    return results if isinstance(results, list) else []


def _search_familysearch(surname, given, birth_year, death_year):
    """Search FamilySearch — births, deaths, and census.

    Uses the cookie-based library. Gracefully skips if cookies expired.
    Returns combined results from multiple FamilySearch searches.
    """
    try:
        from sources.familysearch import FamilySearch
        fs = FamilySearch()  # loads cookies from session file
    except (RuntimeError, Exception) as e:
        print(f"      FamilySearch unavailable: {e}")
        return []

    results = []
    county = _cfg.region.county or "Derbyshire"

    try:
        # Birth registration index — has mother's maiden name
        if birth_year:
            births, _ = fs.search_births(
                surname=surname, given=given,
                place=county,
                year_from=birth_year - 2, year_to=birth_year + 2,
                count=5)
            for r in births:
                r["_fs_type"] = "birth"
            results.extend(births)

        # Death registration index — fills FreeBMD gaps
        if death_year:
            deaths, _ = fs.search_deaths(
                surname=surname, given=given,
                place=county,
                year_from=death_year - 1, year_to=death_year + 1,
                count=5)
            for r in deaths:
                r["_fs_type"] = "death"
            results.extend(deaths)
        elif birth_year:
            # No death year known — broad search
            deaths, _ = fs.search_deaths(
                surname=surname, given=given,
                place=county,
                year_from=birth_year + 30, year_to=birth_year + 90,
                count=5)
            for r in deaths:
                r["_fs_type"] = "death"
            results.extend(deaths)

        # Marriage records — spouse names, witnesses
        if birth_year:
            start = birth_year + 16
            end = death_year or (birth_year + 50)
            marriages, _ = fs.search_marriages(
                surname=surname, given=given,
                place=county,
                year_from=start, year_to=end,
                count=5)
            for r in marriages:
                r["_fs_type"] = "marriage"
            results.extend(marriages)

        # Census records — household composition
        if birth_year:
            for census_year in CENSUS_YEARS:
                if census_year < birth_year:
                    continue
                if death_year and census_year > death_year:
                    continue
                census, _ = fs.search_census(
                    year=census_year,
                    surname=surname, given=given,
                    place=county,
                    count=3)
                for r in census:
                    r["_fs_type"] = "census"
                    r["census_year"] = census_year
                results.extend(census)

        # Broad sweep — hits military, burial, probate, church records,
        # land records, obituaries, and everything else FamilySearch indexes.
        # No event-type filter, just name + date range + county.
        if birth_year:
            broad, _ = fs.search(
                surname=surname, given=given,
                birth_place=county,
                birth_year_from=birth_year - 2,
                birth_year_to=birth_year + 2,
                count=10)
            # Deduplicate against targeted results by ARK
            seen_arks = {r.get("ark") for r in results if r.get("ark")}
            for r in broad:
                if r.get("ark") not in seen_arks:
                    r["_fs_type"] = "broad"
                    results.append(r)

    except Exception as e:
        print(f"      FamilySearch search error: {e}")

    return results


def _search_probate(surname, given, birth_year, death_year):
    from sources import probate
    year_from = death_year - 1 if death_year else (birth_year + 40 if birth_year else None)
    year_to = (death_year or (birth_year + 95 if birth_year else None))
    if not year_from:
        return []
    results = probate.search(surname, first_name=given,
                              year_from=year_from, year_to=year_to)
    return results if isinstance(results, list) else []


def _search_freereg(surname, given, birth_year, death_year):
    from sources import freereg_search
    start = birth_year - 5 if birth_year else 1700
    end = min(death_year or (birth_year + 90 if birth_year else 1900), 1900)
    results = freereg_search.do_search(
        surname, given or "", "all three types", start, end,
        chapman_codes=[_chapman_code()])
    return results if isinstance(results, list) else []


def _search_wirksworth(surname):
    from sources import wirksworth
    try:
        results = wirksworth.search_parish(surname)
        return results if isinstance(results, list) else []
    except Exception:
        return []


def _has_results(result) -> bool:
    """Check if a result has any actual data."""
    if isinstance(result, list):
        return len(result) > 0
    if isinstance(result, dict):
        return any(_has_results(v) for v in result.values())
    return False


def _get_learned_year(state: dict, fact_type: str) -> int | None:
    """Check confirmed facts for dates learned during research."""
    import re
    for fact in state.get("confirmed_facts", []):
        if fact.get("type", "").startswith(fact_type):
            match = re.search(r"\b(1[6-9]\d{2}|20[0-2]\d)\b", fact.get("value", ""))
            if match:
                return int(match.group(1))
    return None
