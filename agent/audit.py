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

        # === MISSING LOCATION CHECKS (WikiTree Data Doctor 457/463) ===

        birth_loc = (node.get("BirthLocation", "") or "").strip()
        death_loc = (node.get("DeathLocation", "") or "").strip()

        if birth_year and birth_year < 1930 and not birth_loc:
            lead = Lead(
                lead_id=_make_lead_id(name, "missing_birth_loc", birth_year),
                subject_id=wt_id,
                subject_name=name,
                subject_birth_year=birth_year,
                category="data_quality",
                summary=f"{name} ({wt_id}) — no birth location",
                uncertainty_reasons=["Birth location field is empty"],
                evidence=[Evidence(
                    source="audit",
                    record_summary="BirthLocation is empty",
                    reasons=["Missing birth location (Data Doctor 457)"],
                    search_type="data_quality",
                )],
                next_actions=[NextAction(
                    description=f"Search census/birth records for {name} birth location",
                    source="familysearch",
                    cost="free",
                )],
            )
            lead_store.add(lead)
            leads_created += 1

        if death_year and not death_loc:
            lead = Lead(
                lead_id=_make_lead_id(name, "missing_death_loc", death_year),
                subject_id=wt_id,
                subject_name=name,
                subject_birth_year=birth_year,
                category="data_quality",
                summary=f"{name} ({wt_id}) — no death location",
                uncertainty_reasons=["Death location field is empty"],
                evidence=[Evidence(
                    source="audit",
                    record_summary="DeathLocation is empty",
                    reasons=["Missing death location (Data Doctor 463)"],
                    search_type="data_quality",
                )],
                next_actions=[NextAction(
                    description=f"Search death records for {name} death location",
                    source="familysearch",
                    cost="free",
                )],
            )
            lead_store.add(lead)
            leads_created += 1

        # === PROFILE COMPLETENESS SCORE ===

        completeness = 0
        completeness_max = 7
        if node.get("FirstName"):
            completeness += 1
        if birth_year:
            completeness += 1
        if birth_loc:
            completeness += 1
        if death_year:
            completeness += 1
        if death_loc:
            completeness += 1
        if bio and len(bio.strip()) > 50:
            completeness += 1
        if bio and ("<ref" in bio or "Sources" in bio):
            completeness += 1

        if completeness <= 2 and birth_year and birth_year < 1930:
            lead = Lead(
                lead_id=_make_lead_id(name, "incomplete", birth_year),
                subject_id=wt_id,
                subject_name=name,
                subject_birth_year=birth_year,
                category="data_quality",
                summary=f"{name} ({wt_id}) — profile very incomplete ({completeness}/{completeness_max})",
                uncertainty_reasons=[f"Only {completeness} of {completeness_max} key fields populated"],
                evidence=[Evidence(
                    source="audit",
                    record_summary=f"Completeness score: {completeness}/{completeness_max}",
                    reasons=[f"Profile completeness {completeness}/{completeness_max}"],
                    search_type="data_quality",
                )],
                next_actions=[NextAction(
                    description=f"Research {name} to fill in missing dates, locations, and bio",
                    source="familysearch",
                    cost="free",
                )],
            )
            lead_store.add(lead)
            leads_created += 1

    # === ANCESTOR EXTENSION — find parents for end-of-line profiles ===

        parents = twin.parents_of(wt_id)
        if not parents and birth_year and birth_year < 1920:
            # No parents and born before 1920 — researchable via parish/civil records
            # Higher priority for older profiles (deeper tree extension)
            # Skip profiles with "Unknown" first name (GEDCOM placeholders)
            if first and first.lower() not in ("unknown", "testdebug", "private"):
                source_hint = "familysearch"
                search_desc = f"Search christening/baptism records for {name} b.{birth_year}"
                if birth_year < 1837:
                    search_desc = f"Search parish registers for {name} b.{birth_year}"
                    source_hint = "freereg"
                elif birth_year < 1870:
                    search_desc += " (or parish registers)"

                lead = Lead(
                    lead_id=_make_lead_id(name, "find_parents", birth_year),
                    subject_id=wt_id,
                    subject_name=name,
                    subject_birth_year=birth_year,
                    category="ancestor_extension",
                    summary=f"{name} ({wt_id}) — no parents, extend tree",
                    uncertainty_reasons=[f"End-of-line ancestor, born {birth_year}"],
                    evidence=[Evidence(
                        source="audit",
                        record_summary=f"No parent links. Born {birth_year} {birth_loc}",
                        reasons=["End-of-line ancestor"],
                        search_type="ancestor_extension",
                    )],
                    next_actions=[NextAction(
                        description=search_desc,
                        source=source_hint,
                        cost="free",
                    )],
                    is_direct_ancestor=True,
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

    # Count completeness stats
    completeness_scores = []
    for wt_id in twin._graph.nodes:
        node = twin.get(wt_id)
        if not node:
            continue
        score = 0
        if node.get("FirstName"):
            score += 1
        if _extract_year(node.get("BirthDate", "")):
            score += 1
        if (node.get("BirthLocation", "") or "").strip():
            score += 1
        if _extract_year(node.get("DeathDate", "")):
            score += 1
        if (node.get("DeathLocation", "") or "").strip():
            score += 1
        bio = node.get("Bio") or node.get("bio") or ""
        if bio and len(bio.strip()) > 50:
            score += 1
        if bio and ("<ref" in bio or "Sources" in bio):
            score += 1
        completeness_scores.append(score)

    avg_completeness = sum(completeness_scores) / len(completeness_scores) if completeness_scores else 0

    return {
        "facts": facts,
        "leads_created": leads_created,
        "profiles_checked": profiles_checked,
        "relationships_checked": relationships_checked,
        "avg_completeness": avg_completeness,
        "completeness_max": 7,
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
    if results.get("avg_completeness"):
        print(f"  Avg completeness: {results['avg_completeness']:.1f}/{results['completeness_max']}")

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
