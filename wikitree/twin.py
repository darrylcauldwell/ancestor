"""Local digital twin of WikiTree — NetworkX graph backed by JSON on disk.

Two graphs:
  - twin (read-only mirror): exact copy of WikiTree, synced via API
  - working (session workspace): copy of twin + research findings,
    proposed links, drafted bios — all tentative until pushed

Nodes = profiles (keyed by WikiTree ID, attributes = raw API fields)
Edges = relationships (typed: parent, spouse, sibling)

Usage:
    twin = LocalTwin()
    twin.load()                          # Load from disk
    twin.sync()                          # Refresh from WikiTree API

    twin.get("Cauldwell-171")            # Profile attributes
    twin.children_of("Cauldwell-171")    # Relationship traversal
    twin.without_bio()                   # Gap analysis

    work = twin.working_copy()           # Mutable session workspace
    work.add_proposed(...)               # Add research findings

CLI:
    python -m wikitree.twin sync
    python -m wikitree.twin status
    python -m wikitree.twin gaps
    python -m wikitree.twin show Cauldwell-171
    python -m wikitree.twin tree Cauldwell-100
"""

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import networkx as nx

def _twin_file():
    from project_config import config
    return config.project.data_dir / ".wikitree-twin.json"


class LocalTwin:
    """Read-only mirror of WikiTree profiles as a NetworkX graph."""

    def __init__(self):
        self._graph = nx.DiGraph()
        self._synced_at = None

    # --- Load / Save ---

    def load(self) -> bool:
        """Load graph from disk. Returns True if loaded."""
        if not _twin_file().exists():
            return False
        data = json.loads(_twin_file().read_text())
        self._graph = nx.node_link_graph(data["graph"])
        self._synced_at = data.get("synced_at")
        return True

    def save(self):
        """Persist graph to disk."""
        data = {
            "synced_at": self._synced_at,
            "profile_count": self._graph.number_of_nodes(),
            "relationship_count": self._graph.number_of_edges(),
            "graph": nx.node_link_data(self._graph),
        }
        _twin_file().write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str))

    # --- Sync from WikiTree API ---

    def sync(self, seed: str = ""):
        """Fetch all profiles and relationships from WikiTree API.

        This is the only method that calls the API. Everything else
        reads from the local graph.
        """
        from wikitree.api import WikiTreeAPI

        email = os.environ.get("WIKITREE_EMAIL", "")
        password = os.environ.get("WIKITREE_PASSWORD", "")
        if not email or not password:
            raise SystemExit("Set WIKITREE_EMAIL and WIKITREE_PASSWORD in .env")

        api = WikiTreeAPI(email=email, password=password)
        api.login()

        # Step 1: Get all watchlist IDs
        print("Fetching watchlist...")
        watchlist = api.get_watchlist(
            fields="Id,Name", page_size=1000)
        wt_ids = [p.get("Name") for p in watchlist if p.get("Name")]
        print(f"  {len(wt_ids)} profiles on watchlist")

        # Step 2: Batch fetch full profiles
        print("Fetching full profiles...")
        profiles = api.get_profiles(
            wt_ids,
            progress=lambda done, total: print(f"  {done}/{total}") if done % 200 == 0 else None)
        print(f"  {len(profiles)} profiles fetched")

        # Step 3: Build graph — add nodes
        self._graph = nx.DiGraph()
        for wt_id, profile in profiles.items():
            self._graph.add_node(wt_id, **profile)

        # Step 4: Batch fetch relationships
        print("Fetching relationships...")
        all_ids = list(profiles.keys())
        for i in range(0, len(all_ids), 100):
            chunk = all_ids[i:i + 100]
            rels = api.get_relatives(
                chunk, get_parents=True, get_children=True,
                get_spouses=True, get_siblings=True)

            for item in rels:
                for entry in item.get("items", []):
                    person = entry.get("person", {})
                    person_id = person.get("Name")
                    if not person_id:
                        continue

                    for rel_type, edge_type in [
                        ("Children", "parent"),
                        ("Spouses", "spouse"),
                        ("Siblings", "sibling"),
                    ]:
                        relatives = person.get(rel_type, {})
                        if isinstance(relatives, list):
                            continue  # empty list
                        for rid, rp in relatives.items():
                            rel_id = rp.get("Name")
                            if not rel_id:
                                continue

                            # Ensure relative node exists
                            if not self._graph.has_node(rel_id):
                                self._graph.add_node(rel_id, **rp)

                            if edge_type == "parent":
                                # person is parent of child
                                self._graph.add_edge(person_id, rel_id, type="parent")
                            elif edge_type == "spouse":
                                # bidirectional
                                self._graph.add_edge(person_id, rel_id, type="spouse")
                                self._graph.add_edge(rel_id, person_id, type="spouse")
                            elif edge_type == "sibling":
                                self._graph.add_edge(person_id, rel_id, type="sibling")
                                self._graph.add_edge(rel_id, person_id, type="sibling")

            if i + 100 < len(all_ids):
                print(f"  {min(i + 100, len(all_ids))}/{len(all_ids)} processed")
                time.sleep(0.5)

        self._synced_at = datetime.now(timezone.utc).isoformat()
        self.save()

        print(f"\nSync complete:")
        print(f"  {self._graph.number_of_nodes()} profiles")
        print(f"  {self._graph.number_of_edges()} relationships")
        print(f"  Saved to {_twin_file()}")

    # --- Profile access ---

    def get(self, wt_id: str) -> dict | None:
        """Get raw profile attributes for a WikiTree ID."""
        if self._graph.has_node(wt_id):
            return dict(self._graph.nodes[wt_id])
        return None

    def bio(self, wt_id: str) -> str:
        """Get bio text for a profile."""
        node = self.get(wt_id)
        if not node:
            return ""
        return node.get("Bio") or node.get("bio") or ""

    # --- Relationship traversal ---

    def parents_of(self, wt_id: str) -> list[dict]:
        """Profiles that are parents of wt_id."""
        results = []
        for pred in self._graph.predecessors(wt_id):
            edge = self._graph.edges[pred, wt_id]
            if edge.get("type") == "parent":
                results.append({"wt_id": pred, **self._graph.nodes[pred]})
        return results

    def children_of(self, wt_id: str) -> list[dict]:
        """Profiles that are children of wt_id."""
        results = []
        for succ in self._graph.successors(wt_id):
            edge = self._graph.edges[wt_id, succ]
            if edge.get("type") == "parent":
                results.append({"wt_id": succ, **self._graph.nodes[succ]})
        return results

    def spouses_of(self, wt_id: str) -> list[dict]:
        """Profiles linked as spouse of wt_id."""
        results = []
        for neighbor in self._graph.successors(wt_id):
            edge = self._graph.edges[wt_id, neighbor]
            if edge.get("type") == "spouse":
                results.append({"wt_id": neighbor, **self._graph.nodes[neighbor]})
        return results

    def siblings_of(self, wt_id: str) -> list[dict]:
        """Profiles linked as sibling of wt_id."""
        results = []
        for neighbor in self._graph.successors(wt_id):
            edge = self._graph.edges[wt_id, neighbor]
            if edge.get("type") == "sibling":
                results.append({"wt_id": neighbor, **self._graph.nodes[neighbor]})
        return results

    # --- Graph traversal ---

    def ancestors_of(self, wt_id: str, depth: int = 5) -> list[dict]:
        """BFS up parent edges to find ancestors."""
        results = []
        visited = set()
        queue = [(wt_id, 0)]
        while queue:
            current, d = queue.pop(0)
            if d > depth:
                break
            for parent in self.parents_of(current):
                pid = parent["wt_id"]
                if pid not in visited:
                    visited.add(pid)
                    parent["generation"] = d + 1
                    results.append(parent)
                    queue.append((pid, d + 1))
        return results

    def descendants_of(self, wt_id: str, depth: int = 5) -> list[dict]:
        """BFS down parent edges to find descendants."""
        results = []
        visited = set()
        queue = [(wt_id, 0)]
        while queue:
            current, d = queue.pop(0)
            if d > depth:
                break
            for child in self.children_of(current):
                cid = child["wt_id"]
                if cid not in visited:
                    visited.add(cid)
                    child["generation"] = d + 1
                    results.append(child)
                    queue.append((cid, d + 1))
        return results

    # --- Gap analysis ---

    def _birth_year(self, wt_id: str) -> int | None:
        node = self.get(wt_id)
        if not node:
            return None
        bd = node.get("BirthDate", "") or ""
        match = re.match(r"(\d{4})", bd)
        if match:
            year = int(match.group(1))
            return year if year > 0 else None
        return None

    def _is_historical(self, wt_id: str) -> bool:
        """Born before 1930 — eligible for research."""
        year = self._birth_year(wt_id)
        return year is not None and year < 1930

    def without_bio(self) -> list[dict]:
        """Historical profiles with empty or short bios."""
        results = []
        for wt_id in self._graph.nodes:
            if not self._is_historical(wt_id):
                continue
            bio = self.bio(wt_id)
            if not bio or len(bio.strip()) < 50:
                node = self.get(wt_id)
                results.append({"wt_id": wt_id, **node})
        return sorted(results, key=lambda x: self._birth_year(x["wt_id"]) or 9999)

    def without_parents(self) -> list[dict]:
        """Historical profiles with no parent links."""
        results = []
        for wt_id in self._graph.nodes:
            if not self._is_historical(wt_id):
                continue
            if not self.parents_of(wt_id):
                node = self.get(wt_id)
                results.append({"wt_id": wt_id, **node})
        return sorted(results, key=lambda x: self._birth_year(x["wt_id"]) or 9999)

    def without_dates(self) -> list[dict]:
        """Profiles missing birth year or death year (historical only)."""
        results = []
        for wt_id in self._graph.nodes:
            node = self.get(wt_id)
            if not node:
                continue
            bd = node.get("BirthDate", "") or ""
            dd = node.get("DeathDate", "") or ""
            has_birth = bd and not bd.startswith("0000")
            has_death = dd and not dd.startswith("0000")
            if not has_birth or not has_death:
                if has_birth and self._is_historical(wt_id):
                    results.append({"wt_id": wt_id, "missing": "death" if has_birth else "birth", **node})
                elif not has_birth:
                    results.append({"wt_id": wt_id, "missing": "birth", **node})
        return results

    # --- Search ---

    def search(self, first: str = "", last: str = "", birth_year: int | None = None) -> list[dict]:
        """Fuzzy search across all profiles."""
        first_upper = first.upper()
        last_upper = last.upper()
        results = []

        for wt_id in self._graph.nodes:
            node = self._graph.nodes[wt_id]
            score = 0.0

            node_first = (node.get("FirstName") or "").upper()
            node_last = (node.get("LastNameAtBirth") or "").upper()
            node_birth = self._birth_year(wt_id)

            if last_upper and node_last == last_upper:
                score += 0.5
            elif last_upper and (last_upper in node_last or node_last in last_upper):
                score += 0.3

            if first_upper and node_first == first_upper:
                score += 0.3
            elif first_upper and (first_upper in node_first or node_first in first_upper):
                score += 0.2

            if birth_year and node_birth:
                diff = abs(birth_year - node_birth)
                if diff == 0:
                    score += 0.2
                elif diff <= 2:
                    score += 0.15
                elif diff <= 5:
                    score += 0.05

            if score >= 0.5:
                results.append({"wt_id": wt_id, "score": round(score, 2), **node})

        return sorted(results, key=lambda x: x["score"], reverse=True)

    # --- Working copy ---

    def working_copy(self) -> "WorkingGraph":
        """Create a mutable session workspace from this twin."""
        return WorkingGraph(self._graph.copy())

    # --- Metadata ---

    @property
    def count(self) -> int:
        return self._graph.number_of_nodes()

    @property
    def edge_count(self) -> int:
        return self._graph.number_of_edges()

    @property
    def synced_at(self) -> str | None:
        return self._synced_at

    @property
    def age_hours(self) -> float | None:
        if not self._synced_at:
            return None
        try:
            if isinstance(self._synced_at, (int, float)):
                synced = datetime.fromtimestamp(self._synced_at, tz=timezone.utc)
            else:
                synced = datetime.fromisoformat(str(self._synced_at))
            now = datetime.now(timezone.utc)
            return (now - synced).total_seconds() / 3600
        except (ValueError, TypeError):
            return None


