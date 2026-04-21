"""
findagrave.py — Reusable Find a Grave search library

Find a Grave (findagrave.com) is the world's largest gravesite collection,
with over 230 million memorial records. This library provides programmatic
access via the internal JSON API used by the website's search page.

Usage:
    from findagrave import search

    results = search("Cauldwell", first_name="Robert")
    for r in results:
        print(r["name"], r["death_date"], r["cemetery"])

    # With year filters and location
    results = search("Brooks", first_name="George", death_year=1937,
                     location="Derbyshire, England")

    # Fetch full memorial details (bio, inscription) for a specific record
    detail = fetch_memorial(10772492)
    print(detail["bio"])

Search parameters:
    surname:     Required. Last name to search.
    first_name:  Optional. First name(s). Use full first name, not initials.
    birth_year:  Optional. Year of birth (int).
    death_year:  Optional. Year of death (int).
    location:    Optional. Location string, e.g. "Derbyshire, England".
                 Defaults to "" (worldwide). Use county/state + country format.
    year_range:  Optional. Tolerance for year filters. Default 0 (exact).
                 Values: 1, 2, 3, 4, 5, 10, 25.
    limit:       Optional. Max results to return. Default 20.

Return format (search):
    List of dicts with keys:
        name, birth_date, death_date, burial_location, cemetery,
        memorial_id, memorial_url, plot, is_veteran

Return format (fetch_memorial):
    Dict with keys:
        name, birth_date, death_date, birth_place, death_place,
        cemetery, cemetery_url, burial_location, bio, inscription,
        memorial_id, memorial_url, plot

Find a Grave data notes:
  - Records are contributed by volunteers; coverage varies by region.
  - Military cemeteries (CWGC, VA) tend to have good coverage.
  - Bio text often contains CWGC or obituary data added by contributors.
  - Inscription field is separate from bio; many memorials lack inscriptions.
  - The "location" filter searches cemetery location, not birth/death place.
"""

import urllib.request
import urllib.parse
import json
import re
import sys

# Common location strings for UK genealogy research
DERBYSHIRE = "Derbyshire, England"
STAFFORDSHIRE = "Staffordshire, England"
NOTTINGHAMSHIRE = "Nottinghamshire, England"
YORKSHIRE = "Yorkshire, England"

# Year range filter values accepted by the API
# 0 = exact, 1-5 = +/- N years, 10 = +/- 10, 25 = +/- 25
YEAR_EXACT = "exact"
YEAR_1 = "1"
YEAR_2 = "2"
YEAR_3 = "3"
YEAR_5 = "5"
YEAR_10 = "10"
YEAR_25 = "25"

_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

_BASE_URL = "https://www.findagrave.com"
_SEARCH_URL = f"{_BASE_URL}/memorial/search"


def _make_request(url, headers=None):
    """Make an HTTP request with appropriate headers."""
    hdrs = {
        "User-Agent": _USER_AGENT,
    }
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, headers=hdrs)
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", errors="replace")


def _parse_record(rec):
    """Convert a raw API record dict to our standardised output format."""
    # Build burial location from city/state/country
    location_parts = []
    for key in ("cemeteryCityName", "cemeteryStateName", "cemeteryCountryName"):
        val = rec.get(key)
        if val:
            location_parts.append(val)
    burial_location = ", ".join(location_parts)

    memorial_id = rec.get("memorialId", "")
    name_url = rec.get("nameForURL", "")

    return {
        "name": rec.get("titleName", rec.get("fullName", "")),
        "birth_date": rec.get("birthDate", "unknown"),
        "death_date": rec.get("deathDate", "unknown"),
        "burial_location": burial_location,
        "cemetery": rec.get("cemeteryName", ""),
        "memorial_id": memorial_id,
        "memorial_url": f"{_BASE_URL}/memorial/{memorial_id}/{name_url}",
        "plot": rec.get("plot", ""),
        "is_veteran": rec.get("isVeteran", False),
    }


