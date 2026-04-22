"""Session harness — the single entry point for a research session.

Two categories only:
  Facts: verified changes to apply to WikiTree (the queue)
  Leads: promising findings to investigate (the backlog)

Usage:
    from session import Session

    s = Session()
    s.start()
    s.research("Ernest Cauldwell", birth_year=1887, gender="M")
    s.review()        # Show facts queue + top leads
    s.apply()         # Walk through facts with approval
    s.leads()         # View lead backlog
    s.end()

Or from CLI:
    python session.py research "Ernest Cauldwell" --birth-year 1887 --gender M
    python session.py leads
"""

from wikitree.twin import LocalTwin
from agent.pipeline import research_person
from agent.integrate import integrate_research
from agent.leads import LeadStore
from agent.record import save_state


class Session:
    """Research session harness."""

    def __init__(self):
        self.twin = LocalTwin()
        self.lead_store = LeadStore()
        self._facts = []         # the queue
        self._researched = []

    def start(self):
        """Load twin and leads from disk."""
        if self.twin.load():
            age = self.twin.age_hours
            age_str = f"{age:.1f}h ago" if age is not None else "unknown"
            print(f"Twin loaded: {self.twin.count} profiles, "
                  f"{self.twin.edge_count} relationships (synced {age_str})")
        else:
            print("No twin data on disk.")
            print("Run: python -m wikitree.twin sync")

        lead_count = self.lead_store.load()
        open_leads = self.lead_store.open_count()
        if lead_count:
            print(f"Leads: {open_leads} open, {lead_count} total")

        # Show gaps
        no_bio = self.twin.without_bio()
        no_parents = self.twin.without_parents()
        if no_bio or no_parents:
            print(f"Gaps: {len(no_bio)} without bio, "
                  f"{len(no_parents)} without parents")
        print()

    def research(self, name: str, birth_year: int | None = None,
                 gender: str = "M", location: str = ""):
        """Research a person. Produces facts and leads."""
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

        # Integrate into facts and leads
        result = integrate_research(state, self.twin, self.lead_store)
        self.lead_store.save()

        facts = result.get("facts", [])
        self._facts.extend(facts)

        self._researched.append({
            "name": name,
            "wt_id": result.get("wt_id"),
            "facts": len(facts),
            "leads_created": result.get("leads_created", 0),
            "confirmed": len(state.get("confirmed_facts", [])),
        })

        print(f"\n  Researched: {name} → {result.get('wt_id')}")
        print(f"  Confirmed records: {len(state.get('confirmed_facts', []))}")
        print(f"  Facts queued: {len(facts)}")
        print(f"  Leads created: {result.get('leads_created', 0)}")

    def review(self):
        """Show the fact queue and top leads."""
        print(f"\n{'=' * 60}")
        print(f"SESSION REVIEW")
        print(f"{'=' * 60}")

        # Facts queue
        if self._facts:
            print(f"\n  FACTS TO APPLY ({len(self._facts)}):")
            for f in self._facts:
                action = f.get("action", "")
                wt_id = f.get("wt_id", "")
                if action == "update_field":
                    print(f"    {wt_id}: {f['field']} → {f['value']}")
                elif action == "update_bio":
                    print(f"    {wt_id}: bio ({len(f.get('bio', ''))} chars)")
                elif f.get("type") and f.get("value"):
                    # Investigation-sourced fact
                    sources = ", ".join(f.get("sources", []))
                    print(f"    [{f['type']}] {f['value']}")
                    if sources:
                        print(f"           Sources: {sources}")
                else:
                    print(f"    {wt_id}: {action or '?'}")
        else:
            print(f"\n  No facts to apply.")

        # Top leads
        top = self.lead_store.by_priority("open")
        if top:
            print(f"\n  TOP LEADS ({len(top)} open):")
            for lead in top[:10]:
                print(f"    [{lead.priority:+d}] {lead.summary}")
                if lead.next_actions:
                    cost = f" [{lead.next_actions[0].cost}]" if lead.next_actions[0].cost == "paid" else ""
                    print(f"          Next: {lead.next_actions[0].description}{cost}")
            if len(top) > 10:
                print(f"    ... and {len(top) - 10} more")

        return self._facts

    def apply(self):
        """Walk through fact queue with approval, push to WikiTree."""
        if not self._facts:
            print("No facts to apply.")
            return

        print(f"\n{'=' * 60}")
        print(f"APPLYING {len(self._facts)} facts")
        print(f"{'=' * 60}")

        applied = 0
        skipped = 0

        for fact in self._facts:
            action = fact.get("action", "?")
            wt_id = fact.get("wt_id", "?")

            if action == "update_field":
                print(f"\n  {wt_id}: {fact['field']} → {fact['value']}")
                print(f"  Sources: {', '.join(fact.get('sources', []))}")
            elif action == "update_bio":
                bio = fact.get("bio", "")
                preview = bio[:200] + "..." if len(bio) > 200 else bio
                print(f"\n  {wt_id}: update bio ({len(bio)} chars)")
                print(f"  {preview}")

            response = input("  Apply? (yes/no/quit): ").strip().lower()

            if response in ("quit", "q"):
                remaining = len(self._facts) - applied - skipped
                print(f"\n  Stopped. Applied {applied}, skipped {skipped}, {remaining} remaining")
                break

            if response in ("yes", "y"):
                success = self._push_fact(fact)
                if success:
                    applied += 1
                else:
                    print("  Failed — skipping")
                    skipped += 1
            else:
                skipped += 1

        print(f"\nApplied: {applied}, Skipped: {skipped}")

    def _push_fact(self, fact: dict) -> bool:
        """Push a single fact to WikiTree."""
        try:
            from agent.local.writeback import push_bio
            from wikitree.local.editor import WikiTreeWebEditor
        except ImportError:
            print("  Write tooling not available")
            return False

        try:
            wt_id = fact.get("wt_id", "")
            profile = self.twin.get(wt_id)
            if not profile:
                print(f"  Profile {wt_id} not in twin")
                return False
            user_id = str(profile.get("Id", ""))

            if fact["action"] == "update_bio":
                push_bio(user_id, fact["bio"], summary="Biography from research")
                return True

            elif fact["action"] == "update_field":
                with WikiTreeWebEditor() as ed:
                    if not ed.is_authed():
                        print("  WikiTree session expired")
                        return False
                    if not ed.load_edit_page(user_id):
                        return False
                    ed.fill_fields({fact["field"]: fact["value"]})
                    ed.save(summary=f"Updated {fact['field']} from research")
                return True

        except Exception as e:
            print(f"  Error: {e}")
            return False

    def investigate(self, lead_id: str):
        """Run LLM investigation loop on a lead, then extract facts deterministically."""
        lead = self.lead_store.get(lead_id)
        if not lead:
            print(f"Lead not found: {lead_id}")
            return

        from agent.investigator import investigate_lead
        result = investigate_lead(lead, self.twin, self.lead_store)

        # Show what happened
        print(f"\n{'=' * 60}")
        print(f"INVESTIGATION COMPLETE: {result.iterations} iterations")
        print(f"{'=' * 60}")

        for i, reasoning in enumerate(result.reasoning_log):
            print(f"\n  --- Iteration {i + 1} ---")
            print(f"  {reasoning[:500]}")

        print(f"\n  Searches executed: {len(result.searches_executed)}")
        print(f"  New evidence: {len(result.new_evidence)}")
        print(f"  Facts extracted: {len(result.facts_extracted)}")
        print(f"  Verdict: {result.verdict}")

        # Facts go to the queue for WikiTree push
        for fact in result.facts_extracted:
            self._facts.append(fact)

        if result.questions:
            print(f"\n  QUESTIONS FOR YOU:")
            for q in result.questions:
                print(f"    ? {q}")

        self.lead_store.save()

    def investigate_cluster(self, family_key: str):
        """Investigate a cluster of related leads together."""
        from agent.investigator import cluster_leads, investigate_cluster

        clusters = cluster_leads(self.lead_store, self.twin)
        target = None
        for c in clusters:
            if c.family_key.lower() == family_key.lower():
                target = c
                break

        if not target:
            print(f"Cluster not found: {family_key}")
            print("Available clusters:")
            for c in clusters[:15]:
                total_priority = sum(l.priority for l in c.leads)
                print(f"  [{total_priority:+d}] {c.family_key} ({len(c.leads)} leads)")
            return

        result = investigate_cluster(target, self.twin, self.lead_store)

        print(f"\n{'=' * 60}")
        print(f"CLUSTER COMPLETE: {result.family_key}")
        print(f"{'=' * 60}")
        print(f"  Leads: {result.lead_count}")
        print(f"  Iterations: {result.iterations}")
        print(f"  Searches: {len(result.searches_executed)}")
        print(f"  Facts extracted: {len(result.facts_extracted)}")
        print(f"  Resolved: {result.leads_resolved}/{result.lead_count}")

        for fact in result.facts_extracted:
            self._facts.append(fact)

        if result.questions:
            print(f"\n  QUESTIONS:")
            for q in result.questions:
                print(f"    ? {q}")

        self.lead_store.save()

    def list_clusters(self):
        """Show lead clusters sorted by total priority."""
        from agent.investigator import cluster_leads

        clusters = cluster_leads(self.lead_store, self.twin)
        print(f"\n{'=' * 60}")
        print(f"LEAD CLUSTERS: {len(clusters)} families")
        print(f"{'=' * 60}")

        for c in clusters:
            total_priority = sum(l.priority for l in c.leads)
            print(f"\n  [{total_priority:+d}] {c.family_key} ({len(c.leads)} leads)")
            for lead in c.leads[:5]:
                print(f"       {lead.subject_name} ({lead.category})")
            if len(c.leads) > 5:
                print(f"       ... and {len(c.leads) - 5} more")

    def leads(self, status: str = "open", limit: int = 20):
        """Display leads sorted by priority."""
        all_leads = self.lead_store.by_priority(status)

        print(f"\n{'=' * 60}")
        print(f"LEADS ({status.upper()}): {len(all_leads)} total")
        print(f"{'=' * 60}")

        for lead in all_leads[:limit]:
            print(f"\n  [{lead.priority:+d}] {lead.lead_id}")
            print(f"       {lead.summary}")
            print(f"       Evidence: {len(lead.evidence)} items")
            if lead.next_actions:
                for action in lead.next_actions[:2]:
                    cost = f" [{action.cost}]" if action.cost == "paid" else ""
                    print(f"       → {action.description}{cost}")

        if len(all_leads) > limit:
            print(f"\n  ... and {len(all_leads) - limit} more")

    def end(self):
        """Save and print session summary."""
        self.lead_store.save()

        print(f"\n{'=' * 60}")
        print(f"SESSION COMPLETE")
        print(f"{'=' * 60}")
        print(f"  Researched: {len(self._researched)} people")
        for r in self._researched:
            print(f"    {r['name']} → {r['wt_id']} "
                  f"({r['confirmed']} confirmed, {r['facts']} facts queued, "
                  f"{r['leads_created']} leads)")
        print(f"  Facts in queue: {len(self._facts)}")
        print(f"  Leads open: {self.lead_store.open_count()}")


