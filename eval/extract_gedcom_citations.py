"""
GEDCOM citation extractor for the §5.8.5 evidence-reproduction-rate metric.

The twin-export GEDCOM (Cauldwell Family Tree.twin-export.ged) stores
citations as prose inside `1 NOTE` blocks, not as standard SOUR/CITN
tags. This script parses the prose into structured tuples comparable
with pipeline-emitted citations.

Output: JSON file at eval/certified/_gedcom_citations.json with shape:

    {
      "@I50113363@": [
        {"source": "freebmd", "kind": "birth_registration",
         "quarter": "Dec", "year": 1887, "district": "Belper",
         "volume": "7b", "page": "559", "raw": "..."},
        ...
      ],
      ...
    }

Run from repo root: `python eval/extract_gedcom_citations.py`
"""

import json
import re
import sys
from pathlib import Path

GEDCOM_PATH = Path("Cauldwell Family Tree.twin-export.ged")
OUTPUT_PATH = Path("eval/certified/_gedcom_citations.json")

# The 13 corpus subject IDs (11 yaml files; John pair has 2 IDs). T7 defensible-delta tier (5.8.1).
CORPUS_IDS = [
    "@I50113363@",  # Ernest
    "@I50113395@",  # Mabel cluster A canonical
    "@I50100727@",  # Lily (guardrail)
    "@I50110493@",  # Robert
    "@I13644681@",  # John pair member 1
    "@I50137743@",  # John pair member 2
    "@I12119734@",  # Sarah Jane Byard (sparse_evidence)
    "@I32675347@",  # Charles Herbert Hodgkinson (sparse + long_life)
    "@I50100950@",  # Catherine Hannah Bown (name_change_at_marriage)
    "@I50189843@",  # Elizabeth Cauldwell -> Beighton (cross_county_migration)
    "@I50179960@",  # Stephen Sherwin (pre_civil_registration)
    "@I50104443@",  # George Bowden (geographic_outlier)
    "@I50166073@",  # Lydia Kenworthy -> Twyford (sparse + brief_life)
]


# --- Prose citation patterns -----------------------------------------------

_MONTH_RE = r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"

# "FreeBMD birth Dec 1887 Belper vol7b p559"
# "FreeBMD death Mar 1959 Ashbourne vol3a p14"
# "FreeBMD marriage Jun 1909 Belper vol7b p1359"
# "FreeBMD birth Sep 1885 Belper"  (no vol/page)
FREEBMD_RE = re.compile(
    rf"FreeBMD\s+(?P<kind>birth|death|marriage)\s+"
    rf"(?P<quarter>{_MONTH_RE})\s+(?P<year>\d{{4}})\s+"
    rf"(?P<district>[A-Za-z][A-Za-z .'-]*?)"
    rf"(?:\s+vol(?P<vol>\w+)\s+p(?P<page>\d+))?"
    rf"(?=[\s,.)]|$)",
    re.IGNORECASE | re.MULTILINE,
)

# "GRO vol7b p977" inside narrative prose — same shape as FreeBMD vol/page.
# Captured separately because the source label is GRO not FreeBMD.
GRO_RE = re.compile(
    r"GRO\s+vol(?P<vol>\w+)\s+p(?P<page>\d+)",
    re.IGNORECASE,
)

# Month name in GRO lookback context — accepts full or 3-letter abbrev.
# Normalised to 3-letter Title case via _MONTH_ABBREV so the quarter field
# is comparable with the Title-cased FreeBMD pattern output.
_GRO_MONTH_RE = (
    r"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
    r"Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b"
)
_MONTH_ABBREV = {
    "jan": "Jan", "feb": "Feb", "mar": "Mar", "apr": "Apr",
    "may": "May", "jun": "Jun", "jul": "Jul", "aug": "Aug",
    "sep": "Sep", "oct": "Oct", "nov": "Nov", "dec": "Dec",
}

# "FamilySearch 1901 census: ... (ARK p_10268848273)"
# "FamilySearch 1911 census: ... (ARK 1G2B-WFR)"
FAMILYSEARCH_CENSUS_RE = re.compile(
    r"FamilySearch\s+(?P<year>\d{4})\s+census\s*:?\s*(?P<desc>[^()]*)"
    r"\(ARK\s+(?P<ark>[A-Za-z0-9_\-]+)\)",
    re.IGNORECASE,
)