class WorkingGraph:
    """Mutable session workspace — copy of twin + research findings.

    Used during a research session to track proposed changes before
    pushing them to WikiTree.
    """

    def __init__(self, graph: nx.DiGraph):
        self._graph = graph

    def get(self, wt_id: str) -> dict | None:
        if self._graph.has_node(wt_id):
            return dict(self._graph.nodes[wt_id])
        return None

    def add_proposed_profile(self, temp_id: str, **fields):
        """Add a proposed new profile (not yet on WikiTree)."""
        self._graph.add_node(temp_id, _proposed=True, **fields)

    def add_proposed_relationship(self, from_id: str, to_id: str, rel_type: str):
        """Add a proposed relationship edge."""
        self._graph.add_edge(from_id, to_id, type=rel_type, _proposed=True)

    def update_bio(self, wt_id: str, bio: str):
        """Update bio in working copy."""
        if self._graph.has_node(wt_id):
            self._graph.nodes[wt_id]["Bio"] = bio
            self._graph.nodes[wt_id]["bio"] = bio

    def update_fields(self, wt_id: str, fields: dict):
        """Update profile fields in working copy."""
        if self._graph.has_node(wt_id):
            self._graph.nodes[wt_id].update(fields)

    def proposed_profiles(self) -> list[dict]:
        """List all proposed (not-yet-created) profiles."""
        results = []
        for wt_id in self._graph.nodes:
            node = self._graph.nodes[wt_id]
            if node.get("_proposed"):
                results.append({"wt_id": wt_id, **node})
        return results

    def proposed_relationships(self) -> list[dict]:
        """List all proposed (not-yet-linked) relationships."""
        results = []
        for u, v, data in self._graph.edges(data=True):
            if data.get("_proposed"):
                results.append({"from": u, "to": v, "type": data.get("type")})
        return results

    def add_research(self, wt_id: str, key: str, value):
        """Store research metadata on a profile node.

        Stored under _research dict, separate from WikiTree fields.
        Examples: occupations from census, addresses, military details.
        """
        if not self._graph.has_node(wt_id):
            return
        node = self._graph.nodes[wt_id]
        if "_research" not in node:
            node["_research"] = {}
        if key in node["_research"] and isinstance(node["_research"][key], list):
            if value not in node["_research"][key]:
                node["_research"][key].append(value)
        else:
            node["_research"][key] = value

    def get_research(self, wt_id: str) -> dict:
        """Retrieve research metadata for a profile."""
        if self._graph.has_node(wt_id):
            return self._graph.nodes[wt_id].get("_research", {})
        return {}

    def search(self, first: str = "", last: str = "",
               birth_year: int | None = None) -> list[dict]:
        """Fuzzy search across all profiles in working copy."""
        first_upper = first.upper()
        last_upper = last.upper()
        results = []

        for wt_id in self._graph.nodes:
            node = self._graph.nodes[wt_id]
            score = 0.0

            node_first = (node.get("FirstName") or "").upper()
            node_last = (node.get("LastNameAtBirth") or "").upper()

            if last_upper and node_last == last_upper:
                score += 0.5
            elif last_upper and (last_upper in node_last or node_last in last_upper):
                score += 0.3

            if first_upper and node_first == first_upper:
                score += 0.3
            elif first_upper and (first_upper in node_first or node_first in first_upper):
                score += 0.2

            if birth_year:
                bd = node.get("BirthDate", "") or ""
                if bd and bd[:4].isdigit():
                    node_year = int(bd[:4])
                    if node_year > 0:
                        diff = abs(birth_year - node_year)
                        if diff == 0:
                            score += 0.2
                        elif diff <= 2:
                            score += 0.15

            if score >= 0.5:
                results.append({"wt_id": wt_id, "score": round(score, 2), **node})

        return sorted(results, key=lambda x: x["score"], reverse=True)

    def has_node(self, wt_id: str) -> bool:
        return self._graph.has_node(wt_id)


