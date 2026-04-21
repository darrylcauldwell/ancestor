"""
wirksworth.py — Reusable library for wirksworth.org.uk parish records

The Wirksworth website (wirksworth.org.uk) hosts Ince's Pedigrees covering
~20,000 Wirksworth-area people 1799-1860, plus parish register transcriptions
(104,000 entries) for Wirksworth, Middleton, and Matlock in Derbyshire.

Contributed pedigrees are narrative-format family histories submitted by
researchers. They are text-heavy HTML, not structured tree data, so parsing
extracts people with best-effort heuristics.

The parish registers cover baptisms, marriages, and burials and use a
structured PRE-formatted layout that is more reliably parsed.

Usage:
    from wirksworth import get_pedigree, list_pedigrees, fetch_raw_pedigree

    # List all available pedigrees
    pedigrees = list_pedigrees()
    for p in pedigrees:
        print(p["surname"], p["url"], p["contributor"])

    # Fetch and parse a specific pedigree
    people = get_pedigree("CAUL")
    for person in people:
        print(person["name"], person["birth_year"], person["occupation"])

    # Get raw HTML for manual analysis
    html = fetch_raw_pedigree("CAUL", page=1)
"""

import urllib.request
import urllib.parse
import re
import json
from html.parser import HTMLParser

BASE_URL = "http://www.wirksworth.org.uk"

# Known pedigree codes extracted from PEDIGREE.htm index
# Format: {code: {"surname": ..., "contributor": ..., "pages": [urls]}}
_PEDIGREE_INDEX_URL = f"{BASE_URL}/PEDIGREE.htm"
_REGISTER_INDEX_URL = f"{BASE_URL}/REGISTER.htm"


def _fetch(url, timeout=20):
    """Fetch a URL and return decoded text."""
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 (compatible; genealogy-research)"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def _strip_html(text):
    """Remove HTML tags and decode entities."""
    text = re.sub(r'<[^>]+>', ' ', text)
    text = text.replace('&amp;', '&')
    text = text.replace('&#169;', '(c)')
    text = text.replace('&nbsp;', ' ')
    text = text.replace('&#160;', ' ')
    text = re.sub(r'\s+', ' ', text).strip()
    return text


def _extract_years(text):
    """Extract 4-digit years from text."""
    return [int(y) for y in re.findall(r'\b1[5-9]\d{2}\b', text)]


def _extract_date(text, keyword):
    """Extract a date/year following a keyword like 'born', 'obt', 'married'."""
    # Try "born March 15th 1673" or "born 1792"
    pattern = rf'{keyword}\s+(?:(?:January|February|March|April|May|June|July|August|September|October|November|December|Nov\.|Jan\.|Feb\.)\s+\d+(?:st|nd|rd|th)?\s+)?(\d{{4}})'
    m = re.search(pattern, text, re.IGNORECASE)
    if m:
        return int(m.group(1))
    # Try "born August 24th 1645"
    pattern2 = rf'{keyword}\s+\w+\s+\d+\w*\s+(\d{{4}})'
    m2 = re.search(pattern2, text, re.IGNORECASE)
    if m2:
        return int(m2.group(1))
    return None


def list_pedigrees():
    """
    Fetch and parse the pedigree index page from wirksworth.org.uk.

    Returns a list of dicts with keys:
        surname     - Family surname (e.g., "CAULDWELL-1")
        code        - URL filename code (e.g., "P-CAUL-1")
        url         - Full URL to the pedigree page
        contributor - Name of the person who submitted the pedigree
    """
    html = _fetch(_PEDIGREE_INDEX_URL)
    pedigrees = []

    # Parse table rows: <A HREF=P-CAUL-1.htm>CAULDWELL-1</A> ... contributor
    pattern = r'<A\s+HREF=([^>]+\.htm)>([^<]+)</A></TD><TD><H5>([^<]*)'
    for m in re.finditer(pattern, html, re.IGNORECASE):
        href = m.group(1).strip()
        surname = _strip_html(m.group(2)).strip()
        contributor = _strip_html(m.group(3)).strip()

        # Skip non-pedigree links
        if not surname or surname in ('most recent', 'largest'):
            continue

        code = href.replace('.htm', '').replace('.HTM', '')
        url = f"{BASE_URL}/{href}"

        pedigrees.append({
            "surname": surname,
            "code": code,
            "url": url,
            "contributor": contributor,
        })

    return pedigrees


