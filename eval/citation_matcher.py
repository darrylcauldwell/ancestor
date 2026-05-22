"""
Citation matcher for the §5.8.5 evidence-reproduction-rate metric.

Python port of `Ancestor Research/Services/Research/CitationMatcher.swift`.
Keep the two in sync when adding new patterns or source families.

Two input shapes:

1. GEDCOM-side citations — already structured dicts emitted by
   `eval/extract_gedcom_citations.py`:
       {"source": "freebmd", "kind": "birth_registration",
        "quarter": "Dec", "year": 1887, "district": "Belper",
        "volume": "7b", "page": "559"}

2. Pipeline-side citations — flat strings emitted by
   `agent.pipeline._apply_scores`, of the form
   `"<search_type>: <record_summary>"`. Example:
       "death_registration: Ernest CAULDWELL, Mar 1959, Ashbourne (vol 3a p.14), age 71"

`parse_pipeline_citation` turns the second into the same `CitedIdentifier`
shape as `from_gedcom_dict` produces, so `equivalent(a, b)` can compare
them symmetrically.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# --- Types -----------------------------------------------------------------

# Matches Swift CitationMatch enum
EXACT = "exact"
PARTIAL = "partial"
NO_MATCH = "no_match"


@dataclass(frozen=True)
class CitedIdentifier:
    source: str           # "freebmd", "gro", "familysearch", "cwgc", ...
    kind: str             # "birth_registration", "death_registration", ...
    identifiers: tuple    # tuple of (key, value) pairs — frozen for hashability
    raw: str = ""

    @classmethod
    def make(cls, source: str, kind: str, identifiers: dict, raw: str = "") -> "CitedIdentifier":
        # Normalise: strip None values, lowercase district, str-ify everything
        clean = {}
        for k, v in identifiers.items():
            if v is None:
                continue
            sv = str(v)
            if k == "district":
                sv = sv.strip().lower()
            clean[k] = sv
        return cls(
            source=source.lower(),
            kind=kind.lower(),
            identifiers=tuple(sorted(clean.items())),
            raw=raw,
        )

    def get(self, key: str) -> str | None:
        for k, v in self.identifiers:
            if k == key:
                return v
        return None


# --- Source family classification ------------------------------------------

_FAMILY_FREEBMD = {"freebmd", "gro"}
_FAMILY_FAMILYSEARCH = {"familysearch"}
_FAMILY_CWGC = {"cwgc"}


def _family(source: str) -> str:
    s = source.lower()
    if s in _FAMILY_FREEBMD:
        return "freebmd"
    if s in _FAMILY_FAMILYSEARCH:
        return "familysearch"
    if s in _FAMILY_CWGC:
        return "cwgc"
    return "other"


# --- GEDCOM side: dict → CitedIdentifier ----------------------------------

def from_gedcom_dict(d: dict) -> CitedIdentifier:
    source = d.get("source", "unknown")
    kind = d.get("kind", "unknown")
    # Strip the meta fields, keep the identifier-bearing ones.
    ids = {k: v for k, v in d.items() if k not in ("source", "kind", "raw", "description")}
    return CitedIdentifier.make(source, kind, ids, raw=d.get("raw", ""))


# --- Pipeline side: flat string → CitedIdentifier --------------------------

_MONTH = r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"

# "death_registration: Ernest CAULDWELL, Mar 1959, Ashbourne (vol 3a p.14), age 71"
# "birth_registration: Joseph Cauldwell, Jun 1882, Belper (vol 7b p.483)"
# "marriage: Ernest Cauldwell, Mar 1915, Ashbourne (vol 7b p.977), Ward"
_FREEBMD_PIPELINE_RE = re.compile(
    rf"^(?P<search>birth|death|marriage)(?:_registration)?:\s*"
    rf"(?P<name>[^,]+),\s*"
    rf"(?P<quarter>{_MONTH})\s+(?P<year>\d{{4}}),\s*"
    rf"(?P<district>[^,(]+?)"
    rf"(?:\s*\(vol\s*(?P<vol>\w+)\s+p\.?(?P<page>\d+)\))?"
    rf"(?:,\s*age\s*\d+)?"
    rf"(?:,\s*(?P<spouse>[A-Z][a-zA-Z]+))?\s*$",
    re.IGNORECASE,
)

# "census_1891: Ernest CAULDWELL, census 1891, born 1887 Turnditch"
# Census via FamilySearch search-type may emit a different shape; broaden later.
_CENSUS_PIPELINE_RE = re.compile(
    rf"^census(?:_(?P<year2>\d{{4}}))?:\s*(?P<name>[^,]+),\s*census\s+(?P<year>\d{{4}})"
    rf"(?:,\s*born\s+(?P<born>\d{{4}})\s+(?P<place>[^,]+))?",
    re.IGNORECASE,
)

# CWGC has no fixed format in pipeline emissions — fall back to keyword sniffing.
_CWGC_PIPELINE_DATE_RE = re.compile(
    rf"died\s+(?P<day>\d{{1,2}})\s+(?P<month>{_MONTH})\s+(?P<year>\d{{4}})",
    re.IGNORECASE,
)
_CWGC_PIPELINE_PLOT_RE = re.compile(r"([IVXLCDM]+\.\s*[A-Z]\.\s*\d+[A-Z]?)")


def _kind_from_search_type(search_type: str) -> str:
    s = search_type.lower()
    if s.startswith("census"):
        return "census"
    if s == "marriage" or s == "marriage_registration":
        return "marriage_registration"
    if s == "death" or s == "death_registration":
        return "death_registration"
    if s == "birth" or s == "birth_registration":
        return "birth_registration"
    if "military" in s or "cwgc" in s or "war" in s:
        return "war_grave"
    return s


def parse_pipeline_citation(s: str) -> CitedIdentifier | None:
    """Turn a pipeline-emitted source string into a CitedIdentifier.

    Pipeline format is `<search_type>: <record_summary>`. The search_type
    tells us the kind; the record_summary carries the discriminating
    identifiers.
    """
    if not s or ":" not in s:
        return None
    raw = s
    search_type, _, summary = s.partition(":")
    search_type = search_type.strip().lower()
    kind = _kind_from_search_type(search_type)

    # Try FreeBMD shape first — covers birth, death, marriage
    m = _FREEBMD_PIPELINE_RE.match(s.strip())
    if m and kind in ("birth_registration", "death_registration", "marriage_registration"):
        ids = {
            "quarter": m.group("quarter"),
            "year": m.group("year"),
            "district": m.group("district"),
        }
        if m.group("vol"):
            ids["volume"] = m.group("vol")
        if m.group("page"):
            ids["page"] = m.group("page")
        return CitedIdentifier.make("freebmd", kind, ids, raw=raw)

    # Census shape
    m = _CENSUS_PIPELINE_RE.match(s.strip())
    if m and kind == "census":
        ids = {"year": m.group("year")}
        if m.group("place"):
            ids["place"] = m.group("place").strip()
        return CitedIdentifier.make("freecen", kind, ids, raw=raw)

    # CWGC / military
    if kind == "war_grave":
        ids: dict = {}
        dm = _CWGC_PIPELINE_DATE_RE.search(summary)
        if dm:
            ids["date_of_death"] = f"{dm.group('day')} {dm.group('month')} {dm.group('year')}"
        pm = _CWGC_PIPELINE_PLOT_RE.search(summary)
        if pm:
            ids["plot"] = pm.group(1).replace(" ", "")
        if ids:
            return CitedIdentifier.make("cwgc", kind, ids, raw=raw)

    return None


# --- Match rules (ported from Swift) --------------------------------------

def _match_freebmd(a: CitedIdentifier, b: CitedIdentifier) -> str:
    aD, bD = a.get("district"), b.get("district")
    if not aD or not bD or aD != bD:
        return NO_MATCH
    if a.get("quarter") != b.get("quarter") or a.get("year") != b.get("year"):
        return NO_MATCH
    aVol, bVol = a.get("volume"), b.get("volume")
    aPage, bPage = a.get("page"), b.get("page")
    if aVol is not None and bVol is not None:
        return EXACT if (aVol == bVol and aPage == bPage) else NO_MATCH
    if aVol is None and bVol is None:
        return EXACT
    return PARTIAL


def _match_familysearch_census(a: CitedIdentifier, b: CitedIdentifier) -> str:
    if a.get("year") != b.get("year"):
        return NO_MATCH
    aArk, bArk = a.get("ark"), b.get("ark")
    if aArk is not None and bArk is not None:
        return EXACT if aArk == bArk else NO_MATCH
    return PARTIAL


def _match_cwgc(a: CitedIdentifier, b: CitedIdentifier) -> str:
    aPlot, bPlot = a.get("plot"), b.get("plot")
    if aPlot is not None and bPlot is not None:
        return EXACT if aPlot == bPlot else NO_MATCH
    aDod, bDod = a.get("date_of_death"), b.get("date_of_death")
    if aDod and aDod == bDod:
        return PARTIAL
    return NO_MATCH


def _match_generic(a: CitedIdentifier, b: CitedIdentifier) -> str:
    return EXACT if a.identifiers == b.identifiers else NO_MATCH


def equivalent(a: CitedIdentifier, b: CitedIdentifier) -> str:
    """Symmetric matcher: returns 'exact', 'partial', or 'no_match'."""
    if _family(a.source) != _family(b.source):
        return NO_MATCH
    if a.kind != b.kind:
        return NO_MATCH
    fam = _family(a.source)
    if fam == "freebmd":
        return _match_freebmd(a, b)
    if fam == "familysearch":
        return _match_familysearch_census(a, b)
    if fam == "cwgc":
        return _match_cwgc(a, b)
    return _match_generic(a, b)


# --- Reproduction-rate helper ---------------------------------------------

def count_reproduced(gedcom_cites: list[dict], pipeline_cites: list[str]) -> int:
    """Return the number of GEDCOM citations the pipeline reproduced.

    Counts both 'exact' and 'partial' matches — partial is appropriate when
    a side is missing secondary identifiers (e.g. bio prose lacks vol/page
    but primary keys match). Each GEDCOM citation matches at most once.
    """
    gedcom = [from_gedcom_dict(c) for c in gedcom_cites]
    pipeline: list[CitedIdentifier] = []
    for s in pipeline_cites:
        parsed = parse_pipeline_citation(s)
        if parsed is not None:
            pipeline.append(parsed)

    matched: set[int] = set()
    reproduced = 0
    for g in gedcom:
        for i, p in enumerate(pipeline):
            if i in matched:
                continue
            verdict = equivalent(g, p)
            if verdict in (EXACT, PARTIAL):
                matched.add(i)
                reproduced += 1
                break
    return reproduced