# --- CLI ---

def _print_profile(node: dict, wt_id: str = ""):
    name = f"{node.get('FirstName', '')} {node.get('LastNameAtBirth', '')}".strip()
    bd = node.get("BirthDate", "") or ""
    dd = node.get("DeathDate", "") or ""
    bl = node.get("BirthLocation", "") or ""
    print(f"  {wt_id or node.get('Name', '?'):25s} {name:30s} b.{bd:12s} d.{dd:12s} {bl}")


def main():
    import sys
    args = sys.argv[1:] if len(sys.argv) > 1 else ["status"]
    command = args[0]

    twin = LocalTwin()

    if command == "sync":
        from project_config import config as cfg
        seed = args[1] if len(args) > 1 else cfg.project.seed_profile
        twin.sync(seed=seed)

    elif command == "status":
        if twin.load():
            age = twin.age_hours
            age_str = f"{age:.1f} hours ago" if age is not None else "unknown"
            print(f"Twin loaded from disk")
            print(f"  Profiles: {twin.count}")
            print(f"  Relationships: {twin.edge_count}")
            print(f"  Last sync: {twin.synced_at} ({age_str})")
        else:
            print("No twin data on disk. Run: python -m wikitree.twin sync")

    elif command == "gaps":
        if not twin.load():
            print("No twin data. Run: python -m wikitree.twin sync")
            return

        no_bio = twin.without_bio()
        no_parents = twin.without_parents()
        no_dates = twin.without_dates()

        print(f"=== Profiles without bio ({len(no_bio)}) ===")
        for p in no_bio[:20]:
            _print_profile(p, p["wt_id"])

        print(f"\n=== Profiles without parents ({len(no_parents)}) ===")
        for p in no_parents[:20]:
            _print_profile(p, p["wt_id"])

        print(f"\n=== Profiles without dates ({len(no_dates)}) ===")
        for p in no_dates[:20]:
            missing = p.get("missing", "?")
            _print_profile(p, f"{p['wt_id']} [{missing}]")

    elif command == "show" and len(args) > 1:
        if not twin.load():
            print("No twin data. Run: python -m wikitree.twin sync")
            return
        wt_id = args[1]
        node = twin.get(wt_id)
        if not node:
            print(f"Profile {wt_id} not found")
            return
        print(f"=== {wt_id} ===")
        for key in sorted(node.keys()):
            val = node[key]
            if isinstance(val, str) and len(val) > 100:
                val = val[:100] + "..."
            elif isinstance(val, dict) and len(str(val)) > 100:
                val = f"{{...{len(val)} keys}}"
            print(f"  {key}: {val}")

        print(f"\nParents: {[p['wt_id'] for p in twin.parents_of(wt_id)]}")
        print(f"Children: {[c['wt_id'] for c in twin.children_of(wt_id)]}")
        print(f"Spouses: {[s['wt_id'] for s in twin.spouses_of(wt_id)]}")
        print(f"Siblings: {[s['wt_id'] for s in twin.siblings_of(wt_id)]}")

    elif command == "tree" and len(args) > 1:
        if not twin.load():
            print("No twin data. Run: python -m wikitree.twin sync")
            return
        wt_id = args[1]
        node = twin.get(wt_id)
        if not node:
            print(f"Profile {wt_id} not found")
            return

        name = f"{node.get('FirstName', '')} {node.get('LastNameAtBirth', '')}".strip()
        print(f"=== Ancestors of {name} ({wt_id}) ===")
        ancestors = twin.ancestors_of(wt_id, depth=10)
        for a in ancestors:
            indent = "  " * a.get("generation", 1)
            aname = f"{a.get('FirstName', '')} {a.get('LastNameAtBirth', '')}".strip()
            print(f"{indent}{a['wt_id']} {aname} b.{a.get('BirthDate', '?')}")

        print(f"\n=== Descendants of {name} ({wt_id}) ===")
        descendants = twin.descendants_of(wt_id, depth=10)
        for d in descendants:
            indent = "  " * d.get("generation", 1)
            dname = f"{d.get('FirstName', '')} {d.get('LastNameAtBirth', '')}".strip()
            print(f"{indent}{d['wt_id']} {dname} b.{d.get('BirthDate', '?')}")

    else:
        print("Usage: python -m wikitree.twin <command>")
        print("  sync    — Fetch all profiles from WikiTree API")
        print("  status  — Show twin age and counts")
        print("  gaps    — List profiles needing work")
        print("  show ID — Show one profile with relationships")
        print("  tree ID — Show ancestor/descendant tree")


if __name__ == "__main__":
    main()
