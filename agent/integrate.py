"""Integrate research findings into the working copy graph.

Translates the pipeline's state dict (confirmed_facts, household_members)
into working copy updates (field changes, proposed profiles, relationships,
bio text, research metadata).

This is the bridge between the research pipeline and the digital twin.
"""

import re
from agent.drafter import draft_bio


def apply_research_to_graph(state: dict, working_copy, twin) -> str | None:
    """Apply research findings to the working copy.

    Returns the matched wt_id, or None if no match found.
    """
    person = state["person"]
    name = person.get("name", "")
    birth_year = person.get("birth_year")
    facts = state.get("confirmed_facts", [])
    household = state.get("household_members", [])

    # 1. Find the subject in the working copy
    name_parts = name.split()
    first = name_parts[0] if name_parts else ""
    last = name_parts[-1] if len(name_parts) > 1 else ""

    matches = working_copy.search(first=first, last=last, birth_year=birth_year)
    wt_id = matches[0]["wt_id"] if matches else None

    if not wt_id:
        # Create as proposed profile
        temp_id = f"_proposed_{name.replace(' ', '_')}_{birth_year or 'unknown'}"
        working_copy.add_proposed_profile(
            temp_id,
            FirstName=first,
            LastNameAtBirth=last,
            BirthDate=f"{birth_year}-00-00" if birth_year else "",
            BirthLocation=person.get("birth_location", ""),
            Gender=_map_gender(person.get("gender", "")),
        )
        wt_id = temp_id
        print(f"  [INTEGRATE] New profile proposed: {temp_id}")
    else:
        print(f"  [INTEGRATE] Matched to {wt_id}")

    # 2. Map confirmed facts to fields
    field_updates = {}
    research_data = {"confirmed_facts": [], "sources": set()}

    for fact in facts:
        fact_type = fact.get("type", "")
        value = fact.get("value", "")
        sources = fact.get("sources", [])

        research_data["confirmed_facts"].append(fact)
        for src in sources:
            research_data["sources"].add(src)

        if fact_type == "birth":
            date = _extract_date(value)
            if date:
                current = working_copy.get(wt_id) or {}
                if not current.get("BirthDate") or current["BirthDate"].startswith("0000"):
                    field_updates["BirthDate"] = date

        elif fact_type == "death":
            date = _extract_date(value)
            if date:
                current = working_copy.get(wt_id) or {}
                if not current.get("DeathDate") or current["DeathDate"].startswith("0000"):
                    field_updates["DeathDate"] = date

        elif fact_type == "marriage":
            # Store marriage info as research metadata
            working_copy.add_research(wt_id, "marriages", {
                "value": value, "sources": sources
            })

        elif fact_type == "census":
            # Extract occupation and address
            occ = _extract_field(value, "occupation")
            addr = _extract_field(value, "address")
            if occ:
                working_copy.add_research(wt_id, "occupations", {
                    "value": occ, "sources": sources
                })
            if addr:
                working_copy.add_research(wt_id, "addresses", {
                    "value": addr, "sources": sources
                })

        elif fact_type == "military":
            working_copy.add_research(wt_id, "military", {
                "value": value, "sources": sources
            })

        elif fact_type == "burial":
            working_copy.add_research(wt_id, "burial", {
                "value": value, "sources": sources
            })

        elif fact_type == "probate":
            working_copy.add_research(wt_id, "probate", {
                "value": value, "sources": sources
            })

    # Apply field updates
    if field_updates:
        working_copy.update_fields(wt_id, field_updates)
        for field, value in field_updates.items():
            print(f"  [INTEGRATE] {field}: {value}")

    # Store sources list
    research_data["sources"] = list(research_data["sources"])
    working_copy.add_research(wt_id, "sources", research_data["sources"])

    # Store uncertain records for human review
    uncertain = state.get("uncertain_records", [])
    if uncertain:
        working_copy.add_research(wt_id, "uncertain_records", uncertain)

    # 3. Draft and store bio
    current_profile = working_copy.get(wt_id) or {}
    current_bio = current_profile.get("Bio") or current_profile.get("bio") or ""

    if facts and (not current_bio or len(current_bio.strip()) < 50):
        bio = draft_bio(state)
        working_copy.update_bio(wt_id, bio)
        print(f"  [INTEGRATE] Bio drafted ({len(bio)} chars)")

    # 4. Add household members
    for member in household:
        member_name = member.get("name", "").strip()
        if not member_name:
            continue

        relationship = _infer_relationship(member)
        if not relationship:
            continue

        # Search for existing profile
        member_parts = member_name.split()
        m_first = member_parts[0] if member_parts else ""
        m_last = member_parts[-1] if len(member_parts) > 1 else ""
        m_birth = member.get("birth_year_approx")

        member_matches = working_copy.search(first=m_first, last=m_last, birth_year=m_birth)

        if member_matches and member_matches[0]["score"] >= 0.7:
            # Existing profile — add relationship if not already linked
            member_wt_id = member_matches[0]["wt_id"]
            if relationship == "spouse":
                working_copy.add_proposed_relationship(wt_id, member_wt_id, "spouse")
            elif relationship in ("father", "mother"):
                working_copy.add_proposed_relationship(member_wt_id, wt_id, "parent")
            elif relationship == "child":
                working_copy.add_proposed_relationship(wt_id, member_wt_id, "parent")
            elif relationship == "sibling":
                working_copy.add_proposed_relationship(wt_id, member_wt_id, "sibling")
        else:
            # New person — add as proposed
            temp_id = f"_proposed_{member_name.replace(' ', '_')}_{m_birth or 'unknown'}"
            if not working_copy.has_node(temp_id):
                working_copy.add_proposed_profile(
                    temp_id,
                    FirstName=m_first,
                    LastNameAtBirth=m_last,
                    BirthDate=f"{m_birth}-00-00" if m_birth else "",
                    BirthLocation=member.get("birth_place", ""),
                    Gender=_map_gender_from_relationship(member),
                    _census_occupation=member.get("occupation", ""),
                    _census_year=member.get("census_year"),
                )
                if relationship == "spouse":
                    working_copy.add_proposed_relationship(wt_id, temp_id, "spouse")
                elif relationship in ("father", "mother"):
                    working_copy.add_proposed_relationship(temp_id, wt_id, "parent")
                elif relationship == "child":
                    working_copy.add_proposed_relationship(wt_id, temp_id, "parent")
                elif relationship == "sibling":
                    working_copy.add_proposed_relationship(wt_id, temp_id, "sibling")

                print(f"  [INTEGRATE] Proposed: {member_name} ({relationship})")

    return wt_id


