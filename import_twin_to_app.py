#!/usr/bin/env python3
"""Import Python digital twin into the app's SQLite database.

Does exactly what the app's db.importSnapshot() does:
writes profiles and relationships to the SQLite schema.
"""

import json
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path


def main():
    # Load Python twin
    twin_file = Path(".wikitree-twin.json")
    if not twin_file.exists():
        print("ERROR: .wikitree-twin.json not found")
        return

    data = json.loads(twin_file.read_text())
    nodes = data["graph"]["nodes"]
    edges = data["graph"].get("edges") or data["graph"].get("links") or []

    # Find app database
    container = Path.home() / "Library/Containers/dev.dreamfold.Ancestor-Research/Data/Library/Application Support/AncestorResearch/projects"
    db_files = list(container.glob("*.sqlite"))
    if not db_files:
        print("ERROR: No app database found")
        return

    db_path = db_files[0]
    print(f"Database: {db_path.name}")

    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()

    # Create a transaction record
    tx_id = str(uuid.uuid4())
    now = datetime.now().isoformat()
    cursor.execute("""
        INSERT INTO transactions (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """, (tx_id, '"importWikiTree"', "structural", now, now, 0, len(nodes)))

    # Import profiles
    imported = 0
    skipped = 0
    for node in nodes:
        wt_id = node.get("Name") or node.get("id")
        if not wt_id:
            continue

        first_name = (node.get("FirstName") or "").strip() or None
        last_name = (node.get("LastNameAtBirth") or "").strip() or None
        gender_raw = node.get("Gender", "")
        gender = gender_raw.lower() if gender_raw in ("Male", "Female") else None

        birth_date = node.get("BirthDate") or ""
        if birth_date in ("", "0000-00-00"):
            birth_date = None
        death_date = node.get("DeathDate") or ""
        if death_date in ("", "0000-00-00"):
            death_date = None

        birth_location = node.get("BirthLocation") or None
        if birth_location == "":
            birth_location = None
        death_location = node.get("DeathLocation") or None
        if death_location == "":
            death_location = None

        bio = node.get("Bio") or node.get("bio") or None
        if bio == "":
            bio = None

        # Parse years from dates
        birth_earliest = None
        birth_latest = None
        if birth_date and len(birth_date) >= 4:
            try:
                year = int(birth_date[:4])
                if 1500 <= year <= 2030:
                    birth_earliest = year
                    birth_latest = year
            except ValueError:
                pass

        death_earliest = None
        death_latest = None
        if death_date and len(death_date) >= 4:
            try:
                year = int(death_date[:4])
                if 1500 <= year <= 2030:
                    death_earliest = year
                    death_latest = year
            except ValueError:
                pass

        external_ids = json.dumps({"wikitree": wt_id})

        try:
            cursor.execute("""
                INSERT OR REPLACE INTO profiles
                (id, external_ids, first_name, last_name, gender,
                 birth_date_original, birth_date_earliest, birth_date_latest,
                 birth_location,
                 death_date_original, death_date_earliest, death_date_latest,
                 death_location, bio, created_by_transaction_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                wt_id, external_ids, first_name, last_name, gender,
                birth_date, birth_earliest, birth_latest,
                birth_location,
                death_date, death_earliest, death_latest,
                death_location, bio, tx_id
            ))
            imported += 1
        except Exception as e:
            print(f"  Error importing {wt_id}: {e}")
            skipped += 1

    print(f"Profiles: {imported} imported, {skipped} skipped")

    # Import relationships from edges
    # Build ID→Name mapping for numeric IDs
    id_to_name = {}
    for node in nodes:
        nid = node.get("Id") or node.get("id")
        name = node.get("Name")
        if nid and name:
            id_to_name[nid] = name
            id_to_name[str(nid)] = name

    # Also process relationships from getRelatives-style data in edges
    rel_count = 0
    seen_edges = set()

    for edge in edges:
        source = edge.get("source")
        target = edge.get("target")
        rel_type = edge.get("type", "")

        if not source or not target:
            continue

        # Map numeric IDs to names if needed
        if source in id_to_name:
            source = id_to_name[source]
        if target in id_to_name:
            target = id_to_name[target]

        # Only import parent and spouse (siblings derived from shared parents)
        if rel_type == "parent":
            edge_key = f"parent:{source}:{target}"
            if edge_key in seen_edges:
                continue
            seen_edges.add(edge_key)

            # Determine parent role from profile gender
            cursor.execute("SELECT gender FROM profiles WHERE id = ?", (source,))
            row = cursor.fetchone()
            role = None
            if row and row[0]:
                role = "father" if row[0] == "male" else "mother" if row[0] == "female" else None

            rel_id = str(uuid.uuid4())
            # Check for existing relationship before inserting
            existing = cursor.execute(
                "SELECT 1 FROM relationships WHERE from_id = ? AND to_id = ? AND type = 'parent' LIMIT 1",
                (source, target)
            ).fetchone()
            if existing:
                continue

            cursor.execute("""
                INSERT INTO relationships
                (id, from_id, to_id, type, role, subtype, created_by_transaction_id)
                VALUES (?, ?, ?, 'parent', ?, 'unknown', ?)
            """, (rel_id, source, target, role, tx_id))
            rel_count += 1

        elif rel_type == "spouse":
            # Deduplicate bidirectional spouse edges
            edge_key1 = f"spouse:{source}:{target}"
            edge_key2 = f"spouse:{target}:{source}"
            if edge_key1 in seen_edges or edge_key2 in seen_edges:
                continue
            seen_edges.add(edge_key1)
            seen_edges.add(edge_key2)

            existing = cursor.execute(
                "SELECT 1 FROM relationships WHERE from_id = ? AND to_id = ? AND type = 'spouse' LIMIT 1",
                (source, target)
            ).fetchone()
            if existing:
                continue

            rel_id = str(uuid.uuid4())
            cursor.execute("""
                INSERT INTO relationships
                (id, from_id, to_id, type, subtype, created_by_transaction_id)
                VALUES (?, ?, ?, 'spouse', 'unknown', ?)
            """, (rel_id, source, target, tx_id))
            rel_count += 1

    print(f"Relationships: {rel_count} imported")

    # Add field sources for provenance
    for node in nodes:
        wt_id = node.get("Name") or node.get("id")
        if not wt_id:
            continue
        fields = []
        if node.get("FirstName"):
            fields.append(("firstName", node["FirstName"]))
        if node.get("LastNameAtBirth"):
            fields.append(("lastName", node["LastNameAtBirth"]))
        birth_date = node.get("BirthDate", "")
        if birth_date and birth_date != "0000-00-00":
            fields.append(("birthDate", birth_date))
        if node.get("BirthLocation"):
            fields.append(("birthLocation", node["BirthLocation"]))
        death_date = node.get("DeathDate", "")
        if death_date and death_date != "0000-00-00":
            fields.append(("deathDate", death_date))
        if node.get("DeathLocation"):
            fields.append(("deathLocation", node["DeathLocation"]))

        for field, raw in fields:
            cursor.execute("""
                INSERT OR IGNORE INTO field_sources
                (entity_id, entity_kind, field, origin, raw, added_at, created_by_transaction_id)
                VALUES (?, 'profile', ?, 'wikitree', ?, ?, ?)
            """, (wt_id, field, raw, now, tx_id))

    # Update project metadata
    cursor.execute("UPDATE project_meta SET last_refreshed = ?", (now,))

    conn.commit()
    conn.close()

    print(f"\nImport complete. Restart the app to see changes.")


if __name__ == "__main__":
    main()
