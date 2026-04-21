"""Deterministic match scorer — replaces LLM correlation.

Computes a weighted score for how likely a search result matches
the person being researched. Python does this perfectly; the LLM
kept getting it wrong.

Score > 0.8: confirmed match
Score 0.4-0.8: uncertain — flag for human review
Score < 0.4: rejected

All rules and knowledge come from rules.py — this module only
applies them to score records.
"""

import re
from agent.config import MATCH_ACCEPT, MATCH_UNCERTAIN
from agent.rules import (
    validate_record,
    check_marriage_age,
    years_match,
    name_similarity_score,
    geographic_plausibility,
    is_derbyshire_district,
    is_non_local,
    parishes_in_district,
    CENSUS_AGE_TOLERANCE,
    BIRTH_YEAR_TOLERANCE,
)


def score_result(result: dict, person: dict, search_type: str) -> dict:
    """Score how likely a search result matches our person.

    Returns:
        {
            "score": 0.0-1.0,
            "verdict": "match" | "uncertain" | "reject" | "impossible",
            "reasons": ["why this score"],
            "record_summary": "compact description"
        }
    """
    # Handle enriched census format
    if "search_match" in result:
        r = result["search_match"]
    else:
        r = result

    scores = []

    # --- NAME MATCH ---
    name_score = _score_name(r, person)
    scores.append(("name", name_score[0], name_score[1]))

    # --- DATE MATCH ---
    date_score = _score_date(r, person, search_type)
    if date_score[0] == -1:  # Impossible
        return {
            "score": 0.0,
            "verdict": "impossible",
            "reasons": [date_score[1]],
            "record_summary": _summarise_record(r, search_type),
        }
    scores.append(("date", date_score[0], date_score[1]))

    # --- GEOGRAPHIC MATCH ---
    geo_score = _score_geography(r, person)
    scores.append(("geography", geo_score[0], geo_score[1]))

    # --- FAMILY CONTEXT ---
    family_score = _score_family_context(result, person)
    if family_score[0] > 0:
        scores.append(("family", family_score[0], family_score[1]))

    # Weighted average
    weights = {"name": 0.3, "date": 0.3, "geography": 0.25, "family": 0.15}
    total_weight = sum(weights.get(s[0], 0.1) for s in scores)
    weighted_sum = sum(s[1] * weights.get(s[0], 0.1) for s in scores)
    final_score = weighted_sum / total_weight if total_weight > 0 else 0.0

    reasons = [f"{s[0]}: {s[2]}" for s in scores]

    if final_score >= MATCH_ACCEPT:
        verdict = "match"
    elif final_score >= MATCH_UNCERTAIN:
        verdict = "uncertain"
    else:
        verdict = "reject"

    return {
        "score": round(final_score, 2),
        "verdict": verdict,
        "reasons": reasons,
        "record_summary": _summarise_record(r, search_type),
    }


def _score_name(r: dict, person: dict) -> tuple[float, str]:
    """Score name similarity using rules.name_similarity_score."""
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
        return (0.5, "cannot compare names")

    surname_score = name_similarity_score(record_surname, person_surname)
    if surname_score == 0.0:
        return (0.0, f"surname mismatch: {record_surname} vs {person_surname}")

    given_score = name_similarity_score(record_given, person_given) if record_given and person_given else 0.5

    combined = (surname_score * 0.6) + (given_score * 0.4)
    return (combined, f"surname={surname_score:.2f}, given={given_score:.2f}")


def _score_date(r: dict, person: dict, search_type: str) -> tuple[float, str]:
    """Score date plausibility using rules.validate_record. Returns -1 for impossible."""
    birth_year = person.get("birth_year")
    death_year = person.get("death_year")
    record_year = _extract_year_from_record(r)

    if not record_year or not birth_year:
        return (0.5, "insufficient date information")

    # Use rules.validate_record for hard checks
    validation = validate_record(record_year, birth_year, death_year, search_type)
    if validation.startswith("impossible"):
        return (-1, validation)

    if search_type == "death":
        age_at_death = record_year - birth_year

        # Check age-at-death field (FreeBMD deaths)
        recorded_age = r.get("spouse_or_mother", "")
        if recorded_age and recorded_age.isdigit():
            recorded = int(recorded_age)
            if years_match(recorded, age_at_death, tolerance=2):
                return (0.9, f"age at death {recorded} matches expected {age_at_death}")
            else:
                return (0.1, f"age at death {recorded} doesn't match expected {age_at_death}")

        if 20 <= age_at_death <= 95:
            return (0.6, f"died {record_year}, age ~{age_at_death} (plausible)")
        return (0.3, f"died {record_year}, age ~{age_at_death} (unusual)")

    elif search_type == "marriage":
        age_at_marriage = record_year - birth_year
        if not check_marriage_age(birth_year, record_year):
            return (-1, f"married {record_year} at age {age_at_marriage}")
        if 18 <= age_at_marriage <= 45:
            return (0.7, f"married {record_year}, age ~{age_at_marriage} (typical)")
        return (0.4, f"married {record_year}, age ~{age_at_marriage}")

    elif search_type == "census":
        census_birth = r.get("birth_year")
        if isinstance(census_birth, int):
            if years_match(census_birth, birth_year, CENSUS_AGE_TOLERANCE):
                return (0.9, f"census birth year {census_birth} matches ~{birth_year}")
            diff = abs(census_birth - birth_year)
            if diff <= 5:
                return (0.3, f"census birth year {census_birth} is {diff} years off")
            return (0.0, f"census birth year {census_birth} is {diff} years off")
        return (0.5, "no birth year in census record")

    else:
        # Birth or unknown
        if years_match(record_year, birth_year, BIRTH_YEAR_TOLERANCE):
            return (0.9, f"year {record_year} matches ~{birth_year}")
        diff = abs(record_year - birth_year)
        if diff <= 5:
            return (0.3, f"year {record_year} is {diff} years from ~{birth_year}")
        return (0.0, f"year {record_year} is {diff} years from ~{birth_year}")


