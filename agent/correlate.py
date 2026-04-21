"""Correlate phase — two-pass correlation for entity resolution.

Pass 1 (SCREEN): Sort results into REJECTED or CANDIDATE. Nothing confirmed.
Pass 2 (RESOLVE): Cross-reference all candidates against family context
                  and each other. Only now confirm facts.

This solves the "Elizabeth problem" — when multiple plausible matches exist,
the model must consider them TOGETHER, not individually.
"""

from agent.llm import ask_json

SCREEN_SYSTEM = """You are a genealogist screening search results.

For each result, decide: REJECT or CANDIDATE.

REJECT if:
- The annotation says IMPOSSIBLE (always reject these)
- The annotation says LIKELY DIFFERENT PERSON and you agree
- The name, date, or location clearly don't fit

CANDIDATE if:
- The annotation says POSSIBLE MATCH
- The dates and location are plausible
- You're unsure — keep it as a candidate for further analysis

Do NOT confirm any facts yet. Just sort into rejected and candidates.
Multiple candidates for the same person are expected — we'll resolve them in the next step.

Respond with JSON only."""


RESOLVE_SYSTEM = """You are a genealogist resolving which candidate records belong to one specific person.

You have multiple candidate records that MIGHT refer to our person. Your job is to determine which ones actually do, using cross-referencing:

CROSS-REFERENCING PRINCIPLES:
1. Census household context is the strongest evidence — if we know who they lived with, use that to filter.
2. Marriage records that name the correct spouse = strong match.
3. Death records must be AFTER the last known alive date and in a plausible location.
4. Multiple records that independently point to the same dates/locations = high confidence.
5. When candidates conflict (two different death dates), pick the one with more supporting evidence, or flag as conflict.
6. A single record with no corroboration = LOW confidence. Don't confirm it unless nothing contradicts it.
7. Prefer the candidate that is MOST CONSISTENT with everything else we know.

If no candidate is clearly the right match, say so — "unresolved" is better than wrong.

Respond with JSON only."""


AVAILABLE_SEARCHES = """Choose next searches from:
- birth_registration — FreeBMD births
- death_registration — FreeBMD deaths
- marriage — FreeBMD marriages
- census_YEAR — census for 1841/1851/1861/1871/1881/1891/1901/1911
- census_all — all plausible census years
- military_service — CWGC war graves (men born ~1880-1900)
- burial_memorial — Find a Grave
- DONE — stop, all objectives complete or exhausted"""


def analyse_and_plan(narrative: str, results_text: str) -> dict | None:
    """Two-pass correlation: screen then resolve.

    Returns dict with:
        analysis: str
        new_facts: [{type, value, source, confidence}]
        rejected_records: [{record, reason}]
        conflicts: [{description, source_a, source_b}]
        next_searches: [...]
    """
    # PASS 1: Screen into rejected vs candidates
    screen_result = _screen(narrative, results_text)
    if screen_result is None:
        return None

    candidates = screen_result.get("candidates", [])
    rejected = screen_result.get("rejected", [])

    # If no candidates, skip pass 2
    if not candidates:
        return {
            "analysis": screen_result.get("analysis", "No candidates found."),
            "new_facts": [],
            "rejected_records": rejected,
            "conflicts": [],
            "next_searches": screen_result.get("next_searches", ["DONE"]),
        }

    # If only 1 candidate per type, no ambiguity — can confirm directly
    # If multiple candidates, need pass 2 to resolve
    needs_resolution = len(candidates) > 1

    if not needs_resolution:
        # Single candidate — confirm with medium confidence
        facts = []
        for c in candidates:
            facts.append({
                "type": c.get("type", "unknown"),
                "value": c.get("value", ""),
                "sources": c.get("sources", []),
                "confidence": "medium",
            })
        return {
            "analysis": screen_result.get("analysis", "Single candidate confirmed."),
            "new_facts": facts,
            "rejected_records": rejected,
            "conflicts": [],
            "next_searches": screen_result.get("next_searches", []),
        }

    # PASS 2: Resolve multiple candidates against each other + family context
    resolve_result = _resolve(narrative, candidates)
    if resolve_result is None:
        # Fallback: keep all as unresolved
        return {
            "analysis": "Resolution failed — keeping candidates as unresolved.",
            "new_facts": [],
            "rejected_records": rejected,
            "conflicts": [],
            "next_searches": screen_result.get("next_searches", []),
        }

    # Merge rejected from both passes
    all_rejected = rejected + resolve_result.get("rejected_records", [])

    return {
        "analysis": resolve_result.get("analysis", ""),
        "new_facts": resolve_result.get("confirmed_facts", []),
        "rejected_records": all_rejected,
        "conflicts": resolve_result.get("conflicts", []),
        "next_searches": resolve_result.get("next_searches",
                                             screen_result.get("next_searches", [])),
    }


