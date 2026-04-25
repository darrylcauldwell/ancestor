#!/usr/bin/env python3
"""Compare Python digital twin with Swift app database.

Reports every gap between what the Python SDK produces and what
the Swift app has stored. Run after syncing both:
  1. python3 -m wikitree.twin sync    (Python twin → .wikitree-twin.json)
  2. App → Settings → Refresh          (Swift app → SQLite)

Usage:
    python3 compare_twins.py
"""

import json
import sqlite3
import sys
from pathlib import Path


def load_python_twin():
    """Load the Python digital twin from JSON."""
    twin_file = Path(".wikitree-twin.json")
    if not twin_file.exists():
        print("ERROR: .wikitree-twin.json not found. Run: python3 -m wikitree.twin sync")
        sys.exit(1)

    data = json.loads(twin_file.read_text())
    nodes = data["graph"]["nodes"]

    profiles = {}
    for node in nodes:
        wt_id = node.get("Name") or node.get("id")
        if not wt_id:
            continue
        profiles[wt_id] = {
            "first_name": (node.get("FirstName") or "").strip(),
            "last_name": (node.get("LastNameAtBirth") or "").strip(),
            "birth_date": node.get("BirthDate") or "",
            "death_date": node.get("DeathDate") or "",
            "birth_location": node.get("BirthLocation") or "",
            "death_location": node.get("DeathLocation") or "",
            "gender": node.get("Gender") or "",
            "bio": bool(node.get("Bio") or node.get("bio")),
        }

    edges = data["graph"].get("edges") or data["graph"].get("links") or []
    relationships = []
    for edge in edges:
        relationships.append({
            "source": edge.get("source"),
            "target": edge.get("target"),
            "type": edge.get("type", ""),
        })

    return profiles, relationships


def load_app_database():
    """Load the Swift app database from SQLite."""
    # Find the database in the sandboxed container
    container = Path.home() / "Library/Containers/dev.dreamfold.Ancestor-Research/Data/Library/Application Support/AncestorResearch/projects"
    if not container.exists():
        print(f"ERROR: App database directory not found at {container}")
        print("Has the app been run with a project?")
        sys.exit(1)

    db_files = list(container.glob("*.sqlite"))
    if not db_files:
        print("ERROR: No .sqlite files found in app projects directory")
        sys.exit(1)

    if len(db_files) > 1:
        print(f"Multiple projects found: {[f.name for f in db_files]}")
        print("Using the first one.")

    db_path = db_files[0]
    print(f"App database: {db_path.name}")

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row

    profiles = {}
    for row in conn.execute("SELECT * FROM profiles"):
        pid = row["id"]
        profiles[pid] = {
            "first_name": (row["first_name"] or "").strip(),
            "last_name": (row["last_name"] or "").strip(),
            "birth_date": row["birth_date_original"] or "",
            "death_date": row["death_date_original"] or "",
            "birth_location": row["birth_location"] or "",
            "death_location": row["death_location"] or "",
            "gender": row["gender"] or "",
            "bio": bool(row["bio"]),
        }

    relationships = []
    for row in conn.execute("SELECT * FROM relationships"):
        relationships.append({
            "source": row["from_id"],
            "target": row["to_id"],
            "type": row["type"],
        })

    conn.close()
    return profiles, relationships


