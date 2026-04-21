"""Integrate research findings into facts and leads.

Facts: verified data that can be applied to WikiTree (the queue)
Leads: promising findings that need further investigation (the backlog)

No "proposed changes" — everything is either a fact or a lead.
"""

import re
from agent.drafter import draft_bio
from agent.leads import Lead, Evidence, NextAction, LeadStore, _make_lead_id


def integrate_research(state: dict, twin, lead_store: LeadStore) -> dict:
    """Process research results into facts and leads.

    Returns dict with:
        "facts": list of verified changes to apply to WikiTree
        "leads_created": int count of new leads opened
    """
    person = state["person"]
    name = person.get("name", "")
    birth_year = person.get("birth_year")
    confirmed = state.get("confirmed_facts", [])
    household = state.get("household_members", [])

    # Find the subject in the twin
    name_parts = name.split()
    first = name_parts[0] if name_parts else ""
    last = name_parts[-1] if len(name_parts) > 1 else ""

    matches = twin.search(first=first, last=last, birth_year=birth_year)
    wt_id = matches[0]["wt_id"] if matches else None

    if wt_id:
        print(f"  [INTEGRATE] Matched to {wt_id}")
    else:
        print(f"  [INTEGRATE] No WikiTree profile found for {name}")

    # === BUILD FACT QUEUE ===
    facts = []

    # Field updates from confirmed facts
    if wt_id:
        profile = twin.get(wt_id) or {}

        for fact in confirmed:
            fact_type = fact.get("type", "")
            value = fact.get("value", "")
            sources = fact.get("sources", [])

            if fact_type == "birth":
                date = _extract_date(value)
                current = profile.get("BirthDate", "") or ""
                if date and (not current or current.startswith("0000")):
                    facts.append({
                        "action": "update_field",
                        "wt_id": wt_id,
                        "field": "BirthDate",
                        "value": date,
                        "sources": sources,
                    })

            elif fact_type == "death":
                date = _extract_date(value)
                current = profile.get("DeathDate", "") or ""
                if date and (not current or current.startswith("0000")):
                    facts.append({
                        "action": "update_field",
                        "wt_id": wt_id,
                        "field": "DeathDate",
                        "value": date,
                        "sources": sources,
                    })

        # Bio draft if empty
        current_bio = profile.get("Bio") or profile.get("bio") or ""
        if confirmed and (not current_bio or len(current_bio.strip()) < 50):
            bio = draft_bio(state)
            facts.append({
                "action": "update_bio",
                "wt_id": wt_id,
                "bio": bio,
                "sources": [s for f in confirmed for s in f.get("sources", [])],
            })
            print(f"  [INTEGRATE] Bio drafted ({len(bio)} chars)")

    for fact in facts:
        print(f"  [INTEGRATE] Fact: {fact['action']} {fact.get('field', '')} {fact.get('value', '')}")

    # === HOUSEHOLD MEMBERS → LEADS ===
    leads_created = 0

    for member in household:
        member_name = member.get("name", "").strip()
        if not member_name:
            continue

        relationship = _infer_relationship(member)
        if not relationship:
            continue

        # Skip the subject themselves
        if member_name.upper() == name.upper():
            continue

        m_birth = member.get("birth_year_approx")
        census_year = member.get("census_year")
        occupation = member.get("occupation", "")
        birth_place = member.get("birth_place", "")

        # Check if this person already exists in the twin
        m_parts = member_name.split()
        m_first = m_parts[0] if m_parts else ""
        m_last = m_parts[-1] if len(m_parts) > 1 else ""
        existing = twin.search(first=m_first, last=m_last, birth_year=m_birth)

        if existing and existing[0]["score"] >= 0.7:
            # Known person — but is the relationship linked?
            # This is a lead to verify the link, not a fact
            existing_id = existing[0]["wt_id"]
            lead_id = _make_lead_id(member_name, "relationship", census_year)

            lead = Lead(
                lead_id=lead_id,
                subject_id=existing_id,
                subject_name=member_name,
                subject_birth_year=m_birth,
                category="relationship",
                summary=f"{member_name} ({relationship} of {name}) — found in {census_year} census, exists as {existing_id}",
                uncertainty_reasons=[f"Relationship inferred from {census_year} census — verify link on WikiTree"],
                evidence=[Evidence(
                    source=f"census_{census_year}",
                    record_summary=f"{member_name}, {relationship}, age {member.get('age', '?')}, {birth_place}",
                    reasons=[f"Found as {relationship} in {name}'s household"],
                    search_type="census",
                )],
                next_actions=[NextAction(
                    description=f"Check if {existing_id} is linked as {relationship} of {wt_id or name} on WikiTree",
                    source="wikitree",
                    cost="free",
                )],
            )
            lead_store.add(lead)
            leads_created += 1
        else:
            # Unknown person — lead to investigate who they are
            lead_id = _make_lead_id(member_name, "identity", m_birth)

            actions = []
            if m_birth and m_birth >= 1837:
                actions.append(NextAction(
                    description=f"Search FreeBMD for {member_name} birth ~{m_birth}",
                    source="freebmd",
                    parameters={"surname": m_last, "given": m_first, "event": "births",
                                "year_start": m_birth - 2, "year_end": m_birth + 2},
                    cost="free",
                ))
            actions.append(NextAction(
                description=f"Search WikiTree for existing {member_name} profile",
                source="wikitree",
                cost="free",
            ))

            lead = Lead(
                lead_id=lead_id,
                subject_id="",
                subject_name=member_name,
                subject_birth_year=m_birth,
                category="identity",
                summary=f"{member_name} ({relationship} of {name}) — found in {census_year} census, no WikiTree profile",
                uncertainty_reasons=[
                    f"Only seen in one source ({census_year} census)",
                    "No WikiTree profile found — may exist under different spelling",
                ],
                evidence=[Evidence(
                    source=f"census_{census_year}",
                    record_summary=f"{member_name}, {relationship}, age {member.get('age', '?')}, {occupation}, born {birth_place}",
                    reasons=[f"Found as {relationship} in {name}'s household"],
                    search_type="census",
                )],
                next_actions=actions,
            )
            lead_store.add(lead)
            leads_created += 1

    if leads_created:
        print(f"  [INTEGRATE] {leads_created} household members → leads")

    return {
        "facts": facts,
        "leads_created": leads_created,
        "wt_id": wt_id,
    }


def _extract_date(value: str) -> str | None:
    """Extract WikiTree date format from a fact value string."""
    quarter_map = {"Mar": "03", "Jun": "06", "Sep": "09", "Dec": "12"}
    match = re.search(r"(Mar|Jun|Sep|Dec)\s+(\d{4})", value)
    if match:
        return f"{match.group(2)}-{quarter_map[match.group(1)]}-00"
    match = re.search(r"\b(1[6-9]\d{2})\b", value)
    if match:
        return f"{match.group(1)}-00-00"
    return None


def _infer_relationship(member: dict) -> str | None:
    rel = (member.get("relationship") or "").lower()
    if rel in ("head", ""):
        return None
    if "wife" in rel or "husband" in rel or "spouse" in rel:
        return "spouse"
    if "son" in rel or "daughter" in rel or "child" in rel:
        return "child"
    if "father" in rel or "mother" in rel or "parent" in rel:
        return "parent"
    if "brother" in rel or "sister" in rel or "sibling" in rel:
        return "sibling"
    if "law" in rel:
        return "in-law"
    return None