def _extract_date(value: str) -> str | None:
    """Extract a date from a fact value string.

    Returns WikiTree format: YYYY-MM-00 or YYYY-00-00
    """
    quarter_map = {"Mar": "03", "Jun": "06", "Sep": "09", "Dec": "12"}

    # Try "Mar 1887" or "Dec 1959" pattern
    match = re.search(r"(Mar|Jun|Sep|Dec)\s+(\d{4})", value)
    if match:
        return f"{match.group(2)}-{quarter_map[match.group(1)]}-00"

    # Try bare year
    match = re.search(r"\b(1[6-9]\d{2})\b", value)
    if match:
        return f"{match.group(1)}-00-00"

    return None


def _extract_field(value: str, field_name: str) -> str | None:
    """Extract a named field from a census fact value string."""
    lower = value.lower()
    if f"{field_name}:" in lower:
        after = lower.split(f"{field_name}:")[1]
        result = after.split(",")[0].strip()
        if result and result != "none":
            return result.title()
    return None


def _infer_relationship(member: dict) -> str | None:
    """Map census relationship to graph edge type."""
    rel = (member.get("relationship") or "").lower()
    if rel in ("head", ""):
        return None
    if "wife" in rel or "husband" in rel or "spouse" in rel:
        return "spouse"
    if "son" in rel or "daughter" in rel or "child" in rel:
        return "child"
    if "father" in rel or "mother" in rel or "parent" in rel:
        return "father" if _is_male(member) else "mother"
    if "brother" in rel or "sister" in rel or "sibling" in rel:
        return "sibling"
    return None


def _is_male(member: dict) -> bool:
    rel = (member.get("relationship") or "").lower()
    return any(w in rel for w in ("husband", "son", "father", "brother"))


def _map_gender(gender: str) -> str:
    if gender and gender.upper() == "F":
        return "Female"
    return "Male"


def _map_gender_from_relationship(member: dict) -> str:
    rel = (member.get("relationship") or "").lower()
    if any(w in rel for w in ("wife", "daughter", "mother", "sister")):
        return "Female"
    return "Male"
