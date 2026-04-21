"""Render module — translates between machine state and LLM-readable text.

This is the memory manager. It controls what enters the context window.
Full evidence lives in Python memory and on disk. The LLM only sees
compact, relevant summaries rendered fresh each iteration.

KEY DESIGN: Python pre-annotates results with date arithmetic and
geographic analysis BEFORE the LLM sees them. The LLM validates
annotations rather than computing from scratch.
"""

from agent.rules import DISTRICT_PARISHES, NON_LOCAL_DISTRICTS as NON_DERBY_DISTRICTS


def render_narrative(state: dict) -> str:
    """Render the current knowledge state as a compact narrative for the LLM."""
    lines = [f"RESEARCHING: {state['person']['name']}"]

    person = state["person"]
    known = []
    if person.get("birth_year"):
        known.append(f"born ~{person['birth_year']}")
    if person.get("death_year"):
        known.append(f"died {person['death_year']}")
    if person.get("birth_location"):
        known.append(person["birth_location"])
    if person.get("gender"):
        known.append(f"gender: {person['gender']}")
    if known:
        lines.append(f"STARTED WITH: {', '.join(known)}")
    else:
        lines.append("STARTED WITH: name only — no dates or location")

    # Family context — how this person was discovered
    family_ctx = person.get("family_context")
    if family_ctx:
        lines.append(f"\nFAMILY CONTEXT (use this to filter candidates):")
        lines.append(f"  Discovered as: {family_ctx.get('relationship', '?')} of {family_ctx.get('discovered_via', '?')}")
        if family_ctx.get("source"):
            lines.append(f"  Source: {family_ctx['source']}")
        if family_ctx.get("notes"):
            lines.append(f"  Notes: {family_ctx['notes']}")

    facts = state.get("confirmed_facts", [])
    if facts:
        lines.append("\nCONFIRMED FACTS:")
        for f in facts:
            sources = ", ".join(f.get("sources", []))
            lines.append(
                f"  - {f['type']}: {f['value']} "
                f"[{f.get('confidence', '?')}] ({sources})"
            )
    else:
        lines.append("\nCONFIRMED FACTS: none yet")

    rejected = state.get("rejected_records", [])
    if rejected:
        lines.append("\nREJECTED (not this person):")
        for r in rejected[-10:]:  # Last 10 to keep compact
            lines.append(f"  - {r['record']} — {r['reason']}")

    conflicts = state.get("conflicts", [])
    if conflicts:
        lines.append("\nCONFLICTS (unresolved):")
        for c in conflicts:
            lines.append(f"  - {c['description']}")

    searched = state.get("searched", [])
    if searched:
        lines.append("\nSEARCHED (don't repeat):")
        for s in searched:
            status = s.get("status", "done")
            symbol = {"found": "found", "empty": "empty", "error": "ERROR"}.get(
                status, status
            )
            lines.append(f"  - {s['source']}: {symbol}")

    # Household members found in census records (real data, not inferred)
    household = state.get("household_members", [])
    if household:
        lines.append(f"\nHOUSEHOLD MEMBERS FOUND IN CENSUS (real data):")
        for m in household:
            birth_str = f"born ~{m['birth_year_approx']}" if m.get('birth_year_approx') else f"age {m.get('age', '?')}"
            lines.append(
                f"  - {m['name']}, {m['relationship']}, {birth_str}, "
                f"{m.get('occupation', '')}, born {m.get('birth_place', '?')} "
                f"(census {m.get('census_year', '?')})"
            )

    objectives = state.get("objectives", {})
    open_objectives = [
        k for k, v in objectives.items() if v not in ("found", "exhausted", "not_applicable")
    ]
    if open_objectives:
        lines.append(f"\nSTILL NEED: {', '.join(open_objectives)}")
    else:
        lines.append("\nALL OBJECTIVES COMPLETE")

    return "\n".join(lines)


