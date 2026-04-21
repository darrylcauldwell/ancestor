"""Deterministic record classifier — fact, lead, or impossible.

Replaces probabilistic scoring with pass/fail gate checks.
A record is a FACT only if ALL gates pass. If any gate fails
but the record looks promising, it's a LEAD. If a hard rule
is violated (died before born, etc.), it's IMPOSSIBLE.

All rules come from rules.py — this module applies them.
"""

import re
from agent.rules import (
    validate_record,
    check_marriage_age,
    years_match,
    name_similarity_score,
    is_derbyshire_district,
    is_non_local,
    parishes_in_district,
    CENSUS_AGE_TOLERANCE,
    BIRTH_YEAR_TOLERANCE,
)


def classify_result(result: dict, person: dict, search_type: str) -> dict:
    """Classify a search result as fact, lead, or impossible.

    Returns:
        {
            "verdict": "fact" | "lead" | "impossible",
            "gates": {"name": "pass"|"fail", "date": ..., "geography": ...},
            "reasons": ["why each gate passed/failed"],
            "failed_gates": ["name of failed gates"],
            "record_summary": "compact description"
        }
    """
    if "search_match" in result:
        r = result["search_match"]
    else:
        r = result

    gates = {}
    reasons = []
    failed = []

    # --- GATE 1: NAME ---
    name_result = _check_name(r, person)
    gates["name"] = name_result[0]
    reasons.append(f"name: {name_result[1]}")
    if name_result[0] == "fail":
        failed.append("name")

    # --- GATE 2: DATE ---
    date_result = _check_date(r, person, search_type)
    gates["date"] = date_result[0]
    reasons.append(f"date: {date_result[1]}")
    if date_result[0] == "impossible":
        return {
            "verdict": "impossible",
            "gates": gates,
            "reasons": reasons,
            "failed_gates": ["date"],
            "record_summary": _summarise_record(r, search_type),
        }
    if date_result[0] == "fail":
        failed.append("date")

    # --- GATE 3: GEOGRAPHY ---
    geo_result = _check_geography(r, person)
    gates["geography"] = geo_result[0]
    reasons.append(f"geography: {geo_result[1]}")
    if geo_result[0] == "fail":
        failed.append("geography")

    # --- GATE 4: FAMILY CONTEXT (bonus, not required) ---
    family_result = _check_family_context(result, person)
    if family_result[0] != "skip":
        gates["family"] = family_result[0]
        reasons.append(f"family: {family_result[1]}")

    # --- VERDICT ---
    if not failed:
        verdict = "fact"
    elif "name" in failed:
        # Wrong name is a rejection, not a lead
        verdict = "impossible"
    else:
        # Date or geography failed but name matches — it's a lead
        verdict = "lead"

    return {
        "verdict": verdict,
        "gates": gates,
        "reasons": reasons,
        "failed_gates": failed,
        "record_summary": _summarise_record(r, search_type),
    }


# Keep backward compatibility — score_result wraps classify_result
def score_result(result: dict, person: dict, search_type: str) -> dict:
    """Backward-compatible wrapper. Returns classify_result output
    with added 'score' field for display purposes."""
    classified = classify_result(result, person, search_type)

    # Map verdict to legacy score for display
    score_map = {"fact": 1.0, "lead": 0.5, "impossible": 0.0}
    classified["score"] = score_map.get(classified["verdict"], 0.0)

    return classified


def _check_name(r: dict, person: dict) -> tuple[str, str]:
    """Gate: does the surname match?

    Pass: surname similarity >= 0.7 (handles Caldwell/Cauldwell)
    Fail: surname doesn't match at all
    """
    person_name = person.get("name", "").upper()
    person_parts = person_name.split()
    person_surname = person_parts[-1] if person_parts else ""
    person_given = person_parts[0] if len(person_parts) > 1 else ""

    record_surname = (r.get("surname", "") or "").upper()
    record_given = (r.get("firstname", "") or r.get("name", "")).upper()

    # FreeCen returns full name in "name" field
    if not record_surname and record_given:
        parts = record_given.split()
        if len(parts) >= 2:
            record_given = parts[0]
            record_surname = parts[-1]

    if not record_surname or not person_surname:
        return ("fail", "cannot compare — missing surname")

    surname_score = name_similarity_score(record_surname, person_surname)
    if surname_score < 0.7:
        return ("fail", f"surname mismatch: {record_surname} vs {person_surname}")

    # Given name must also match — surname alone isn't enough
    if record_given and person_given:
        given_score = name_similarity_score(record_given, person_given)
        if given_score < 0.7:
            return ("fail", f"given name mismatch: {record_given} vs {person_given}")
    elif not record_given:
        # No given name in record — can't confirm identity
        return ("fail", "no given name in record to compare")
    else:
        given_score = 0.5

    return ("pass", f"surname={surname_score:.2f}, given={given_score:.2f}")


