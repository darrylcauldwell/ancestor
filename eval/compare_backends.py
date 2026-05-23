"""Side-by-side parity comparison of two harness run artifacts
(SWIFT_MCP_EVAL_BACKEND_SPEC #Change9).

Reads two `eval/runs/*.json` files produced by `run_harness.py`,
aligns subjects by id, and reports per-kind verdict agreement /
disagreement between backends. Renders a Markdown-flavoured table to
stdout suitable for pasting into a commit message or commenting
inline on a drift investigation.

Usage:
    python eval/compare_backends.py <python.json> <swift.json>
"""

import json
import sys
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def subjects_by_id(run: dict) -> dict[str, dict]:
    """Key each subject by its first id so two runs can be aligned."""
    out: dict[str, dict] = {}
    for s in run.get("subjects", []):
        ids = s.get("ids") or []
        if ids:
            out[ids[0]] = s
    return out


def per_kind(subject: dict) -> dict[str, dict | None]:
    return ((subject.get("metrics") or {}).get("per_kind_agreement") or {})


def cell(verdict: str | None) -> str:
    """Compact cell label for the parity table."""
    if verdict is None:
        return "—"
    return verdict


def compare(py_path: Path, sw_path: Path) -> None:
    py_run = load(py_path)
    sw_run = load(sw_path)

    py_subjects = subjects_by_id(py_run)
    sw_subjects = subjects_by_id(sw_run)

    all_ids = sorted(set(py_subjects) | set(sw_subjects))

    print(f"# Backend parity — python vs swift-mcp")
    print()
    print(f"- python source: `{py_path}` ({py_run.get('timestamp', '?')})")
    print(f"- swift source:  `{sw_path}` ({sw_run.get('timestamp', '?')})")
    print()

    # --- Per-subject table ---
    # One row per (subject, kind). Columns: expected | python | swift |
    # python_agrees | swift_agrees | backends_agree.
    rows: list[tuple] = []
    agree_count = 0
    disagree_count = 0
    only_one_measured = 0
    both_unmeasured = 0
    for sid in all_ids:
        py = py_subjects.get(sid)
        sw = sw_subjects.get(sid)
        label = (py or sw or {}).get("label", "?")
        py_kinds = per_kind(py) if py else {}
        sw_kinds = per_kind(sw) if sw else {}
        kinds = sorted(set(py_kinds) | set(sw_kinds))
        for kind in kinds:
            py_entry = py_kinds.get(kind) or {}
            sw_entry = sw_kinds.get(kind) or {}
            expected = py_entry.get("expected") or sw_entry.get("expected")
            py_actual = py_entry.get("actual")
            sw_actual = sw_entry.get("actual")
            if py_actual is None and sw_actual is None:
                state = "both_unmeasured"
                both_unmeasured += 1
            elif py_actual is None or sw_actual is None:
                state = "one_unmeasured"
                only_one_measured += 1
            elif py_actual == sw_actual:
                state = "agree"
                agree_count += 1
            else:
                state = "disagree"
                disagree_count += 1
            rows.append((sid, label, kind, expected, py_actual, sw_actual, state))

    # Headline
    print("## Headline")
    print()
    total_measured = agree_count + disagree_count
    pct = (agree_count / total_measured * 100) if total_measured else 0
    print(f"- both-backend measured cells:  {total_measured}")
    print(f"- backends agree:               {agree_count} ({pct:.0f}% of measured)")
    print(f"- backends disagree:            {disagree_count}")
    print(f"- only one backend measured:    {only_one_measured}")
    print(f"- neither measured (unmeasurable kinds): {both_unmeasured}")
    print()

    # Disagreements first — the actionable rows
    disagreements = [r for r in rows if r[6] == "disagree"]
    if disagreements:
        print("## Backend disagreements (actionable drift)")
        print()
        print("| Subject | Kind | Expected | Python | Swift |")
        print("|---|---|---|---|---|")
        for sid, label, kind, exp, py, sw, _ in disagreements:
            print(f"| {label} | {kind} | {cell(exp)} | {cell(py)} | {cell(sw)} |")
        print()

    # One-side-only measurements — likely envelope-coverage gap
    one_only = [r for r in rows if r[6] == "one_unmeasured"]
    if one_only:
        print("## Measured by one backend only")
        print()
        print("| Subject | Kind | Expected | Python | Swift |")
        print("|---|---|---|---|---|")
        for sid, label, kind, exp, py, sw, _ in one_only:
            print(f"| {label} | {kind} | {cell(exp)} | {cell(py)} | {cell(sw)} |")
        print()

    # Full table at the foot
    print("## Full per-(subject, kind) matrix")
    print()
    print("| Subject | Kind | Expected | Python | Swift | State |")
    print("|---|---|---|---|---|---|")
    for sid, label, kind, exp, py, sw, state in rows:
        print(f"| {label} | {kind} | {cell(exp)} | {cell(py)} | {cell(sw)} | {state} |")


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    compare(Path(sys.argv[1]), Path(sys.argv[2]))


if __name__ == "__main__":
    main()
