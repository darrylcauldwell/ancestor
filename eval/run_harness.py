"""
§5.8.6 eval harness runner.

Loads the certified corpus YAMLs and the GEDCOM-citation sidecar JSON,
invokes the research pipeline against each subject, and emits per-kind
precision/recall + a single headline number suitable for commit-message
deltas.

Backends:
  --backend python  (default) — in-process call to `agent.pipeline.research_person`
  --backend mock              — empty envelope (skeleton plumbing)

Run from repo root:
    python eval/run_harness.py
    python eval/run_harness.py --only @I50113363@           # single subject
    python eval/run_harness.py --backend mock               # no live HTTP
"""

import argparse
import datetime as dt
import json
import os
import re
import sys
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
    for person in persons:
        state = research_person(person)
        envelope = _state_to_envelope(state)
        for key in ("supported_hypotheses", "contradicted_hypotheses",
                    "inconclusive_hypotheses", "discovered_citations"):
            aggregated[key].extend(envelope[key])

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


# --- Metric computation ----------------------------------------------------

# Map expected_per_kind keys to the pipeline fact-type tokens that
# would land in `supported_hypotheses[].kind` for that kind. Kinds that
# aren't directly emitted by the pipeline (parent_link,
# identity_disambiguation) are absent and reported as "unmeasured".
_KIND_FACT_TYPES: dict[str, set[str]] = {
    "birth_disambiguation": {"birth", "birth_registration"},
    # A CWGC war-grave record is the authoritative death record for
    # casualties who died abroad (no civil GRO entry exists). Count
    # `military` fact-types toward death_disambiguation too — see
    # eval/certified/I50110493_robert_cauldwell.yaml (foreign-record
    # axis: corpus expects CWGC to satisfy death_disambiguation).
    "death_disambiguation": {"death", "death_registration", "military", "war_grave", "cwgc"},
    "marriage_disambiguation": {"marriage", "marriage_registration"},
    "military_service": {"military", "war_grave", "cwgc"},
}


def _actual_verdict_for_kind(kind: str, pipeline_result: dict) -> str | None:
    """Derive 'supported' / 'contradicted' / 'inconclusive' for one kind
    from the envelope, or None if we can't measure it (kind isn't
    directly emitted by the pipeline).

    Rules:
      - supported   : ≥1 supported hypothesis of one of the kind's types
      - contradicted: no supported but ≥1 contradicted hint that matches
      - inconclusive: neither
    """
    if kind == "spouse_disambiguation":
        # Derived: any supported marriage whose value carries a spouse
        # surname (post-1912 FreeBMD spouse_or_mother field).
        for h in pipeline_result.get("supported_hypotheses", []) or []:
            if h.get("kind") in {"marriage", "marriage_registration"}:
                v = (h.get("value") or "")
                # Marriage summary ends with `, <Spouse>` when spouse known
                if re.search(r"\)\s*,\s*[A-Z][a-zA-Z]+\s*$", v):
                    return "supported"
        return "inconclusive"

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
        # Strip suffix from compound keys for verdict derivation
        base_kind = kind.split(".", 1)[0]
        actual = _actual_verdict_for_kind(base_kind, pipeline_result)
        out[kind] = {
            "expected": expected,
            "actual": actual,
            "agree": (actual == expected) if actual is not None else None,
        }
    return out


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
    parser.add_argument("--backend", choices=["python", "mock"], default="python",
                        help="Pipeline backend (default: python — in-process agent.pipeline.research_person)")
    parser.add_argument("--only", default=None,
                        help="Run only the subject whose primary id matches this string (e.g. @I50113363@)")
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

    backend_call = _python_pipeline_call if args.backend == "python" else _mock_pipeline_call
    print(f"Backend: {args.backend}")
    if args.only:
        print(f"Filter: only subjects whose ids include {args.only}")
    print()

    results: list[tuple[dict, list[str], dict]] = []
    for subject in subjects:
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

    if not results:
        print("No subjects matched.", file=sys.stderr)
        sys.exit(1)

    report = render_report(results)
    print(report)

    artifact = write_run_artifact(Path(args.out), results)
    print(f"\nWrote {artifact}")


if __name__ == "__main__":
    main()