def _screen(narrative: str, results_text: str) -> dict | None:
    """Pass 1: Sort results into REJECTED or CANDIDATE."""
    prompt = f"""{narrative}

NEW SEARCH RESULTS (pre-annotated by system):
{results_text}

Sort each result into REJECTED or CANDIDATE based on the annotations and your judgement.
Then suggest what to search next.

Return JSON:
{{
    "analysis": "Brief reasoning for each result",
    "candidates": [
        {{"type": "birth|death|marriage|census|military|burial", "value": "record description", "sources": ["source ref"], "reasoning": "why this is a candidate"}}
    ],
    "rejected": [
        {{"record": "record description", "reason": "why rejected"}}
    ],
    "next_searches": ["search_type_1", "search_type_2"]
}}

{AVAILABLE_SEARCHES}"""

    return ask_json(prompt, system=SCREEN_SYSTEM)


def _resolve(narrative: str, candidates: list) -> dict | None:
    """Pass 2: Cross-reference candidates against each other and family context."""
    candidates_text = "\n".join(
        f"  [{i+1}] {c.get('type', '?')}: {c.get('value', '?')} "
        f"(reasoning: {c.get('reasoning', 'none')})"
        for i, c in enumerate(candidates)
    )

    prompt = f"""{narrative}

CANDIDATE RECORDS (all plausible, need resolution):
{candidates_text}

Cross-reference these candidates against:
1. The family context (household members, known relationships)
2. Each other (do they tell a consistent story?)
3. Known facts (do they fit with what's already confirmed?)

For each candidate, decide: CONFIRM (with confidence) or REJECT (with reason) or UNRESOLVED.

Return JSON:
{{
    "analysis": "How you cross-referenced and what you concluded",
    "confirmed_facts": [
        {{"type": "birth|death|marriage|census", "value": "...", "sources": ["..."], "confidence": "high|medium|low"}}
    ],
    "rejected_records": [
        {{"record": "...", "reason": "..."}}
    ],
    "conflicts": [
        {{"description": "...", "source_a": "...", "source_b": "..."}}
    ],
    "next_searches": ["search_type_1"]
}}"""

    return ask_json(prompt, system=RESOLVE_SYSTEM)


def plan_initial_searches(state: dict) -> list:
    """Decide what to search first based on what we know at the start."""
    person = state["person"]
    birth_year = person.get("birth_year")
    death_year = person.get("death_year")
    gender = (person.get("gender") or "").upper()

    searches = []

    if birth_year:
        searches.append("birth_registration")

        if death_year:
            searches.append("death_registration")

        from agent.config import CENSUS_YEARS
        for year in CENSUS_YEARS:
            if birth_year <= year <= (death_year or birth_year + 90):
                searches.append(f"census_{year}")

        from agent.config import WW1_START, WW1_END
        if gender != "F" and WW1_START <= birth_year <= WW1_END:
            searches.append("military_service")
    else:
        searches.append("census_all")
        searches.append("burial_memorial")

    return searches