# "CWGC: Corporal Robert Cauldwell, 1st Bn West Yorkshire Regt,
#  died 14 Jul 1918, Lijssenthoek Military Cemetery XXVIII.G.3A"
CWGC_RE = re.compile(
    r"CWGC[:\s]+(?P<rest>.+?)(?:\n|$)",
    re.IGNORECASE,
)

# CWGC sub-patterns to extract identifiers from the rest-of-line
CWGC_DATE_RE = re.compile(rf"died\s+(?P<day>\d{{1,2}})\s+(?P<month>{_MONTH_RE})\s+(?P<year>\d{{4}})", re.IGNORECASE)
CWGC_PLOT_RE = re.compile(r"([IVXLCDM]+\.\s*[A-Z]\.\s*\d+[A-Z]?)")
CWGC_CEMETERY_RE = re.compile(r"([A-Z][\w ]+(?:Cemetery|Memorial|Cemetary))", re.IGNORECASE)


# --- Meta-signal patterns (staller detection) ------------------------------
#
# These flag explicit uncertainty in the bio prose. The eval harness uses
# them to define T7's "stalled profile" population — no need for the harness
# to invent its own staller heuristic when the bio note labels it directly.

# Twin-export auto-generated estimation marker (33 profiles in the corpus).
# Shape: "Birth year ABT YYYY estimated from <relation>. No independent record
# located at time of profile creation; further research via census/FreeBMD
# recommended."
META_ESTIMATED_RE = re.compile(
    r"(?P<field>Birth|Death)\s+year\s+ABT\s+(?P<year>\d{4})\s+estimated\s+from\s+"
    r"(?P<source>spouse|parent|child|sibling)\s+(?P<who>[^.]+?)\.\s*"
    r"No independent record located",
    re.IGNORECASE,
)

# WikiTree `<ref>...source needed...</ref>` template marker.
META_SOURCE_NEEDED_RE = re.compile(
    r"(?:<ref>\s*)?A source for this information is needed",
    re.IGNORECASE,
)

# "may have been conflated", "may be the X christened" — explicit identity risk.
META_CONFLATION_RE = re.compile(
    r"(?:may have been conflated|may be the [A-Z][^.]{0,80}christened)",
    re.IGNORECASE,
)

# Softer hedges — "approximately N", "possibly in X", "unverified", "unconfirmed".
# Counted but not treated as hard stallers; useful for precision-tuning.
META_HEDGE_RE = re.compile(
    r"\b(?:approximately\s+\d+|possibly|unconfirmed|unverified|may have been)\b",
    re.IGNORECASE,
)


def extract_meta_signals(bio: str) -> list[dict]:
    """Detect explicit uncertainty markers in the bio prose."""
    signals: list[dict] = []

    for m in META_ESTIMATED_RE.finditer(bio):
        signals.append({
            "kind": "estimated_from_relation",
            "field": m.group("field").lower(),
            "year": int(m.group("year")),
            "source_relation": m.group("source"),
            "source_person": m.group("who").strip(),
            "raw": m.group(0).strip(),
        })

    for m in META_SOURCE_NEEDED_RE.finditer(bio):
        signals.append({
            "kind": "source_needed",
            "raw": m.group(0).strip(),
        })

    for m in META_CONFLATION_RE.finditer(bio):
        signals.append({
            "kind": "conflation_risk",
            "raw": m.group(0).strip(),
        })

    for m in META_HEDGE_RE.finditer(bio):
        signals.append({
            "kind": "hedge",
            "raw": m.group(0).strip(),
        })

    return signals


def parse_bio_note(block: str) -> str:
    """Concatenate `2 CONT`/`2 CONC` lines from the first `1 NOTE` in a block."""
    m = re.search(r"^1 NOTE (.+?)(?=^1 [A-Z_]|\Z)", block, re.MULTILINE | re.DOTALL)
    if not m:
        return ""
    out = []
    for line in m.group(1).split("\n"):
        if line.startswith("2 CONT "):
            out.append(line[7:])
        elif line.startswith("2 CONC "):
            if out:
                out[-1] += line[7:]
    return "\n".join(out)


