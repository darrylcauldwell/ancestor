"""
probate.py — Reusable England & Wales Probate Calendar search library

The Probate Calendar (probatesearch.service.gov.uk) is the official HMCTS
service for searching grants of probate, letters of administration, and
soldier wills for England & Wales.

The website is a Vue.js SPA backed by a Nuxeo document management system.
This library queries the underlying JSON API directly (the same Nuxeo
page-provider endpoint the website uses), requiring no authentication for
read-only searches.

Usage:
    from probate import search

    results = search("Cauldwell")
    results = search("Cauldwell", first_name="John")
    results = search("Cauldwell", year_from=2000, year_to=2010)

    for r in results:
        print(r["name"], r["death_date"], r["grant_type"], r["registry"])

Coverage notes:
  - Digital grants: mainly from ~1996 onwards (probate/administration).
  - Soldier wills: WWI/WWII era (separate collection, included in results).
  - Pre-1996 records are NOT in this system — use The National Archives
    or physical Probate Calendar volumes for earlier periods.
  - The API returns a maximum of 1000 results per query; use date ranges
    to narrow large result sets.

Return dict keys:
  name            Full name (firstnames + surname)
  surname         Surname as stored
  first_names     First/given names as stored
  death_date      Date of death (YYYY-MM-DD string, or None)
  probate_date    Date of probate/grant (YYYY-MM-DD string, or None)
  birth_date      Date of birth (YYYY-MM-DD string, or None)
  age_at_death    Age at death (int or None)
  address         Address lines joined (or empty string)
  postcode        Postcode (or empty string)
  title           Title/honorific (or empty string)
  grant_type      E.g. "PROBATE", "ADMINISTRATION", "ADMON/WILL"
  registry        Probate registry office name
  probate_number  Grant/probate reference number
  regiment_number Regiment number (soldier wills, or None)
  document_id     Nuxeo document UID (for ordering copies)
"""

import json
import sys
import urllib.request
import urllib.parse

# ---------------------------------------------------------------------------
# API configuration
# ---------------------------------------------------------------------------

_BASE_URL = "https://probatesearch.service.gov.uk"
_SEARCH_ENDPOINT = (
    "/api/csp/api/v1/search/pp/pp_mainstream_default_search/execute"
)
_USER_AGENT = "Mozilla/5.0 (compatible; genealogy-research)"
_DEFAULT_PAGE_SIZE = 50
_MAX_PAGE_SIZE = 1000


def _format_date(iso_str):
    """Extract YYYY-MM-DD from an ISO datetime string, or return None."""
    if not iso_str:
        return None
    return iso_str[:10]


def _join_address(props):
    """Build a single address string from the four address-line fields."""
    parts = []
    for key in ("hmctsgrant:estateaddressline1",
                "hmctsgrant:estateaddressline2",
                "hmctsgrant:estateaddressline3",
                "hmctsgrant:estateaddressline4"):
        val = (props.get(key) or "").strip()
        if val:
            parts.append(val)
    return ", ".join(parts)


def _entry_to_dict(entry):
    """Convert a single Nuxeo document entry to our simplified dict."""
    p = entry.get("properties", {})
    surname = (p.get("hmctsgrant:surname") or "").strip()
    first_names = (p.get("hmctsgrant:firstnames") or "").strip()
    name = f"{first_names} {surname}".strip() if first_names else surname

    return {
        "name": name,
        "surname": surname,
        "first_names": first_names,
        "death_date": _format_date(p.get("hmctsgrant:dateofdeath")),
        "probate_date": _format_date(p.get("hmctsgrant:dateofprobate")),
        "birth_date": _format_date(p.get("hmctsgrant:dateofbirth")),
        "age_at_death": p.get("hmctsgrant:estateage_atdeath"),
        "address": _join_address(p),
        "postcode": (p.get("hmctsgrant:estatepostcode") or "").strip(),
        "title": (p.get("hmctsgrant:estatetitle") or "").strip(),
        "grant_type": (p.get("hmctsgrant:grantdocTypeoOfName") or "").strip(),
        "registry": (p.get("hmctsgrant:registryofficename") or "").strip(),
        "probate_number": (p.get("hmctsgrant:probatenumber") or "").strip(),
        "regiment_number": p.get("hmctsgrant:regimentnumber"),
        "document_id": entry.get("uid", ""),
    }


