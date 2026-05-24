"""Populate a fresh empty project's sqlite with the 15-person discovery
seed, copied from `Cauldwell Family Tree.twin-export.ged`'s sqlite.

Seed = starter-7 + Lily (guardrail control) + Claire's tree (her, her
parents, her 4 grandparents). All FAM relationships connecting any
two seed members are copied. For every female seed member with a
known spouse, `married_surname` is set to the spouse's `last_name`
even though twin-export's own column is empty for them (its GEDCOM
import predates the dual-name schema).

Prerequisites:
    1. In the Ancestor Research app, create a new empty project
       (e.g. "Cauldwell Discovery"). The app creates a fresh
       .sqlite under ~/Library/Containers/.../projects/<UUID>.sqlite
       with v1-v5 migrations applied.
    2. Quit the app (or switch to the project picker) so the sqlite
       isn't locked.
    3. Run this script with --target <new-project.sqlite>.
    4. Reopen the app, select the new project. Verify 15 profiles + 13
       families show up.

Usage:
    python populate_discovery_project.py --target <path-to-new-project.sqlite>
"""
import argparse
import json
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path

# 15-person seed — same set as extract_discovery_seed.py
SEED_IDS = {
    # starter-7 (validated, well-cited)
    "@I50098374@": "Darryl James Cauldwell",
    "@I50100747@": "David Nigel Cauldwell",
    "@I50100815@": "Jennifer Margaret Holmes",
    "@I50100821@": "Ernest Victor Cauldwell",
    "@I50100841@": "Kathleen Dorothy Wheeldon",
    "@I50100853@": "Reginald Maitland Holmes",
    "@I50110394@": "Lilian Mary Brooks",
    # Guardrail control (living minor)
    "@I50100727@": "Lily Margaret Cauldwell",
    # Wife + her tree
    "@I50110391@": "Claire Louise Rose",
    "@I50137869@": "David Rose (Claire's father — alive)",
    "@I50110398@": "Margaret Helen Marshall (Claire's mother — d.1987)",
    "@I50113368@": "Norman Rose (paternal grandfather)",
    "@I50100923@": "Norah Beresford (paternal grandmother)",
    "@I50100928@": "Harry Marshall (maternal grandfather — d.1951)",
    "@I50137818@": "Elsie Elizabeth Twyford (maternal grandmother)",
}

DEFAULT_SOURCE = (
    "/Users/darrylcauldwell/Library/Containers/dev.dreamfold."
    "Ancestor-Research/Data/Library/Application Support/AncestorResearch/"
    "projects/788F5EA4-32A3-4739-BAF4-FE53A47C95C2.sqlite"
)


def derive_married_surnames(src: sqlite3.Connection) -> dict[str, str]:
    """For every female seed member with a recorded spouse, return
    the spouse's last_name as her married surname."""
    out: dict[str, str] = {}
    ids = list(SEED_IDS.keys())
    placeholders = ",".join("?" for _ in ids)

    females = src.execute(
        f"SELECT id FROM profiles WHERE id IN ({placeholders}) AND gender = 'female'",
        ids,
    ).fetchall()

    for (female_id,) in females:
        # Spouse row may have us as from_id OR to_id — check both.
        spouse_row = src.execute(
            "SELECT from_id, to_id FROM relationships "
            "WHERE type='spouse' AND (from_id=? OR to_id=?) LIMIT 1",
            (female_id, female_id),
        ).fetchone()
        if not spouse_row:
            continue
        spouse_id = spouse_row[1] if spouse_row[0] == female_id else spouse_row[0]
        spouse_surname_row = src.execute(
            "SELECT last_name FROM profiles WHERE id = ?", (spouse_id,)
        ).fetchone()
        if spouse_surname_row and spouse_surname_row[0]:
            out[female_id] = spouse_surname_row[0]
    return out