def render_results(raw_results: dict, state: dict | None = None) -> str:
    """Render search results with pre-computed annotations.

    If state is provided, each result is annotated with:
    - Age difference from known birth year
    - Geographic plausibility
    - Temporal possibility (before birth? after death?)
    - A verdict: POSSIBLE MATCH / LIKELY DIFFERENT / IMPOSSIBLE
    """
    birth_year = None
    death_year = None
    birth_location = None

    if state:
        birth_year = state.get("person", {}).get("birth_year")
        death_year = state.get("person", {}).get("death_year")
        birth_location = state.get("person", {}).get("birth_location", "")
        # Also check confirmed facts for learned dates
        for fact in state.get("confirmed_facts", []):
            if not birth_year and fact.get("type", "").startswith("birth"):
                birth_year = _extract_year(fact.get("value", ""))
            if not death_year and fact.get("type", "").startswith("death"):
                death_year = _extract_year(fact.get("value", ""))

    lines = []

    for source, data in raw_results.items():
        lines.append(f"\n=== {source.upper()} ===")

        # Determine if this is a death/marriage search (changes how we interpret years)
        search_type = _classify_search_type(source)

        if isinstance(data, str) and data.startswith("error:"):
            lines.append(f"  SERVER ERROR: {data}")
            lines.append(f"  (This source could not be searched — may need retry)")
            continue

        if isinstance(data, list):
            _render_annotated_list(lines, data, birth_year, death_year,
                                   birth_location, search_type=search_type)
        elif isinstance(data, dict):
            for sub_key, sub_data in data.items():
                sub_search_type = _classify_search_type(sub_key) or search_type
                lines.append(f"\n  --- {sub_key} ---")
                if isinstance(sub_data, str) and sub_data.startswith("error:"):
                    lines.append(f"    SERVER ERROR: {sub_data}")
                elif isinstance(sub_data, list):
                    _render_annotated_list(lines, sub_data, birth_year, death_year,
                                           birth_location, indent="    ",
                                           search_type=sub_search_type)
                else:
                    lines.append(f"    {sub_data}")

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
        return "death"  # CWGC records are death records
    if "burial" in key or "grave" in key:
        return "burial"
    return "unknown"


def _render_annotated_list(lines, results, birth_year, death_year,
                            birth_location, indent="  ",
                            search_type="unknown") -> None:
    """Render results with pre-computed annotations."""
    if not results:
        lines.append(f"{indent}No results found.")
        return

    for i, r in enumerate(results[:15]):
        record_text = _render_one_result(r)
        annotation = _annotate_result(r, birth_year, death_year,
                                       birth_location, search_type)

        lines.append(f"{indent}[{i + 1}] {record_text}")
        if annotation:
            lines.append(f"{indent}    {annotation}")

    if len(results) > 15:
        lines.append(f"{indent}... and {len(results) - 15} more results")


