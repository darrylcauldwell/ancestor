#!/usr/bin/env python3
"""Search FreeREG for genealogy records."""

import re
import time
import requests
from bs4 import BeautifulSoup

BASE_URL = "https://www.freereg.org.uk"
SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xhtml+xml,*/*;q=0.9",
    "Accept-Language": "en-GB,en;q=0.9",
})

# Discovered by probing the form
RECORD_TYPE_VALUES = {
    "M": None,  # Will be filled by probe_form()
    "B": None,
    "Bu": None,
    "": None,  # All types
}


def probe_form():
    """GET the search form and print all inputs to discover exact field names/values."""
    url = f"{BASE_URL}/search_queries/new"
    resp = SESSION.get(url, timeout=30)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")

    print("=== FORM PROBE ===")
    meta = soup.find("meta", {"name": "csrf-token"})
    csrf = meta.get("content") if meta else None
    print(f"CSRF token found: {bool(csrf)}")

    print("\nAll INPUT elements:")
    for inp in soup.find_all("input"):
        name = inp.get("name", "")
        val = inp.get("value", "")
        itype = inp.get("type", "")
        label_text = ""
        # Try to find associated label
        inp_id = inp.get("id", "")
        if inp_id:
            label = soup.find("label", {"for": inp_id})
            if label:
                label_text = label.get_text(strip=True)
        print(f"  [{itype}] name={name!r} value={val!r} label={label_text!r}")

    print("\nAll SELECT elements:")
    for sel in soup.find_all("select"):
        print(f"  SELECT name={sel.get('name')!r}")
        for opt in sel.find_all("option"):
            print(f"    option value={opt.get('value','')!r} text={opt.get_text(strip=True)!r}")

    print("=== END PROBE ===\n")
    return csrf, soup


def get_csrf_and_form_data():
    """GET the new search page and extract CSRF token plus record type values."""
    url = f"{BASE_URL}/search_queries/new"
    resp = SESSION.get(url, timeout=30)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")

    # CSRF token
    meta = soup.find("meta", {"name": "csrf-token"})
    csrf = meta.get("content") if meta else None
    if not csrf:
        inp = soup.find("input", {"name": "authenticity_token"})
        if inp:
            csrf = inp.get("value")

    # Discover record type radio values
    radio_map = {}
    for inp in soup.find_all("input", {"type": "radio"}):
        name = inp.get("name", "")
        val = inp.get("value", "")
        inp_id = inp.get("id", "")
        label_text = ""
        if inp_id:
            label = soup.find("label", {"for": inp_id})
            if label:
                label_text = label.get_text(strip=True).lower()
        if "record_type" in name or "type" in name.lower():
            radio_map[label_text] = val

    return csrf, radio_map, soup


def do_search(last_name, first_name, record_type_label, start_year, end_year, fuzzy=False, chapman_codes=None):
    """
    Perform a FreeREG search and return parsed results.
    record_type_label: 'marriage', 'baptism', 'burial', or '' for all
    """
    if chapman_codes is None:
        chapman_codes = ["DBY"]

    print(f"\n{'='*70}")
    print(f"SEARCH: surname={last_name!r}, first={first_name!r}, type={record_type_label!r}, years={start_year}-{end_year}, fuzzy={fuzzy}")
    print(f"{'='*70}")

    # Fresh CSRF token and form metadata for each search
    try:
        csrf, radio_map, soup = get_csrf_and_form_data()
    except Exception as e:
        print(f"  ERROR getting form data: {e}")
        return []

    if not csrf:
        print("  WARNING: No CSRF token found")

    # Resolve record type value
    if radio_map:
        # Find matching radio value
        rt_val = None
        label_lower = record_type_label.lower()
        for label, val in radio_map.items():
            if label_lower in label or label in label_lower:
                rt_val = val
                break
        if rt_val is None and record_type_label == "":
            # All types - use first or empty
            rt_val = list(radio_map.values())[0] if radio_map else ""
        print(f"  Radio map: {radio_map}")
        print(f"  Resolved record_type value: {rt_val!r}")
    else:
        # Fallback: FreeREG historically uses these values
        rt_map = {"marriage": "M", "baptism": "B", "burial": "Bu", "": ""}
        rt_val = rt_map.get(record_type_label.lower(), record_type_label)
        print(f"  Fallback record_type value: {rt_val!r}")

    # Build POST data as list of tuples to handle multi-value fields
    data = []
    if csrf:
        data.append(("authenticity_token", csrf))
    data.append(("search_query[last_name]", last_name))
    data.append(("search_query[first_name]", first_name))
    if rt_val is not None and rt_val != "":
        data.append(("search_query[record_type]", rt_val))
    data.append(("search_query[start_year]", str(start_year)))
    data.append(("search_query[end_year]", str(end_year)))
    if fuzzy:
        data.append(("search_query[fuzzy]", "1"))
    for code in chapman_codes:
        data.append(("search_query[chapman_codes][]", code))
    data.append(("commit", "Search"))

    headers = {
        "X-CSRF-Token": csrf or "",
        "Referer": f"{BASE_URL}/search_queries/new",
        "Origin": BASE_URL,
        "Content-Type": "application/x-www-form-urlencoded",
    }

    print(f"  POST data: {data}")

    try:
        resp = SESSION.post(
            f"{BASE_URL}/search_queries",
            data=data,
            headers=headers,
            timeout=60,
            allow_redirects=True,
        )
        resp.raise_for_status()
        print(f"  Response URL: {resp.url}  Status: {resp.status_code}")
    except Exception as e:
        print(f"  ERROR posting search: {e}")
        return []

    return parse_results(resp.text, resp.url)


def parse_results(html, url):
    """Parse search results HTML and return list of result dicts."""
    soup = BeautifulSoup(html, "html.parser")

    # Check for validation errors
    error_elems = soup.find_all(string=re.compile(r"error prohibited|prohibited this", re.I))
    if error_elems:
        # Get full error messages
        error_list = soup.find("ul", class_=re.compile(r"error"))
        if error_list:
            errors = [li.get_text(strip=True) for li in error_list.find_all("li")]
            print(f"  VALIDATION ERRORS: {errors}")
        else:
            print(f"  VALIDATION ERROR detected (details not extracted)")
        # Print form field hints
        text = soup.get_text(separator=" ", strip=True)
        print(f"  Page text snippet: {text[:600]}")
        return []

    # Check for no results / error messages
    no_results = soup.find(string=re.compile(r"no results|no records found|0 result", re.I))
    if no_results:
        print(f"  No results found.")
        return []

    # Look for result count
    for s in soup.strings:
        if re.search(r"\d+\s+result", s, re.I):
            print(f"  Result count text: {s.strip()}")
            break

    results = []

    # Find all tables or result rows
    tables = soup.find_all("table")
    if not tables:
        # Look for individual result containers
        result_divs = soup.find_all("div", class_=re.compile(r"result|record", re.I))
        if result_divs:
            print(f"  Found {len(result_divs)} result divs")
        else:
            text = soup.get_text(separator=" ", strip=True)
            if "sign" in text.lower() and "in" in text.lower():
                print("  Page appears to require login.")
            elif len(text) < 500:
                print(f"  Page text (short): {text[:500]}")
            else:
                print(f"  No results table found. Page URL: {url}")
                print(f"  Page snippet: {text[:1000]}")
        return []

    for table in tables:
        rows = table.find_all("tr")
        headers = []
        for i, row in enumerate(rows):
            cells = row.find_all(["th", "td"])
            if not cells:
                continue
            cell_texts = [c.get_text(strip=True) for c in cells]

            if row.find("th"):
                headers = cell_texts
                print(f"  Table headers: {headers}")
                continue

            if not headers:
                if any(h in cell_texts for h in ["Name", "Date", "Parish", "County", "Record Type", "Surname"]):
                    headers = cell_texts
                    print(f"  Table headers (detected): {headers}")
                    continue

            # Extract links
            links = row.find_all("a", href=True)
            record_url = None
            for link in links:
                href = link["href"]
                if "/search_records/" in href or "/freereg1_csv_entries/" in href:
                    record_url = href if href.startswith("http") else BASE_URL + href
                    break

            if headers:
                row_data = dict(zip(headers, cell_texts))
            else:
                row_data = {f"col{j}": v for j, v in enumerate(cell_texts)}

            # Normalise the FreeREG "Record Type" column into a flat
            # `record_type` key (lowercase) so the pipeline's scorer
            # ‑‑ which falls back to `_classify_search_type("parish
            # _registers") == "unknown"` when this is absent ‑‑ can
            # classify the row as baptism / marriage / burial. Without
            # this, FreeREG marriages were filed under "unknown" and
            # never counted toward marriage_disambiguation in the §5.8
            # harness (Stephen Sherwin pre-civil baseline gap).
            rt_raw = row_data.get("Record Type", "")
            if rt_raw:
                row_data["record_type"] = rt_raw.strip().lower()

            if any(v for v in row_data.values()):
                row_data["_url"] = record_url
                results.append(row_data)
                print(f"  RESULT: {row_data}")

    if not results:
        # Try anchor tags with record links directly
        record_links = soup.find_all("a", href=re.compile(r"/search_records/|/freereg1_csv_entries/"))
        if record_links:
            print(f"  Found {len(record_links)} record links directly")
            for link in record_links:
                href = link["href"]
                url_full = href if href.startswith("http") else BASE_URL + href
                results.append({"_url": url_full, "link_text": link.get_text(strip=True)})
                print(f"  RECORD LINK: {url_full} — {link.get_text(strip=True)}")

    if not results:
        text = soup.get_text(separator="\n", strip=True)
        print(f"  No structured results found. Page text snippet:\n{text[:1500]}")

    return results


def fetch_record_detail(record_url):
    """Fetch and display a specific record's detail page."""
    if not record_url:
        return
    print(f"\n  --- Detail: {record_url} ---")
    try:
        time.sleep(1)
        resp = SESSION.get(record_url, timeout=30)
        resp.raise_for_status()
        soup = BeautifulSoup(resp.text, "html.parser")

        # Extract all definition lists
        for dl in soup.find_all("dl"):
            dts = dl.find_all("dt")
            dds = dl.find_all("dd")
            for dt, dd in zip(dts, dds):
                print(f"    {dt.get_text(strip=True)}: {dd.get_text(strip=True)}")

        for table in soup.find_all("table"):
            rows = table.find_all("tr")
            for row in rows:
                cells = row.find_all(["th", "td"])
                if cells:
                    texts = [c.get_text(strip=True) for c in cells]
                    print(f"    {' | '.join(texts)}")

        # Fallback: print main content text
        main = soup.find("main") or soup.find("div", id="content") or soup.find("div", class_="container")
        if main:
            text = main.get_text(separator="\n", strip=True)
            if text:
                print(f"    {text[:3000]}")
    except Exception as e:
        print(f"    ERROR fetching detail: {e}")


def main():
    # First probe the form to understand fields
    try:
        probe_form()
    except Exception as e:
        print(f"Form probe failed: {e}")

    # Pause to be polite
    time.sleep(2)

    searches = [
        # (last_name, first_name, record_type_label, start_year, end_year, fuzzy)
        ("Twyford", "George", "marriage", 1876, 1884, True),
        ("Kenworthy", "Lydia", "marriage", 1876, 1884, True),
        ("Twyford", "", "marriage", 1876, 1884, False),
        ("Kenworthy", "", "marriage", 1876, 1884, False),
        ("Twyford", "", "baptism", 1800, 1815, False),
        ("Kenworthy", "James", "baptism", 1780, 1810, False),
    ]

    all_results = {}
    for last_name, first_name, record_type_label, start_year, end_year, fuzzy in searches:
        key = f"{last_name}_{first_name}_{record_type_label}_{start_year}_{end_year}"
        results = do_search(last_name, first_name, record_type_label, start_year, end_year, fuzzy)
        all_results[key] = results

        # Fetch detail for promising results (limit to first 5)
        for r in results[:5]:
            url = r.get("_url")
            if url:
                fetch_record_detail(url)

        time.sleep(3)

    print(f"\n{'='*70}")
    print("SUMMARY")
    print(f"{'='*70}")
    for key, results in all_results.items():
        print(f"  {key}: {len(results)} result(s)")
        for r in results:
            print(f"    {r}")


if __name__ == "__main__":
    main()
