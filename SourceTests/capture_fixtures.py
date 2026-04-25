#!/usr/bin/env python3
"""Capture test fixtures from live sources for Swift parser testing.

Run once to populate Fixtures/ and Expected/ directories.
Uses the existing Python source libraries (proven correct).

Usage:
    cd /Users/darrylcauldwell/Development/ancestor
    python SourceTests/capture_fixtures.py
"""

import json
import os
import sys
import urllib.request
import urllib.parse

# Add project root to path so we can import sources
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Fixtures")
EXPECTED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Expected")


def save_fixture(source_dir, name, raw_data, parsed_data):
    """Save raw HTTP response and parsed output."""
    os.makedirs(f"{FIXTURES}/{source_dir}", exist_ok=True)
    os.makedirs(EXPECTED, exist_ok=True)

    # Save raw response
    if isinstance(raw_data, bytes):
        raw_data = raw_data.decode("utf-8", errors="replace")
    if isinstance(raw_data, (dict, list)):
        raw_data = json.dumps(raw_data, indent=2)

    ext = "json" if raw_data.strip().startswith("{") or raw_data.strip().startswith("[") else "html"
    with open(f"{FIXTURES}/{source_dir}/{name}.{ext}", "w") as f:
        f.write(raw_data)

    # Save parsed output
    with open(f"{EXPECTED}/{source_dir}_{name}.json", "w") as f:
        json.dump(parsed_data, f, indent=2, default=str)

    count = len(parsed_data) if isinstance(parsed_data, list) else "dict"
    print(f"  ✓ {source_dir}/{name}: {count} records")


