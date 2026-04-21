"""Audit existing WikiTree data against deterministic rules.

Runs entirely against the local twin — no external searches, no API calls.
Finds structural errors and suspicious data in the existing tree.

Produces facts (definite errors) and leads (investigate further).

Usage:
    from agent.audit import audit_tree
    facts, leads_created = audit_tree(twin, lead_store)

CLI:
    python session.py audit
"""

from agent.rules import (
    check_birth_before_death,
    check_parent_age_gap,
    check_marriage_age,
    check_lifespan,
    years_match,
    CENSUS_AGE_TOLERANCE,
)
from agent.leads import Lead, Evidence, NextAction, LeadStore, _make_lead_id

import re


def audit_tree(twin, lead_store: LeadStore) -> dict:
    """Audit every profile and relationship in the twin.

    Returns:
        {
            "facts": [...],       # definite errors to fix
            "leads_created": int, # suspicious items to investigate
            "profiles_checked": int,
            "relationships_checked": int,
        }
    """
    facts = []
    leads_created = 0
    profiles_checked = 0
    relationships_checked = 0

    for wt_id in twin._graph.nodes:
        node = twin.get(wt_id)
        if not node:
            continue

        profiles_checked += 1
        first = node.get("FirstName", "")
        last = node.get("LastNameAtBirth", "")
        name = f"{first} {last}".strip()
        birth_year = _extract_year(node.get("BirthDate", ""))
        death_year = _extract_year(node.get("DeathDate", ""))
        bio = node.get("Bio") or node.get("bio") or ""

        # === SELF-CONSISTENCY CHECKS ===

        # Birth after death
        if birth_year and death_year and not check_birth_before_death(birth_year, death_year):
            facts.append({
                "type": "error",
                "wt_id": wt_id,
                "description": f"{name}: born {birth_year} but died {death_year} — birth after death",
                "action": "fix_dates",
            })

        # Impossible lifespan
        if birth_year and death_year and not check_lifespan(birth_year, death_year):
            facts.append({
                "type": "error",
                "wt_id": wt_id,
                "description": f"{name}: born {birth_year}, died {death_year} — lifespan {death_year - birth_year} years",
                "action": "fix_dates",
            })

        # === PARENT CHECKS ===
        parents = twin.parents_of(wt_id)
        for parent in parents:
            relationships_checked += 1
            parent_name = f"{parent.get('FirstName', '')} {parent.get('LastNameAtBirth', '')}".strip()
            parent_birth = _extract_year(parent.get("BirthDate", ""))
            parent_wt_id = parent["wt_id"]

            if birth_year and parent_birth:
                gap = birth_year - parent_birth

                # Parent born AFTER child — definite error
                if gap < 0:
                    facts.append({
                        "type": "error",
                        "wt_id": wt_id,
                        "description": f"{name} (b.{birth_year}): parent {parent_name} ({parent_wt_id}) born {parent_birth} — parent is YOUNGER",
                        "action": "remove_parent_link",
                        "parent_id": parent_wt_id,
                    })

                # Parent too young — definite error
                elif gap < 14:
                    facts.append({
                        "type": "error",
                        "wt_id": wt_id,
                        "description": f"{name} (b.{birth_year}): parent {parent_name} ({parent_wt_id}) only {gap} years older — likely sibling not parent",
                        "action": "check_parent_link",
                        "parent_id": parent_wt_id,
                    })

                # Parent suspiciously old — lead
                elif gap > 55:
                    lead = Lead(
                        lead_id=_make_lead_id(name, "parent_age", birth_year),
                        subject_id=wt_id,
                        subject_name=name,
                        subject_birth_year=birth_year,
                        category="relationship",
                        summary=f"{name}: parent {parent_name} was {gap} years older — unusual but possible",
                        uncertainty_reasons=[f"Age gap {gap} years is unusual (>55)"],
                        evidence=[Evidence(
                            source="audit",
                            record_summary=f"Parent {parent_name} b.{parent_birth}, child {name} b.{birth_year}, gap={gap}",
                            reasons=[f"Age gap {gap} years"],
                            search_type="relationship",
                        )],
                        next_actions=[NextAction(
                            description=f"Verify {parent_name} is correct parent — check census or birth certificate",
                            source="census",
                            cost="free",
                        )],
                    )
                    lead_store.add(lead)
                    leads_created += 1

            # Parent died before child born
            parent_death = _extract_year(parent.get("DeathDate", ""))
            if birth_year and parent_death:
                if parent_death < birth_year - 1:  # Allow 1 year for posthumous birth
                    facts.append({
                        "type": "error",
                        "wt_id": wt_id,
                        "description": f"{name} (b.{birth_year}): parent {parent_name} ({parent_wt_id}) died {parent_death} — died before child born",
                        "action": "check_parent_link",
                        "parent_id": parent_wt_id,
                    })

        # === SPOUSE CHECKS ===
        spouses = twin.spouses_of(wt_id)
        for spouse in spouses:
            relationships_checked += 1
            spouse_name = f"{spouse.get('FirstName', '')} {spouse.get('LastNameAtBirth', '')}".strip()

            # Same person linked as own spouse
            if spouse["wt_id"] == wt_id:
                facts.append({
                    "type": "error",
                    "wt_id": wt_id,
                    "description": f"{name}: linked as own spouse",
                    "action": "remove_spouse_link",
                })

        # === DATA QUALITY CHECKS ===

        # No bio and born pre-1930
        if birth_year and birth_year < 1930:
            if not bio or len(bio.strip()) < 50:
                lead = Lead(
                    lead_id=_make_lead_id(name, "missing_bio", birth_year),
                    subject_id=wt_id,
                    subject_name=name,
                    subject_birth_year=birth_year,
                    category="data_quality",
                    summary=f"{name} ({wt_id}) — no biography",
                    uncertainty_reasons=["Profile has no narrative bio — needs research"],
                    evidence=[Evidence(
                        source="audit",
                        record_summary=f"Bio is empty or too short ({len(bio.strip())} chars)",
                        reasons=["Missing bio"],
                        search_type="data_quality",
                    )],
                    next_actions=[NextAction(
                        description=f"Research {name} and draft a biography",
                        source="research_agent",
                        cost="free",
                    )],
                )
                lead_store.add(lead)
                leads_created += 1

            # Has bio but no sources
            if bio and len(bio.strip()) > 50 and "<ref" not in bio and "Sources" not in bio:
                lead = Lead(
                    lead_id=_make_lead_id(name, "unsourced", birth_year),
                    subject_id=wt_id,
                    subject_name=name,
                    subject_birth_year=birth_year,
                    category="data_quality",
                    summary=f"{name} ({wt_id}) — bio has no source citations",
                    uncertainty_reasons=["Bio exists but has no references — may be unverified GEDCOM data"],
                    evidence=[Evidence(
                        source="audit",
                        record_summary="Bio present but no <ref> tags or Sources section",
                        reasons=["Unsourced bio"],
                        search_type="data_quality",
                    )],
                    next_actions=[NextAction(
                        description=f"Verify bio content and add source citations",
                        source="research_agent",
                        cost="free",
                    )],
                )
                lead_store.add(lead)
                leads_created += 1

    # === DUPLICATE DETECTION ===
    seen = {}  # (first, last, birth_year) -> wt_id
    for wt_id in twin._graph.nodes:
        node = twin.get(wt_id)
        if not node:
            continue
        first = (node.get("FirstName", "") or "").upper()
        last = (node.get("LastNameAtBirth", "") or "").upper()
        birth = _extract_year(node.get("BirthDate", ""))
        if not first or not last or not birth:
            continue

        key = (first, last, birth)
        if key in seen:
            other_id = seen[key]
            facts.append({
                "type": "duplicate",
                "wt_id": wt_id,
                "description": f"Possible duplicate: {first} {last} b.{birth} exists as both {wt_id} and {other_id}",
                "action": "merge_profiles",
                "other_id": other_id,
            })
        else:
            seen[key] = wt_id

    return {
        "facts": facts,
        "leads_created": leads_created,
        "profiles_checked": profiles_checked,
        "relationships_checked": relationships_checked,
    }


def print_audit_results(results: dict):
    """Print audit results in a readable format."""
    facts = results["facts"]
    errors = [f for f in facts if f["type"] == "error"]
    duplicates = [f for f in facts if f["type"] == "duplicate"]

    print(f"\n{'=' * 60}")
    print(f"AUDIT RESULTS")
    print(f"{'=' * 60}")
    print(f"  Profiles checked: {results['profiles_checked']}")
    print(f"  Relationships checked: {results['relationships_checked']}")
    print(f"  Errors found: {len(errors)}")
    print(f"  Duplicates found: {len(duplicates)}")
    print(f"  Leads created: {results['leads_created']}")

    if errors:
        print(f"\n  ERRORS ({len(errors)}):")
        for e in errors:
            print(f"    ! {e['description']}")

    if duplicates:
        print(f"\n  POSSIBLE DUPLICATES ({len(duplicates)}):")
        for d in duplicates:
            print(f"    ? {d['description']}")


def _extract_year(date_str: str) -> int | None:
    if not date_str:
        return None
    match = re.match(r"(\d{4})", str(date_str))
    if match:
        year = int(match.group(1))
        return year if year > 0 else None
    return None
