"""Branch phase — identify new research leads from confirmed findings.

One LLM call at the end of a person's research. Examines all confirmed
facts to find parents, spouses, siblings, children worth researching.
"""

from agent.llm import ask_json
from agent.render import render_narrative

SYSTEM_PROMPT = """You are a genealogist identifying people to research next.

CRITICAL RULES:
1. ONLY name people who EXPLICITLY APPEAR in the search results or confirmed facts.
2. DO NOT guess, infer, or assume family members exist.
3. If a census household is shown with members listed, you may include those members — they are real data.
4. If NO household data is shown, DO NOT invent parents, siblings, or children.
5. Each lead must have a name AND a source that explicitly mentions them by name.

GOOD example: "John Cauldwell, age 45, Head — listed in 1891 census household" = REAL data, include it
BAD example: "John Cauldwell, likely the father based on surname" = INFERENCE, do NOT include

For each person, provide:
- Their exact name as it appears in the source data
- Birth year calculated from census age (census_year minus age = approximate birth year)
- Their relationship as explicitly stated in the source (e.g., "Head", "Wife", "Son")
- Which specific source record they appear in

If no real people are explicitly named in the data, return an empty leads list.

RESPOND WITH VALID JSON ONLY."""


def find_leads(state: dict) -> list | None:
    """Identify new people to research from confirmed findings.

    Returns list of dicts: [{name, birth_year_approx, relationship, source, notes}]
    """
    narrative = render_narrative(state)

    prompt = f"""{narrative}

Based on all confirmed facts and search results, identify people
who should be researched next.

Return JSON:
{{
    "leads": [
        {{
            "name": "Full Name",
            "birth_year_approx": 1861,
            "relationship": "father|mother|spouse|sibling|child",
            "source": "which source mentioned them",
            "notes": "any useful context"
        }}
    ]
}}

If no leads were found, return: {{"leads": []}}"""

    result = ask_json(prompt, system=SYSTEM_PROMPT)
    if result and isinstance(result, dict):
        return result.get("leads", [])
    return []
