"""
§5.8.6 eval harness runner — skeleton.

Loads the certified corpus YAMLs and the GEDCOM-citation sidecar JSON,
invokes the research pipeline against each subject, and emits per-kind
precision/recall + a single headline number suitable for commit-message
deltas.

The pipeline invocation is currently MOCKED — see `_mock_pipeline_call`
below. Real integration is a separate task (Swift CLI scheme or
FieldResearcherMCP-driven run). The mock returns an empty result so the
skeleton runs end-to-end and validates the data plumbing.

Run from repo root:
    python eval/run_harness.py
    python eval/run_harness.py --corpus eval/certified --out eval/runs/
"""

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

import yaml


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


# --- Pipeline (mocked) -----------------------------------------------------

def _mock_pipeline_call(subject: dict) -> dict:
    """Stand-in for `ResearchPipeline.research(subject:config:)`.

    Returns an empty result envelope. Real implementation will shell
    out to `swift run eval` or drive the FieldResearcherMCP server.
    The harness scaffold here is what proves the metric-aggregation
    pipeline before that real integration lands.
    """
    return {
        "supported_hypotheses": [],
        "contradicted_hypotheses": [],
        "inconclusive_hypotheses": [],
        "discovered_citations": [],
        "mocked": True,
    }


# --- Metric computation ----------------------------------------------------

def compute_metrics(subject: dict, pipeline_result: dict, gedcom_cites: list[dict]) -> dict:
    """Compute precision / recall / contradiction-count / reproduction-rate
    for one subject. All metrics are tolerant of missing fields — skeleton
    output must be a valid metrics envelope even when the pipeline returns
    nothing."""
    expected_kinds: dict = subject.get("expected_per_kind", {}) or {}
    expected_supported = int(subject.get("expected_supported_count", 0))

    supported = pipeline_result.get("supported_hypotheses", []) or []
    contradicted = pipeline_result.get("contradicted_hypotheses", []) or []
    discovered = pipeline_result.get("discovered_citations", []) or []

    reproduction_target = len(gedcom_cites)
    reproduced = 0
    # Real implementation will call into CitationMatcher to decide
    # whether each `discovered` matches an entry in gedcom_cites.
    # Skeleton: count is 0 because mock produces no citations.

    is_guardrail = "hallucination_guardrail" in (subject.get("difficulty_axes") or [])
    guardrail_violation = is_guardrail and len(supported) > 0

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
        "mocked": pipeline_result.get("mocked", False),
    }


# --- Reporting -------------------------------------------------------------

def format_per_subject_row(subject: dict, ids: list[str], metrics: dict) -> str:
    label = subject_label(subject)
    axes = ",".join(subject.get("difficulty_axes") or [])
    id_str = "+".join(ids) if len(ids) > 1 else (ids[0] if ids else "")
    return (
        f"  {id_str:50}  {label:42}  [{axes}]\n"
        f"    expected: {metrics['expected_supported_count']} supported"
        f"  /  {metrics['reproduction_target']} cited"
        f"   |  reported: {metrics['reported_supported_count']} supported"
        f"  /  {metrics['reproduced_count']} reproduced"
        + ("  [GUARDRAIL VIOLATION]" if metrics["guardrail_violation"] else "")
    )


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
    parser = argparse.ArgumentParser(description="§5.8.6 eval harness runner (skeleton).")
    parser.add_argument("--corpus", default="eval/certified", help="Certified corpus directory")
    parser.add_argument("--citations", default="eval/certified/_gedcom_citations.json", help="GEDCOM citations sidecar")
    parser.add_argument("--out", default="eval/runs", help="Run-artifact output directory")
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

    results: list[tuple[dict, list[str], dict]] = []
    for subject in subjects:
        ids = extract_subject_ids(subject)
        # Citation lookup — union all of the subject's IDs.
        subject_cites: list[dict] = []
        for sid in ids:
            entry = citations.get(sid, [])
            if isinstance(entry, dict):
                subject_cites.extend(entry.get("citations", []))
            else:
                subject_cites.extend(entry)

        pipeline_result = _mock_pipeline_call(subject)
        metrics = compute_metrics(subject, pipeline_result, subject_cites)
        results.append((subject, ids, metrics))

    report = render_report(results)
    print(report)

    artifact = write_run_artifact(Path(args.out), results)
    print(f"\nWrote {artifact}")


if __name__ == "__main__":
    main()
