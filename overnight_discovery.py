"""Overnight discovery driver — recursive tree expansion via MCP.

BFS from seed profile IDs. For each profile:
  1. kick_off_research → wait for completion → get_research_result
  2. Query pending_facts; call approve_pending_fact on each whose
     source belongs to a trust-tier-1/2 host (FreeBMD, FreeREG,
     FreeCen, Probate, CWGC, Wirksworth, FamilySearch).
  3. Query leads created during this run; call promote_lead on
     father/mother/spouse leads with sufficient evidence.
  4. Enqueue any newly-created profile IDs (from promote_lead) so the
     BFS expands outward.

Requires:
  * MCP server built (`cd FieldResearcherMCP && swift build`).
  * Project sqlite path (the new empty discovery project, post-populator).
  * `ANCESTOR_MCP_AUTO_APPROVE=1` in the env so both approve_pending_fact
    and promote_lead pass their gates. The driver sets this automatically
    on the spawned MCP subprocess.

State + logging:
  * `--log-path overnight-<ts>.jsonl` — append-only per-event log.
  * `--state-path overnight-<ts>.state.json` — queue + seen-set snapshot
    after every profile; restart-safe.

Caps:
  * `--max-depth N` (default 4)
  * `--max-nodes N` (default 200)
  * `--max-wall-hours H` (default 8)
  * `--max-promotions-per-profile N` (default 3 — typically father + mother + spouse)

Usage:
  python overnight_discovery.py \\
    --db <new-project.sqlite> \\
    --seeds @I50098374@ @I50100747@ ...   # OR --seeds-from-db to pick up every profile
"""
import argparse
import json
import os
import sqlite3
import sys
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

# Reuse the harness's MCP client — it already handles retries on
# transient SQLite contention and the kick_off/poll/result protocol.
sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from run_harness import _SwiftMCPClient, _resolve_swift_mcp_binary  # type: ignore

# Trust-tier hosts that auto-approve maps to. Tier 1: government /
# canonical (FreeBMD GRO mirror, CWGC, UK Probate Calendar). Tier 2:
# volunteer / parish (FreeREG, FreeCen, Wirksworth). FamilySearch +
# FindAGrave + Familyhistory.com are NOT in this set — they require
# human review.
APPROVE_HOSTS = {
    "freebmd.org.uk",
    "www.freebmd.org.uk",
    "freereg.org.uk",
    "www.freereg.org.uk",
    "freecen.org.uk",
    "www.freecen.org.uk",
    "probatesearch.service.gov.uk",
    "www.cwgc.org",
    "cwgc.org",
    "wirksworth.org.uk",
    "www.wirksworth.org.uk",
}

PROMOTABLE_RELATIONSHIPS = {"father", "mother", "spouse"}


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat(timespec="seconds")


def host_of(url: str) -> str:
    if not url:
        return ""
    try:
        # Cheap host extraction — no urlparse needed for our cases.
        return url.split("//", 1)[-1].split("/", 1)[0].lower()
    except Exception:
        return ""


class JsonlLogger:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = self.path.open("a", encoding="utf-8")

    def event(self, kind: str, **fields) -> None:
        rec = {"ts": now_iso(), "kind": kind, **fields}
        self._fh.write(json.dumps(rec) + "\n")
        self._fh.flush()

    def close(self) -> None:
        self._fh.close()


def load_state(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text())
    return {"queue": [], "seen": [], "promotions_per_profile": {}, "started_at": now_iso()}


def save_state(path: Path, state: dict) -> None:
    path.write_text(json.dumps(state, indent=2))


def seed_from_db(db_path: Path) -> list[str]:
    with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as con:
        return [row[0] for row in con.execute(
            "SELECT id FROM profiles WHERE is_deleted = 0 ORDER BY id"
        ).fetchall()]


def pending_facts_for(db_path: Path, profile_id: str) -> list[dict]:
    """All open pending_facts on this profile.

    Status filter alone is sufficient — facts transition out of
    `readyForReview` on approve/reject/skip. The earlier created_at
    filter against the run's started_at compared Python ISO format
    against SQLite's space-separated Date format and silently
    returned empty.
    """
    with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as con:
        con.row_factory = sqlite3.Row
        rows = con.execute("""
            SELECT id, source_url, fact_kind
            FROM pending_facts
            WHERE profile_id = ?
              AND review_status = 'readyForReview'
        """, (profile_id,)).fetchall()
        return [dict(r) for r in rows]


