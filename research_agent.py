"""Genealogy Research Agent — CLI entry point.

Architecture:
  Python searches and scores (deterministic)
  DeepSeek-R1 suggests strategy (reasoning)
  Human reviews and decides

Phase 1: Closed loop (search → score → strategise → execute → repeat)
Phase 2: Branching (household members auto-queued for research)

Usage:
    # Single person
    python research_agent.py "Ernest Cauldwell" --birth-year 1887 --gender M

    # With branching (research family)
    python research_agent.py "Ernest Cauldwell" --birth-year 1887 --gender M --branch

    # Control depth and max persons
    python research_agent.py "Ernest Cauldwell" --birth-year 1887 --gender M --branch --depth 2 --max-persons 10
"""

import argparse
import json
import sys
import os
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))

from agent.pipeline import research_person
from agent.config import MAX_DEPTH, MAX_PERSONS


def main():
    parser = argparse.ArgumentParser(description="Genealogy Research Agent")
    parser.add_argument("name", help="Person's full name")
    parser.add_argument("--birth-year", type=int, help="Approximate birth year")
    parser.add_argument("--death-year", type=int, help="Death year (if known)")
    parser.add_argument("--gender", choices=["M", "F"], help="Gender")
    from project_config import config as cfg
    parser.add_argument("--location", default=cfg.region.county or "England", help="Birth location")
    parser.add_argument("--branch", action="store_true",
                        help="Auto-research household members (Phase 2)")
    parser.add_argument("--depth", type=int, default=MAX_DEPTH,
                        help=f"Max generations to branch (default: {MAX_DEPTH})")
    parser.add_argument("--max-persons", type=int, default=MAX_PERSONS,
                        help=f"Max persons to research (default: {MAX_PERSONS})")
    parser.add_argument("--father", help="Father's name (for living people)")
    parser.add_argument("--father-birth", type=int, help="Father's birth year")
    parser.add_argument("--mother", help="Mother's name (for living people)")
    parser.add_argument("--mother-birth", type=int, help="Mother's birth year")
    args = parser.parse_args()

    # Build provided family for living people
    provided_family = []
    if args.father:
        provided_family.append({
            "name": args.father,
            "relationship": "Father",
            "birth_year_approx": args.father_birth,
            "age": None,
            "occupation": "",
            "birth_place": args.location,
            "census_year": None,
            "address": "",
            "parish": "",
        })
    if args.mother:
        provided_family.append({
            "name": args.mother,
            "relationship": "Mother",
            "birth_year_approx": args.mother_birth,
            "age": None,
            "occupation": "",
            "birth_place": args.location,
            "census_year": None,
            "address": "",
            "parish": "",
        })

    starting_person = {
        "name": args.name,
        "birth_year": args.birth_year,
        "death_year": args.death_year,
        "gender": args.gender,
        "birth_location": args.location,
        "provided_family": provided_family,
    }

    if not args.branch:
        # Single person mode
        print(f"Researching: {args.name}")
        print(f"Architecture: Python scoring + deterministic analysis")
        print(f"Mode: Single person (use --branch to research family)")
        state = research_person(starting_person)
        _print_summary(args.name, state)
        return

    # Branching mode — research person then auto-queue household members
    print(f"Researching: {args.name} + family")
    print(f"Architecture: Python scoring + deterministic analysis")
    print(f"Mode: Branching (depth={args.depth}, max={args.max_persons})")
    print()

    queue = [(starting_person, 0)]  # (person, depth)
    researched = set()
    all_states = []
    total = 0

    while queue and total < args.max_persons:
        person, depth = queue.pop(0)

        # Dedup key
        person_key = _person_key(person)
        if person_key in researched:
            continue

        # Research this person
        state = research_person(person)
        researched.add(person_key)
        all_states.append(state)
        total += 1

        # Queue household members if within depth limit
        if depth < args.depth:
            new_leads = _extract_leads(state, person, researched)
            if new_leads:
                print(f"\n  [BRANCH] Queueing {len(new_leads)} household members "
                      f"(depth {depth + 1}/{args.depth}):")
                for lead in new_leads:
                    print(f"    → {lead['name']} "
                          f"(~{lead.get('birth_year', '?')}, "
                          f"{lead.get('relationship', '?')})")
                    queue.append((lead, depth + 1))

        # Show queue status
        remaining = [p for p, _ in queue if _person_key(p) not in researched]
        if remaining:
            print(f"\n  Queue: {len(remaining)} remaining, "
                  f"{total}/{args.max_persons} researched")

    # Final summary
    print(f"\n{'=' * 60}")
    print(f"BRANCHING COMPLETE")
    print(f"{'=' * 60}")
    print(f"  Total persons researched: {total}")
    print(f"  Results saved to: agent-research/")
    print()

    for state in all_states:
        name = state["person"]["name"]
        facts = len(state.get("confirmed_facts", []))
        household = len(state.get("household_members", []))
        print(f"  {name}: {facts} facts, {household} household members")

    # Save family summary
    _save_family_summary(all_states)