def fetch_raw_pedigree(code, page=1):
    """
    Fetch raw HTML for a pedigree page.

    Args:
        code: The 4-letter surname code (e.g., "CAUL" for Cauldwell)
              or full code (e.g., "P-CAUL-1")
        page: Page number (default 1). Some families have multiple pages.

    Returns:
        Raw HTML string, or None if the page returns 404/error.
    """
    if code.startswith("P-"):
        url = f"{BASE_URL}/{code}.htm"
    else:
        url = f"{BASE_URL}/P-{code}-{page}.htm"

    try:
        return _fetch(url)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    except Exception:
        return None


def _parse_narrative_pedigree(html):
    """
    Parse a narrative-style pedigree (like Stuart Flint's Cauldwell page).

    These are prose descriptions, not structured trees. We extract people
    with best-effort pattern matching on names, dates, occupations, and
    relationships.

    Returns a list of person dicts.
    """
    # Strip to the main content area
    text = _strip_html(html)
    people = []
    seen = set()

    # Pattern: "Name born YEAR" or "Name born Month Day YEAR"
    born_patterns = [
        # "John born 1792"
        r'([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s+born?\s+(?:\w+\s+\d+\w*\s+)?(\d{4})',
        # "Nathaniel Caldwell born 1815"
        r'([A-Z][a-z]+(?:\s+[A-Z][a-zA-Z]+)+)\s+born?\s+(?:\w+\s+\d+\w*\s+)?(\d{4})',
    ]

    for pattern in born_patterns:
        for m in re.finditer(pattern, text):
            name = m.group(1).strip()
            birth_year = int(m.group(2))
            key = (name.lower(), birth_year)
            if key not in seen:
                seen.add(key)
                people.append({
                    "name": name,
                    "birth_year": birth_year,
                    "death_year": None,
                    "spouse": None,
                    "marriage_year": None,
                    "parents": None,
                    "occupation": None,
                    "location": None,
                    "source_text": m.group(0)[:200],
                })

    # Now try to enrich with marriage, occupation, death info from surrounding context
    # "married [Spouse] [YEAR]"
    marriage_pattern = r'([A-Z][a-z]+(?:\s+[A-Z][a-zA-Z]+)*)\s+(?:born\s+\d{4}\s+)?married\s+([A-Z][a-z]+(?:\s+[A-Z][a-zA-Z]+)*)\s*(?:of\s+\w+\s*)?(?:(\d{4}))?'
    for m in re.finditer(marriage_pattern, text):
        name = m.group(1).strip()
        spouse = m.group(2).strip()
        m_year = int(m.group(3)) if m.group(3) else None

        # Try to find existing person and update
        updated = False
        for p in people:
            if p["name"].lower() == name.lower():
                p["spouse"] = spouse
                if m_year:
                    p["marriage_year"] = m_year
                updated = True
                break
        if not updated:
            key = (name.lower(), None)
            if key not in seen:
                seen.add(key)
                people.append({
                    "name": name,
                    "birth_year": None,
                    "death_year": None,
                    "spouse": spouse,
                    "marriage_year": m_year,
                    "parents": None,
                    "occupation": None,
                    "location": None,
                    "source_text": m.group(0)[:200],
                })

    # Extract occupations
    occupation_patterns = [
        (r'(\w+(?:\s+\w+)*)\s+was\s+(?:a\s+)?((?:Police\s+officer|Gamekeeper|Head\s+Forester|Forester|Agricultural\s+Labourer|Master\s+Stonemason|Building\s+Contractor|Master\s+Grocer|School\s+Mistress|Farrier|Blacksmith|Mining\s+Agent|Lead\s+Miner|Brick\s+Manufacturer|Innkeeper|Gents\s+Outfitter)[^.]*)', re.IGNORECASE),
    ]
    for pattern, flags in occupation_patterns:
        for m in re.finditer(pattern, text, flags):
            name_part = m.group(1).strip()
            occ = m.group(2).strip()
            for p in people:
                if name_part.lower() in p["name"].lower() or p["name"].lower() in name_part.lower():
                    p["occupation"] = occ
                    break

    return people