def leads_for(db_path: Path, profile_id: str) -> list[dict]:
    """All open leads on this profile. Same status-only rationale
    as pending_facts_for — leads transition out of 'new' on
    promote/dismiss."""
    with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as con:
        con.row_factory = sqlite3.Row
        rows = con.execute("""
            SELECT id, relationship, name, surname, given_name, birth_year, death_year, evidence
            FROM leads
            WHERE profile_id = ?
              AND status = 'new'
        """, (profile_id,)).fetchall()
        return [dict(r) for r in rows]


def is_promotable(lead: dict) -> bool:
    rel = (lead.get("relationship") or "").lower()
    if rel not in PROMOTABLE_RELATIONSHIPS:
        return False
    # Surname must exist and not be empty.
    if not (lead.get("surname") or "").strip():
        return False
    # Given name normally required, BUT parent-inferred leads
    # (id prefix `lead_parentInferred_`) carry no given name by
    # design — the BMD index doesn't expose a parent's given
    # name. These leads create placeholder ancestor profiles
    # which the engine then researches to fill in the rest.
    is_parent_inferred = (lead.get("id") or "").startswith("lead_parentInferred_")
    if not is_parent_inferred and not (lead.get("given_name") or "").strip():
        return False
    # Evidence must be non-trivial.
    if len((lead.get("evidence") or "").strip()) < 20:
        return False
    return True


def process_profile(profile_id: str, depth: int, args, mcp, db_path: Path,
                    logger: JsonlLogger, state: dict) -> list[str]:
    """Run research + approve + promote for one profile. Returns the
    list of NEW profile IDs created during promotion (to enqueue)."""
    started = now_iso()
    started_secs = time.monotonic()
    logger.event("research_start", profile_id=profile_id, depth=depth)

    try:
        envelope = mcp.research_profile(profile_id, mode="extend", scope="county")
    except Exception as e:
        logger.event("research_error", profile_id=profile_id, depth=depth, error=str(e))
        return []

    secs = round(time.monotonic() - started_secs, 1)
    sup = len(envelope.get("supported_hypotheses") or [])
    inc = len(envelope.get("inconclusive_hypotheses") or [])
    cont = len(envelope.get("contradicted_hypotheses") or [])
    logger.event("research_done", profile_id=profile_id, depth=depth,
                 secs=secs, supported=sup, inconclusive=inc, contradicted=cont)

    # Throttle detection — Swift's circuit breaker shape per memory.
    if secs > 1300 and sup == 0:
        logger.event("throttle_suspected", profile_id=profile_id, secs=secs,
                     note="0 supported in ~1400s = FreeBMD circuit breaker")
        logger.event("cooldown_start", duration_minutes=120)
        time.sleep(120 * 60)
        logger.event("cooldown_end")

    # Auto-approve pending_facts from trust-tier hosts.
    approved = 0
    refused = 0
    for pf in pending_facts_for(db_path, profile_id):
        if host_of(pf.get("source_url", "")) not in APPROVE_HOSTS:
            continue
        try:
            result = mcp._tool_call("approve_pending_fact", {"pending_fact_id": pf["id"]})
            if result.get("status") == "approved":
                approved += 1
                logger.event("fact_approved", profile_id=profile_id,
                             pending_fact_id=pf["id"], field=pf.get("fact_kind"))
            else:
                refused += 1
                logger.event("fact_refused", profile_id=profile_id,
                             pending_fact_id=pf["id"], reason=result.get("reason"))
        except Exception as e:
            logger.event("fact_approve_error", profile_id=profile_id,
                         pending_fact_id=pf["id"], error=str(e))

    # Promote leads (father/mother/spouse only).
    new_profile_ids: list[str] = []
    promo_budget = args.max_promotions_per_profile
    promoted_this_round = state["promotions_per_profile"].setdefault(profile_id, 0)
    remaining_budget = max(promo_budget - promoted_this_round, 0)
    if remaining_budget == 0:
        logger.event("promote_budget_exhausted", profile_id=profile_id,
                     already_promoted=promoted_this_round)

    for lead in leads_for(db_path, profile_id):
        if remaining_budget <= 0:
            break
        if not is_promotable(lead):
            logger.event("lead_skipped", profile_id=profile_id, lead_id=lead["id"],
                         relationship=lead.get("relationship"),
                         reason="not_promotable")
            continue
        try:
            result = mcp._tool_call("promote_lead", {"lead_id": lead["id"]})
            if result.get("status") == "promoted":
                new_id = result.get("new_profile_id", "")
                new_profile_ids.append(new_id)
                state["promotions_per_profile"][profile_id] = promoted_this_round + 1
                promoted_this_round += 1
                remaining_budget -= 1
                logger.event("lead_promoted", profile_id=profile_id, lead_id=lead["id"],
                             new_profile_id=new_id, relationship=lead.get("relationship"),
                             name=lead.get("name"))
            else:
                logger.event("lead_refused", profile_id=profile_id, lead_id=lead["id"],
                             reason=result.get("reason"), detail=result.get("detail"))
        except Exception as e:
            logger.event("promote_error", profile_id=profile_id, lead_id=lead["id"], error=str(e))

    logger.event("profile_done", profile_id=profile_id, depth=depth, secs=secs,
                 approved=approved, refused=refused, promoted=len(new_profile_ids))
    return new_profile_ids


