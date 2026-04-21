"""
freecen.py — Reusable FreeCen search library

FreeCen (freecen.org.uk) is a volunteer transcription of England & Wales
census records 1841–1911. This library provides programmatic access via
the same POST form used by the website's search interface.

Usage:
    from freecen import search, detail, search_detail

    # Quick search — returns summary results (no HTTP per record)
    results = search("Cauldwell", county="DBY", year=1891)
    for r in results:
        print(r["name"], r["birth_year"], r["census_district"])

    # Full detail search — returns flat dicts with all census fields
    # (name, age, sex, occupation, birth_place, relationship, address,
    #  parish, county, census_year, piece_folio)
    records = search_detail("Land", first_name="George", year=1891, county="DBY")
    for r in records:
        print(r["name"], r["age"], r["occupation"], r["address"])

    # Get full household from a specific record page
    household = detail(results[0]["record_url"])
    for person in household["members"]:
        print(person["name"], person["age"], person["occupation"])

County codes:  Use Chapman codes (e.g. "DBY" for Derbyshire).
Census years:  1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911.

FreeCen data notes:
  - Coverage is incomplete — depends on volunteer transcription progress.
  - The database is a finding tool; verify results against original images.
  - 1901 and 1911 coverage is particularly patchy for some counties.
"""

import urllib.request
import urllib.parse
import re
import html as html_module
import sys

# Common Chapman county codes
DERBYSHIRE = "DBY"
NOTTINGHAMSHIRE = "NTT"
STAFFORDSHIRE = "STS"
YORKSHIRE_WEST = "YKS"  # West Riding
LANCASHIRE = "LAN"
LINCOLNSHIRE = "LIN"
LEICESTERSHIRE = "LEI"
CHESHIRE = "CHS"
WARWICKSHIRE = "WAR"

VALID_YEARS = {1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911}

_BASE = "https://www.freecen.org.uk"


