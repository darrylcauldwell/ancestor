"""Strategist — DeepSeek-R1 reads context and suggests research strategy.

This replaces the old correlate.py. The LLM no longer matches records
(Python scorer does that). Instead it reads confirmed facts and
suggests non-obvious research directions.

Called once per person AFTER Python has searched and scored.
"""

from agent.llm import ask_json

SYSTEM_PROMPT = """You are an experienced English genealogist reviewing a family's research progress.

Your job is to spot non-obvious connections and suggest specific searches that a checklist wouldn't generate.

Think step by step. Chain through the logic of what relationships tell you:
- Census "Mother-in-Law" means mother of the spouse — their surname reveals the maiden name
- A missing person from later censuses might have died, moved, enlisted, or married and changed household
- A gap between children might indicate infant deaths worth searching for
- Witnesses on marriage certificates are often family members
- Parish registers before 1837 are the only source for births, marriages, and deaths

Be specific. Don't say "search for birth records." Say "search FreeBMD births for Elizabeth BARKER, Belper district, 1858-1864" — give names, sources, date ranges, and districts.

IMPORTANT CONSTRAINTS:
- This family is from Derbyshire. Always include a district or county in search parameters.
- Use narrow date ranges (5-10 years max) — wide searches return thousands of irrelevant results.
- FreeBMD spouse surname filter only works for marriages after Sep 1912 and births after Sep 1911.
- Only suggest searches that haven't already been done (check ALREADY SEARCHED list).

Respond with valid JSON only."""


def suggest_strategy(state: dict) -> dict | None:
    """Ask DeepSeek-R1 to analyse research progress and suggest next steps.

    Returns:
        {
            "insights": ["non-obvious observations about the family"],
            "searches": [
                {
                    "description": "what to search for and why",
                    "source": "freebmd|freecen|cwgc|findagrave|freereg|parish",
                    "parameters": {"surname": "...", "given": "...", ...},
                    "reasoning": "chain of logic for why this search matters"
                }
            ],
            "questions": ["things that need human input to resolve"]
        }
    """
    # Build context from state
    context = _build_context(state)

    prompt = f"""{context}

Review this research progress. What do you notice that the researcher might have missed?

Focus on:
1. What do the RELATIONSHIPS tell us? (surnames, connections, maiden names)
2. What GAPS exist that a specific search could fill?
3. What NON-OBVIOUS leads emerge from the confirmed facts?
4. Any INCONSISTENCIES worth investigating?

Return JSON:
{{
    "insights": [
        "Each insight should show your step-by-step reasoning"
    ],
    "searches": [
        {{
            "description": "What to search for",
            "source": "freebmd|freecen|cwgc|findagrave|freereg",
            "parameters": {{"surname": "...", "given": "...", "year_start": 0, "year_end": 0, "event": "births|deaths|marriages", "district": "..."}},
            "reasoning": "Why this search — show the chain of logic"
        }}
    ],
    "questions": [
        "Anything that needs human judgement to resolve"
    ]
}}"""

    return ask_json(prompt, system=SYSTEM_PROMPT)


def _build_context(state: dict) -> str:
    """Build rich context for the strategist from current state."""
    lines = []
    person = state["person"]

    lines.append(f"PERSON: {person.get('name', 'Unknown')}")

    # Known facts
    known = []
    if person.get("birth_year"):
        known.append(f"born ~{person['birth_year']}")
    if person.get("death_year"):
        known.append(f"died {person['death_year']}")
    if person.get("birth_location"):
        known.append(f"in {person['birth_location']}")
    if person.get("gender"):
        known.append(f"gender: {person['gender']}")
    lines.append(f"KNOWN: {', '.join(known) if known else 'minimal information'}")

    # Family context
    family = person.get("family_context")
    if family:
        lines.append(f"\nFAMILY CONTEXT:")
        lines.append(f"  Discovered as: {family.get('relationship', '?')} "
                      f"of {family.get('discovered_via', '?')}")
        if family.get("notes"):
            lines.append(f"  Notes: {family['notes']}")

    # Confirmed facts from scoring
    facts = state.get("confirmed_facts", [])
    if facts:
        lines.append(f"\nCONFIRMED FACTS ({len(facts)}):")
        for f in facts:
            sources = ", ".join(f.get("sources", []))
            lines.append(f"  - {f['type']}: {f['value']} [{f.get('confidence')}] ({sources})")

    # Household members (real people found in census)
    household = state.get("household_members", [])
    if household:
        lines.append(f"\nHOUSEHOLD MEMBERS FROM CENSUS ({len(household)}):")
        for m in household:
            birth_str = f"born ~{m['birth_year_approx']}" if m.get('birth_year_approx') else f"age {m.get('age', '?')}"
            lines.append(
                f"  - {m['name']}, {m['relationship']}, {birth_str}, "
                f"{m.get('occupation', '')}, born {m.get('birth_place', '?')} "
                f"(census {m.get('census_year', '?')})"
            )

    # What's been searched
    searched = state.get("searched", [])
    if searched:
        lines.append(f"\nALREADY SEARCHED:")
        for s in searched:
            lines.append(f"  - {s['source']}: {s.get('status', '?')}")

    # Rejected records (brief)
    rejected = state.get("rejected_records", [])
    if rejected:
        lines.append(f"\nREJECTED RECORDS: {len(rejected)} (scored too low or impossible)")

    # Objectives
    objectives = state.get("objectives", {})
    open_obj = [k for k, v in objectives.items()
                if v not in ("found", "exhausted", "not_applicable")]
    if open_obj:
        lines.append(f"\nSTILL INVESTIGATING: {', '.join(open_obj)}")

    return "\n".join(lines)
