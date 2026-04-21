#!/usr/bin/env python3
"""Collect WikiTree state by walking outward from a seed profile.

Given a seed WikiTree ID, traverse `getRelatives` breadth-first until all
reachable profiles are known, then fetch each full profile (including
Bio) via the batched `getProfiles`. Persist the result to
`.wikitree-state.json` for downstream enrichment tooling.

The walk naturally stays inside the user's tree because WikiTree relatives
graph is tightly clustered around the ancestors of the seed person.

Commands:
  python wikitree_state.py refresh [SEED]   — re-walk and save full state
  python wikitree_state.py show WT_ID       — print a single profile
  python wikitree_state.py list             — list known profiles (Name, birth, death)
  python wikitree_state.py stats            — counts and summary
"""
import json
import sys
import time
from pathlib import Path

import os

from wikitree import WikiTreeAPI, get_bio_text

STATE_FILE = Path(__file__).parent / ".wikitree-state.json"
from project_config import config as _cfg
DEFAULT_SEED = _cfg.project.seed_profile or "Cauldwell-103"

# Hard cap on walk depth so a mis-linked celebrity profile doesn't drag in
# 10,000 distant cousins. The family tree is ~6 generations so 8 is plenty.
MAX_DEPTH = 8


def _extract_relative_ids(relatives_resp):
    """Pull WT Names (Smith-123) out of a getRelatives response.

    Response shape: a list where each item has an "items" list; each
    item has Spouses/Children/Parents/Siblings dicts keyed by Id.
    """
    ids = set()
    if not isinstance(relatives_resp, list):
        return ids
    for item in relatives_resp:
        if not isinstance(item, dict):
            continue
        for container in item.get("items") or []:
            if not isinstance(container, dict):
                continue
            person = container.get("person") or {}
            for rel_key in ("Spouses", "Children", "Parents", "Siblings"):
                rel = person.get(rel_key) or {}
                if isinstance(rel, dict):
                    for _id, rel_person in rel.items():
                        if isinstance(rel_person, dict) and rel_person.get("Name"):
                            ids.add(rel_person["Name"])
                elif isinstance(rel, list):
                    # occasionally comes back as a list when empty
                    pass
    return ids


def walk_tree(api, seed=DEFAULT_SEED, max_depth=MAX_DEPTH):
    """BFS walk via getRelatives. Returns set of WT IDs (Name field)."""
    known = {seed}
    frontier = {seed}
    depth = 0
    while frontier and depth < max_depth:
        print(f"  depth {depth}: {len(frontier)} to expand, "
              f"{len(known)} total known", flush=True)
        batch = list(frontier)
        next_frontier = set()
        # getRelatives accepts batched keys, same 100-limit as getProfiles
        for i in range(0, len(batch), 100):
            chunk = batch[i:i + 100]
            resp = api.get_relatives(chunk)
            new_ids = _extract_relative_ids(resp)
            next_frontier |= new_ids
            time.sleep(0.3)
        next_frontier -= known
        known |= next_frontier
        frontier = next_frontier
        depth += 1
    print(f"  walk complete: {len(known)} profiles across {depth} levels",
          flush=True)
    return known


def refresh(api=None, seed=DEFAULT_SEED):
    """Walk tree + fetch full profiles; persist to STATE_FILE.

    If `api` is not provided, creates one from WIKITREE_EMAIL/WIKITREE_PASSWORD
    environment variables.
    """
    if api is None:
        api = WikiTreeAPI(
            email=os.environ.get("WIKITREE_EMAIL", ""),
            password=os.environ.get("WIKITREE_PASSWORD", ""),
        )
        me = api.login()
    else:
        me = api.whoami()
        if not me:
            raise SystemExit("✗ API session not authenticated. "
                             "Run `python -m wikitree login` first.")
    print(f"Authenticated as {me['user_name']} "
          f"(watchlist={me['watchlist_count']})")

    print(f"\nWalking from seed {seed}...")
    all_ids = walk_tree(api, seed=seed)

    print(f"\nFetching {len(all_ids)} full profiles...")
    def report(done, total):
        print(f"  {done}/{total}", flush=True)
    profiles = api.get_profiles(sorted(all_ids), progress=report)

    state = {
        "seed": seed,
        "fetched_at": int(time.time()),
        "authenticated_as": me["user_name"],
        "count": len(profiles),
        "profiles": profiles,
    }
    STATE_FILE.write_text(json.dumps(state, indent=2, default=str))
    print(f"\n✓ Saved {len(profiles)} profiles to {STATE_FILE}")
    return state


def load_state():
    if not STATE_FILE.exists():
        raise SystemExit(f"No state file at {STATE_FILE}. "
                         f"Run `python wikitree_state.py refresh` first.")
    return json.loads(STATE_FILE.read_text())


def _cli():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "refresh":
        seed = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_SEED
        refresh(seed=seed)
    elif cmd == "show":
        if len(sys.argv) < 3:
            print("Usage: wikitree_state.py show WT_ID")
            sys.exit(1)
        wt_id = sys.argv[2]
        state = load_state()
        profile = state["profiles"].get(wt_id)
        if not profile:
            print(f"No profile for {wt_id} in state "
                  f"(known: {state['count']}; "
                  f"last refreshed {state['fetched_at']}).")
            sys.exit(1)
        # Drop bio for terminal display; show preview
        bio = get_bio_text(profile)
        profile.pop("bio", None)
        profile.pop("Bio", None)
        print(json.dumps(profile, indent=2, default=str))
        if bio:
            print(f"\n[bio: {len(bio)} chars — preview]\n{bio[:500]}...")
    elif cmd == "list":
        state = load_state()
        rows = []
        for name, p in state["profiles"].items():
            birth = p.get("BirthDate") or p.get("BirthDateDecade") or ""
            death = p.get("DeathDate") or p.get("DeathDateDecade") or ""
            first = p.get("FirstName") or ""
            last = p.get("LastNameAtBirth") or ""
            rows.append((name, f"{first} {last}".strip(), birth, death))
        rows.sort(key=lambda r: (r[2] or "9999", r[1]))
        for name, who, b, d in rows:
            print(f"  {name:30s}  {who:35s}  {b:12s}  {d}")
    elif cmd == "stats":
        state = load_state()
        profs = state["profiles"].values()
        living = sum(1 for p in profs if p.get("IsLiving") == 1)
        with_bio = sum(1 for p in profs if get_bio_text(p))
        with_birth = sum(1 for p in profs if p.get("BirthDate"))
        with_death = sum(1 for p in profs if p.get("DeathDate"))
        print(f"State: {STATE_FILE}")
        print(f"  Seed:             {state['seed']}")
        print(f"  Authenticated as: {state.get('authenticated_as')}")
        print(f"  Fetched at:       {state['fetched_at']}")
        print(f"  Profiles:         {state['count']}")
        print(f"  Living:           {living}")
        print(f"  With bio:         {with_bio}")
        print(f"  With BirthDate:   {with_birth}")
        print(f"  With DeathDate:   {with_death}")
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    _cli()