def _score_geography(r: dict, person: dict) -> tuple[float, str]:
    """Score geographic plausibility using rules."""
    district = (r.get("district", "") or "").strip()
    birth_location = (person.get("birth_location", "") or "").lower()

    if not district:
        county = (r.get("census_county", "") or r.get("birth_county", "") or "").lower()
        if "derby" in county:
            return (0.7, "Derbyshire county")
        if county:
            return (0.2, f"county: {county}")
        return (0.5, "no location data")

    district_clean = district.replace(" district", "").strip()

    # Check using rules
    non_derby = is_non_local(district_clean)
    if non_derby:
        return (0.0, f"{district_clean} is in {non_derby}, not Derbyshire")

    if is_derbyshire_district(district_clean):
        parishes = parishes_in_district(district_clean)
        if birth_location and any(p.lower() in birth_location for p in parishes):
            return (1.0, f"{district_clean} covers {birth_location}")
        return (0.7, f"{district_clean} is in Derbyshire")

    return (0.4, f"unknown district: {district_clean}")


def _score_family_context(result: dict, person: dict) -> tuple[float, str]:
    """Score against family context if available."""
    family = person.get("family_context")
    if not family:
        return (0.0, "no family context")

    household = None
    if isinstance(result, dict) and "household" in result:
        household = result.get("household")

    if not household or not household.get("members"):
        return (0.0, "no household data to check")

    members = household["members"]
    discovered_via = (family.get("discovered_via", "") or "").upper()

    for m in members:
        name = (m.get("name", "") or "").upper()
        if discovered_via and any(part in name for part in discovered_via.split() if len(part) > 2):
            return (0.9, f"household contains {m.get('name')} (expected family member)")

    return (0.0, "expected family member not in household")


def score_all_results(raw_results: dict, person: dict) -> dict:
    """Score all search results for a person."""
    scored = {}

    for source, data in raw_results.items():
        search_type = _classify_search_type(source)
        results = _flatten_results(data)

        scored_results = []
        for r in results:
            s = score_result(r, person, search_type)
            s["result"] = r
            scored_results.append(s)

        scored_results.sort(key=lambda x: x["score"], reverse=True)
        scored[source] = scored_results

    return scored


def summarise_scored_results(scored: dict) -> str:
    """Render scored results as compact text for display."""
    lines = []
    for source, results in scored.items():
        lines.append(f"\n=== {source.upper()} ===")
        matches = [r for r in results if r["verdict"] == "match"]
        uncertain = [r for r in results if r["verdict"] == "uncertain"]
        rejected = [r for r in results if r["verdict"] in ("reject", "impossible")]

        if matches:
            lines.append(f"  MATCHED ({len(matches)}):")
            for r in matches:
                lines.append(f"    [{r['score']}] {r['record_summary']}")
                lines.append(f"         {'; '.join(r['reasons'])}")

        if uncertain:
            lines.append(f"  UNCERTAIN ({len(uncertain)}):")
            for r in uncertain:
                lines.append(f"    [{r['score']}] {r['record_summary']}")
                lines.append(f"         {'; '.join(r['reasons'])}")

        if rejected:
            lines.append(f"  REJECTED ({len(rejected)}):")
            for r in rejected[:5]:
                lines.append(f"    [{r['score']}] {r['record_summary']}")
                lines.append(f"         {'; '.join(r['reasons'])}")
            if len(rejected) > 5:
                lines.append(f"    ... and {len(rejected) - 5} more rejected")

    return "\n".join(lines)


def _classify_search_type(source_key: str) -> str:
    """Determine what kind of records a source returns."""
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
    """Flatten nested result structures into a single list."""
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
    """Extract year from a result dict."""
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
    """One-line summary of a record."""
    if "quarter" in r and "vol" in r:
        name = f"{r.get('firstname', '')} {r.get('surname', '')}".strip()
        spouse = r.get("spouse_or_mother", "")
        spouse_str = f", {spouse}" if spouse and not spouse.isdigit() else ""
        return (
            f"{name}, {r.get('quarter', '')} {r.get('year', '')}, "
            f"{r.get('district', '')} (vol {r.get('vol', '')} p.{r.get('page', '')})"
            f"{spouse_str}"
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
