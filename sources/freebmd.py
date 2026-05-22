"""
freebmd.py — Reusable FreeBMD search library

FreeBMD (freebmd.org.uk) is a volunteer transcription of England & Wales
civil registration indexes 1837–1983. This library provides programmatic
access via the same POST API used by the website's search form.

Usage:
    from freebmd import search, ASHBOURNE, BELPER

    results = search("Births", "Barker", given="Elizabeth",
                     start=1845, end=1870, district=ASHBOURNE)
    for r in results:
        print(r["quarter"], r["year"], r["surname"], r["firstname"])

Search types:  "Births", "Deaths", "Marriages", "All"
Districts:     Use the integer constants below, or pass any FreeBMD district ID.

FreeBMD data notes:
  - Mother's maiden name (births) only appears from Sep 1911 onwards.
  - Spouse surname (marriages) only appears from Sep 1912 onwards.
  - Coverage is incomplete — especially for pre-1865 records.
  - Bakewell district (ID "420") has essentially no coverage before 1941.
    Matlock, Darley Dale, Youlgreave, and Snitterton all fall within
    Bakewell registration district. Use Ancestry or GRO certificates instead.
  - start/end must be integers (year only). Passing strings silently
    returns all records with no date filtering.
  - GRO terms prohibit automated scraping of gro.gov.uk; FreeBMD is a
    separate volunteer project with its own terms allowing this use.

Response row format (raw semicolon-delimited):
  Births/Deaths separator:  " ;0;QUARTER;YEAR"  (0=births, 1=deaths)
  Marriages separator:      " ;2;QUARTER;YEAR"
  Data row:  confidence;surname;firstname;mother_or_spouse;district_flag;district;vol;page;id

Quarter numbers: 1=Mar, 2=Jun, 3=Sep, 4=Dec
"""

import urllib.request
import urllib.parse
import re

# Common Derbyshire/Nottinghamshire district IDs
ASHBOURNE = "418"
BELPER = "722"
BASFORD = "676"    # covers Loscoe/Heanor area
BAKEWELL = "420"
CHESTERFIELD = "621"
DERBY = "710"
WORKSOP = "765"

QUARTER_NAMES = {"1": "Mar", "2": "Jun", "3": "Sep", "4": "Dec"}
# Reverse: quarter name → number
QUARTER_NUMS = {v: k for k, v in QUARTER_NAMES.items()}