def catch_up_existing(profile_id: str, depth: int, args, mcp, db_path: Path,
                       logger: JsonlLogger, state: dict) -> list[str]:
    """Approve + promote already-existing open leads / pending_facts on a
    profile that was researched in a prior run but had the broken date
    filter on its leads/pending_facts queries. No new research kicked
    off — just the approve + promote step.

    Returns newly-created profile IDs to enqueue, same shape as
    process_profile."""
    logger.event("catch_up_start", profile_id=profile_id, depth=depth)

    approved = 0
    refused = 0
    for pf in pending_facts_for(db_path, profile_id):
        if host_of(pf.get("source_url", "")) not in APPROVE_HOSTS:
            continue
        try:
            result = mcp._tool_call("approve_pending_fact", {"pending_fact_id": pf["id"]})
            if result.get("status") == "approved":
                approved += 1
                logger.event("fact_approved", profile_id=profile_id,
                             pending_fact_id=pf["id"], field=pf.get("fact_kind"))
            else:
                refused += 1
                logger.event("fact_refused", profile_id=profile_id,
                             pending_fact_id=pf["id"], reason=result.get("reason"))
        except Exception as e:
            logger.event("fact_approve_error", profile_id=profile_id,
                         pending_fact_id=pf["id"], error=str(e))

    new_profile_ids: list[str] = []
    promo_budget = args.max_promotions_per_profile
    promoted_this_round = state["promotions_per_profile"].setdefault(profile_id, 0)
    remaining_budget = max(promo_budget - promoted_this_round, 0)

    for lead in leads_for(db_path, profile_id):
        if remaining_budget <= 0:
            break
        if not is_promotable(lead):
            continue
        try:
            result = mcp._tool_call("promote_lead", {"lead_id": lead["id"]})
            if result.get("status") == "promoted":
                new_id = result.get("new_profile_id", "")
                new_profile_ids.append(new_id)
                state["promotions_per_profile"][profile_id] = promoted_this_round + 1
                promoted_this_round += 1
                remaining_budget -= 1
                logger.event("lead_promoted", profile_id=profile_id, lead_id=lead["id"],
                             new_profile_id=new_id, relationship=lead.get("relationship"),
                             name=lead.get("name"))
            else:
                logger.event("lead_refused", profile_id=profile_id, lead_id=lead["id"],
                             reason=result.get("reason"))
        except Exception as e:
            logger.event("promote_error", profile_id=profile_id, lead_id=lead["id"], error=str(e))

    logger.event("catch_up_done", profile_id=profile_id, depth=depth,
                 approved=approved, refused=refused, promoted=len(new_profile_ids))
    return new_profile_ids


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, help="Target project sqlite (the new discovery project).")
    ap.add_argument("--seeds", nargs="+", help="Seed profile IDs.")
    ap.add_argument("--seeds-from-db", action="store_true",
                    help="Seed from every non-deleted profile already in the DB.")
    ap.add_argument("--max-depth", type=int, default=4)
    ap.add_argument("--max-nodes", type=int, default=200)
    ap.add_argument("--max-wall-hours", type=float, default=8.0)
    ap.add_argument("--max-promotions-per-profile", type=int, default=3)
    ap.add_argument("--log-path", default=None,
                    help="Override logger path. Default: eval/runs/overnight-<ts>.jsonl")
    ap.add_argument("--state-path", default=None,
                    help="Override state path. Default: eval/runs/overnight-<ts>.state.json")
    args = ap.parse_args()

    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        raise SystemExit(f"target db not found: {db_path}")

    if not args.seeds and not args.seeds_from_db:
        raise SystemExit("Provide --seeds <ids> or --seeds-from-db.")

    ts = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    log_path = Path(args.log_path or f"eval/runs/overnight-{ts}.jsonl")
    state_path = Path(args.state_path or f"eval/runs/overnight-{ts}.state.json")

    logger = JsonlLogger(log_path)

    state = load_state(state_path)
    if not state["queue"] and not state["seen"]:
        # Fresh run — seed the queue.
        seeds = args.seeds or seed_from_db(db_path)
        for s in seeds:
            state["queue"].append([s, 0])
        save_state(state_path, state)
        logger.event("run_start", seeds=seeds, max_depth=args.max_depth,
                     max_nodes=args.max_nodes, max_wall_hours=args.max_wall_hours)
    else:
        logger.event("run_resume", queue=len(state["queue"]), seen=len(state["seen"]))

    # Crucial: set env BEFORE spawning the MCP subprocess.
    env = os.environ.copy()
    env["ANCESTOR_MCP_AUTO_APPROVE"] = "1"
    os.environ["ANCESTOR_MCP_AUTO_APPROVE"] = "1"

    binary = _resolve_swift_mcp_binary()
    deadline = time.monotonic() + args.max_wall_hours * 3600

    queue = deque(tuple(item) for item in state["queue"])
    seen = set(state["seen"])

    # On resume: catch up already-seen profiles whose lead-promotion
    # was silently skipped by the v0 driver's broken created_at filter.
    # Idempotent — promote_lead's gate refuses already-resolved leads.
    needs_catch_up = bool(seen) and not state.get("caught_up_v1", False)

    try:
        with _SwiftMCPClient(binary, str(db_path),
                              poll_interval_s=5.0,
                              per_subject_timeout_s=1800.0) as mcp:
            if needs_catch_up:
                logger.event("catch_up_pass_start", seen_count=len(seen))
                for pid in sorted(seen):
                    new_ids = catch_up_existing(pid, 0, args, mcp, db_path, logger, state)
                    for new_id in new_ids:
                        if new_id and new_id not in seen:
                            queue.append((new_id, 1))
                state["caught_up_v1"] = True
                state["queue"] = [list(t) for t in queue]
                state["seen"] = sorted(seen)
                save_state(state_path, state)
                logger.event("catch_up_pass_done", new_in_queue=len(queue))

            while queue:
                if time.monotonic() > deadline:
                    logger.event("max_wall_hit", elapsed_hours=args.max_wall_hours)
                    break
                if len(seen) >= args.max_nodes:
                    logger.event("max_nodes_hit", seen_count=len(seen))
                    break

                profile_id, depth = queue.popleft()
                if profile_id in seen:
                    continue
                if depth > args.max_depth:
                    logger.event("max_depth_skip", profile_id=profile_id, depth=depth)
                    continue
                seen.add(profile_id)

                new_ids = process_profile(profile_id, depth, args, mcp, db_path, logger, state)
                for new_id in new_ids:
                    if new_id and new_id not in seen:
                        queue.append((new_id, depth + 1))

                # Persist state snapshot every profile.
                state["queue"] = [list(t) for t in queue]
                state["seen"] = sorted(seen)
                save_state(state_path, state)
    except KeyboardInterrupt:
        logger.event("interrupted")
    except Exception as e:
        logger.event("fatal_error", error=str(e))
        raise
    finally:
        logger.event("run_end", queue_remaining=len(queue), seen_count=len(seen))
        logger.close()

    print(f"\nDone. Log: {log_path}")
    print(f"State: {state_path}")
    print(f"Seen: {len(seen)} profiles")


if __name__ == "__main__":
    main()
