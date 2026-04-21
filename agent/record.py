"""Record module — save full research state to disk.

Stores the complete evidence trail: every iteration, every search result,
every LLM analysis, every rejection. Human reviews before merging.
"""

import json
from datetime import datetime, timezone
from pathlib import Path

RESEARCH_DIR = Path(__file__).parent.parent / "agent-research"


def save_state(state: dict) -> Path:
    """Save the current research state for a person.

    Called after each iteration (crash recovery) and at completion.
    Returns path to the saved file.
    """
    RESEARCH_DIR.mkdir(exist_ok=True)

    corpus_id = _make_id(state["person"])

    output = {
        "corpus_id": corpus_id,
        "last_updated": datetime.now(timezone.utc).isoformat(),
        "person": state["person"],
        "confirmed_facts": state.get("confirmed_facts", []),
        "rejected_records": state.get("rejected_records", []),
        "uncertain_records": state.get("uncertain_records", []),
        "conflicts": state.get("conflicts", []),
        "objectives": state.get("objectives", {}),
        "searched": state.get("searched", []),
        "household_members": state.get("household_members", []),
        "strategy": state.get("strategy"),
        "new_leads": state.get("new_leads", []),
        "corpus_match": _safe_corpus_match(state.get("corpus_match")),
        "discrepancies": state.get("discrepancies", []),
    }

    filepath = RESEARCH_DIR / f"{corpus_id}.json"
    filepath.write_text(json.dumps(output, indent=2, ensure_ascii=False))
    return filepath


def _safe_corpus_match(match: dict | None) -> dict | None:
    """Strip the full person dict from corpus match to keep file size manageable."""
    if not match:
        return None
    return {
        "corpus_id": match.get("corpus_id"),
        "corpus_name": match.get("corpus_name"),
        "corpus_birth_year": match.get("corpus_birth_year"),
        "corpus_death_year": match.get("corpus_death_year"),
        "corpus_parent_ids": match.get("corpus_parent_ids"),
        "match_score": match.get("match_score"),
    }


def _make_id(person: dict) -> str:
    """Generate a corpus-style ID from person info."""
    name = person.get("name", "unknown").lower().replace(" ", "_")
    year = person.get("birth_year", "unknown")
    return f"{name}_{year}"