def _annotate_result(r: dict, birth_year: int | None, death_year: int | None,
                      birth_location: str | None,
                      search_type: str = "unknown") -> str:
    """Pre-compute date and geographic annotation for one result.

    search_type tells us how to interpret the year field:
    - "birth": year = when person was born
    - "death": year = when person DIED (compare against lifespan, not birth year)
    - "marriage": year = when person married (must be between birth+14 and death)
    - "census": year = when census taken (person's age tells us birth year)
    - "burial": dates are death-related
    """
    if not isinstance(r, dict):
        return ""

    issues = []
    supports = []

    # Handle enriched census format
    if "search_match" in r:
        r_data = r["search_match"]
    else:
        r_data = r

    # Extract the year from this record
    record_year = r_data.get("year") or r_data.get("birth_year") or r_data.get("census_year")
    if isinstance(record_year, str):
        record_year = _extract_year(record_year)

    record_district = r_data.get("district", "").strip()

    # --- DATE ANALYSIS (depends on search type) ---

    if search_type == "death" and birth_year and record_year:
        # For DEATH records: year = death year
        # Check: is the implied lifespan plausible?
        age_at_death = record_year - birth_year
        if age_at_death < 0:
            issues.append(f"died {record_year} before birth ~{birth_year} — IMPOSSIBLE")
        elif age_at_death > 110:
            issues.append(f"died {record_year}, would be age {age_at_death} — implausible lifespan")
        elif 20 <= age_at_death <= 95:
            supports.append(f"died {record_year}, would be age ~{age_at_death} (plausible lifespan)")
        elif age_at_death < 20:
            supports.append(f"died {record_year}, would be age ~{age_at_death} (young death — possible)")
        else:
            supports.append(f"died {record_year}, would be age ~{age_at_death}")

        # Also check: spouse_or_mother field on death records contains age at death
        spouse_field = r_data.get("spouse_or_mother", "")
        if spouse_field and spouse_field.isdigit():
            recorded_age = int(spouse_field)
            if abs(recorded_age - age_at_death) <= 2:
                supports.append(f"recorded age at death ({recorded_age}) matches expected age ({age_at_death})")
            else:
                issues.append(f"recorded age at death ({recorded_age}) doesn't match expected ({age_at_death})")

    elif search_type == "marriage" and birth_year and record_year:
        # For MARRIAGE records: year = marriage year
        age_at_marriage = record_year - birth_year
        if age_at_marriage < 14:
            issues.append(f"married {record_year}, would be age {age_at_marriage} — too young, IMPOSSIBLE")
        elif age_at_marriage > 80:
            issues.append(f"married {record_year}, would be age {age_at_marriage} — very unlikely")
        elif 16 <= age_at_marriage <= 50:
            supports.append(f"married {record_year}, would be age ~{age_at_marriage} (typical marriage age)")
        else:
            supports.append(f"married {record_year}, would be age ~{age_at_marriage}")

        # After known death?
        if death_year and record_year > death_year:
            issues.append(f"married {record_year} but died {death_year} — IMPOSSIBLE")

    elif search_type in ("birth", "unknown") and birth_year and record_year:
        # For BIRTH records or unknown: year = birth year
        if r_data.get("record_id") or ("vol" in r_data and "page" in r_data):
            diff = abs(record_year - birth_year)
            if diff <= 2:
                supports.append(f"birth year {record_year} is within 2 years of ~{birth_year}")
            elif diff <= 5:
                issues.append(f"born {record_year} = {diff} years from expected ~{birth_year}")
            else:
                issues.append(f"born {record_year} = {diff} years from expected ~{birth_year} — very unlikely same person")

    # Census age check (search_type == "census")
    if search_type == "census":
        r_check = r_data
        if "search_match" in r:
            r_check = r["search_match"]
        census_birth = r_check.get("birth_year")
        census_year = r_check.get("census_year")
        if birth_year and census_birth and isinstance(census_birth, int):
            diff = abs(census_birth - birth_year)
            if diff <= 2:
                supports.append(f"census birth year {census_birth} consistent with ~{birth_year}")
            elif diff <= 5:
                issues.append(f"census says born {census_birth}, we expect ~{birth_year} ({diff} year gap — possible census error)")
            else:
                issues.append(f"census says born {census_birth} but we expect ~{birth_year} ({diff} year gap — likely different person)")

    # --- GEOGRAPHIC ANALYSIS ---
    if record_district:
        district_clean = record_district.replace(" district", "").strip()

        if district_clean in NON_DERBY_DISTRICTS:
            location = NON_DERBY_DISTRICTS[district_clean]
            issues.append(f"{district_clean} is in {location}, not Derbyshire")
        elif district_clean in DISTRICT_PARISHES:
            covered = DISTRICT_PARISHES[district_clean]
            if birth_location:
                loc_lower = birth_location.lower()
                if any(p.lower() in loc_lower for p in covered):
                    supports.append(f"{district_clean} district covers {birth_location}")
                else:
                    supports.append(f"{district_clean} district is in Derbyshire (plausible)")
            else:
                supports.append(f"{district_clean} district is in Derbyshire")

    # --- BUILD VERDICT ---
    if any("IMPOSSIBLE" in i for i in issues):
        return ">>> IMPOSSIBLE: " + "; ".join(issues)
    elif issues and not supports:
        return ">>> LIKELY DIFFERENT PERSON: " + "; ".join(issues)
    elif issues and supports:
        return ">>> UNCERTAIN: " + "; ".join(supports) + " BUT " + "; ".join(issues)
    elif supports:
        return ">>> POSSIBLE MATCH: " + "; ".join(supports)
    else:
        return ""