def _check_date(r: dict, person: dict, search_type: str) -> tuple[str, str]:
    """Gate: is the date temporally possible and plausible?

    Pass: record date within expected tolerance
    Fail: date is off but not impossible (lead candidate)
    Impossible: violates hard temporal rules
    """
    birth_year = person.get("birth_year")
    death_year = person.get("death_year")
    record_year = _extract_year_from_record(r)

    if not record_year or not birth_year:
        return ("fail", "insufficient date information")

    # Hard rule check
    validation = validate_record(record_year, birth_year, death_year, search_type)
    if validation.startswith("impossible"):
        return ("impossible", validation)

    if search_type == "death":
        age_at_death = record_year - birth_year
        # Check age-at-death field (FreeBMD)
        recorded_age = r.get("spouse_or_mother", "")
        if recorded_age and recorded_age.isdigit():
            recorded = int(recorded_age)
            if years_match(recorded, age_at_death, tolerance=2):
                return ("pass", f"age at death {recorded} matches expected {age_at_death}")
            else:
                return ("fail", f"age at death {recorded} doesn't match expected {age_at_death}")
        # No age field — plausible lifespan?
        if 15 <= age_at_death <= 100:
            return ("pass", f"died {record_year}, age ~{age_at_death} (plausible)")
        return ("fail", f"died {record_year}, age ~{age_at_death} (unusual)")

    elif search_type == "marriage":
        if not check_marriage_age(birth_year, record_year):
            return ("impossible", f"married {record_year} at age {record_year - birth_year}")
        age = record_year - birth_year
        if 16 <= age <= 60:
            return ("pass", f"married {record_year}, age ~{age} (typical)")
        return ("fail", f"married {record_year}, age ~{age} (unusual)")

    elif search_type == "census":
        census_birth = r.get("birth_year")
        if isinstance(census_birth, int):
            if years_match(census_birth, birth_year, CENSUS_AGE_TOLERANCE):
                return ("pass", f"census birth year {census_birth} matches ~{birth_year}")
            diff = abs(census_birth - birth_year)
            return ("fail", f"census birth year {census_birth} is {diff} years off")
        return ("fail", "no birth year in census record")

    else:
        # Birth or unknown
        if years_match(record_year, birth_year, BIRTH_YEAR_TOLERANCE):
            return ("pass", f"year {record_year} matches ~{birth_year}")
        diff = abs(record_year - birth_year)
        if diff <= 5:
            return ("fail", f"year {record_year} is {diff} years from ~{birth_year}")
        return ("impossible", f"year {record_year} is {diff} years from ~{birth_year}")


def _check_geography(r: dict, person: dict) -> tuple[str, str]:
    """Gate: is the location plausible?

    Pass: record is in a configured district
    Fail: unknown district (might be right, might not)
    Impossible: confirmed non-local district
    """
    district = (r.get("district", "") or "").strip()
    birth_location = (person.get("birth_location", "") or "").lower()

    if not district:
        county = (r.get("census_county", "") or r.get("birth_county", "") or "").lower()
        if "derby" in county:
            return ("pass", "Derbyshire county")
        if county:
            return ("fail", f"county: {county}")
        return ("fail", "no location data")

    district_clean = district.replace(" district", "").strip()

    non_local = is_non_local(district_clean)
    if non_local:
        return ("fail", f"{district_clean} is in {non_local}, not local")

    if is_derbyshire_district(district_clean):
        parishes = parishes_in_district(district_clean)
        if birth_location and any(p.lower() in birth_location for p in parishes):
            return ("pass", f"{district_clean} covers {birth_location}")
        return ("pass", f"{district_clean} is in research area")

    return ("fail", f"unknown district: {district_clean}")


def _check_family_context(result: dict, person: dict) -> tuple[str, str]:
    """Bonus gate: does the census household contain expected family?

    This is optional — not having family context doesn't fail the record.
    """
    family = person.get("family_context")
    if not family:
        return ("skip", "no family context")

    household = None
    if isinstance(result, dict) and "household" in result:
        household = result.get("household")

    if not household or not household.get("members"):
        return ("skip", "no household data")

    members = household["members"]
    discovered_via = (family.get("discovered_via", "") or "").upper()

    for m in members:
        name = (m.get("name", "") or "").upper()
        if discovered_via and any(part in name for part in discovered_via.split() if len(part) > 2):
            return ("pass", f"household contains {m.get('name')} (expected)")

    return ("fail", "expected family member not in household")