def _parse_structured_pedigree(html):
    """
    Parse a structured PRE-formatted pedigree (like Wardman's).

    These use indentation levels (1, 2, 3, ...) to show generations,
    with dates in parentheses like bpt (16/7/1707) or b 1832.

    Returns a list of person dicts.
    """
    people = []
    seen = set()

    # Find all PRE blocks
    pre_blocks = re.findall(r'<PRE>(.*?)</PRE>', html, re.DOTALL | re.IGNORECASE)
    if not pre_blocks:
        # Fall back to full text
        pre_blocks = [html]

    for block in pre_blocks:
        text = _strip_html(block)
        lines = text.split('\n')

        for line in lines:
            line = line.strip()
            if not line or line.startswith('Further') or line.startswith('Text'):
                continue

            # Match generation number + name
            m = re.match(r'(\d+)\s+([A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+)*)', line)
            if not m:
                continue

            gen = int(m.group(1))
            name = m.group(2).strip()

            # Extract dates
            birth_year = None
            death_year = None
            baptism = None
            spouse = None
            marriage_year = None

            # bpt (date) or b (date) or b YEAR
            bpt_m = re.search(r'bpt?\s*\(([^)]+)\)', line)
            if bpt_m:
                date_str = bpt_m.group(1)
                yr = re.search(r'(\d{4})', date_str)
                if yr:
                    birth_year = int(yr.group(1))
                baptism = date_str

            b_m = re.search(r'\bb\s+(\d{4})', line)
            if b_m and not birth_year:
                birth_year = int(b_m.group(1))

            b_m2 = re.search(r'\bb\s*\(([^)]+)\)', line)
            if b_m2:
                date_str = b_m2.group(1)
                yr = re.search(r'(\d{4})', date_str)
                if yr:
                    birth_year = int(yr.group(1))

            # death: d (date) or d YEAR
            d_m = re.search(r'\bd\s+(\d{4})', line)
            if d_m:
                death_year = int(d_m.group(1))
            d_m2 = re.search(r'\bd\s*\(([^)]+)\)', line)
            if d_m2:
                yr = re.search(r'(\d{4})', d_m2.group(1))
                if yr:
                    death_year = int(yr.group(1))

            # marriage: m (date) Spouse
            mar_m = re.search(r'\bm\s+(?:\([^)]+\)\s+)?([A-Z][a-z]+(?:\s+[A-Z][A-Za-z]+)*)', line)
            if mar_m:
                spouse = mar_m.group(1).strip()
            mar_y = re.search(r'\bm\s*\(([^)]+)\)', line)
            if mar_y:
                yr = re.search(r'(\d{4})', mar_y.group(1))
                if yr:
                    marriage_year = int(yr.group(1))

            # bd = buried date
            bd_m = re.search(r'\bbd\s+(\d+/\d+/\d{4})', line)

            key = (name.lower(), birth_year, gen)
            if key not in seen:
                seen.add(key)
                people.append({
                    "name": name,
                    "birth_year": birth_year,
                    "death_year": death_year,
                    "baptism": baptism,
                    "spouse": spouse,
                    "marriage_year": marriage_year,
                    "generation": gen,
                    "parents": None,
                    "occupation": None,
                    "location": None,
                    "source_text": line[:200],
                })

    return people


def get_pedigree(code, page=1):
    """
    Fetch and parse a pedigree page from wirksworth.org.uk.

    Args:
        code: 4-letter surname code (e.g., "CAUL") or full code ("P-CAUL-1")
        page: Page number for multi-page pedigrees

    Returns:
        List of dicts with keys:
            name, birth_year, death_year, spouse, marriage_year,
            parents, occupation, location, source_text

        Returns None if the page doesn't exist.
    """
    html = fetch_raw_pedigree(code, page)
    if html is None:
        return None

    # Check if it's a 404 page
    if '404' in html[:500] and 'not found' in html[:500].lower():
        return None

    # Detect format: structured (PRE-based) vs narrative
    if '<PRE>' in html or '<pre>' in html:
        return _parse_structured_pedigree(html)
    else:
        return _parse_narrative_pedigree(html)