def main():
    """CLI entry point."""
    import sys
    args = sys.argv[1:] if len(sys.argv) > 1 else ["help"]
    command = args[0]

    if command == "research":
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
        s.end()

    elif command == "leads":
        status = args[1] if len(args) > 1 else "open"
        s = Session()
        s.start()
        s.leads(status=status)

    elif command == "apply":
        s = Session()
        s.start()
        s.review()
        s.apply()
        s.end()

    elif command == "audit":
        from agent.audit import audit_tree, print_audit_results
        s = Session()
        s.start()
        results = audit_tree(s.twin, s.lead_store)
        print_audit_results(results)
        s.lead_store.save()
        print(f"\n  Leads saved. View with: python session.py leads")

    elif command == "investigate":
        if len(args) < 2:
            print("Usage: python session.py investigate <lead_id>")
            return
        lead_id = args[1]
        s = Session()
        s.start()
        s.investigate(lead_id)
        s.review()
        s.end()

    elif command == "investigate-top":
        count = int(args[1]) if len(args) > 1 else 1
        s = Session()
        s.start()
        top = s.lead_store.by_priority("open")
        if not top:
            print("No open leads to investigate.")
            return
        for lead in top[:count]:
            print(f"\n  Investigating: {lead.lead_id} (priority {lead.priority:+d})")
            s.investigate(lead.lead_id)
        s.review()
        s.end()

    elif command == "clusters":
        s = Session()
        s.start()
        s.list_clusters()

    elif command == "investigate-cluster":
        if len(args) < 2:
            print("Usage: python session.py investigate-cluster \"Family Name\"")
            return
        family_key = " ".join(args[1:])
        s = Session()
        s.start()
        s.investigate_cluster(family_key)
        s.review()
        s.end()

    elif command == "investigate-top-clusters":
        count = int(args[1]) if len(args) > 1 else 3
        from agent.investigator import cluster_leads
        s = Session()
        s.start()
        clusters = cluster_leads(s.lead_store, s.twin)
        for c in clusters[:count]:
            total = sum(l.priority for l in c.leads)
            print(f"\n  Investigating cluster: {c.family_key} "
                  f"({len(c.leads)} leads, priority {total:+d})")
            s.investigate_cluster(c.family_key)
        s.review()
        s.end()

    elif command == "gaps":
        s = Session()
        s.start()
        no_bio = s.twin.without_bio()
        no_parents = s.twin.without_parents()
        print(f"\nWithout bio ({len(no_bio)}):")
        for p in no_bio[:15]:
            name = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip()
            print(f"  {p['wt_id']:25s} {name}")
        print(f"\nWithout parents ({len(no_parents)}):")
        for p in no_parents[:15]:
            name = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip()
            print(f"  {p['wt_id']:25s} {name}")

    else:
        print("Usage: python session.py <command>")
        print("  research \"Name\" --birth-year YYYY --gender M")
        print("  leads [open|investigating|confirmed|dismissed]")
        print("  clusters                          — show lead clusters by family")
        print("  investigate <lead_id>             — LLM investigation on one lead")
        print("  investigate-top [N]               — investigate top N priority leads")
        print("  investigate-cluster \"Family Name\" — investigate a family cluster")
        print("  investigate-top-clusters [N]      — investigate top N clusters")
        print("  apply     — apply fact queue to WikiTree")
        print("  audit     — check existing data for errors")
        print("  gaps      — show profiles needing work")


if __name__ == "__main__":
    main()