def _render_one_result(r: dict) -> str:
    """Render a single result dict as a compact one-liner."""
    if not isinstance(r, dict):
        return str(r)

    # FreeBMD format
    if "quarter" in r and "vol" in r:
        name = f"{r.get('firstname', '')} {r.get('surname', '')}".strip()
        spouse = r.get("spouse_or_mother", "")
        spouse_str = f", spouse/mother: {spouse}" if spouse else ""
        return (
            f"{name}, {r.get('quarter', '')} {r.get('year', '')}, "
            f"{r.get('district', '')} district "
            f"(vol {r.get('vol', '')} p.{r.get('page', '')}){spouse_str}"
        )

    # FreeCen enriched format (search match + household)
    if "search_match" in r:
        match = r["search_match"]
        household = r.get("household")
        base = (
            f"{match.get('name', '?')}, census {match.get('census_year', '?')}, "
            f"born {match.get('birth_year', '?')} {match.get('birth_place', '?')}, "
            f"{match.get('census_district', '')}, {match.get('census_county', '')}"
        )
        if household and household.get("members"):
            dwelling = household.get("dwelling", {})
            address = dwelling.get("address", "")
            parish = dwelling.get("parish", "")
            members = household["members"]
            member_lines = [f"\n      Address: {address}, {parish}"]
            member_lines.append(f"      Household ({len(members)} members):")
            for m in members:
                target = " <<<" if m.get("is_target") else ""
                member_lines.append(
                    f"        - {m.get('name', '?')}, {m.get('relationship', '?')}, "
                    f"age {m.get('age', '?')}, {m.get('occupation', '')}, "
                    f"born {m.get('birth_place', '?')}{target}"
                )
            return base + "\n".join(member_lines)
        return base

    # FreeCen simple format
    if "census_year" in r and "birth_place" in r:
        return (
            f"{r.get('name', '?')}, census {r.get('census_year', '?')}, "
            f"born {r.get('birth_year', '?')} {r.get('birth_place', '?')}, "
            f"{r.get('census_district', '')}, {r.get('census_county', '')}"
        )

    # FreeCen household member format
    if "relationship" in r and "age" in r:
        return (
            f"{r.get('name', '?')}, {r.get('relationship', '?')}, "
            f"age {r.get('age', '?')}, {r.get('occupation', '')}, "
            f"born {r.get('birth_place', '?')}"
        )

    # CWGC format
    if "regiment" in r or "casualty_id" in r:
        return (
            f"{r.get('name', '?')}, {r.get('rank', '')} "
            f"{r.get('regiment', '')}, "
            f"died {r.get('date_of_death', '?')}, "
            f"age {r.get('age', '?')}, "
            f"{r.get('cemetery_memorial', '')}"
        )

    # Find a Grave format
    if "memorial_id" in r:
        return (
            f"{r.get('name', '?')}, "
            f"b.{r.get('birth_date', '?')} d.{r.get('death_date', '?')}, "
            f"{r.get('cemetery', '')}, {r.get('burial_location', '')}"
        )

    # Generic fallback
    useful_keys = ["name", "surname", "firstname", "year", "date", "place", "location"]
    parts = []
    for k in useful_keys:
        if k in r and r[k]:
            parts.append(f"{k}: {r[k]}")
    if parts:
        return ", ".join(parts)

    return str(r)[:200]


def _extract_year(text: str) -> int | None:
    """Extract a four-digit year from text."""
    import re
    match = re.search(r"\b(1[6-9]\d{2}|20[0-2]\d)\b", str(text))
    return int(match.group(1)) if match else None
