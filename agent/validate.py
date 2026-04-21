"""Validate module — checks LLM output for impossibilities before accepting.

Python safety net. Catches errors a 7B model might miss:
temporal impossibilities, logical contradictions, malformed data.
"""


def validate_facts(new_facts: list, state: dict) -> list:
    """Filter out impossible facts. Returns only valid ones."""
    birth_year = _get_known_year(state, "birth")
    death_year = _get_known_year(state, "death")
    valid = []

    for fact in new_facts:
        problems = _check_fact(fact, birth_year, death_year)
        if problems:
            print(f"    REJECTED by validator: {fact.get('value', '?')}")
            for p in problems:
                print(f"      Reason: {p}")
            # Move to rejected records instead of silently dropping
            state.setdefault("rejected_records", []).append({
                "record": fact.get("value", "?"),
                "reason": "; ".join(problems),
            })
        else:
            valid.append(fact)

    return valid


def validate_rejections(rejections: list, state: dict) -> list:
    """Ensure rejections have required fields."""
    valid = []
    for r in rejections:
        if isinstance(r, dict) and "record" in r and "reason" in r:
            valid.append(r)
    return valid


def _check_fact(fact: dict, birth_year: int | None, death_year: int | None) -> list:
    """Return list of problems with a fact. Empty list = valid."""
    problems = []
    fact_type = fact.get("type", "")
    value = fact.get("value", "")

    # Extract year from the value string
    fact_year = _extract_year(value)

    if fact_year and birth_year:
        # Death fact before birth — impossible
        if fact_type.startswith("death") and fact_year < birth_year:
            problems.append(f"Death in {fact_year} but born {birth_year} — death before birth")

        # Event before birth
        if fact_type in ("marriage", "census", "military") and fact_year < birth_year:
            problems.append(f"Event in {fact_year} but born {birth_year}")

        # Marriage too young (before age 14)
        if fact_type == "marriage" and fact_year < birth_year + 14:
            problems.append(f"Marriage at age {fact_year - birth_year} — too young")

    if fact_year and death_year:
        # Event after death
        if fact_type in ("marriage", "census") and fact_year > death_year:
            problems.append(f"Event in {fact_year} but died {death_year}")

    if birth_year and death_year:
        # Impossible lifespan
        if death_year < birth_year:
            problems.append(f"Death {death_year} before birth {birth_year}")
        if (death_year - birth_year) > 110:
            problems.append(f"Lifespan of {death_year - birth_year} years — implausible")

    # Check confidence is valid
    if fact.get("confidence") not in ("high", "medium", "low"):
        fact["confidence"] = "low"  # Fix rather than reject

    return problems


def _get_known_year(state: dict, fact_type: str) -> int | None:
    """Extract a known year from confirmed facts or initial person data."""
    # Check person data first
    person = state.get("person", {})
    if fact_type == "birth" and person.get("birth_year"):
        return person["birth_year"]
    if fact_type == "death" and person.get("death_year"):
        return person["death_year"]

    # Check confirmed facts
    for fact in state.get("confirmed_facts", []):
        if fact.get("type", "").startswith(fact_type):
            year = _extract_year(fact.get("value", ""))
            if year:
                return year

    return None


def _extract_year(text: str) -> int | None:
    """Extract a four-digit year from text."""
    import re
    match = re.search(r"\b(1[6-9]\d{2}|20[0-2]\d)\b", str(text))
    return int(match.group(1)) if match else None


def update_known_dates(state: dict) -> None:
    """After new facts are confirmed, update birth/death years
    in the person dict so future searches use them.

    Validates consistency before applying — won't set a death year
    that's before the birth year, for example.
    """
    birth_year = state["person"].get("birth_year")
    death_year = state["person"].get("death_year")

    for fact in state.get("confirmed_facts", []):
        year = _extract_year(fact.get("value", ""))
        if not year:
            continue

        if fact.get("type", "").startswith("birth") and not birth_year:
            state["person"]["birth_year"] = year
            birth_year = year
            print(f"    Updated birth year: {year}")

        if fact.get("type", "").startswith("death") and not death_year:
            # Validate: death must be after birth
            if birth_year and year < birth_year:
                print(f"    REJECTED death year {year} — before birth {birth_year}")
                continue
            # Validate: lifespan must be plausible
            if birth_year and (year - birth_year) > 110:
                print(f"    REJECTED death year {year} — implausible age {year - birth_year}")
                continue
            state["person"]["death_year"] = year
            death_year = year
            print(f"    Updated death year: {year}")
