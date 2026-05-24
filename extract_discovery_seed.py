"""Build a 15-person seed GEDCOM for the overnight discovery run.

Selects the starter-7 + Darryl's spouse Claire + her tree (parents +
grandparents) + Lily as the guardrail control, drawn from the
LLM-built twin-export GEDCOM. Only FAM records whose every linked
member is in the seed are included; cross-FAM references to
non-seed people are dropped, so the output is a self-contained
subset with no dangling pointers.

Usage:
    python extract_discovery_seed.py \\
        --input "Cauldwell Family Tree.twin-export.ged" \\
        --output "Cauldwell Family Tree.discovery-seed.ged"
"""
import argparse
from pathlib import Path

SEED_IDS = {
    # starter-7 (validated, ground-truth citations)
    "@I50098374@": "Darryl James Cauldwell",
    "@I50100747@": "David Nigel Cauldwell",
    "@I50100815@": "Jennifer Margaret Holmes",
    "@I50100821@": "Ernest Victor Cauldwell",
    "@I50100841@": "Kathleen Dorothy Wheeldon",
    "@I50100853@": "Reginald Maitland Holmes",
    "@I50110394@": "Lilian Mary Brooks",
    # Guardrail control (living minor — engine should refuse)
    "@I50100727@": "Lily Margaret Cauldwell",
    # Wife + her tree (Claire's father is alive; mother + grandparents deceased)
    "@I50110391@": "Claire Louise Rose",
    "@I50137869@": "David Rose (Claire's father)",
    "@I50110398@": "Margaret Helen Marshall (Claire's mother)",
    "@I50113368@": "Norman Rose (paternal grandfather)",
    "@I50100923@": "Norah Beresford (paternal grandmother)",
    "@I50100928@": "Harry Marshall (maternal grandfather)",
    "@I50137818@": "Elsie Elizabeth Twyford (maternal grandmother)",
}


def parse_records(path: Path):
    """Yield (record_id, record_type, lines) for every 0-level block."""
    current_id = None
    current_type = None
    current_lines: list[str] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("0 "):
                if current_lines:
                    yield current_id, current_type, current_lines
                parts = line.split(" ", 3)
                if len(parts) >= 3 and parts[1].startswith("@"):
                    current_id = parts[1]
                    current_type = parts[2]
                else:
                    current_id = None
                    current_type = parts[1] if len(parts) > 1 else ""
                current_lines = [line]
            else:
                current_lines.append(line)
        if current_lines:
            yield current_id, current_type, current_lines


def fam_member_ids(fam_lines: list[str]) -> set[str]:
    """Pull every @I*@ reference from a FAM record's HUSB/WIFE/CHIL lines."""
    ids: set[str] = set()
    for line in fam_lines:
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("HUSB", "WIFE", "CHIL") and parts[2].startswith("@"):
            ids.add(parts[2])
    return ids


def filter_fam(fam_lines: list[str], seed_ids: set[str]) -> list[str]:
    """Drop HUSB/WIFE/CHIL lines pointing to non-seed people."""
    out: list[str] = []
    for line in fam_lines:
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("HUSB", "WIFE", "CHIL") and parts[2].startswith("@"):
            if parts[2] not in seed_ids:
                continue
        out.append(line)
    return out


def filter_indi(indi_lines: list[str], seed_fam_ids: set[str]) -> list[str]:
    """Drop FAMC/FAMS pointers to families we excluded."""
    out: list[str] = []
    for line in indi_lines:
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("FAMC", "FAMS") and parts[2].startswith("@"):
            if parts[2] not in seed_fam_ids:
                continue
        out.append(line)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="Cauldwell Family Tree.twin-export.ged")
    ap.add_argument("--output", default="Cauldwell Family Tree.discovery-seed.ged")
    args = ap.parse_args()

    src = Path(args.input)
    dst = Path(args.output)
    if not src.exists():
        raise SystemExit(f"input GEDCOM not found: {src}")

    records = list(parse_records(src))

    # 1. Find the IDs of every FAM record where the surviving members
    #    are ALL in the seed (after dropping non-seed HUSB/WIFE/CHIL lines).
    seed_ids = set(SEED_IDS.keys())
    fam_keep: dict[str, list[str]] = {}
    for rec_id, rec_type, lines in records:
        if rec_type != "FAM":
            continue
        members = fam_member_ids(lines)
        if members & seed_ids:
            fam_keep[rec_id] = filter_fam(lines, seed_ids)

    seed_fam_ids = set(fam_keep.keys())

    # 2. Build output: HEAD passthrough, seed INDIs (with non-seed FAMC/
    #    FAMS lines stripped), seed FAMs, TRLR.
    out_lines: list[str] = []
    head_lines: list[str] = []
    indis: list[list[str]] = []
    fams: list[list[str]] = []

    for rec_id, rec_type, lines in records:
        if rec_type == "HEAD":
            head_lines = lines
        elif rec_type == "INDI" and rec_id in seed_ids:
            indis.append(filter_indi(lines, seed_fam_ids))
        elif rec_type == "FAM" and rec_id in seed_fam_ids:
            fams.append(fam_keep[rec_id])
        # All other record types (SOUR, NOTE, OBJE, …) are dropped —
        # the engine will rediscover sources during the overnight run.

    if not head_lines:
        head_lines = [
            "0 HEAD",
            "1 SOUR extract_discovery_seed.py",
            "1 GEDC",
            "2 VERS 5.5.1",
            "2 FORM LINEAGE-LINKED",
            "1 CHAR UTF-8",
        ]

    out_lines.extend(head_lines)
    for indi in indis:
        out_lines.extend(indi)
    for fam in fams:
        out_lines.extend(fam)
    out_lines.append("0 TRLR")

    dst.write_text("\n".join(out_lines) + "\n", encoding="utf-8")

    # Summary
    print(f"Wrote {dst}")
    print(f"  INDI records:  {len(indis)} / {len(SEED_IDS)} expected")
    print(f"  FAM records:   {len(fams)}")
    print(f"  Total lines:   {len(out_lines)}")
    missing = seed_ids - {l[0].split()[1] for l in indis if l and l[0].startswith("0 ")}
    indi_ids_found = set()
    for indi in indis:
        if indi and indi[0].startswith("0 "):
            indi_ids_found.add(indi[0].split()[1])
    missing = seed_ids - indi_ids_found
    if missing:
        print("  ⚠ MISSING:")
        for mid in sorted(missing):
            print(f"     {mid} — {SEED_IDS.get(mid, '?')}")
    else:
        print("  All 15 seed IDs found.")


if __name__ == "__main__":
    main()