def _get_session():
    """Fetch a fresh session cookie and hidden form tokens from FreeBMD."""
    req = urllib.request.Request(
        "https://www.freebmd.org.uk/search",
        headers={"User-Agent": "Mozilla/5.0 (compatible; genealogy-research)"}
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        html = r.read().decode("utf-8", errors="replace")
        cookie = r.headers.get("Set-Cookie", "").split(";")[0]
    db = re.search(r'name="db"\s+value="([^"]+)"', html)
    v  = re.search(r'name="v"\s+value="([^"]+)"', html)
    return cookie, db.group(1) if db else "", v.group(1) if v else ""


def _parse_html(html):
    """
    Parse the searchData JavaScript array from a FreeBMD results page.

    Returns a list of dicts with keys:
      year, quarter, surname, firstname, spouse_or_mother,
      district, vol, page, record_id

    Returns a string (error message) if no data was found.
    """
    m = re.search(r'var searchData = new Array \((.*?)\);', html, re.DOTALL)
    if not m:
        # Check for count-too-large message
        cnt = re.search(r'(\d[\d,]+)\s+entr', html, re.IGNORECASE)
        if cnt:
            return f"Too many results ({cnt.group(1)}) — narrow search with more specific criteria"
        err = re.search(r'<em>([^<]+)</em>', html)
        if err and "error" in html.lower():
            return f"FreeBMD error: {err.group(1).strip()}"
        return "No results found"

    rows = re.findall(r'"([^"]*)"', m.group(1))
    records = []
    current_year = None
    current_quarter = None

    for row in rows:
        parts = row.split(";")
        # Separator rows: parts[1] in ("0","1","2") = births/deaths/marriages
        # parts[2] is quarter digit (1-4), parts[3] is the year
        if (len(parts) >= 4
                and parts[1] in ("0", "1", "2")
                and parts[2] in ("1", "2", "3", "4")):
            current_quarter = QUARTER_NAMES[parts[2]]
            try:
                current_year = int(parts[3])
            except ValueError:
                current_year = None

        elif (len(parts) >= 8
              and parts[2] not in ("", "Q")
              and not parts[2].startswith("/")):
            records.append({
                "year": current_year,
                "quarter": current_quarter,
                "surname": parts[1],
                "firstname": urllib.parse.unquote(parts[2]),
                "spouse_or_mother": urllib.parse.unquote(parts[3]).strip(),
                "district": parts[5],
                "vol": parts[6],
                "page": parts[7],
                "record_id": parts[8].split(":")[0] if len(parts) > 8 else "",
            })

    return records


def search(record_type, surname, given="", start=None, end=None,
           district="", s_surname="", s_given=""):
    """
    Search FreeBMD for birth, death, or marriage records.

    Args:
        record_type: "Births", "Deaths", "Marriages", or "All"
        surname:     Surname to search (required)
        given:       Given/first name (optional)
        start:       Start year as int, e.g. 1845
        end:         End year as int, e.g. 1870
        district:    District ID string (use constants: ASHBOURNE, BELPER, etc.)
                     or "" for all districts
        s_surname:   Spouse/mother surname (marriages/births from 1912/1911)
        s_given:     Spouse/mother given name

    Returns:
        List of result dicts, or a string error message.

    Each result dict contains:
        year (int or None), quarter (str e.g. "Mar"), surname, firstname,
        spouse_or_mother, district, vol, page, record_id
    """
    cookie, db, v = _get_session()

    fields = [
        ("type", record_type),
        ("surname", surname),
        ("given", given),
        ("s_surname", s_surname),
        ("s_given", s_given),
        ("start", str(start) if start else ""),
        ("end", str(end) if end else ""),
        # sq/eq are the start/end quarter dropdowns on the FreeBMD form.
        # Without them, the server silently ignores the year range filter
        # and returns matches across all years.
        ("sq", "1"),
        ("eq", "4"),
        ("districtid", str(district)),
        ("db", db),
        ("v", v),
        ("find.x", "1"),
        ("find.y", "1"),
    ]

    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        "https://www.freebmd.org.uk/cgi/search.pl",
        data=data,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; genealogy-research)",
            "Cookie": cookie,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        html = r.read().decode("utf-8", errors="replace")

    return _parse_html(html)


def print_results(results, title=None, year_filter=None):
    """
    Pretty-print a list of FreeBMD results.

    Args:
        results:     Output of search()
        title:       Optional header string
        year_filter: Optional (start_year, end_year) tuple to filter
    """
    if title:
        print(f"\n=== {title} ===")
    if isinstance(results, str):
        print(f"  {results}")
        return
    shown = results
    if year_filter:
        lo, hi = year_filter
        shown = [r for r in results if r["year"] and lo <= r["year"] <= hi]
    print(f"  {len(shown)} result(s)")
    for r in shown:
        spouse_str = f" / {r['spouse_or_mother']}" if r["spouse_or_mother"] else ""
        yr = f"{r['quarter']} {r['year']}" if r["year"] else "date unknown"
        dist = r["district"] or ""
        ref = f"vol{r['vol']} p{r['page']}" if r["vol"] else f"p{r['page']}"
        print(f"  {yr:12} | {r['surname']}, {r['firstname']}{spouse_str} | {dist} {ref}")


# ---------------------------------------------------------------------------
# Quick demo when run directly
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("FreeBMD library — quick demo")
    print("Searching: Elizabeth Barker births, Ashbourne, 1845-1870")
    r = search("Births", "Barker", given="Elizabeth", start=1845, end=1870, district=ASHBOURNE)
    print_results(r)

    print("\nSearching: John Cauldwell marriages, Belper, 1875-1885")
    r = search("Marriages", "Cauldwell", given="John", start=1875, end=1885, district=BELPER)
    print_results(r)