def extract_citations(bio: str) -> list[dict]:
    """Apply the four prose-citation patterns to a bio note string."""
    citations: list[dict] = []

    for m in FREEBMD_RE.finditer(bio):
        citations.append({
            "source": "freebmd",
            "kind": f"{m.group('kind').lower()}_registration",
            "quarter": m.group("quarter"),
            "year": int(m.group("year")),
            "district": m.group("district").strip(),
            "volume": m.group("vol"),
            "page": m.group("page"),
            "raw": m.group(0).strip().rstrip(",.)"),
        })

    for m in GRO_RE.finditer(bio):
        # Context: look ~80 chars backward for kind + district + year cues.
        start = max(0, m.start() - 200)
        ctx = bio[start:m.start()]
        kind = None
        if re.search(r"\bmarri(?:ed|age)\b", ctx, re.IGNORECASE):
            kind = "marriage_registration"
        elif re.search(r"\bborn\b|\bbirth\b", ctx, re.IGNORECASE):
            kind = "birth_registration"
        elif re.search(r"\bdied\b|\bdeath\b", ctx, re.IGNORECASE):
            kind = "death_registration"
        year_m = re.search(r"\b(1[6-9]\d{2}|20\d{2})\b", ctx[-100:])
        quarter_m = re.search(_GRO_MONTH_RE, ctx[-100:], re.IGNORECASE)
        district_m = re.search(r"\(([A-Z][a-z ]+)\s*,?\s*GRO", bio[m.start() - 40:m.start() + 40])
        citations.append({
            "source": "gro",
            "kind": kind or "unknown",
            "quarter": _MONTH_ABBREV[quarter_m.group(1)[:3].lower()] if quarter_m else None,
            "year": int(year_m.group(1)) if year_m else None,
            "district": district_m.group(1).strip() if district_m else None,
            "volume": m.group("vol"),
            "page": m.group("page"),
            "raw": bio[max(0, m.start()-60):m.end()+5].strip(),
        })

    for m in FAMILYSEARCH_CENSUS_RE.finditer(bio):
        citations.append({
            "source": "familysearch",
            "kind": "census",
            "year": int(m.group("year")),
            "ark": m.group("ark"),
            "description": m.group("desc").strip().rstrip(","),
            "raw": m.group(0).strip(),
        })

    for m in CWGC_RE.finditer(bio):
        rest = m.group("rest")
        date_m = CWGC_DATE_RE.search(rest)
        plot_m = CWGC_PLOT_RE.search(rest)
        cem_m = CWGC_CEMETERY_RE.search(rest)
        citations.append({
            "source": "cwgc",
            "kind": "war_grave",
            "date_of_death": (
                f"{date_m.group('day')} {date_m.group('month')} {date_m.group('year')}"
                if date_m else None
            ),
            "cemetery": cem_m.group(1).strip() if cem_m else None,
            "plot": plot_m.group(1).strip() if plot_m else None,
            "raw": m.group(0).strip(),
        })

    return citations


def main():
    if not GEDCOM_PATH.exists():
        print(f"ERROR: {GEDCOM_PATH} not found (run from repo root)", file=sys.stderr)
        sys.exit(1)

    text = GEDCOM_PATH.read_text(encoding="utf-8", errors="replace")

    result: dict[str, dict] = {}
    for sid in CORPUS_IDS:
        # Extract the INDI block for this subject
        m = re.search(
            rf"^0 {re.escape(sid)} INDI\n(.*?)(?=^0 @|\Z)",
            text,
            re.MULTILINE | re.DOTALL,
        )
        if not m:
            print(f"  {sid}: NOT FOUND in GEDCOM", file=sys.stderr)
            result[sid] = {"citations": [], "meta_signals": []}
            continue
        bio = parse_bio_note(m.group(1))
        citations = extract_citations(bio)
        meta = extract_meta_signals(bio)
        result[sid] = {"citations": citations, "meta_signals": meta}

        flags = []
        if any(s["kind"] == "estimated_from_relation" for s in meta):
            flags.append("STALLER")
        if any(s["kind"] == "conflation_risk" for s in meta):
            flags.append("CONFLATION_RISK")
        flag_str = f"  [{','.join(flags)}]" if flags else ""

        print(f"  {sid}: {len(citations)} citation(s), {len(meta)} meta-signal(s){flag_str}")
        for c in citations:
            tag = c.get("source", "?")
            kind = c.get("kind", "?")
            print(f"    [{tag}/{kind}] {c.get('raw', '')[:80]}")
        for s in meta:
            print(f"    [meta/{s['kind']}] {s.get('raw', '')[:80]}")

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"\nWrote {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
