"""
§5.8.6 eval harness runner.

Loads the certified corpus YAMLs and the GEDCOM-citation sidecar JSON,
invokes the research pipeline against each subject, and emits per-kind
precision/recall + a single headline number suitable for commit-message
deltas.

Backends:
  --backend python    (default) — in-process call to `agent.pipeline.research_person`
  --backend mock                — empty envelope (skeleton plumbing)
  --backend swift-mcp           — out-of-process call to the Swift app via
                                  FieldResearcherMCP. Requires a pre-built
                                  binary and a pre-provisioned test DB; see
                                  SWIFT_MCP_EVAL_BACKEND_SPEC §5.

Run from repo root:
    python eval/run_harness.py
    python eval/run_harness.py --only @I50113363@           # single subject
    python eval/run_harness.py --backend mock               # no live HTTP
    python eval/run_harness.py --backend swift-mcp \
        --db-path ~/Library/Application\\ Support/AncestorResearchEval/test-corpus.sqlite
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import yaml

# Make `agent.*` and sibling eval modules importable when invoked as
# `python eval/run_harness.py`
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from citation_matcher import count_reproduced  # noqa: E402


# --- Data loading ----------------------------------------------------------

def load_corpus(corpus_dir: Path) -> list[dict]:
    """Load every *.yaml in corpus_dir (skipping files starting with _)."""
    subjects: list[dict] = []
    for path in sorted(corpus_dir.glob("*.yaml")):
        if path.name.startswith("_"):
            continue
        with path.open() as f:
            data = yaml.safe_load(f)
        data["_path"] = str(path)
        subjects.append(data)
    return subjects


def load_gedcom_citations(json_path: Path) -> dict:
    """Load the _gedcom_citations.json sidecar."""
    if not json_path.exists():
        return {}
    return json.loads(json_path.read_text())


def extract_subject_ids(subject: dict) -> list[str]:
    """Each YAML may name a single profile, a pair, or a cluster.
    Return the list of profile IDs the subject covers."""
    if "profile_id" in subject:
        return [subject["profile_id"]]
    if "subjects" in subject:
        return [s["profile_id"] for s in subject["subjects"]]
    if "cluster_a_should_merge" in subject:
        ids = list(subject["cluster_a_should_merge"].get("members", []))
        ids += list(subject.get("cluster_b_must_remain_separate", {}).get("members", []))
        return ids
    return []


def subject_label(subject: dict) -> str:
    """Short human-readable label for a corpus subject."""
    if "canonical_name" in subject:
        return subject["canonical_name"]
    if "subjects" in subject and subject["subjects"]:
        return f"{subject['subjects'][0].get('canonical_name', '?')} (pair)"
    if "cluster_a_should_merge" in subject:
        return subject["cluster_a_should_merge"].get("canonical_name", "cluster")
    return "?"


# --- Pipeline backends -----------------------------------------------------

def _mock_pipeline_call(subject: dict) -> dict:
    """Empty envelope — used to validate the harness's metric plumbing
    without making any live HTTP calls."""
    return {
        "supported_hypotheses": [],
        "contradicted_hypotheses": [],
        "inconclusive_hypotheses": [],
        "discovered_citations": [],
        "mocked": True,
    }


_MONTHS = {
    "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
    "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
}


def _parse_year_from_gedcom_date(value) -> int | None:
    """Pull a 4-digit year out of a GEDCOM-style date like "DEC 1887",
    "12 NOV 1904", "1841", or a yaml int."""
    if value is None:
        return None
    if isinstance(value, int):
        return value if 1500 < value < 2100 else None
    m = re.search(r"\b(1[5-9]\d{2}|20\d{2})\b", str(value))
    return int(m.group(1)) if m else None


def _gender_from_relationships(subject: dict) -> str | None:
    """No explicit gender field on most subjects — leave None and let
    the pipeline treat it as unknown (it gates military-service search
    on M only)."""
    return None


def _seed_year(seed_facts: list, field: str) -> int | None:
    for sf in seed_facts or []:
        if sf.get("field") == field:
            return _parse_year_from_gedcom_date(sf.get("value"))
    return None


def _seed_location(seed_facts: list, field: str) -> str | None:
    for sf in seed_facts or []:
        if sf.get("field") == field:
            return sf.get("value")
    return None


def _subject_to_persons(subject: dict) -> list[dict]:
    """Extract one or more `research_person`-shaped person dicts from a
    corpus YAML. Handles single / pair / cluster variants."""
    persons: list[dict] = []

    def build(name: str, seed_facts: list, location: str | None = None) -> dict:
        birth_year = _seed_year(seed_facts, "birthDate")
        death_year = _seed_year(seed_facts, "deathDate")
        birth_location = location or _seed_location(seed_facts, "birthLocation") or "England"
        return {
            "name": name,
            "birth_year": birth_year,
            "death_year": death_year,
            "gender": _gender_from_relationships(subject),
            "birth_location": birth_location,
            "provided_family": [],
        }

    # Single subject
    if "profile_id" in subject:
        persons.append(build(
            subject.get("canonical_name", "?"),
            subject.get("seed_facts") or [],
        ))
        return persons

    # Pair: subjects: [...]
    if "subjects" in subject:
        for s in subject["subjects"]:
            persons.append(build(
                s.get("canonical_name", "?"),
                s.get("seed_facts") or [],
            ))
        return persons

    # Cluster: one merged canonical + (optionally) a separate cluster_b
    if "cluster_a_should_merge" in subject:
        a = subject["cluster_a_should_merge"]
        persons.append(build(
            a.get("canonical_name", "?").split(" → ")[0],  # use pre-marriage form
            a.get("seed_facts") or [],
        ))
        b = subject.get("cluster_b_must_remain_separate") or {}
        if b.get("canonical_name") and b.get("seed_facts"):
            persons.append(build(
                b.get("canonical_name", "?"),
                b.get("seed_facts") or [],
            ))
        return persons

    return persons


def _state_to_envelope(state: dict) -> dict:
    """Map a `research_person` state dict to the harness envelope.

    - confirmed_facts → supported_hypotheses, but exclude the
      "user-provided" stub fact emitted by the unsearchable-person
      short-circuit (would otherwise hand a free supported hit to the
      hallucination-guardrail subject).
    - rejected_records → contradicted_hypotheses
    - lead_candidates → inconclusive_hypotheses
    - confirmed_facts.sources → discovered_citations (flattened)
    """
    supported = []
    citations = []
    for fact in state.get("confirmed_facts") or []:
        sources = fact.get("sources") or []
        if sources == ["user-provided"]:
            continue
        supported.append({
            "kind": fact.get("type", "unknown"),
            "value": fact.get("value"),
            "sources": sources,
            "confidence": fact.get("confidence"),
        })
        citations.extend(sources)

    contradicted = [
        {"value": r.get("record"), "reason": r.get("reason")}
        for r in state.get("rejected_records") or []
    ]
    inconclusive = [
        {
            "kind": lc.get("search_type"),
            "summary": lc.get("record_summary"),
            "source": lc.get("source"),
            "reasons": lc.get("reasons"),
        }
        for lc in state.get("lead_candidates") or []
    ]

    return {
        "supported_hypotheses": supported,
        "contradicted_hypotheses": contradicted,
        "inconclusive_hypotheses": inconclusive,
        "discovered_citations": citations,
        "parent_link_verdict": state.get("parent_link_verdict"),
        "identity_verdict": state.get("identity_verdict"),
        "spouse_verdict": state.get("spouse_verdict"),
        "mocked": False,
    }


def _python_pipeline_call(subject: dict) -> dict:
    """In-process call to `agent.pipeline.research_person`, once per
    person extracted from the subject (single / pair / cluster), with
    results aggregated into one envelope."""
    from agent.pipeline import research_person

    persons = _subject_to_persons(subject)
    if not persons:
        return {
            "supported_hypotheses": [],
            "contradicted_hypotheses": [],
            "inconclusive_hypotheses": [],
            "discovered_citations": [],
            "mocked": False,
            "_note": "no persons extracted from subject",
        }

    aggregated = {
        "supported_hypotheses": [],
        "contradicted_hypotheses": [],
        "inconclusive_hypotheses": [],
        "discovered_citations": [],
        "mocked": False,
    }
    parent_link_verdicts: list[str | None] = []
    identity_verdicts: list[str | None] = []
    spouse_verdicts: list[str | None] = []
    for person in persons:
        state = research_person(person)
        envelope = _state_to_envelope(state)
        for key in ("supported_hypotheses", "contradicted_hypotheses",
                    "inconclusive_hypotheses", "discovered_citations"):
            aggregated[key].extend(envelope[key])
        parent_link_verdicts.append(envelope.get("parent_link_verdict"))
        identity_verdicts.append(envelope.get("identity_verdict"))
        spouse_verdicts.append(envelope.get("spouse_verdict"))

    # Strongest verdict across members: supported > contradicted > inconclusive.
    # None values are ignored unless every member is None (then result is None).
    def _strongest(verdicts: list[str | None]) -> str | None:
        non_none = [v for v in verdicts if v is not None]
        if not non_none:
            return None
        if "supported" in non_none:
            return "supported"
        if "contradicted" in non_none:
            return "contradicted"
        return "inconclusive"

    aggregated["parent_link_verdict"] = _strongest(parent_link_verdicts)
    aggregated["identity_verdict"] = _strongest(identity_verdicts)
    aggregated["spouse_verdict"] = _strongest(spouse_verdicts)

    # Pair/cluster subjects research the same person twice (one run per
    # member). The pipeline finds the same source records each time, so
    # the aggregate would double-count without this dedupe. Key shape
    # matches what _state_to_envelope emits per category.
    if len(persons) > 1:
        aggregated["supported_hypotheses"] = _dedupe(
            aggregated["supported_hypotheses"], key=lambda h: (h.get("kind"), h.get("value")))
        aggregated["contradicted_hypotheses"] = _dedupe(
            aggregated["contradicted_hypotheses"], key=lambda h: h.get("value"))
        aggregated["inconclusive_hypotheses"] = _dedupe(
            aggregated["inconclusive_hypotheses"], key=lambda h: (h.get("kind"), h.get("summary")))
        aggregated["discovered_citations"] = _dedupe(
            aggregated["discovered_citations"], key=lambda s: s)
    return aggregated


def _dedupe(items: list, key) -> list:
    seen = set()
    out = []
    for item in items:
        k = key(item)
        if k in seen:
            continue
        seen.add(k)
        out.append(item)
    return out


# --- Swift MCP backend -----------------------------------------------------
#
# Spawns FieldResearcherMCP as a subprocess and speaks line-delimited
# JSON-RPC over its stdin / stdout. One process per harness run, reused
# across all subjects (spec §5.2). See SWIFT_MCP_EVAL_BACKEND_SPEC for
# the contract.

_SWIFT_MCP_DEFAULT_DB = (
    "~/Library/Application Support/AncestorResearchEval/test-corpus.sqlite"
)
# Debug-first so a recently-rebuilt debug binary takes precedence over
# a stale release artifact. Release is the eventual shipping target
# (spec §5.2's example) but is only the right choice once someone has
# actually run `swift build -c release` recently. Override either with
# --mcp-binary.
_SWIFT_MCP_BINARY_CANDIDATES = (
    "FieldResearcherMCP/.build/debug/FieldResearcherMCP",
    "FieldResearcherMCP/.build/release/FieldResearcherMCP",
)


class _SwiftMCPClient:
    """Minimal JSON-RPC stdio client for FieldResearcherMCP."""

    def __init__(self, binary_path: str, db_path: str,
                 poll_interval_s: float = 3.0,
                 per_subject_timeout_s: float = 600.0):
        self.binary_path = binary_path
        self.db_path = db_path
        self.poll_interval_s = poll_interval_s
        self.per_subject_timeout_s = per_subject_timeout_s
        self.proc: subprocess.Popen | None = None
        self._next_id = 1

    def start(self) -> None:
        self.proc = subprocess.Popen(
            [self.binary_path, self.db_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        # MCP handshake — initialize then notify/initialized. The server
        # is forgiving but the contract expects both.
        self._call("initialize", {"protocolVersion": "2024-11-05",
                                   "clientInfo": {"name": "eval-harness",
                                                  "version": "1.0"},
                                   "capabilities": {}})
        self._notify("notifications/initialized", {})

    def stop(self) -> None:
        if self.proc is None:
            return
        try:
            if self.proc.stdin and not self.proc.stdin.closed:
                self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.proc = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()

    # --- JSON-RPC plumbing ---

    def _send(self, payload: dict) -> None:
        assert self.proc and self.proc.stdin
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def _read_line(self) -> dict:
        assert self.proc and self.proc.stdout
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("MCP server closed stdout unexpectedly")
        return json.loads(line)

    def _notify(self, method: str, params: dict) -> None:
        # Notifications have no id and expect no response.
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def _call(self, method: str, params: dict) -> dict:
        rid = self._next_id
        self._next_id += 1
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        # MCP is request/response in lockstep; the next line is our reply.
        while True:
            resp = self._read_line()
            if resp.get("id") != rid:
                # Defensive — the server should reply in order, but if a
                # stray notification appears, skip it.
                continue
            if "error" in resp:
                raise RuntimeError(f"MCP error on {method}: {resp['error']}")
            return resp.get("result", {})

    # --- High-level operations ---

    def _tool_call_text(self, name: str, args: dict) -> str:
        """Invoke a tool and return the raw text content (no JSON parse).

        Retries on transient SQLite contention. The running Ancestor
        Research app and the MCP server both open the same DB via
        GRDB's DatabaseQueue (DELETE journal mode, not WAL), so the
        watcher's write windows briefly block MCP reads. Backed-off
        retry rides those out without surfacing as a harness failure.
        """
        last_error: Exception | None = None
        for attempt in range(8):
            try:
                result = self._call("tools/call", {"name": name, "arguments": args})
                content = result.get("content") or []
                if not content or "text" not in content[0]:
                    raise RuntimeError(f"{name}: no text content in response: {result}")
                return content[0]["text"]
            except RuntimeError as e:
                msg = str(e)
                if "database is locked" not in msg and "SQLite error 5" not in msg:
                    raise
                last_error = e
                time.sleep(0.5 * (attempt + 1))  # 0.5s, 1s, 1.5s, ... up to 4s
        raise last_error or RuntimeError(f"{name}: exhausted retries")

    def _tool_call(self, name: str, args: dict) -> dict:
        """Invoke a tool that returns JSON-as-text; parse back to a dict."""
        text = self._tool_call_text(name, args)
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            raise RuntimeError(f"{name}: response was not JSON: {text[:200]}")

    # kick_off_research is the only tool we use that returns human
    # prose rather than JSON — that shape is intentional (Claude Code
    # users invoke it interactively). Extract the request_id with a
    # narrow regex against the documented sentence.
    _KICK_OFF_REQUEST_ID_RE = re.compile(r"request_id:\s*(req_[0-9A-Fa-f-]+)")

    def research_profile(self, profile_id: str,
                          mode: str = "extend",
                          scope: str = "county") -> dict:
        """Kick off research for one profile and return its envelope.

        Three-step protocol (SWIFT_MCP_EVAL_BACKEND_SPEC §3):
            1. kick_off_research → request_id
            2. poll get_run_status → status == completed, run_id
            3. get_research_result(run_id) → envelope
        """
        queued_text = self._tool_call_text("kick_off_research", {
            "profile_id": profile_id, "mode": mode, "scope": scope,
        })
        m = self._KICK_OFF_REQUEST_ID_RE.search(queued_text)
        if not m:
            raise RuntimeError(f"kick_off_research returned no request_id: {queued_text[:200]}")
        request_id = m.group(1)

        deadline = time.monotonic() + self.per_subject_timeout_s
        run_id: str | None = None
        while time.monotonic() < deadline:
            status = self._tool_call("get_run_status", {"request_id": request_id})
            state = status.get("status")
            if state == "completed":
                run_id = status.get("run_id")
                break
            if state == "failed":
                raise RuntimeError(f"research run failed: {status.get('error', '?')}")
            time.sleep(self.poll_interval_s)
        if run_id is None:
            raise TimeoutError(
                f"research for {profile_id} did not complete within "
                f"{self.per_subject_timeout_s}s"
            )

        envelope = self._tool_call("get_research_result", {"run_id": run_id})
        if "error" in envelope:
            raise RuntimeError(f"get_research_result: {envelope['error']}")
        return envelope


def _resolve_swift_mcp_binary() -> str:
    """Pick the first FieldResearcherMCP binary that exists, preferring
    release over debug. Raises a helpful error if neither is built."""
    repo_root = Path(__file__).resolve().parents[1]
    for rel in _SWIFT_MCP_BINARY_CANDIDATES:
        candidate = repo_root / rel
        if candidate.exists():
            return str(candidate)
    raise FileNotFoundError(
        "FieldResearcherMCP binary not found. Build with: "
        "`cd FieldResearcherMCP && swift build [-c release]`"
    )


def _resolve_swift_mcp_db_path(cli_path: str | None) -> str:
    """Pick the test DB path. Precedence: --db-path, $ANCESTOR_EVAL_DB,
    documented default (spec §5.1)."""
    raw = cli_path or os.environ.get("ANCESTOR_EVAL_DB") or _SWIFT_MCP_DEFAULT_DB
    path = os.path.expanduser(raw)
    if not Path(path).exists():
        raise FileNotFoundError(
            f"Swift-MCP test database not found at {path}. "
            "Provision it manually (spec §5.1): launch Ancestor Research, "
            "import Cauldwell Family Tree.twin-export.ged into a project "
            "named `eval-corpus`, copy the resulting .sqlite to the path "
            "above, or pass --db-path / set ANCESTOR_EVAL_DB."
        )
    return path


def _swift_mcp_pipeline_call(subject: dict, client: _SwiftMCPClient) -> dict:
    """Drive FieldResearcherMCP for one corpus subject, aggregating
    across pair/cluster members. Output shape matches
    `_python_pipeline_call` so the metric layer is backend-agnostic.

    Per-person failures (timeout, MCP error) are logged but don't
    abort the whole run — the subject ends up with whatever envelopes
    succeeded plus a `_partial_failure` note. Lets a single misbehaving
    cluster member not lose the other 11 subjects of work.
    """
    profile_ids = extract_subject_ids(subject)
    if not profile_ids:
        return {
            "supported_hypotheses": [],
            "contradicted_hypotheses": [],
            "inconclusive_hypotheses": [],
            "discovered_citations": [],
            "mocked": False,
            "_note": "no profile_ids extracted from subject",
        }

    aggregated = {
        "supported_hypotheses": [],
        "contradicted_hypotheses": [],
        "inconclusive_hypotheses": [],
        "discovered_citations": [],
        "mocked": False,
    }
    parent_link_verdicts: list[str | None] = []
    identity_verdicts: list[str | None] = []
    spouse_verdicts: list[str | None] = []
    failures: list[str] = []
    for pid in profile_ids:
        try:
            envelope = client.research_profile(pid)
        except (TimeoutError, RuntimeError) as e:
            print(f"  ! {pid}: {type(e).__name__}: {e}", file=sys.stderr)
            failures.append(f"{pid}: {type(e).__name__}: {e}")
            continue
        for key in ("supported_hypotheses", "contradicted_hypotheses",
                    "inconclusive_hypotheses", "discovered_citations"):
            aggregated[key].extend(envelope.get(key) or [])
        parent_link_verdicts.append(envelope.get("parent_link_verdict"))
        identity_verdicts.append(envelope.get("identity_verdict"))
        spouse_verdicts.append(envelope.get("spouse_verdict"))
        # Diagnostic fields — pass through, accumulate across person-runs.
        for key in ("_throttled", "_dispatch_log"):
            existing = aggregated.setdefault(key, [])
            existing.extend(envelope.get(key) or [])
    if failures:
        aggregated["_partial_failure"] = failures

    def _strongest(verdicts: list[str | None]) -> str | None:
        non_none = [v for v in verdicts if v is not None]
        if not non_none:
            return None
        if "supported" in non_none:
            return "supported"
        if "contradicted" in non_none:
            return "contradicted"
        return "inconclusive"

    aggregated["parent_link_verdict"] = _strongest(parent_link_verdicts)
    aggregated["identity_verdict"] = _strongest(identity_verdicts)
    aggregated["spouse_verdict"] = _strongest(spouse_verdicts)

    if len(profile_ids) > 1:
        aggregated["supported_hypotheses"] = _dedupe(
            aggregated["supported_hypotheses"], key=lambda h: (h.get("kind"), h.get("value")))
        aggregated["contradicted_hypotheses"] = _dedupe(
            aggregated["contradicted_hypotheses"], key=lambda h: h.get("value"))
        aggregated["inconclusive_hypotheses"] = _dedupe(
            aggregated["inconclusive_hypotheses"], key=lambda h: (h.get("kind"), h.get("summary")))
        aggregated["discovered_citations"] = _dedupe(
            aggregated["discovered_citations"], key=lambda s: s)
    return aggregated


# --- Metric computation ----------------------------------------------------

# Map expected_per_kind keys to the pipeline fact-type tokens that
# would land in `supported_hypotheses[].kind` for that kind. parent_link
# and identity_disambiguation use explicit per-state verdicts emitted by
# the pipeline (see `_actual_verdict_for_kind`).
_KIND_FACT_TYPES: dict[str, set[str]] = {
    # Pre-1837 baptisms substitute for a civil birth registration in
    # FreeREG parish data; count them toward birth_disambiguation so
    # pre-civil-registration subjects (e.g. Stephen Sherwin b.1774)
    # aren't penalised for the registration era.
    "birth_disambiguation": {"birth", "birth_registration", "baptism"},
    # A CWGC war-grave record is the authoritative death record for
    # casualties who died abroad (no civil GRO entry exists). Count
    # `military` fact-types toward death_disambiguation too — see
    # eval/certified/I50110493_robert_cauldwell.yaml (foreign-record
    # axis: corpus expects CWGC to satisfy death_disambiguation).
    "death_disambiguation": {"death", "death_registration", "military", "war_grave", "cwgc"},
    "marriage_disambiguation": {"marriage", "marriage_registration"},
    # FreeREG parish burial is the canonical death record for rural
    # subjects whose passing wasn't civilly registered (Stephen
    # Sherwin's 1858 Brassington burial is the headline case).
    "burial_disambiguation": {"burial"},
    "baptism_disambiguation": {"baptism"},
    "military_service": {"military", "war_grave", "cwgc"},
}


def _actual_verdict_for_kind(kind: str, pipeline_result: dict, full_kind: str | None = None) -> str | None:
    """Derive 'supported' / 'contradicted' / 'inconclusive' for one kind
    from the envelope, or None if we can't measure it (kind isn't
    directly emitted by the pipeline).

    Rules:
      - supported   : ≥1 supported hypothesis of one of the kind's types
      - contradicted: no supported but ≥1 contradicted hint that matches
      - inconclusive: neither
    """
    if kind == "spouse_disambiguation":
        # Pipeline emits an explicit spouse_verdict from three signals
        # (post-1912 FreeBMD spouse name, household co-residence, twin
        # spouse edges) — see agent/pipeline.py:_emit_spouse_verdict.
        # That's strictly more capable than the old harness-side regex
        # which only handled signal 1 and missed Robert (pre-1912
        # marriage, spouse only visible via CWGC next-of-kin + twin).
        return pipeline_result.get("spouse_verdict")

    # Pipeline-emitted explicit verdicts (added for §5.8 per-kind metric).
    if kind == "parent_link":
        return pipeline_result.get("parent_link_verdict")
    if kind == "identity_disambiguation":
        # Single-subject identity (e.g. John pair "are these the same
        # person?") collapses to the aggregated identity_verdict — that
        # works.
        #
        # Per-cluster identity (e.g. Mabel's `identity_disambiguation.
        # cluster_b: contradicted` — "did the pipeline correctly NOT
        # merge cluster_b's people with cluster_a's?") is a different
        # question. The pipeline doesn't yet emit a merge-decision
        # signal between two profile IDs, so cluster-level verdicts are
        # unmeasurable from the current envelope. Returning None marks
        # them as unmeasured rather than spuriously claiming the
        # aggregated single-subject value. The kinship-verification
        # harness mode (task 12) is the right home for this.
        if full_kind and full_kind.startswith("identity_disambiguation.cluster_"):
            return None
        return pipeline_result.get("identity_verdict")

    fact_types = _KIND_FACT_TYPES.get(kind)
    if fact_types is None:
        return None  # unmeasured

    supported = pipeline_result.get("supported_hypotheses", []) or []
    if any(h.get("kind") in fact_types for h in supported):
        return "supported"
    # `contradicted_hypotheses` holds rejected_records — these are
    # records that failed name/date/geography gates, mostly OTHER
    # people. A real "contradicted" verdict would require evidence
    # against the proposed hypothesis (e.g. found person alive after
    # proposed death date), which the envelope doesn't currently
    # carry. Until the pipeline emits structured contradictions, the
    # honest verdict when no supported fact lands is "inconclusive".
    return "inconclusive"


def _per_kind_agreement(expected_kinds: dict, pipeline_result: dict) -> dict:
    """For each expected_per_kind key, compute actual verdict and
    whether it agrees with expected. Nested dicts (cluster_a/cluster_b
    under identity_disambiguation) are flattened with dot-keys.

    Returns a flat dict of `{key: {expected, actual, agree}}`.
    """
    flat = {}
    for k, v in expected_kinds.items():
        if isinstance(v, dict):
            for sub_k, sub_v in v.items():
                flat[f"{k}.{sub_k}"] = sub_v
        else:
            flat[k] = v

    out = {}
    for kind, expected in flat.items():
        # Strip suffix from compound keys for verdict derivation. The
        # full kind (with suffix) is passed too so per-cluster cases
        # like `identity_disambiguation.cluster_b` can opt out of the
        # single-subject verdict — they require a merge-decision signal
        # the pipeline doesn't currently emit.
        base_kind = kind.split(".", 1)[0]
        actual = _actual_verdict_for_kind(base_kind, pipeline_result, full_kind=kind)
        out[kind] = {
            "expected": expected,
            "actual": actual,
            "agree": _verdicts_agree(expected, actual) if actual is not None else None,
        }
    return out


def _verdicts_agree(expected: str, actual: str) -> bool:
    """Compare expected vs actual verdict, tolerant of annotated forms.

    The corpus authors needed to express richer outcomes than the simple
    supported/contradicted/inconclusive trichotomy — verdicts like
    `supported_with_district_anomaly`, `supported_via_matched_page`,
    `supported_with_year_correction`. These are semantically `supported`
    with a why-tag; the pipeline emits the bare verdict, so a strict
    `==` registers a false ✗.

    Normalise both sides to the base verdict (first underscore-separated
    token) and compare those. `out_of_scope` and `not_yet_verified` are
    treated as `inconclusive` because that's the pipeline's behaviour
    when it has nothing to claim.
    """
    return _normalise_verdict(expected) == _normalise_verdict(actual)


_VERDICT_BASE_ALIASES = {
    "out_of_scope": "inconclusive",
    "not_yet_verified": "inconclusive",
}


def _normalise_verdict(v) -> str:
    """Pull a verdict down to its base form: 'supported_with_X' → 'supported'."""
    if not isinstance(v, str):
        return str(v)
    # supported_with_*, supported_via_*, contradicted_by_*, etc.
    for base in ("supported", "contradicted", "inconclusive"):
        if v == base or v.startswith(f"{base}_"):
            return base
    return _VERDICT_BASE_ALIASES.get(v, v)


def compute_metrics(subject: dict, pipeline_result: dict, gedcom_cites: list[dict]) -> dict:
    """Compute precision / recall / contradiction-count / reproduction-rate
    for one subject. All metrics are tolerant of missing fields — skeleton
    output must be a valid metrics envelope even when the pipeline returns
    nothing."""
    expected_kinds: dict = subject.get("expected_per_kind", {}) or {}
    expected_supported = int(subject.get("expected_supported_count") or 0)

    supported = pipeline_result.get("supported_hypotheses", []) or []
    contradicted = pipeline_result.get("contradicted_hypotheses", []) or []
    discovered = pipeline_result.get("discovered_citations", []) or []

    reproduction_target = len(gedcom_cites)
    reproduced = count_reproduced(gedcom_cites, discovered)

    is_guardrail = "hallucination_guardrail" in (subject.get("difficulty_axes") or [])
    guardrail_violation = is_guardrail and len(supported) > 0

    per_kind = _per_kind_agreement(expected_kinds, pipeline_result)

    return {
        "expected_supported_count": expected_supported,
        "reported_supported_count": len(supported),
        "contradiction_count": len(contradicted),
        "reproduction_target": reproduction_target,
        "reproduced_count": reproduced,
        "reproduction_rate": (reproduced / reproduction_target) if reproduction_target else None,
        "is_guardrail": is_guardrail,
        "guardrail_violation": guardrail_violation,
        "expected_per_kind": expected_kinds,
        "per_kind_agreement": per_kind,
        "mocked": pipeline_result.get("mocked", False),
        # Surface the swift-mcp envelope's `_throttled` source list
        # (populated by RunRequestWatcher when any source's circuit
        # breaker is open at completion time). Lets parity reports
        # tell "this run was throttled, not drift-divergent" apart.
        "throttled_sources": pipeline_result.get("_throttled") or [],
        # Pass through partial-failure notes from
        # _swift_mcp_pipeline_call (per-person timeouts that didn't
        # abort the whole subject).
        "partial_failure": pipeline_result.get("_partial_failure") or [],
        # Per-source-query dispatch log (swift-mcp backend only).
        # Each entry is {source, kind, summary, results?, error?}.
        # Lets a parity-disagreement investigation tell "search never
        # fired" from "search fired and returned nothing" from
        # "search fired and records failed gates" — diagnostic
        # required for the Ernest-marriage-Ashbourne investigation.
        "dispatch_log": pipeline_result.get("_dispatch_log") or [],
    }


# --- Reporting -------------------------------------------------------------

def format_per_subject_row(subject: dict, ids: list[str], metrics: dict) -> str:
    label = subject_label(subject)
    axes = ",".join(subject.get("difficulty_axes") or [])
    id_str = "+".join(ids) if len(ids) > 1 else (ids[0] if ids else "")
    lines = [
        f"  {id_str:50}  {label:42}  [{axes}]",
        f"    expected: {metrics['expected_supported_count']} supported"
        f"  /  {metrics['reproduction_target']} cited"
        f"   |  reported: {metrics['reported_supported_count']} supported"
        f"  /  {metrics['reproduced_count']} reproduced"
        + ("  [GUARDRAIL VIOLATION]" if metrics["guardrail_violation"] else ""),
    ]
    per_kind = metrics.get("per_kind_agreement") or {}
    for kind, v in per_kind.items():
        exp = v["expected"]
        actual = v["actual"] if v["actual"] is not None else "unmeasured"
        marker = (
            "  ✓" if v["agree"] is True
            else ("  ✗" if v["agree"] is False else "  ·")
        )
        lines.append(f"    {kind:32}  expected={exp:12}  actual={actual:12}{marker}")
    return "\n".join(lines)


def render_report(subjects_with_metrics: list[tuple[dict, list[str], dict]]) -> str:
    lines = []
    lines.append(f"=== Eval harness run: {dt.datetime.now().isoformat(timespec='seconds')} ===")
    lines.append("")
    lines.append("--- Per-subject ---")
    for subject, ids, metrics in subjects_with_metrics:
        lines.append(format_per_subject_row(subject, ids, metrics))
        lines.append("")

    # Corpus aggregates
    exp_sup = sum(m["expected_supported_count"] for _, _, m in subjects_with_metrics)
    rep_sup = sum(m["reported_supported_count"] for _, _, m in subjects_with_metrics)
    exp_rep = sum(m["reproduction_target"] for _, _, m in subjects_with_metrics)
    rep_rep = sum(m["reproduced_count"] for _, _, m in subjects_with_metrics)
    n_guard = sum(1 for _, _, m in subjects_with_metrics if m["is_guardrail"])
    n_violations = sum(1 for _, _, m in subjects_with_metrics if m["guardrail_violation"])
    n_mocked = sum(1 for _, _, m in subjects_with_metrics if m["mocked"])

    lines.append("--- Corpus aggregates ---")
    lines.append(f"  expected_supported_total:     {exp_sup}")
    lines.append(f"  reported_supported_total:     {rep_sup}  ({rep_sup}/{exp_sup})")
    lines.append(f"  reproduction_target_total:    {exp_rep}")
    lines.append(f"  reproduced_total:             {rep_rep}  ({rep_rep}/{exp_rep})")
    lines.append(f"  guardrail_subjects:           {n_guard}")
    lines.append(f"  guardrail_violations:         {n_violations}")
    if n_mocked:
        lines.append(f"  ⚠ pipeline mocked for {n_mocked}/{len(subjects_with_metrics)} subjects")
    lines.append("")

    # Per-kind aggregate: group across subjects, count agreement
    per_kind_totals: dict[str, dict[str, int]] = {}
    for _, _, m in subjects_with_metrics:
        for kind, v in (m.get("per_kind_agreement") or {}).items():
            t = per_kind_totals.setdefault(kind, {"agree": 0, "disagree": 0, "unmeasured": 0})
            if v["agree"] is True:
                t["agree"] += 1
            elif v["agree"] is False:
                t["disagree"] += 1
            else:
                t["unmeasured"] += 1
    if per_kind_totals:
        lines.append("--- Per-kind verdict agreement (corpus-wide) ---")
        for kind in sorted(per_kind_totals.keys()):
            t = per_kind_totals[kind]
            total = t["agree"] + t["disagree"] + t["unmeasured"]
            measured = t["agree"] + t["disagree"]
            rate = f"{t['agree']}/{measured}" if measured else "—"
            unm = f"  ({t['unmeasured']} unmeasured)" if t["unmeasured"] else ""
            lines.append(f"  {kind:32}  {rate} agree across {total} subjects{unm}")
        lines.append("")

    # §5.8.6 headline number — net .supported deterministic hypotheses
    lines.append(f"HEADLINE: {rep_sup} .supported  (target ≥ {exp_sup})")
    return "\n".join(lines)


def write_run_artifact(out_dir: Path, subjects_with_metrics: list[tuple[dict, list[str], dict]]) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = dt.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
    path = out_dir / f"{ts}.json"
    payload = {
        "timestamp": dt.datetime.now().isoformat(timespec="seconds"),
        "subjects": [
            {
                "ids": ids,
                "label": subject_label(subject),
                "difficulty_axes": subject.get("difficulty_axes") or [],
                "metrics": metrics,
            }
            for subject, ids, metrics in subjects_with_metrics
        ],
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    return path


# --- Entry point -----------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="§5.8.6 eval harness runner.")
    parser.add_argument("--corpus", default="eval/certified", help="Certified corpus directory")
    parser.add_argument("--citations", default="eval/certified/_gedcom_citations.json", help="GEDCOM citations sidecar")
    parser.add_argument("--out", default="eval/runs", help="Run-artifact output directory")
    parser.add_argument("--backend", choices=["python", "mock", "swift-mcp"], default="python",
                        help="Pipeline backend (default: python — in-process agent.pipeline.research_person)")
    parser.add_argument("--only", default=None,
                        help="Run only the subject whose primary id matches this string (e.g. @I50113363@)")
    parser.add_argument("--sample", type=int, default=None,
                        help="Run only the first N corpus subjects (after sort). Useful for fast iteration on a fix without burning the volunteer-source rate budget on a full 12-subject sweep.")
    parser.add_argument("--db-path", default=None,
                        help="Swift-MCP backend only: project SQLite. Falls back to $ANCESTOR_EVAL_DB then the documented default.")
    parser.add_argument("--mcp-binary", default=None,
                        help="Swift-MCP backend only: override FieldResearcherMCP binary path. Defaults to release then debug under FieldResearcherMCP/.build/.")
    parser.add_argument("--no-warmup", action="store_true",
                        help="Swift-MCP backend only: skip the Lily warmup probe. The probe runs the hallucination-guardrail subject (~13s baseline) before the full corpus to confirm the watcher is responsive; skip if you've already verified.")
    args = parser.parse_args()

    corpus_dir = Path(args.corpus)
    if not corpus_dir.exists():
        print(f"ERROR: corpus directory {corpus_dir} not found", file=sys.stderr)
        sys.exit(1)

    subjects = load_corpus(corpus_dir)
    citations = load_gedcom_citations(Path(args.citations))

    print(f"Loaded {len(subjects)} subjects from {corpus_dir}")
    n_cites = sum(len(c.get("citations", [])) if isinstance(c, dict) else len(c)
                  for c in citations.values())
    print(f"Loaded {n_cites} GEDCOM-cited identifiers from {args.citations}")
    print()

    print(f"Backend: {args.backend}")
    if args.only:
        print(f"Filter: only subjects whose ids include {args.only}")
    if args.sample:
        print(f"Sample: only first {args.sample} subjects")
    print()

    # Swift-MCP backend needs a long-lived subprocess. Wrap the
    # per-subject loop in a context manager so the server is started
    # once, reused across subjects, and torn down on the way out (incl.
    # on errors). Python / mock paths skip the lifecycle entirely.
    swift_client: _SwiftMCPClient | None = None
    if args.backend == "swift-mcp":
        binary = args.mcp_binary or _resolve_swift_mcp_binary()
        db = _resolve_swift_mcp_db_path(args.db_path)
        print(f"Swift-MCP binary: {binary}")
        print(f"Swift-MCP database: {db}")
        swift_client = _SwiftMCPClient(binary, db)
        swift_client.start()
        # Warmup probe — kick off Lily Margaret Cauldwell (the
        # hallucination-guardrail subject, ~13s baseline because
        # she's presumed-living and short-circuits all network
        # searches) before committing to the full corpus run.
        # If the watcher isn't responsive within 60s, abort early —
        # better than burning ~20 min discovering a stuck pipeline
        # mid-run.
        if not args.no_warmup and not args.only:
            print("Warmup probe: Lily Margaret Cauldwell (@I50100727@)…")
            warmup_start = time.monotonic()
            try:
                old_timeout = swift_client.per_subject_timeout_s
                swift_client.per_subject_timeout_s = 60.0
                _ = swift_client.research_profile("@I50100727@")
                elapsed = time.monotonic() - warmup_start
                print(f"  Warmup ok ({elapsed:.0f}s). Proceeding to full corpus.")
            except (TimeoutError, RuntimeError) as e:
                print(f"  Warmup failed: {type(e).__name__}: {e}", file=sys.stderr)
                print("  → watcher is unresponsive. Aborting before full-corpus run.",
                      file=sys.stderr)
                swift_client.stop()
                sys.exit(2)
            finally:
                swift_client.per_subject_timeout_s = old_timeout

    def backend_call(subject: dict) -> dict:
        if args.backend == "python":
            return _python_pipeline_call(subject)
        if args.backend == "swift-mcp":
            assert swift_client is not None
            return _swift_mcp_pipeline_call(subject, swift_client)
        return _mock_pipeline_call(subject)

    try:
        results: list[tuple[dict, list[str], dict]] = []
        # Sample cap (--sample N): take only the first N subjects of
        # the corpus (after the corpus's natural sort order) so a
        # smoke iteration on a fix doesn't burn the full network
        # budget. Applied AFTER --only so the two compose naturally.
        subject_iter = subjects if args.sample is None else subjects[: args.sample]
        for subject in subject_iter:
            ids = extract_subject_ids(subject)
            if args.only and args.only not in ids:
                continue
            # Citation lookup — union all of the subject's IDs.
            subject_cites: list[dict] = []
            for sid in ids:
                entry = citations.get(sid, [])
                if isinstance(entry, dict):
                    subject_cites.extend(entry.get("citations", []))
                else:
                    subject_cites.extend(entry)

            pipeline_result = backend_call(subject)
            metrics = compute_metrics(subject, pipeline_result, subject_cites)
            results.append((subject, ids, metrics))
    finally:
        if swift_client is not None:
            swift_client.stop()

    if not results:
        print("No subjects matched.", file=sys.stderr)
        sys.exit(1)

    report = render_report(results)
    print(report)

    artifact = write_run_artifact(Path(args.out), results)
    print(f"\nWrote {artifact}")


if __name__ == "__main__":
    main()