def get_pedigree_metadata(code, page=1):
    """
    Fetch metadata about a pedigree page (title, contributor, update date).

    Returns a dict with: title, contributor, update_date, surname, url
    """
    html = fetch_raw_pedigree(code, page)
    if html is None:
        return None

    title_m = re.search(r'<TITLE>([^<]+)</TITLE>', html, re.IGNORECASE)
    update_m = re.search(r'Updated\s+(\d+\s+\w+\s+\d{4})', html, re.IGNORECASE)
    contrib_m = re.search(r'(?:sent by|authored by)[:\s]*([^<]+)', html, re.IGNORECASE)
    surname_m = re.search(r'Descendants of\s+(\w+)', html, re.IGNORECASE)

    return {
        "title": _strip_html(title_m.group(1)) if title_m else None,
        "contributor": _strip_html(contrib_m.group(1)).strip().rstrip('.') if contrib_m else None,
        "update_date": update_m.group(1) if update_m else None,
        "surname": surname_m.group(1) if surname_m else None,
        "url": f"{BASE_URL}/P-{code}-{page}.htm" if not code.startswith("P-") else f"{BASE_URL}/{code}.htm",
    }


def search_parish(surname, record_type='all', year_from=None, year_to=None):
    """
    Search parish register transcriptions on wirksworth.org.uk.

    The site has surname indexes that link to register pages containing
    baptism, marriage, and burial entries.

    Args:
        surname:     Surname to search (case-insensitive)
        record_type: 'baptism', 'marriage', 'burial', or 'all'
        year_from:   Optional start year filter
        year_to:     Optional end year filter

    Returns:
        List of dicts with: name, event_type, date, details, page_ref
        Returns None if the surname index page doesn't exist.

    Note: The parish register pages use a complex multi-file structure.
    This function searches the surname index pages which list entries
    by surname initial letter groupings.
    """
    # The surname index uses codes like C41-16.htm where the first letter
    # determines the page range. We need to find the right index page.
    # Format is: first letter of surname -> index page range
    first_letter = surname[0].upper()

    # Try the surname index page
    # Index format: NAMES-X.htm where X might be a letter range
    # Actually the site uses register pages organized by date, not surname index
    # The main REGISTER.htm page lists the available registers

    results = []

    # The site's surname search is via browsing register pages
    # We can search through the register index for the surname
    # Register pages are organized chronologically: C41-16.htm = 1841 census page 16, etc.
    # Actually the naming is: Cxx-yy.htm where xx=century/decade, yy=page

    # For now, return a note about manual browsing
    # A full implementation would need to spider all register pages
    return {
        "note": "Parish register search requires browsing the register index",
        "register_url": _REGISTER_INDEX_URL,
        "suggestion": f"Search for '{surname}' in the parish registers at {_REGISTER_INDEX_URL}",
        "surname": surname,
    }


def save_data(data, filepath):
    """Save parsed data to a JSON file."""
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"Saved {len(data) if isinstance(data, list) else 'data'} to {filepath}")


# ---------------------------------------------------------------------------
# Quick demo / data extraction when run directly
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import sys

    print("Wirksworth.org.uk Pedigree Library")
    print("=" * 50)

    # List all pedigrees
    print("\nFetching pedigree index...")
    pedigrees = list_pedigrees()
    print(f"Found {len(pedigrees)} contributed pedigrees:")
    for p in pedigrees:
        print(f"  {p['surname']:25s} by {p['contributor']}")

    # Parse Cauldwell pedigree
    print("\n" + "=" * 50)
    print("Parsing CAULDWELL pedigree...")
    cauldwell = get_pedigree("CAUL")
    if cauldwell:
        print(f"Extracted {len(cauldwell)} people:")
        for person in cauldwell:
            spouse_str = f" m. {person['spouse']}" if person.get('spouse') else ""
            occ_str = f" [{person['occupation']}]" if person.get('occupation') else ""
            yr = f"b.{person['birth_year']}" if person.get('birth_year') else "b.?"
            print(f"  {person['name']:30s} {yr}{spouse_str}{occ_str}")

    # Get metadata
    meta = get_pedigree_metadata("CAUL")
    if meta:
        print(f"\nMetadata: {meta}")

    # Save all data
    output = {
        "source": "wirksworth.org.uk",
        "fetched": "2026-04-17",
        "pedigree_index": pedigrees,
        "cauldwell_pedigree": {
            "metadata": meta,
            "people": cauldwell,
        },
    }

    outpath = "/Users/darrylcauldwell/Development/ancestor/wirksworth_data.json"
    save_data(output, outpath)
    print(f"\nAll data saved to {outpath}")