def populate(src_path: Path, dst_path: Path) -> None:
    if not src_path.exists():
        raise SystemExit(f"source sqlite not found: {src_path}")
    if not dst_path.exists():
        raise SystemExit(
            f"target sqlite not found: {dst_path}\n"
            "Create a new empty project in the app first, then quit the app."
        )

    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    dst = sqlite3.connect(str(dst_path))
    dst.execute("PRAGMA foreign_keys = ON")

    # Pre-flight: confirm v5 migrations applied
    have_pending = dst.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pending_facts'"
    ).fetchone()
    if not have_pending:
        raise SystemExit(
            "target project is missing v5 tables (pending_facts). "
            "Open the project in the app once to run migrations, "
            "then quit and re-run this script."
        )

    # Pre-flight: target should be empty (don't double-populate)
    profile_count = dst.execute(
        "SELECT COUNT(*) FROM profiles WHERE is_deleted = 0"
    ).fetchone()[0]
    if profile_count > 0:
        raise SystemExit(
            f"target already has {profile_count} profile(s). "
            "Aborting to avoid double-populate. "
            "Delete the project from the app and create a fresh one."
        )

    married_surnames = derive_married_surnames(src)
    print(f"Derived married surnames for {len(married_surnames)} female(s):")
    for fid, ms in married_surnames.items():
        print(f"  {fid} ({SEED_IDS[fid]}) → married_surname = '{ms}'")

    # Single seed transaction for audit-trail provenance
    txn_id = str(uuid.uuid4()).upper()
    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]

    profile_cols = [
        "id", "external_ids", "first_name", "last_name", "gender",
        "birth_date_original", "birth_date_earliest", "birth_date_latest",
        "birth_date_qualifier", "birth_location",
        "death_date_original", "death_date_earliest", "death_date_latest",
        "death_date_qualifier", "death_location",
        "bio", "created_by_transaction_id", "attributes", "is_deleted",
        "birth_location_code", "death_location_code",
        "middle_name", "nick_name", "mothers_maiden_name", "married_surname",
    ]
    profile_placeholders = ",".join("?" for _ in profile_cols)
    profile_col_list = ",".join(profile_cols)

    rel_cols = [
        "id", "from_id", "to_id", "type", "role", "subtype",
        "marriage_date_original", "marriage_date_earliest",
        "marriage_date_latest", "marriage_date_qualifier",
        "divorce_date_original", "divorce_date_earliest",
        "divorce_date_latest", "divorce_date_qualifier",
        "created_by_transaction_id",
        "marriage_location", "marriage_location_code",
    ]
    rel_placeholders = ",".join("?" for _ in rel_cols)
    rel_col_list = ",".join(rel_cols)

    inserted_profiles = 0
    inserted_relationships = 0

    with dst:
        dst.execute(
            "INSERT INTO transactions(id, kind, undo_strategy, started_at, completed_at, change_count, profile_count) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (txn_id, json.dumps({"discoverySeed": {"source": str(src_path)}}),
             "structural", now, now, 0, len(SEED_IDS)),
        )

        # Profiles
        for seed_id in SEED_IDS:
            row = src.execute(
                f"SELECT {profile_col_list} FROM profiles WHERE id = ?",
                (seed_id,),
            ).fetchone()
            if not row:
                print(f"  ⚠ not in source: {seed_id} — skipped")
                continue
            row = list(row)
            # Rewire created_by_transaction_id to our seed transaction
            txn_idx = profile_cols.index("created_by_transaction_id")
            row[txn_idx] = txn_id
            # Inject derived married_surname
            if seed_id in married_surnames:
                ms_idx = profile_cols.index("married_surname")
                row[ms_idx] = married_surnames[seed_id]
            dst.execute(
                f"INSERT INTO profiles({profile_col_list}) VALUES({profile_placeholders})",
                row,
            )
            inserted_profiles += 1

        # Relationships — only those whose BOTH endpoints are in the seed
        seed_set = set(SEED_IDS)
        placeholders = ",".join("?" for _ in seed_set)
        rels = src.execute(
            f"SELECT {rel_col_list} FROM relationships "
            f"WHERE from_id IN ({placeholders}) AND to_id IN ({placeholders})",
            list(seed_set) + list(seed_set),
        ).fetchall()
        for rel in rels:
            rel = list(rel)
            txn_idx = rel_cols.index("created_by_transaction_id")
            rel[txn_idx] = txn_id
            dst.execute(
                f"INSERT INTO relationships({rel_col_list}) VALUES({rel_placeholders})",
                rel,
            )
            inserted_relationships += 1

        # Refresh the transaction's row counts now that we know them
        dst.execute(
            "UPDATE transactions SET change_count = ?, profile_count = ? WHERE id = ?",
            (inserted_relationships, inserted_profiles, txn_id),
        )

    src.close()
    dst.close()

    print()
    print("=" * 60)
    print(f"Wrote to {dst_path}")
    print(f"  Profiles:       {inserted_profiles} / {len(SEED_IDS)} expected")
    print(f"  Relationships:  {inserted_relationships}")
    print(f"  Transaction:    {txn_id}")
    print()
    print("Next: reopen the app, select the project. Verify the 15 profiles")
    print("appear with full family connections + married surnames.")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", default=DEFAULT_SOURCE,
                    help="Source sqlite (twin-export). Default: Cauldwell.twin-export project.")
    ap.add_argument("--target", required=True,
                    help="Target sqlite (the new empty project). Get the UUID from the picker.")
    args = ap.parse_args()
    populate(Path(args.source).expanduser(), Path(args.target).expanduser())


if __name__ == "__main__":
    main()
