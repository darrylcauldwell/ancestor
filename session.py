"""Session harness — the single entry point for a research session.

Connects the research pipeline to the digital twin via a working copy.
All research findings flow into the working copy. Changes are reviewed
as a diff then applied to WikiTree with human approval.

Usage:
    from session import Session

    s = Session()
    s.start()
    s.research("Ernest Cauldwell", birth_year=1887, gender="M")
    s.review()
    s.apply()
    s.end()

Or from CLI:
    python session.py start
    python session.py research "Ernest Cauldwell" --birth-year 1887 --gender M
    python session.py review
    python session.py apply
"""

from wikitree.twin import LocalTwin
from agent.pipeline import research_person
from agent.integrate import apply_research_to_graph
from agent.diff import compute_diff, print_diff, Change
from agent.record import save_state


class Session:
    """Research session harness."""

    def __init__(self):
        self.twin = LocalTwin()
        self.work = None
        self._changes = []
        self._researched = []

    def start(self):
        """Load twin from disk, create working copy."""
        if self.twin.load():
            age = self.twin.age_hours
            age_str = f"{age:.1f}h ago" if age is not None else "unknown"
            print(f"Twin loaded: {self.twin.count} profiles, "
                  f"{self.twin.edge_count} relationships (synced {age_str})")
        else:
            print("No twin data on disk.")
            print("Run: python -m wikitree.twin sync")
            print("Or continue without twin (research only, no diff/apply)")

        self.work = self.twin.working_copy()
        print(f"Working copy created.\n")

        # Show quick gaps summary
        no_bio = self.twin.without_bio()
        no_parents = self.twin.without_parents()
        if no_bio or no_parents:
            print(f"Gaps: {len(no_bio)} without bio, "
                  f"{len(no_parents)} without parents")

    def research(self, name: str, birth_year: int | None = None,
                 gender: str = "M", location: str = ""):
        """Research a person and integrate findings into working copy."""
        person = {
            "name": name,
            "birth_year": birth_year,
            "gender": gender,
            "birth_location": location,
        }

        # Run the research pipeline
        state = research_person(person)

        # Save research state to disk (audit trail)
        save_state(state)

        # Integrate findings into working copy
        wt_id = apply_research_to_graph(state, self.work, self.twin)

        self._researched.append({
            "name": name,
            "wt_id": wt_id,
            "facts": len(state.get("confirmed_facts", [])),
            "household": len(state.get("household_members", [])),
        })

        print(f"\n  Researched: {name} → {wt_id}")
        print(f"  Facts: {len(state.get('confirmed_facts', []))}, "
              f"Household: {len(state.get('household_members', []))}")

    def review(self):
        """Show diff between working copy and read-only twin."""
        self._changes = compute_diff(self.twin, self.work)
        print_diff(self._changes)
        return self._changes

    def apply(self):
        """Walk through changes with approval, push to WikiTree."""
        if not self._changes:
            self._changes = compute_diff(self.twin, self.work)

        if not self._changes:
            print("No changes to apply.")
            return

        print(f"\n{'=' * 60}")
        print(f"APPLYING {len(self._changes)} changes")
        print(f"{'=' * 60}")

        applied = 0
        skipped = 0

        for change in self._changes:
            print(f"\n  {change}")

            if change.type == "update_bio":
                # Show bio preview
                new_bio = change.new_value or ""
                preview = new_bio[:200] + "..." if len(new_bio) > 200 else new_bio
                print(f"  Preview: {preview}")

            response = input("  Apply? (yes/no/quit): ").strip().lower()

            if response in ("quit", "q"):
                print(f"\n  Stopped. Applied {applied}, skipped {skipped}, "
                      f"remaining {len(self._changes) - applied - skipped}")
                break

            if response in ("yes", "y"):
                success = self._apply_change(change)
                if success:
                    applied += 1
                else:
                    print("  Failed — skipping")
                    skipped += 1
            else:
                skipped += 1

        print(f"\nSession: {applied} applied, {skipped} skipped")

    def _apply_change(self, change: Change) -> bool:
        """Push a single change to WikiTree. Returns True on success."""
        try:
            from agent.local.writeback import push_bio
            from wikitree.local.editor import WikiTreeWebEditor
        except ImportError:
            print("  Write tooling not available (local/ not present)")
            return False

        try:
            if change.type == "update_bio":
                # Find user ID
                profile = self.twin.get(change.wt_id)
                if not profile:
                    print(f"  Profile {change.wt_id} not in twin")
                    return False
                user_id = str(profile.get("Id", ""))
                if not user_id:
                    print(f"  No user ID for {change.wt_id}")
                    return False
                push_bio(user_id, change.new_value,
                         summary="Biography from research session")
                return True

            elif change.type == "update_field":
                profile = self.twin.get(change.wt_id)
                if not profile:
                    return False
                user_id = str(profile.get("Id", ""))
                with WikiTreeWebEditor() as ed:
                    if not ed.is_authed():
                        print("  WikiTree session expired")
                        return False
                    if not ed.load_edit_page(user_id):
                        return False
                    ed.fill_fields({change.field: change.new_value})
                    ed.save(summary=f"Updated {change.field} from research")
                return True

            elif change.type == "new_profile":
                print("  Profile creation requires manual review — skipping auto-apply")
                return False

            elif change.type == "new_relationship":
                print("  Relationship linking requires manual review — skipping auto-apply")
                return False

        except Exception as e:
            print(f"  Error: {e}")
            return False

    def end(self):
        """Save twin updates and print session summary."""
        # Update twin with any applied changes
        self.twin.save()

        print(f"\n{'=' * 60}")
        print(f"SESSION COMPLETE")
        print(f"{'=' * 60}")
        print(f"  Researched: {len(self._researched)} people")
        for r in self._researched:
            print(f"    {r['name']} → {r['wt_id']} "
                  f"({r['facts']} facts, {r['household']} household)")


def main():
    """CLI entry point."""
    import sys
    args = sys.argv[1:] if len(sys.argv) > 1 else ["help"]
    command = args[0]

    if command == "start":
        s = Session()
        s.start()
        print("\nSession started. Use: python session.py research \"Name\" --birth-year YYYY --gender M")

    elif command == "research":
        if len(args) < 2:
            print("Usage: python session.py research \"Name\" --birth-year YYYY --gender M")
            return
        name = args[1]
        birth_year = None
        gender = "M"
        for i, arg in enumerate(args):
            if arg == "--birth-year" and i + 1 < len(args):
                birth_year = int(args[i + 1])
            if arg == "--gender" and i + 1 < len(args):
                gender = args[i + 1]

        s = Session()
        s.start()
        s.research(name, birth_year=birth_year, gender=gender)
        s.review()

    elif command == "review":
        s = Session()
        s.start()
        s.review()

    elif command == "apply":
        s = Session()
        s.start()
        changes = s.review()
        if changes:
            s.apply()
        s.end()

    else:
        print("Usage: python session.py <command>")
        print("  start    — Load twin, show gaps")
        print("  research — Research a person")
        print("  review   — Show pending changes")
        print("  apply    — Apply changes to WikiTree")


if __name__ == "__main__":
    main()