def search(surname, first_name="", birth_year=None, death_year=None,
           location="", year_range=0, limit=20):
    """
    Search Find a Grave for memorial records.

    Args:
        surname:     Last name (required).
        first_name:  First name(s) (optional).
        birth_year:  Birth year as int (optional).
        death_year:  Death year as int (optional).
        location:    Location filter string, e.g. "Derbyshire, England".
        year_range:  Year tolerance: 0 (exact), 1, 2, 3, 5, 10, or 25.
        limit:       Max results to return (default 20, max ~100).

    Returns:
        List of result dicts, or a string error message.

    Each result dict contains:
        name, birth_date, death_date, burial_location, cemetery,
        memorial_id, memorial_url, plot, is_veteran
    """
    params = {
        "ajax": "true",
        "skip": "0",
        "limit": str(limit),
        "lastname": surname,
    }
    if first_name:
        params["firstname"] = first_name
    if birth_year is not None:
        params["birthyear"] = str(birth_year)
        if year_range:
            params["birthyearfilter"] = str(year_range)
    if death_year is not None:
        params["deathyear"] = str(death_year)
        if year_range:
            params["deathyearfilter"] = str(year_range)
    if location:
        params["location"] = location

    url = _SEARCH_URL + "?" + urllib.parse.urlencode(params)

    try:
        raw = _make_request(url, headers={
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/html, */*",
        })
    except Exception as e:
        return f"Request failed: {e}"

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return "Failed to parse response — site may have changed"

    if data.get("responseCode") != 200:
        return f"API error (code {data.get('responseCode')})"

    records = data.get("records", [])
    if not records:
        total = data.get("total", 0)
        if total == 0:
            return "No results found"
        if data.get("tooMany"):
            return f"Too many results ({total}) — narrow search"

    return [_parse_record(r) for r in records]


def fetch_memorial(memorial_id):
    """
    Fetch full details for a specific memorial by ID.

    Scrapes the memorial page to extract bio text, inscription,
    birth/death places, and cemetery details not available from
    the search API.

    Args:
        memorial_id: Integer or string memorial ID.

    Returns:
        Dict with keys: name, birth_date, death_date, birth_place,
        death_place, cemetery, cemetery_url, burial_location, bio,
        inscription, memorial_id, memorial_url, plot
        Or a string error message.
    """
    url = f"{_BASE_URL}/memorial/{memorial_id}"

    try:
        html = _make_request(url)
    except Exception as e:
        return f"Request failed: {e}"

    result = {
        "memorial_id": int(memorial_id),
        "memorial_url": url,
        "name": "",
        "birth_date": "",
        "death_date": "",
        "birth_place": "",
        "death_place": "",
        "cemetery": "",
        "cemetery_url": "",
        "burial_location": "",
        "bio": "",
        "inscription": "",
        "plot": "",
    }

    # Name — from <title> or schema.org markup
    title_m = re.search(
        r'<title>([^(]+)\s*\(', html
    )
    if title_m:
        result["name"] = title_m.group(1).strip().replace(" - Find a Grave Memorial", "")

    # Birth date
    m = re.search(r'itemprop="birthDate">([^<]+)<', html)
    if m:
        result["birth_date"] = m.group(1).strip()

    # Death date
    m = re.search(r'itemprop="deathDate">([^<]+)<', html)
    if m:
        result["death_date"] = re.sub(r'\s*\(aged.*\)', '', m.group(1).strip())

    # Birth place
    m = re.search(r'itemprop="birthPlace">\s*(.*?)\s*</div>', html, re.DOTALL)
    if m:
        result["birth_place"] = re.sub(r'<[^>]+>', '', m.group(1)).strip()
        result["birth_place"] = re.sub(r'\s+', ' ', result["birth_place"])

    # Death place
    m = re.search(r'itemprop="deathPlace">\s*(.*?)\s*</div>', html, re.DOTALL)
    if m:
        result["death_place"] = re.sub(r'<[^>]+>', '', m.group(1)).strip()
        result["death_place"] = re.sub(r'\s+', ' ', result["death_place"])

    # Cemetery name and URL
    m = re.search(
        r'itemprop="url"\s+class="[^"]*"><span[^>]*itemprop="name">([^<]+)</span></a>',
        html
    )
    if m:
        result["cemetery"] = m.group(1).strip()
    m = re.search(r'<a href="(/cemetery/\d+/[^"]+)"[^>]*itemprop="url"', html)
    if m:
        result["cemetery_url"] = _BASE_URL + m.group(1)

    # Burial location from cemetery address
    loc_parts = []
    for field, prop in [
        ("city", "addressLocality"),
        ("state", "addressRegion"),
        ("country", "addressCountry"),
    ]:
        m = re.search(rf'itemprop="{prop}">([^<]+)<', html)
        if m:
            loc_parts.append(m.group(1).strip())
    if loc_parts:
        result["burial_location"] = ", ".join(loc_parts)

    # Bio text (from the fullBio div)
    m = re.search(r'id="fullBio">(.*?)</div>', html, re.DOTALL)
    if not m:
        m = re.search(r'id="partBio">(.*?)</div>', html, re.DOTALL)
    if m:
        bio_html = m.group(1)
        # Convert <p> and <br> to newlines, strip other tags
        bio_text = re.sub(r'<br\s*/?>', '\n', bio_html)
        bio_text = re.sub(r'</p>\s*<p>', '\n', bio_text)
        bio_text = re.sub(r'<[^>]+>', '', bio_text)
        bio_text = bio_text.strip()
        result["bio"] = bio_text

    # Inscription (separate from bio — rendered in its own section)
    m = re.search(
        r'id="inscriptionValue"[^>]*>(.*?)</(?:div|span)',
        html, re.DOTALL
    )
    if m:
        insc_text = re.sub(r'<[^>]+>', '', m.group(1)).strip()
        result["inscription"] = insc_text

    # Plot
    m = re.search(r'id="plotValueLabel"[^>]*>([^<]+)<', html)
    if m:
        result["plot"] = m.group(1).strip()

    return result


def print_results(results, title=None):
    """
    Pretty-print a list of Find a Grave results.

    Args:
        results: Output of search() or a string error message.
        title:   Optional header string.
    """
    if title:
        print(f"\n=== {title} ===")
    if isinstance(results, str):
        print(f"  {results}")
        return
    print(f"  {len(results)} result(s)")
    for r in results:
        vet = " [Veteran]" if r.get("is_veteran") else ""
        print(
            f"  {r['name']:40} | "
            f"{r['birth_date']:>12} - {r['death_date']:<16} | "
            f"{r['cemetery']}{vet}"
        )
        if r.get("burial_location"):
            print(f"  {'':40}   {r['burial_location']}")
        print(f"  {'':40}   {r['memorial_url']}")


def print_memorial(detail):
    """Pretty-print a full memorial detail dict."""
    if isinstance(detail, str):
        print(f"  {detail}")
        return
    print(f"\n=== {detail['name']} (Memorial #{detail['memorial_id']}) ===")
    print(f"  Born:     {detail['birth_date'] or 'unknown'}")
    if detail["birth_place"]:
        print(f"            {detail['birth_place']}")
    print(f"  Died:     {detail['death_date'] or 'unknown'}")
    if detail["death_place"]:
        print(f"            {detail['death_place']}")
    print(f"  Cemetery: {detail['cemetery']}")
    if detail["burial_location"]:
        print(f"            {detail['burial_location']}")
    if detail["plot"]:
        print(f"  Plot:     {detail['plot']}")
    if detail["bio"]:
        print(f"  Bio:      {detail['bio']}")
    if detail["inscription"]:
        print(f"  Inscr:    {detail['inscription']}")
    print(f"  URL:      {detail['memorial_url']}")


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------
def _cli():
    """Command-line interface for Find a Grave searches."""
    args = sys.argv[1:]

    if not args or args[0] in ("-h", "--help", "help"):
        print("Usage:")
        print("  python findagrave.py search SURNAME [FIRSTNAME] [BIRTHYEAR] [DEATHYEAR] [LOCATION]")
        print("  python findagrave.py memorial MEMORIAL_ID")
        print()
        print("Examples:")
        print("  python findagrave.py search Cauldwell Robert")
        print("  python findagrave.py search Cauldwell Robert 1885 1918")
        print("  python findagrave.py search Brooks George 1870 1937 'Derbyshire, England'")
        print("  python findagrave.py memorial 10772492")
        return

    command = args[0].lower()

    if command == "search":
        if len(args) < 2:
            print("Error: surname is required")
            return
        surname = args[1]
        first_name = args[2] if len(args) > 2 else ""
        birth_year = int(args[3]) if len(args) > 3 and args[3].isdigit() else None
        death_year = int(args[4]) if len(args) > 4 and args[4].isdigit() else None
        location = args[5] if len(args) > 5 else ""

        title = f"Find a Grave: {first_name} {surname}".strip()
        if birth_year:
            title += f" b.{birth_year}"
        if death_year:
            title += f" d.{death_year}"
        if location:
            title += f" ({location})"

        results = search(
            surname,
            first_name=first_name,
            birth_year=birth_year,
            death_year=death_year,
            location=location,
        )
        print_results(results, title=title)

    elif command == "memorial":
        if len(args) < 2:
            print("Error: memorial ID is required")
            return
        memorial_id = args[1]
        detail = fetch_memorial(memorial_id)
        print_memorial(detail)

    else:
        print(f"Unknown command: {command}")
        print("Use 'search' or 'memorial'. Run with --help for usage.")


if __name__ == "__main__":
    _cli()