def _fetch_page(params, page_index=0, page_size=_DEFAULT_PAGE_SIZE):
    """Fetch a single page of results from the Nuxeo API."""
    query = dict(params)
    query["currentPageIndex"] = str(page_index)
    query["pageSize"] = str(page_size)

    url = _BASE_URL + _SEARCH_ENDPOINT + "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, headers={
        "User-Agent": _USER_AGENT,
        "X-NXproperties": "hmcts_grant_schema",
        "skipAggregates": "true",
    })
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def search(surname, first_name="", year_from=None, year_to=None,
           max_results=500):
    """
    Search the England & Wales Probate Calendar.

    Args:
        surname:      Surname to search (required). Case-insensitive.
        first_name:   First/given name (optional). Case-insensitive.
        year_from:    Earliest year of death to include (int, optional).
        year_to:      Latest year of death to include (int, optional).
        max_results:  Maximum total results to return (default 500).

    Returns:
        List of result dicts (see module docstring for keys),
        or a string error message on failure.
    """
    params = {
        "hmcts_grant_schema_surname": surname.upper(),
        "hmcts_grant_schema_firstnames": first_name.upper() if first_name else "",
        "hmcts_grant_schema_grantdocTypeOf": "",
        "sortBy": "",
        "sortOrder": "",
    }

    if year_from:
        params["hmcts_grant_schema_dateofdeath_min"] = (
            f"{year_from}-01-01T00:00:00.000Z"
        )
    if year_to:
        params["hmcts_grant_schema_dateofdeath_max"] = (
            f"{year_to}-12-31T23:59:59.999Z"
        )

    try:
        data = _fetch_page(params, page_index=0,
                           page_size=min(max_results, _MAX_PAGE_SIZE))
    except Exception as e:
        return f"Probate search error: {e}"

    if data.get("hasError"):
        return f"Probate search error: {data.get('errorMessage', 'unknown')}"

    total = data.get("resultsCount", 0)
    entries = data.get("entries", [])
    results = [_entry_to_dict(e) for e in entries]

    # Fetch additional pages if needed
    page_count = data.get("pageCount", 1)
    page = 1
    while page < page_count and len(results) < max_results:
        try:
            remaining = max_results - len(results)
            data = _fetch_page(params, page_index=page,
                               page_size=min(remaining, _MAX_PAGE_SIZE))
            entries = data.get("entries", [])
            if not entries:
                break
            results.extend(_entry_to_dict(e) for e in entries)
        except Exception:
            break
        page += 1

    return results[:max_results]


def print_results(results, title=None):
    """
    Pretty-print a list of probate search results.

    Args:
        results:  Output of search() — list of dicts or error string.
        title:    Optional header string.
    """
    if title:
        print(f"\n=== {title} ===")
    if isinstance(results, str):
        print(f"  {results}")
        return
    print(f"  {len(results)} result(s)")
    for r in results:
        death = r["death_date"] or "date unknown"
        probate = r["probate_date"] or ""
        age_str = f" (age {r['age_at_death']})" if r["age_at_death"] else ""
        grant = r["grant_type"] or "unknown type"
        reg = r["registry"] or ""
        addr = r["address"]
        addr_str = f" | {addr}" if addr else ""
        regt = f" [regt {r['regiment_number']}]" if r["regiment_number"] else ""

        print(f"  d.{death}{age_str} | {r['name']} | {grant} "
              f"granted {probate} at {reg}{addr_str}{regt}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cli():
    """Command-line interface for probate searches."""
    args = sys.argv[1:]

    if not args or args[0] in ("-h", "--help", "help"):
        print("Usage: python probate.py search SURNAME [YEAR_FROM] [YEAR_TO] [FIRST_NAME]")
        print()
        print("Examples:")
        print("  python probate.py search Cauldwell")
        print("  python probate.py search Cauldwell 2000 2010")
        print("  python probate.py search Cauldwell 2000 2010 John")
        print()
        print("Searches the England & Wales Probate Calendar at")
        print("probatesearch.service.gov.uk for grants of probate,")
        print("letters of administration, and soldier wills.")
        print()
        print("Note: mainly covers records from ~1996 onwards,")
        print("plus WWI/WWII soldier wills.")
        return

    if args[0] != "search":
        print(f"Unknown command: {args[0]}")
        print("Usage: python probate.py search SURNAME [YEAR_FROM] [YEAR_TO] [FIRST_NAME]")
        sys.exit(1)

    if len(args) < 2:
        print("Error: surname is required")
        sys.exit(1)

    surname = args[1]
    year_from = int(args[2]) if len(args) > 2 else None
    year_to = int(args[3]) if len(args) > 3 else None
    first_name = args[4] if len(args) > 4 else ""

    title_parts = [f"Probate search: {surname}"]
    if first_name:
        title_parts.append(f"({first_name})")
    if year_from or year_to:
        title_parts.append(f"{year_from or '...'}-{year_to or '...'}")

    results = search(surname, first_name=first_name,
                     year_from=year_from, year_to=year_to)
    print_results(results, title=" ".join(title_parts))


if __name__ == "__main__":
    _cli()