def _get_session():
    """Fetch a fresh session cookie and CSRF token from FreeCen."""
    req = urllib.request.Request(
        f"{_BASE}/search_records",
        headers={"User-Agent": "Mozilla/5.0 (compatible; genealogy-research)"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        html = r.read().decode("utf-8", errors="replace")
        cookie = r.headers.get("Set-Cookie", "").split(";")[0]

    csrf = re.search(r'<meta name="csrf-token" content="([^"]+)"', html)
    return cookie, csrf.group(1) if csrf else ""


def _clean(text):
    """Strip HTML tags and decode entities from a string."""
    text = re.sub(r"<[^>]+>", "", text)
    text = html_module.unescape(text)
    return text.strip()


def _parse_results(html):
    """
    Parse the search results HTML table from FreeCen.

    Returns a list of dicts or a string error message.
    Each dict has keys:
        name, birth_county, birth_place, birth_year,
        census_year, census_county, census_district, record_url
    """
    # Check result count
    count_match = re.search(r"We found (\d+)\s+Results?", html)
    if not count_match:
        if "No results found" in html:
            return "No results found"
        return "Could not parse results page"

    count = int(count_match.group(1))
    if count == 0:
        return "No results found"

    rows = re.findall(r"<tr[^>]*>(.*?)</tr>", html, re.DOTALL)
    records = []

    for row in rows:
        tds = re.findall(r"<td[^>]*>(.*?)</td>", row, re.DOTALL)
        if len(tds) < 8:
            continue

        # Extract record URL from the View link in td[0]
        link = re.search(r'href="(/search_records/[^"]+)"', tds[0])
        record_url = f"{_BASE}{link.group(1)}" if link else ""

        name = _clean(tds[1])
        birth_county = _clean(tds[2])
        birth_place = _clean(tds[3])
        birth_year_str = _clean(tds[4])
        census_year_str = _clean(tds[5])
        census_county = _clean(tds[6])
        census_district = _clean(tds[7])

        try:
            birth_year = int(birth_year_str)
        except (ValueError, TypeError):
            birth_year = None

        try:
            census_year = int(census_year_str)
        except (ValueError, TypeError):
            census_year = None

        records.append({
            "name": name,
            "birth_county": birth_county,
            "birth_place": birth_place,
            "birth_year": birth_year,
            "census_year": census_year,
            "census_county": census_county,
            "census_district": census_district,
            "record_url": record_url,
        })

    return records


def search(surname, first_name="", year=None, county="DBY", district=""):
    """
    Search FreeCen for census records.

    Args:
        surname:     Surname to search (required).
        first_name:  First/given name (optional).
        year:        Census year as int (1841-1911) or None for all years.
        county:      Chapman county code (default "DBY" for Derbyshire).
                     Use "" for all counties.
        district:    Registration district name (not currently supported
                     via the simple search — filter results instead).

    Returns:
        List of result dicts, or a string error message.

    Each result dict contains:
        name (str), birth_county (str), birth_place (str),
        birth_year (int or None), census_year (int or None),
        census_county (str), census_district (str), record_url (str)
    """
    if year is not None and year not in VALID_YEARS:
        return f"Invalid census year {year}. Valid years: {sorted(VALID_YEARS)}"

    cookie, csrf = _get_session()

    fields = [
        ("utf8", "\u2713"),
        ("authenticity_token", csrf),
        ("search_query[last_name]", surname),
        ("search_query[first_name]", first_name),
        ("search_query[record_type]", str(year) if year else ""),
        ("search_query[fuzzy]", "0"),
        ("search_query[search_nearby_places]", "0"),
        ("search_query[disabled]", "0"),
        ("search_query[start_year]", ""),
        ("search_query[end_year]", ""),
        ("search_query[sex]", ""),
        ("search_query[marital_status]", ""),
        ("search_query[occupation]", ""),
    ]
    if county:
        fields.append(("search_query[chapman_codes][]", county))

    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        f"{_BASE}/search_queries",
        data=data,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; genealogy-research)",
            "Cookie": cookie,
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": f"{_BASE}/search_records",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        html = r.read().decode("utf-8", errors="replace")

    results = _parse_results(html)

    # Post-filter by district if requested
    if district and isinstance(results, list):
        district_lower = district.lower()
        results = [
            r for r in results
            if district_lower in r["census_district"].lower()
        ]

    return results


def detail(record_url):
    """
    Fetch full household details from a FreeCen individual record page.

    Args:
        record_url: Full URL to a FreeCen search_records page,
                    as returned in the record_url field from search().

    Returns:
        Dict with keys:
            dwelling: dict with census location info
                (census_year, county, district, parish, piece, folio,
                 page, schedule, address)
            members: list of dicts, each with:
                (name, surname, forenames, relationship, marital_status,
                 sex, age, occupation, birth_county, birth_place,
                 disability, notes, is_target)
    """
    req = urllib.request.Request(
        record_url,
        headers={"User-Agent": "Mozilla/5.0 (compatible; genealogy-research)"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        html = r.read().decode("utf-8", errors="replace")

    tables = re.findall(r"<table[^>]*>(.*?)</table>", html, re.DOTALL)

    dwelling = {}
    members = []

    # Table 0: dwelling location details
    if len(tables) >= 1:
        cells = [
            _clean(c)
            for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tables[0], re.DOTALL)
        ]
        # Layout: 12 header cells then 12 value cells (or 11 values if
        # House Number is blank). Headers are fixed:
        # Census, County, District, Civil Parish, Ecclesiastical Parish,
        # Piece, Enumeration District, Folio, Page, Schedule,
        # House Number, House or Street Name
        header_keys = [
            "census_year", "county", "district", "parish",
            "ecclesiastical_parish", "piece", "enumeration_district",
            "folio", "page", "schedule", "house_number", "address",
        ]
        # Find where the numeric year starts (first value cell)
        val_start = None
        for i, c in enumerate(cells):
            if re.match(r"^1[89]\d\d$", c):
                val_start = i
                break
        if val_start is not None:
            for j, key in enumerate(header_keys):
                idx = val_start + j
                if idx < len(cells):
                    dwelling[key] = cells[idx]

    # Table 1: household members
    if len(tables) >= 2:
        cells = [
            _clean(c)
            for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tables[1], re.DOTALL)
        ]
        # First 11 cells are headers:
        # Surname, Forenames, Relationship, Marital Status, Sex, Age,
        # Occupation, Birth County, Birth Place, Disability, Notes
        # Then data rows of 11 cells each. The target person's first
        # cell contains "the person found in your search\nSURNAME"
        # so we need to split that marker from the surname.
        member_keys = [
            "surname", "forenames", "relationship", "marital_status",
            "sex", "age", "occupation", "birth_county", "birth_place",
            "disability", "notes",
        ]

        # Skip header cells (first 11)
        data_cells = cells[11:]

        # Process cells: split marker+surname cells, track target
        processed = []
        target_row_start = None
        for c in data_cells:
            if "person found in your search" in c.lower():
                # Extract the surname that follows the marker text
                parts = c.split("\n")
                surname = ""
                for p in parts:
                    p = p.strip()
                    if p and "person found" not in p.lower():
                        surname = p
                        break
                target_row_start = len(processed)
                processed.append(surname)
            else:
                processed.append(c)

        # Group into rows of 11
        i = 0
        while i + 10 < len(processed):
            row_data = processed[i : i + 11]
            member = dict(zip(member_keys, row_data))
            member["name"] = f"{member.get('forenames', '')} {member.get('surname', '')}".strip()
            member["is_target"] = (i == target_row_start)
            members.append(member)
            i += 11

    return {"dwelling": dwelling, "members": members}


def search_detail(surname, first_name="", year=None, county="DBY", district=""):
    """
    Search FreeCen and fetch detail for each result, returning flat dicts.

    This combines search() + detail() and returns a list of dicts with
    the keys requested for the standard census record format:
        name, age, sex, occupation, birth_place, relationship,
        address, parish, county, census_year, piece_folio

    Note: This makes one HTTP request per search result, so it is slower
    than search() alone. Use search() for quick lookups, and this function
    when you need full household/occupation data.

    Returns:
        List of dicts, or a string error message.
    """
    results = search(surname, first_name=first_name, year=year,
                     county=county, district=district)
    if isinstance(results, str):
        return results

    records = []
    for r in results:
        if not r.get("record_url"):
            continue
        try:
            d = detail(r["record_url"])
        except Exception:
            continue

        dw = d.get("dwelling", {})
        piece_folio = f"{dw.get('piece', '')}/{dw.get('folio', '')}"
        address = dw.get("address", "")
        parish = dw.get("parish", "")
        cen_county = dw.get("county", "")

        for m in d.get("members", []):
            records.append({
                "name": m.get("name", ""),
                "age": m.get("age", ""),
                "sex": m.get("sex", ""),
                "occupation": m.get("occupation", ""),
                "birth_place": m.get("birth_place", ""),
                "relationship": m.get("relationship", ""),
                "address": address,
                "parish": parish,
                "county": cen_county,
                "census_year": r.get("census_year"),
                "piece_folio": piece_folio,
            })

    return records


def print_results(results, title=None):
    """Pretty-print a list of FreeCen search results."""
    if title:
        print(f"\n=== {title} ===")
    if isinstance(results, str):
        print(f"  {results}")
        return
    print(f"  {len(results)} result(s)")
    for r in results:
        birth = f"b.{r['birth_year']}" if r["birth_year"] else "b.?"
        print(
            f"  {r['census_year']} | {r['name']:30s} | {birth:6s} "
            f"| {r['birth_place']:20s} | {r['census_district']}"
        )


def print_household(detail_data):
    """Pretty-print household detail from a FreeCen record page."""
    d = detail_data["dwelling"]
    print(f"\n--- {d.get('parish', '?')}, {d.get('district', '?')} "
          f"({d.get('census_year', '?')}) ---")
    addr = d.get("address", "")
    if addr:
        print(f"  Address: {addr}")
    ref = f"piece {d.get('piece', '?')} folio {d.get('folio', '?')} " \
          f"page {d.get('page', '?')}"
    print(f"  Ref: {ref}")
    print()
    fmt = "  {:<3s} {:<20s} {:<10s} {:<3s} {:<4s} {:<20s} {:<20s}"
    print(fmt.format("", "Name", "Relation", "Sex", "Age", "Occupation", "Birth Place"))
    print("  " + "-" * 82)
    for m in detail_data["members"]:
        marker = " *" if m.get("is_target") else "  "
        name = m.get("name", "?")
        print(fmt.format(
            marker, name[:20], m.get("relationship", "")[:10],
            m.get("sex", ""), m.get("age", ""),
            m.get("occupation", "")[:20], m.get("birth_place", "")[:20],
        ))


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------
def _cli():
    """Command-line interface for FreeCen searches."""
    args = sys.argv[1:]

    if not args or args[0] in ("-h", "--help", "help"):
        print("Usage: python freecen.py search SURNAME [FIRSTNAME] [YEAR] [COUNTY]")
        print("       python freecen.py detail URL")
        print()
        print("Examples:")
        print("  python freecen.py search Cauldwell")
        print("  python freecen.py search Cauldwell John 1891 DBY")
        print("  python freecen.py search Land George 1901 DBY")
        print("  python freecen.py detail https://www.freecen.org.uk/search_records/...")
        print()
        print(f"Valid census years: {sorted(VALID_YEARS)}")
        print("County codes: DBY (Derbyshire), NTT (Nottinghamshire), etc.")
        return

    cmd = args[0].lower()

    if cmd == "search":
        if len(args) < 2:
            print("Error: surname required")
            sys.exit(1)

        surname = args[1]
        first_name = args[2] if len(args) > 2 and not args[2].isdigit() else ""
        # Find year argument (first numeric arg)
        year = None
        county = "DBY"
        for a in args[2:]:
            if a.isdigit() and len(a) == 4:
                year = int(a)
            elif a.isdigit():
                pass  # skip other numbers
            elif len(a) == 3 and a.isupper():
                county = a
            elif a == first_name:
                continue
            else:
                county = a

        print(f"Searching FreeCen: {surname}"
              f"{', ' + first_name if first_name else ''}"
              f"{', ' + str(year) if year else ''}"
              f", county={county}")
        results = search(surname, first_name=first_name, year=year, county=county)
        print_results(results)

        # If we got results, show detail for first one
        if isinstance(results, list) and results:
            print(f"\n  Fetching household for first result...")
            d = detail(results[0]["record_url"])
            print_household(d)

    elif cmd == "detail":
        if len(args) < 2:
            print("Error: URL required")
            sys.exit(1)
        url = args[1]
        d = detail(url)
        print_household(d)

    else:
        print(f"Unknown command: {cmd}")
        print("Use 'search' or 'detail'")
        sys.exit(1)


if __name__ == "__main__":
    _cli()