def compare():
    print("=" * 70)
    print("DIGITAL TWIN COMPARISON: Python SDK vs Swift App")
    print("=" * 70)
    print()

    py_profiles, py_rels = load_python_twin()
    app_profiles, app_rels = load_app_database()

    print(f"Python twin:  {len(py_profiles)} profiles, {len(py_rels)} relationships")
    print(f"Swift app:    {len(app_profiles)} profiles, {len(app_rels)} relationships")
    print()

    # --- Profile comparison ---
    py_ids = set(py_profiles.keys())
    app_ids = set(app_profiles.keys())

    in_py_only = py_ids - app_ids
    in_app_only = app_ids - py_ids
    in_both = py_ids & app_ids

    print(f"PROFILES")
    print(f"  In both:        {len(in_both)}")
    print(f"  Python only:    {len(in_py_only)}")
    print(f"  App only:       {len(in_app_only)}")
    print()

    if in_py_only:
        print(f"  Missing from app ({len(in_py_only)} profiles):")
        for wt_id in sorted(in_py_only)[:30]:
            p = py_profiles[wt_id]
            print(f"    {wt_id:30s}  {p['first_name']} {p['last_name']}")
        if len(in_py_only) > 30:
            print(f"    ... and {len(in_py_only) - 30} more")
        print()

    if in_app_only:
        print(f"  In app but not Python ({len(in_app_only)} profiles):")
        for pid in sorted(in_app_only):
            p = app_profiles[pid]
            print(f"    {pid:30s}  {p['first_name']} {p['last_name']}")
        print()

    # --- Field comparison for shared profiles ---
    field_diffs = []
    fields = ["first_name", "last_name", "birth_date", "death_date",
              "birth_location", "gender"]

    for wt_id in sorted(in_both):
        py_p = py_profiles[wt_id]
        app_p = app_profiles[wt_id]
        for field in fields:
            py_val = py_p.get(field, "").strip()
            app_val = app_p.get(field, "").strip()

            # Normalise date comparisons (Python: "1834-05-17", App: "1834-05-17")
            if py_val and app_val and py_val != app_val:
                # Don't flag trivial differences (0000-00-00 vs empty)
                if py_val == "0000-00-00" or app_val == "0000-00-00":
                    continue
                field_diffs.append((wt_id, field, py_val, app_val))

    if field_diffs:
        print(f"  FIELD DIFFERENCES ({len(field_diffs)} differences across shared profiles):")
        for wt_id, field, py_val, app_val in field_diffs[:20]:
            print(f"    {wt_id:25s} {field:18s} Python: {py_val:30s}  App: {app_val}")
        if len(field_diffs) > 20:
            print(f"    ... and {len(field_diffs) - 20} more")
        print()
    else:
        print("  No field differences in shared profiles ✓")
        print()

    # --- Relationship comparison ---
    py_edge_set = set()
    for r in py_rels:
        py_edge_set.add((r["source"], r["target"], r["type"]))

    app_edge_set = set()
    for r in app_rels:
        app_edge_set.add((r["source"], r["target"], r["type"]))

    edges_py_only = py_edge_set - app_edge_set
    edges_app_only = app_edge_set - py_edge_set
    edges_both = py_edge_set & app_edge_set

    print(f"RELATIONSHIPS")
    print(f"  In both:        {len(edges_both)}")
    print(f"  Python only:    {len(edges_py_only)}")
    print(f"  App only:       {len(edges_app_only)}")
    print()

    if edges_py_only:
        # Filter to only show edges where BOTH profiles are in the app
        relevant = [(s, t, tp) for s, t, tp in edges_py_only
                    if s in app_ids and t in app_ids]
        if relevant:
            print(f"  Missing relationships (both profiles exist in app): {len(relevant)}")
            for s, t, tp in sorted(relevant)[:20]:
                print(f"    {s} → {t} ({tp})")
            if len(relevant) > 20:
                print(f"    ... and {len(relevant) - 20} more")
            print()

    # --- Summary ---
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)
    issues = []
    if in_py_only:
        issues.append(f"{len(in_py_only)} profiles missing from app")
    if field_diffs:
        issues.append(f"{len(field_diffs)} field value differences")
    if edges_py_only:
        issues.append(f"{len(edges_py_only)} relationships missing from app")
    if in_app_only:
        issues.append(f"{len(in_app_only)} profiles in app but not Python")

    if issues:
        print("GAPS FOUND:")
        for issue in issues:
            print(f"  ✗ {issue}")
    else:
        print("  ✓ No gaps — twins are identical")


if __name__ == "__main__":
    compare()