def capture_freebmd():
    """Capture FreeBMD fixtures."""
    print("\nCapturing FreeBMD fixtures...")
    from sources import freebmd

    # Birth search — Thomas Land
    try:
        # Get session first
        cookie, db, v = freebmd._get_session()

        # Build the POST manually to capture raw HTML
        fields = [
            ("type", "Births"), ("surname", "Land"), ("given", "Thomas"),
            ("s_surname", ""), ("s_given", ""),
            ("start", "1832"), ("end", "1836"),
            ("districtid", "722"),  # Belper
            ("db", db), ("v", v),
            ("find.x", "1"), ("find.y", "1"),
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
            raw_html = r.read().decode("utf-8", errors="replace")

        parsed = freebmd._parse_html(raw_html)
        if isinstance(parsed, str):
            print(f"  ✗ FreeBMD births: {parsed}")
        else:
            save_fixture("freebmd", "births_land_belper_1832_1836", raw_html, parsed)
    except Exception as e:
        print(f"  ✗ FreeBMD births failed: {e}")

    # Death search — Cauldwell
    try:
        cookie, db, v = freebmd._get_session()
        fields = [
            ("type", "Deaths"), ("surname", "Cauldwell"), ("given", ""),
            ("s_surname", ""), ("s_given", ""),
            ("start", "1900"), ("end", "1920"),
            ("districtid", ""),
            ("db", db), ("v", v),
            ("find.x", "1"), ("find.y", "1"),
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
            raw_html = r.read().decode("utf-8", errors="replace")

        parsed = freebmd._parse_html(raw_html)
        if isinstance(parsed, str):
            print(f"  ✗ FreeBMD deaths: {parsed}")
        else:
            save_fixture("freebmd", "deaths_cauldwell_1900_1920", raw_html, parsed)
    except Exception as e:
        print(f"  ✗ FreeBMD deaths failed: {e}")


def capture_freecen():
    """Capture FreeCen fixtures."""
    print("\nCapturing FreeCen fixtures...")
    from sources import freecen

    try:
        results = freecen.search("Land", first_name="Thomas", year=1841, county="DBY")
        if isinstance(results, str):
            print(f"  ✗ FreeCen search: {results}")
        else:
            # We need the raw HTML too — re-do the search capturing raw response
            cookie, csrf = freecen._get_session()
            fields = [
                ("utf8", "✓"),
                ("authenticity_token", csrf),
                ("search_query[last_name]", "Land"),
                ("search_query[first_name]", "Thomas"),
                ("search_query[record_type]", "1841"),
                ("search_query[fuzzy]", "0"),
                ("search_query[search_nearby_places]", "0"),
                ("search_query[disabled]", "0"),
                ("search_query[start_year]", ""),
                ("search_query[end_year]", ""),
                ("search_query[sex]", ""),
                ("search_query[marital_status]", ""),
                ("search_query[occupation]", ""),
                ("search_query[chapman_codes][]", "DBY"),
            ]
            data = urllib.parse.urlencode(fields).encode()
            req = urllib.request.Request(
                f"{freecen._BASE}/search_queries",
                data=data,
                headers={
                    "User-Agent": "Mozilla/5.0 (compatible; genealogy-research)",
                    "Cookie": cookie,
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Referer": f"{freecen._BASE}/search_records",
                },
            )
            with urllib.request.urlopen(req, timeout=60) as r:
                raw_html = r.read().decode("utf-8", errors="replace")

            parsed = freecen._parse_results(raw_html)
            if isinstance(parsed, str):
                print(f"  ✗ FreeCen search raw: {parsed}")
            else:
                save_fixture("freecen", "search_land_thomas_1841_dby", raw_html, parsed)

            # Also capture a household detail if we got results
            if isinstance(results, list) and results and results[0].get("record_url"):
                try:
                    detail_url = results[0]["record_url"]
                    req = urllib.request.Request(
                        detail_url,
                        headers={"User-Agent": "Mozilla/5.0 (compatible; genealogy-research)"},
                    )
                    with urllib.request.urlopen(req, timeout=15) as r:
                        detail_html = r.read().decode("utf-8", errors="replace")
                    detail_parsed = freecen.detail(detail_url)
                    save_fixture("freecen", "detail_household", detail_html, detail_parsed)
                except Exception as e:
                    print(f"  ✗ FreeCen detail failed: {e}")
    except Exception as e:
        print(f"  ✗ FreeCen search failed: {e}")


def capture_findagrave():
    """Capture Find a Grave fixtures."""
    print("\nCapturing Find a Grave fixtures...")
    from sources import findagrave

    try:
        # Search
        results = findagrave.search("Cauldwell", first_name="Robert", location="Derbyshire, England")
        if isinstance(results, str):
            print(f"  ✗ Find a Grave search: {results}")
        else:
            # Capture raw JSON response
            params = {
                "ajax": "true", "skip": "0", "limit": "20",
                "lastname": "Cauldwell", "firstname": "Robert",
                "location": "Derbyshire, England",
            }
            url = findagrave._SEARCH_URL + "?" + urllib.parse.urlencode(params)
            try:
                raw = findagrave._make_request(url, headers={
                    "X-Requested-With": "XMLHttpRequest",
                    "Accept": "application/json, text/html, */*",
                })
                save_fixture("findagrave", "search_cauldwell_robert_derby", raw, results)
            except Exception as e:
                print(f"  ✗ Find a Grave raw capture failed: {e}")

            # Capture a memorial detail if we got results
            if results and results[0].get("memorial_id"):
                try:
                    mid = results[0]["memorial_id"]
                    detail = findagrave.fetch_memorial(mid)
                    raw_html = findagrave._make_request(f"{findagrave._BASE_URL}/memorial/{mid}")
                    if not isinstance(detail, str):
                        save_fixture("findagrave", f"memorial_{mid}", raw_html, detail)
                except Exception as e:
                    print(f"  ✗ Find a Grave memorial failed: {e}")
    except Exception as e:
        print(f"  ✗ Find a Grave search failed: {e}")


def capture_cwgc():
    """Capture CWGC fixtures."""
    print("\nCapturing CWGC fixtures...")
    from sources import cwgc

    try:
        results = cwgc.search("Cauldwell")
        if not results:
            print("  ✗ CWGC search: no results")
        else:
            # Capture raw CSV
            url = (
                "https://www.cwgc.org/ExportCasualtySearch?"
                "Surname=Cauldwell&Forename=&Tab=exact"
            )
            req = urllib.request.Request(url, headers={
                "User-Agent": "Mozilla/5.0 (compatible; genealogy-research)"
            })
            with urllib.request.urlopen(req, timeout=20) as r:
                raw_csv = r.read().decode("utf-8", errors="replace")
            save_fixture("cwgc", "search_cauldwell", raw_csv, results)
    except Exception as e:
        print(f"  ✗ CWGC search failed: {e}")


def main():
    print("Capturing test fixtures from live sources...")
    print("This makes real HTTP requests — run when you have internet.")

    capture_findagrave()
    capture_freebmd()
    capture_freecen()
    capture_cwgc()

    print("\nDone. Run 'swift test' in SourceTests/ to validate Swift parsers.")


if __name__ == "__main__":
    main()
