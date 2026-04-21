"""Bio drafter — generates narrative biographies from confirmed research facts.

Pure text generation, no WikiTree interaction. Takes the agent's
confirmed_facts and produces MediaWiki-formatted biography text.

Usage:
    from agent.drafter import draft_bio

    bio = draft_bio(state)
    print(bio)
"""

import re


def draft_bio(state: dict) -> str:
    """Draft a narrative biography from confirmed research facts.

    Returns MediaWiki-formatted bio text.
    """
    person = state["person"]
    name = person.get("name", "Unknown")
    birth_year = person.get("birth_year")
    death_year = person.get("death_year")
    birth_location = person.get("birth_location", "")
    death_location = person.get("death_location", "")

    facts = state.get("confirmed_facts", [])

    lines = ["== Biography ==\n"]

    # Opening line — name with dates and location
    opening = name
    date_parts = []
    if birth_year:
        bp = f"b.{birth_year}"
        if birth_location:
            bp += f", {birth_location}"
        date_parts.append(bp)
    if death_year:
        dp = f"d.{death_year}"
        if death_location:
            dp += f", {death_location}"
        date_parts.append(dp)
    if date_parts:
        opening += f" ({'; '.join(date_parts)})"
    lines.append(opening + ".")

    # Marriage facts
    for mf in _facts_of_type(facts, "marriage"):
        lines.append("")
        lines.append(_clean_fact(mf["value"]) + ".")

    # Census facts — extract occupations
    occupations = set()
    for cf in _facts_of_type(facts, "census"):
        value = cf.get("value", "")
        for keyword in ["occupation:", "occ:"]:
            if keyword in value.lower():
                occ = value.lower().split(keyword)[1].split(",")[0].strip()
                if occ and occ != "none":
                    occupations.add(occ.title())

    if occupations:
        lines.append("")
        lines.append(f"Occupation: {', '.join(sorted(occupations))}.")

    # Military facts
    for mf in _facts_of_type(facts, "military"):
        lines.append("")
        lines.append(_clean_fact(mf["value"]) + ".")

    # Death/burial facts
    for df in _facts_of_type(facts, "death", "burial"):
        value = df.get("value", "")
        if value and "death" not in lines[-1].lower():
            lines.append("")
            lines.append(_clean_fact(value) + ".")

    # Probate facts
    for pf in _facts_of_type(facts, "probate"):
        lines.append("")
        lines.append(_clean_fact(pf["value"]) + ".")

    # Sources section
    lines.append("")
    lines.append("== Sources ==")
    lines.append("<references />")

    source_lines = set()
    for f in facts:
        for src in f.get("sources", []):
            source_lines.add(src)

    if source_lines:
        lines.append("")
        for src in sorted(source_lines):
            lines.append(f"* {src}")

    return "\n".join(lines)


def _facts_of_type(facts: list, *types: str) -> list:
    """Filter facts by type."""
    return [f for f in facts if f.get("type") in types]


def _clean_fact(value: str) -> str:
    """Clean up a fact value for bio text."""
    value = re.sub(r"^[a-z_]+\d*:\s*", "", value)
    if value and value[0].islower():
        value = value[0].upper() + value[1:]
    return value.rstrip(".")
