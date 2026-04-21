"""Compute diff between read-only twin and working copy.

Compares every node and edge to find what changed during a research
session. Returns a list of Change objects for human review and
selective application.
"""

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Change:
    """A single proposed change to WikiTree."""
    type: str           # new_profile, new_relationship, update_field, update_bio
    wt_id: str          # affected profile
    field: str = ""     # which field (for update_field)
    old_value: Any = None
    new_value: Any = None
    source: str = ""    # what produced this change
    related_id: str = ""  # for relationships: the other profile
    rel_type: str = ""    # for relationships: parent, spouse, sibling

    def __str__(self):
        if self.type == "new_profile":
            name = f"{self.new_value.get('FirstName', '')} {self.new_value.get('LastNameAtBirth', '')}".strip()
            return f"CREATE profile: {name} (b.{self.new_value.get('BirthDate', '?')})"
        elif self.type == "new_relationship":
            return f"LINK: {self.wt_id} → {self.related_id} ({self.rel_type})"
        elif self.type == "update_field":
            return f"UPDATE {self.wt_id} {self.field}: {self.old_value!r} → {self.new_value!r}"
        elif self.type == "update_bio":
            old_len = len(self.old_value or "")
            new_len = len(self.new_value or "")
            return f"UPDATE BIO {self.wt_id}: {old_len} → {new_len} chars"
        return f"{self.type}: {self.wt_id}"


# Fields to compare between twin and working copy
COMPARE_FIELDS = [
    "FirstName", "MiddleName", "LastNameAtBirth", "LastNameCurrent",
    "BirthDate", "BirthLocation", "DeathDate", "DeathLocation",
    "Gender",
]


def compute_diff(twin, working_copy) -> list[Change]:
    """Compare working copy against read-only twin.

    Returns list of Change objects representing all proposed modifications.
    """
    changes = []

    # 1. New profiles (proposed nodes not in twin)
    for p in working_copy.proposed_profiles():
        changes.append(Change(
            type="new_profile",
            wt_id=p["wt_id"],
            new_value=p,
        ))

    # 2. New relationships (proposed edges not in twin)
    for r in working_copy.proposed_relationships():
        changes.append(Change(
            type="new_relationship",
            wt_id=r["from"],
            related_id=r["to"],
            rel_type=r["type"],
        ))

    # 3. Field changes on existing profiles
    for wt_id in working_copy._graph.nodes:
        work_node = working_copy._graph.nodes[wt_id]

        # Skip proposed profiles (handled above)
        if work_node.get("_proposed"):
            continue

        twin_node = twin.get(wt_id)
        if not twin_node:
            continue

        # Compare structured fields
        for field_name in COMPARE_FIELDS:
            old_val = twin_node.get(field_name, "") or ""
            new_val = work_node.get(field_name, "") or ""

            # Normalise empty values
            if old_val in ("", "0000-00-00") and new_val in ("", "0000-00-00"):
                continue

            if str(old_val) != str(new_val) and new_val:
                changes.append(Change(
                    type="update_field",
                    wt_id=wt_id,
                    field=field_name,
                    old_value=old_val,
                    new_value=new_val,
                ))

        # Compare bios
        old_bio = twin_node.get("Bio") or twin_node.get("bio") or ""
        new_bio = work_node.get("Bio") or work_node.get("bio") or ""

        if new_bio and new_bio != old_bio and len(new_bio.strip()) > len(old_bio.strip()):
            changes.append(Change(
                type="update_bio",
                wt_id=wt_id,
                old_value=old_bio,
                new_value=new_bio,
            ))

    return changes


def print_diff(changes: list[Change]):
    """Print a human-readable summary of proposed changes."""
    if not changes:
        print("No changes detected.")
        return

    new_profiles = [c for c in changes if c.type == "new_profile"]
    new_rels = [c for c in changes if c.type == "new_relationship"]
    field_updates = [c for c in changes if c.type == "update_field"]
    bio_updates = [c for c in changes if c.type == "update_bio"]

    print(f"\n{'=' * 60}")
    print(f"SESSION DIFF: {len(changes)} proposed changes")
    print(f"{'=' * 60}")

    if new_profiles:
        print(f"\n  NEW PROFILES ({len(new_profiles)}):")
        for c in new_profiles:
            print(f"    {c}")

    if new_rels:
        print(f"\n  NEW RELATIONSHIPS ({len(new_rels)}):")
        for c in new_rels:
            print(f"    {c}")

    if field_updates:
        print(f"\n  FIELD UPDATES ({len(field_updates)}):")
        for c in field_updates:
            print(f"    {c}")

    if bio_updates:
        print(f"\n  BIO UPDATES ({len(bio_updates)}):")
        for c in bio_updates:
            print(f"    {c}")