# === Batch scoring ===

def score_all_results(raw_results: dict, person: dict) -> dict:
    """Classify all search results for a person."""
    scored = {}

    for source, data in raw_results.items():
        search_type = _classify_search_type(source)
        results = _flatten_results(data)

        scored_results = []
        for r in results:
            s = classify_result(r, person, search_type)
            s["result"] = r
            scored_results.append(s)

        # Sort: facts first, then leads, then impossible
        verdict_order = {"fact": 0, "lead": 1, "impossible": 2}
        scored_results.sort(key=lambda x: verdict_order.get(x["verdict"], 3))
        scored[source] = scored_results

    return scored


def summarise_scored_results(scored: dict) -> str:
    """Render classified results as compact text."""
    lines = []
    for source, results in scored.items():
        lines.append(f"\n=== {source.upper()} ===")
        facts = [r for r in results if r["verdict"] == "fact"]
        leads = [r for r in results if r["verdict"] == "lead"]
        rejected = [r for r in results if r["verdict"] == "impossible"]

        if facts:
            lines.append(f"  FACTS ({len(facts)}):")
            for r in facts:
                lines.append(f"    [FACT] {r['record_summary']}")
                lines.append(f"         {'; '.join(r['reasons'])}")

        if leads:
            lines.append(f"  LEADS ({len(leads)}):")
            for r in leads[:10]:
                lines.append(f"    [LEAD] {r['record_summary']}")
                lines.append(f"         Failed: {', '.join(r['failed_gates'])}")
            if len(leads) > 10:
                lines.append(f"    ... and {len(leads) - 10} more leads")

        if rejected:
            lines.append(f"  IMPOSSIBLE ({len(rejected)}):")
            for r in rejected[:5]:
                lines.append(f"    [---] {r['record_summary']}")
                lines.append(f"         {'; '.join(r['reasons'])}")
            if len(rejected) > 5:
                lines.append(f"    ... and {len(rejected) - 5} more rejected")

    return "\n".join(lines)


# === Helpers ===

def _classify_search_type(source_key: str) -> str:
    key = source_key.lower()
    if "death" in key:
        return "death"
    if "birth" in key:
        return "birth"
    if "marriage" in key:
        return "marriage"
    if "census" in key:
        return "census"
    if "military" in key or "cwgc" in key:
        return "death"
    if "burial" in key or "grave" in key:
        return "burial"
    if "probate" in key:
        return "death"
    return "unknown"


def _flatten_results(data) -> list:
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        flat = []
        for v in data.values():
            if isinstance(v, list):
                flat.extend(v)
        return flat
    return []


def _extract_year_from_record(r: dict) -> int | None:
    for field in ("year", "birth_year", "census_year"):
        val = r.get(field)
        if isinstance(val, int):
            return val
        if isinstance(val, str):
            match = re.search(r"\b(1[6-9]\d{2}|20[0-2]\d)\b", val)
            if match:
                return int(match.group(1))
    return None


def _summarise_record(r: dict, search_type: str) -> str:
    if "quarter" in r and "vol" in r:
        name = f"{r.get('firstname', '')} {r.get('surname', '')}".strip()
        spouse = r.get("spouse_or_mother", "")
        spouse_str = f", {spouse}" if spouse and not spouse.isdigit() else ""
        age_str = f", age {spouse}" if spouse and spouse.isdigit() else ""
        return (
            f"{name}, {r.get('quarter', '')} {r.get('year', '')}, "
            f"{r.get('district', '')} (vol {r.get('vol', '')} p.{r.get('page', '')})"
            f"{spouse_str}{age_str}"
        )
    if "census_year" in r:
        return (
            f"{r.get('name', '?')}, census {r.get('census_year', '?')}, "
            f"born {r.get('birth_year', '?')} {r.get('birth_place', '?')}"
        )
    if "casualty_id" in r:
        return (
            f"{r.get('name', '?')}, {r.get('rank', '')} {r.get('regiment', '')}, "
            f"died {r.get('date_of_death', '?')}"
        )
    if "memorial_id" in r:
        return f"{r.get('name', '?')}, {r.get('cemetery', '')}"
    return str(r)[:120]
