"""Audit every corpus YAML in `eval/certified/` against the live
project SQLite for dangling relationship references.

Surfaced 2026-05-24: Sarah Jane Byard and Charles Herbert Hodgkinson
both carried YAML parent IDs that didn't exist in the imported tree,
so the pipeline correctly couldn't promote candidate records to facts
(no family context to validate against). Re-run after any tree
re-import to confirm whether previously out-of-scope subjects are
back in scope.

Usage:
    python eval/audit_corpus.py [--db <project.sqlite>]
"""

import argparse
import sqlite3
import sys
from pathlib import Path

import yaml

DEFAULT_DB = (
    "~/Library/Containers/dev.dreamfold.Ancestor-Research/Data/Library/"
    "Application Support/AncestorResearch/projects/"
    "788F5EA4-32A3-4739-BAF4-FE53A47C95C2.sqlite"
)


def collect_profile_ids(subject: dict) -> list[str]:
    """Subject's own profile id(s) — single / pair / cluster."""
    ids: list[str] = []
    if "profile_id" in subject:
        ids.append(subject["profile_id"])
    for s in subject.get("subjects") or []:
        if s.get("profile_id"):
            ids.append(s["profile_id"])
    if "cluster_a_should_merge" in subject:
        ids += list(subject["cluster_a_should_merge"].get("members") or [])
        ids += list(subject.get("cluster_b_must_remain_separate", {}).get("members") or [])
    return ids


def claimed_kin_ids(subject: dict) -> tuple[list[str], list[str]]:
    """Pull declared parent + spouse IDs out of the YAML's relationships
    block. Returns (parents, spouses)."""
    rels = subject.get("relationships") or {}
    parents = [p.get("id") for p in (rels.get("parents") or []) if p.get("id")]
    spouses = [s.get("id") for s in (rels.get("spouse") or []) if s.get("id")]
    return parents, spouses


def audit(corpus_dir: Path, db_path: Path) -> dict[str, list[str]]:
    db = sqlite3.connect(str(db_path))

    def profile_exists(pid: str) -> bool:
        row = db.execute(
            "SELECT 1 FROM profiles WHERE id = ? AND is_deleted = 0",
            (pid,),
        ).fetchone()
        return row is not None

    def has_any_relationships(pid: str) -> bool:
        row = db.execute(
            "SELECT 1 FROM relationships WHERE from_id = ? OR to_id = ? LIMIT 1",
            (pid, pid),
        ).fetchone()
        return row is not None

    issues_by_file: dict[str, list[str]] = {}
    for path in sorted(corpus_dir.glob("*.yaml")):
        if path.name.startswith("_"):
            continue
        subject = yaml.safe_load(path.read_text())
        problems: list[str] = []

        # Cluster subjects intentionally include duplicate-stub IDs that
        # the engine is supposed to merge into a canonical real person —
        # those stubs have no relationships by design. Only flag a
        # cluster when *every* declared cluster member is orphaned.
        is_cluster = "cluster_a_should_merge" in subject
        profile_ids = collect_profile_ids(subject)

        if is_cluster:
            connected_members = [
                pid for pid in profile_ids
                if profile_exists(pid) and has_any_relationships(pid)
            ]
            missing_members = [pid for pid in profile_ids if not profile_exists(pid)]
            if not connected_members:
                problems.append(
                    f"all {len(profile_ids)} cluster members are orphaned or "
                    f"missing — no connected canonical to merge into"
                )
            for pid in missing_members:
                problems.append(f"cluster member {pid} not in DB")
        else:
            for pid in profile_ids:
                if not profile_exists(pid):
                    problems.append(f"subject profile {pid} not in DB")
                    continue
                if not has_any_relationships(pid):
                    problems.append(
                        f"subject profile {pid} has zero relationship edges "
                        f"(orphaned — pipeline can't establish family context)"
                    )

        parents, spouses = claimed_kin_ids(subject)
        for cp in parents:
            if not profile_exists(cp):
                problems.append(f"declares parent {cp} but profile not in DB")
        for cs in spouses:
            if not profile_exists(cs):
                problems.append(f"declares spouse {cs} but profile not in DB")

        if problems:
            issues_by_file[path.name] = problems

    db.close()
    return issues_by_file


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--db",
        default=DEFAULT_DB,
        help="Project SQLite path. Default: the Cauldwell.twin-export project.",
    )
    parser.add_argument(
        "--corpus",
        default="eval/certified",
        help="Corpus directory. Default: eval/certified.",
    )
    args = parser.parse_args()

    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        print(f"ERROR: DB not found at {db_path}", file=sys.stderr)
        sys.exit(2)

    corpus_dir = Path(args.corpus)
    if not corpus_dir.exists():
        print(f"ERROR: corpus directory {corpus_dir} not found", file=sys.stderr)
        sys.exit(2)

    issues = audit(corpus_dir, db_path)
    if not issues:
        print(f"OK — all corpus YAMLs in {corpus_dir} have valid relationship refs in {db_path}")
        return

    print(f"⚠ Found dangling-ref issues in {len(issues)} subject(s):\n")
    for fname in sorted(issues):
        print(f"  {fname}")
        for problem in issues[fname]:
            print(f"    - {problem}")
        print()
    sys.exit(1)


if __name__ == "__main__":
    main()
