#!/usr/bin/env python3
"""Compare gaps found by Python twin vs Swift app.

Runs gap analysis on both and reports differences.
"""

import json
import sqlite3
from pathlib import Path
from wikitree.twin import LocalTwin


def python_gaps():
    """Run Python gap analysis."""
    twin = LocalTwin()
    twin.load()

    no_bio = twin.without_bio()
    no_parents = twin.without_parents()
    no_dates = twin.without_dates()

    # Build per-profile gap map
    gaps = {}
    for p in no_bio:
        wt_id = p["wt_id"]
        gaps.setdefault(wt_id, {"name": "", "gaps": set()})
        gaps[wt_id]["name"] = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip()
        gaps[wt_id]["gaps"].add("bio")

    for p in no_parents:
        wt_id = p["wt_id"]
        gaps.setdefault(wt_id, {"name": "", "gaps": set()})
        gaps[wt_id]["name"] = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip()
        gaps[wt_id]["gaps"].add("parents")

    for p in no_dates:
        wt_id = p["wt_id"]
        gaps.setdefault(wt_id, {"name": "", "gaps": set()})
        gaps[wt_id]["name"] = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip()
        gaps[wt_id]["gaps"].add(p.get("missing", "date"))

    return twin.count, gaps


def app_gaps():
    """Run Swift app gap analysis by querying the database."""
    container = Path.home() / "Library/Containers/dev.dreamfold.Ancestor-Research/Data/Library/Application Support/AncestorResearch/projects"
    db_path = list(container.glob("*.sqlite"))[0]
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row

    profiles = list(conn.execute("SELECT * FROM profiles"))
    relationships = list(conn.execute("SELECT * FROM relationships"))

    # Build parent lookup
    parent_of = {}  # child_id → set of parent_ids
    for rel in relationships:
        if rel["type"] == "parent":
            child = rel["to_id"]
            parent_of.setdefault(child, set()).add(rel["from_id"])

    gaps = {}
    for p in profiles:
        pid = p["id"]
        first = (p["first_name"] or "").strip()
        last = (p["last_name"] or "").strip()
        name = f"{first} {last}".strip()

        # Check if historical (born before 1930)
        birth_year = p["birth_date_earliest"]
        if birth_year and birth_year >= 1930:
            continue  # Skip living people

        profile_gaps = set()

        # Missing birth date
        if not p["birth_date_original"]:
            profile_gaps.add("birth")

        # Missing death date (only for historical)
        if not p["death_date_original"] and birth_year and birth_year < 1930:
            profile_gaps.add("death")

        # Missing birth location
        if not p["birth_location"]:
            profile_gaps.add("birthLocation")

        # Missing death location
        if not p["death_location"]:
            profile_gaps.add("deathLocation")

        # Missing bio
        bio = p["bio"] or ""
        if len(bio.strip()) < 50:
            profile_gaps.add("bio")

        # Missing parents
        parents = parent_of.get(pid, set())
        if len(parents) == 0:
            profile_gaps.add("parents")

        # Missing gender
        if not p["gender"]:
            profile_gaps.add("gender")

        if profile_gaps:
            gaps[pid] = {"name": name, "gaps": profile_gaps}

    conn.close()
    return len(profiles), gaps


def compare():
    print("=" * 70)
    print("GAP COMPARISON: Python SDK vs Swift App")
    print("=" * 70)
    print()

    py_count, py_gaps = python_gaps()
    app_count, app_gap_data = app_gaps()
    # rename to avoid shadowing the function
    app_gaps_map = app_gap_data

    print(f"Python twin: {py_count} profiles, {len(py_gaps)} with gaps")
    print(f"Swift app:   {app_count} profiles, {len(app_gaps_map)} with gaps")
    print()

    # Compare gap types
    py_gap_types = {}
    for wt_id, info in py_gaps.items():
        for gap in info["gaps"]:
            py_gap_types.setdefault(gap, 0)
            py_gap_types[gap] += 1

    app_gap_types = {}
    for pid, info in app_gaps_map.items():
        for gap in info["gaps"]:
            app_gap_types.setdefault(gap, 0)
            app_gap_types[gap] += 1

    all_gap_types = sorted(set(list(py_gap_types.keys()) + list(app_gap_types.keys())))

    print(f"{'Gap Type':<20s} {'Python':>8s} {'App':>8s} {'Diff':>8s}")
    print("-" * 46)
    for gap_type in all_gap_types:
        py_n = py_gap_types.get(gap_type, 0)
        app_n = app_gap_types.get(gap_type, 0)
        diff = app_n - py_n
        marker = "" if diff == 0 else " ←"
        print(f"  {gap_type:<18s} {py_n:>8d} {app_n:>8d} {diff:>+8d}{marker}")

    print()

    # Find profiles with gaps in Python but not app
    py_ids = set(py_gaps.keys())
    app_ids = set(app_gaps_map.keys())

    in_py_only = py_ids - app_ids
    in_app_only = app_ids - py_ids
    in_both = py_ids & app_ids

    print(f"Profiles with gaps in both:       {len(in_both)}")
    print(f"Profiles with gaps in Python only: {len(in_py_only)}")
    print(f"Profiles with gaps in App only:    {len(in_app_only)}")
    print()

    # For profiles in both, compare which gaps differ
    gap_differences = []
    for wt_id in sorted(in_both):
        py_g = py_gaps[wt_id]["gaps"]
        app_g = app_gaps_map[wt_id]["gaps"]
        if py_g != app_g:
            py_only = py_g - app_g
            app_only = app_g - py_g
            gap_differences.append((wt_id, py_gaps[wt_id]["name"], py_only, app_only))

    if gap_differences:
        print(f"Gap type differences on shared profiles: {len(gap_differences)}")
        for wt_id, name, py_only, app_only in gap_differences[:20]:
            parts = []
            if py_only:
                parts.append(f"Python has: {', '.join(py_only)}")
            if app_only:
                parts.append(f"App has: {', '.join(app_only)}")
            print(f"  {wt_id:30s} {name:20s} {' | '.join(parts)}")
        if len(gap_differences) > 20:
            print(f"  ... and {len(gap_differences) - 20} more")
    else:
        print("Gap types match for all shared profiles ✓")

    print()

    if in_py_only:
        print(f"Profiles with gaps in Python but NOT flagged in App ({len(in_py_only)}):")
        for wt_id in sorted(in_py_only)[:15]:
            info = py_gaps[wt_id]
            print(f"  {wt_id:30s} {info['name']:20s} Python gaps: {', '.join(info['gaps'])}")
        if len(in_py_only) > 15:
            print(f"  ... and {len(in_py_only) - 15} more")
        print()

    if in_app_only:
        print(f"Profiles with gaps in App but NOT flagged in Python ({len(in_app_only)}):")
        for pid in sorted(in_app_only)[:15]:
            info = app_gaps_map[pid]
            print(f"  {pid:30s} {info['name']:20s} App gaps: {', '.join(info['gaps'])}")
        if len(in_app_only) > 15:
            print(f"  ... and {len(in_app_only) - 15} more")

    # Summary
    print()
    print("=" * 70)
    total_py = sum(py_gap_types.values())
    total_app = sum(app_gap_types.values())
    print(f"TOTAL GAP INSTANCES: Python {total_py}, App {total_app}")
    if total_py == total_app and not in_py_only and not in_app_only and not gap_differences:
        print("✓ Gap analysis matches perfectly")
    else:
        print("✗ Differences found — see above")


if __name__ == "__main__":
    compare()