def _extract_leads(state: dict, parent_person: dict, already_researched: set) -> list:
    """Extract research leads from household members.

    Only includes people with enough information to research
    and who haven't been researched already.
    """
    leads = []
    parent_name = parent_person.get("name", "")

    for member in state.get("household_members", []):
        name = member.get("name", "")
        if not name:
            continue

        # Skip if already researched
        birth_year = member.get("birth_year_approx")
        key = f"{name.upper()}_{birth_year or '?'}"
        if key in already_researched:
            continue

        # Skip very young children (under 2) — not enough to search for
        age = member.get("age")
        if age and isinstance(age, str) and "m" in age.lower():
            continue  # months old

        relationship = member.get("relationship", "Unknown")

        # Build family context for the lead
        family_context = {
            "discovered_via": parent_name,
            "relationship": relationship,
            "source": f"census {member.get('census_year', '?')}, "
                       f"{member.get('parish', member.get('address', '?'))}",
            "notes": f"Age {age} in {member.get('census_year', '?')} census, "
                      f"born {member.get('birth_place', '?')}",
        }

        leads.append({
            "name": name,
            "birth_year": birth_year,
            "gender": _guess_gender(relationship),
            "birth_location": member.get("birth_place", cfg.region.county or "England"),
            "family_context": family_context,
            "relationship": relationship,
        })

    return leads


def _person_key(person: dict) -> str:
    """Generate dedup key for a person."""
    name = person.get("name", "").upper()
    year = person.get("birth_year") or "?"
    return f"{name}_{year}"


def _guess_gender(relationship: str) -> str | None:
    """Guess gender from census relationship."""
    rel = (relationship or "").lower()
    if rel in ("head", "son", "brother", "father", "nephew",
               "grandson", "boarder", "lodger", "servant"):
        return "M"
    if rel in ("wife", "daughter", "dau", "sister", "mother",
               "niece", "granddaughter", "ma-law"):
        return "F"
    return None


def _print_summary(name: str, state: dict):
    """Print research summary for single person mode."""
    print(f"\n{'=' * 60}")
    print(f"RESEARCH COMPLETE: {name}")
    print(f"{'=' * 60}")
    print(f"  Confirmed facts: {len(state.get('confirmed_facts', []))}")
    print(f"  Rejected records: {len(state.get('rejected_records', []))}")
    print(f"  Uncertain (need review): {len(state.get('uncertain_records', []))}")
    print(f"  Household members found: {len(state.get('household_members', []))}")
    print(f"  Sources searched: {len(state.get('searched', []))}")
    print(f"  Results saved to: agent-research/")

    strategy = state.get("strategy")
    if strategy and isinstance(strategy, dict) and strategy.get("searches"):
        print(f"\n  DeepSeek-R1 suggests {len(strategy['searches'])} follow-up searches.")


def _save_family_summary(all_states: list):
    """Save a summary of all researched family members."""
    summary = {
        "total_persons": len(all_states),
        "persons": [],
    }

    for state in all_states:
        person = state["person"]
        summary["persons"].append({
            "name": person.get("name"),
            "birth_year": person.get("birth_year"),
            "gender": person.get("gender"),
            "confirmed_facts": len(state.get("confirmed_facts", [])),
            "household_members": len(state.get("household_members", [])),
            "sources_searched": len(state.get("searched", [])),
            "relationship": (person.get("family_context") or {}).get("relationship", "starting person"),
        })

    filepath = Path("agent-research") / "_family_summary.json"
    filepath.write_text(json.dumps(summary, indent=2))
    print(f"\n  Family summary: {filepath}")


if __name__ == "__main__":
    main()
