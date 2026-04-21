"""
cwgc.py — Reusable CWGC (Commonwealth War Graves Commission) search library

The CWGC (cwgc.org) commemorates 1.7 million men and women of the Commonwealth
forces who died in the First and Second World Wars. This library provides
programmatic access by scraping the server-rendered HTML and CSV export
endpoints used by the website.

Usage:
    from cwgc import search, get_casualty

    results = search("Cauldwell", first_name="Robert", war="WW1")
    for r in results:
        print(r["name"], r["rank"], r["date_of_death"])

    details = get_casualty(434549)
    print(details["additional_info"])

War filters:  "WW1" or "1", "WW2" or "2", "" for both

CWGC data notes:
  - Coverage includes Commonwealth forces from both World Wars.
  - The CSV export endpoint returns all matching results (no pagination).
  - Casualty IDs are stable numeric identifiers used in CWGC URLs.
  - Additional info often includes parents, spouse, and hometown.
"""

import csv
import io
import re
import sys
import urllib.request
import urllib.parse

# War filter values used by the CWGC search form
WAR_WW1 = "1"
WAR_WW2 = "2"

_HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; genealogy-research)",
}


def _fetch(url, timeout=20):
    """Fetch a URL with retry on transient errors."""
    from sources._http import fetch
    return fetch(url, headers=_HEADERS, timeout=timeout)


def _normalise_war(war):
    """Convert human-friendly war names to CWGC parameter values."""
    if not war:
        return ""
    w = str(war).strip().upper()
    if w in ("1", "WW1", "WWI", "FIRST", "WORLD WAR 1"):
        return WAR_WW1
    if w in ("2", "WW2", "WWII", "SECOND", "WORLD WAR 2"):
        return WAR_WW2
    return str(war)


def search(surname, first_name="", war="", year_from=None, year_to=None):
    """
    Search CWGC for war dead casualties.

    Args:
        surname:    Surname to search (required)
        first_name: Forename / first name (optional)
        war:        "WW1"/"1" for First World War, "WW2"/"2" for Second,
                    "" for both (default)
        year_from:  Earliest year of death, e.g. 1916 (optional)
        year_to:    Latest year of death, e.g. 1918 (optional)

    Returns:
        List of result dicts, or an empty list if no matches.

    Each result dict contains:
        casualty_id (int), name (str), rank (str), service_number (str),
        regiment (str), unit (str), date_of_death (str), age (int or None),
        cemetery_memorial (str), grave_ref (str), country_of_service (str),
        additional_info (str)
    """
    params = {
        "Surname": surname,
        "Forename": first_name,
        "Tab": "exact",
    }

    war_val = _normalise_war(war)
    if war_val:
        params["WarSelect"] = war_val

    if year_from:
        params["DateDeathFromYear"] = str(year_from)
    if year_to:
        params["DateDeathToYear"] = str(year_to)

    url = "https://www.cwgc.org/ExportCasualtySearch?" + urllib.parse.urlencode(params)

    from sources._http import fetch_quiet
    body = fetch_quiet(url, headers=_HEADERS, label="CWGC")
    if body is None:
        return []

    return _parse_csv(body)


def _parse_csv(body):
    """
    Parse the CSV export from CWGC into a list of result dicts.

    CSV columns:
      Id,Surname,Forename,Initials,AgeAtDeath,Honours,DateOfDeath,
      DateOfDeath2,Rank,Regiment,SecondaryRegiment,Unit,SecondaryUnit,
      CountryOfService,ServiceNumber,Burial,Cemetery,GraveRef,AdditionalInfo
    """
    reader = csv.DictReader(io.StringIO(body))
    results = []

    for row in reader:
        # Build full name from forename + surname
        forename = (row.get("Forename") or "").strip()
        surname = (row.get("Surname") or "").strip()
        name = f"{forename} {surname}".strip() if forename else surname

        # Parse age (0 means unknown in CWGC data)
        try:
            age = int(row.get("AgeAtDeath", 0))
            if age == 0:
                age = None
        except (ValueError, TypeError):
            age = None

        # Clean service number (CWGC wraps in quotes)
        svc = (row.get("ServiceNumber") or "").strip().strip("'\"")

        # Parse date of death from DD/MM/YYYY format
        dod_raw = (row.get("DateOfDeath") or "").strip()
        dod = _format_date(dod_raw)

        # Combine regiment and secondary regiment
        regiment = (row.get("Regiment") or "").strip()
        sec_reg = (row.get("SecondaryRegiment") or "").strip()
        if sec_reg:
            regiment = f"{regiment}; {sec_reg}" if regiment else sec_reg

        # Combine unit and secondary unit
        unit = (row.get("Unit") or "").strip()
        sec_unit = (row.get("SecondaryUnit") or "").strip()
        if sec_unit:
            unit = f"{unit}; {sec_unit}" if unit else sec_unit

        try:
            casualty_id = int(row.get("Id", 0))
        except (ValueError, TypeError):
            casualty_id = 0

        results.append({
            "casualty_id": casualty_id,
            "name": name,
            "rank": (row.get("Rank") or "").strip(),
            "service_number": svc,
            "regiment": regiment,
            "unit": unit,
            "date_of_death": dod,
            "age": age,
            "cemetery_memorial": (row.get("Cemetery") or "").strip(),
            "grave_ref": (row.get("GraveRef") or "").strip(),
            "country_of_service": (row.get("CountryOfService") or "").strip(),
            "additional_info": (row.get("AdditionalInfo") or "").strip(),
        })

    return results


def _format_date(dod_raw):
    """Convert DD/MM/YYYY to a readable date string like '14 July 1918'."""
    if not dod_raw:
        return ""
    months = {
        "01": "January", "02": "February", "03": "March",
        "04": "April", "05": "May", "06": "June",
        "07": "July", "08": "August", "09": "September",
        "10": "October", "11": "November", "12": "December",
    }
    parts = dod_raw.split("/")
    if len(parts) == 3:
        day, month, year = parts
        month_name = months.get(month, month)
        # Strip leading zero from day
        day = str(int(day)) if day.isdigit() else day
        return f"{day} {month_name} {year}"
    return dod_raw


def get_casualty(casualty_id):
    """
    Fetch full details for a specific CWGC casualty by ID.

    Args:
        casualty_id: Numeric CWGC casualty ID (e.g. 434549)

    Returns:
        Dict with keys: casualty_id, name, rank, service_number, regiment,
        unit, date_of_death, age, cemetery_memorial, cemetery_url,
        grave_ref, country, country_of_service, additional_info,
        cwgc_url, certificate_url

        Returns None if the casualty page cannot be fetched or parsed.
    """
    base_url = f"https://www.cwgc.org/find-records/find-war-dead/casualty-details/{casualty_id}/"

    from sources._http import fetch_quiet
    html = fetch_quiet(base_url, headers=_HEADERS, label="CWGC")
    if html is None:
        return None

    return _parse_casualty_page(html, casualty_id)


def _parse_casualty_page(html, casualty_id):
    """Parse a CWGC casualty detail page and extract all fields."""

    result = {
        "casualty_id": casualty_id,
        "name": "",
        "rank": "",
        "service_number": "",
        "regiment": "",
        "unit": "",
        "date_of_death": "",
        "age": None,
        "cemetery_memorial": "",
        "cemetery_url": "",
        "grave_ref": "",
        "country": "",
        "country_of_service": "",
        "additional_info": "",
        "cwgc_url": "",
        "certificate_url": "",
    }

    # Rank and name from h1 (inside casualty-details div)
    h1 = re.search(r'<h1>\s*(?:<span>([^<]*)</span>)?\s*([^<]+?)\s*</h1>',
                    html, re.DOTALL)
    if h1:
        result["rank"] = (h1.group(1) or "").strip()
        result["name"] = (h1.group(2) or "").strip()

    # Service number — inside <div class="service-num">
    svc = re.search(r'class="service-num"[^>]*>.*?</span>\s*([^<]+)<', html,
                    re.DOTALL)
    if svc:
        result["service_number"] = svc.group(1).strip()

    # Extract all detail-blocks: each has a title div then sibling <p> tags
    # Structure: <div class="detail-block"><div class="title">...LABEL</div>
    #            <p>value1</p><p>value2</p></div>
    detail_blocks = re.findall(
        r'<div class="detail-block">(.*?)</div>\s*(?=<div class="detail-block">|</div>)',
        html, re.DOTALL)

    for block in detail_blocks:
        paras = [_decode_entities(p.strip())
                 for p in re.findall(r'<p>(.*?)</p>', block, re.DOTALL)]
        # Clean tags from para contents
        clean_paras = [re.sub(r'<[^>]+>', '', p).strip() for p in paras]

        if "Regiment" in block and "Unit" in block:
            if clean_paras:
                result["regiment"] = clean_paras[0]
            if len(clean_paras) > 1:
                result["unit"] = clean_paras[1]

        elif "Date of Death" in block:
            for p in clean_paras:
                if p.startswith("Died "):
                    result["date_of_death"] = p[5:]
                elif "years old" in p.lower():
                    age_m = re.search(r'(\d+)', p)
                    if age_m:
                        result["age"] = int(age_m.group(1))

        elif "Buried or commemorated at" in block:
            # Cemetery name may be inside an <a> link
            cem_link = re.search(r'<a[^>]*href="([^"]*)"[^>]*>([^<]+)</a>',
                                 block)
            if cem_link:
                result["cemetery_url"] = (
                    "https://www.cwgc.org" + cem_link.group(1))
                result["cemetery_memorial"] = cem_link.group(2).strip()

            # Extract text lines from <p> tags (which may be unclosed).
            # First, get everything after the title div closes.
            after_title = re.split(r'</div>', block, maxsplit=1)
            content = after_title[-1] if len(after_title) > 1 else block

            # Split on <p> tags and extract text
            raw_paras = re.split(r'<p[^>]*>', content)
            all_lines = []
            for chunk in raw_paras:
                chunk = re.sub(r'</p>', '', chunk)
                text = re.sub(r'<[^>]+>', '', chunk).strip()
                for line in text.split('\n'):
                    line = _decode_entities(line.strip())
                    if line:
                        all_lines.append(line)

            # Assign: skip cemetery name, then grave ref, then country
            cem_name = result["cemetery_memorial"].upper().strip()
            for line in all_lines:
                if line.upper().strip() == cem_name:
                    continue
                if not result["grave_ref"]:
                    result["grave_ref"] = line
                elif not result["country"]:
                    result["country"] = line

    # Details list items (Country of Service, Additional Info, etc.)
    items = re.findall(
        r'<span class="bold">([^<]+)</span>\s*<span class="item-detail">([^<]+)</span>',
        html)
    for label, value in items:
        label = label.strip()
        value = value.strip()
        if "Country of Service" in label:
            result["country_of_service"] = value
        elif "Additional Info" in label:
            result["additional_info"] = _decode_entities(value)

    # Build URLs
    result["cwgc_url"] = (
        f"https://www.cwgc.org/find-records/find-war-dead/"
        f"casualty-details/{casualty_id}/"
    )
    result["certificate_url"] = (
        f"https://www.cwgc.org/umbraco/surface/Pdf/"
        f"WarDeadCertificate/?id={casualty_id}"
    )

    return result


def _decode_entities(text):
    """Decode common HTML entities."""
    text = text.replace("&#x27;", "'")
    text = text.replace("&#x26;", "&")
    text = text.replace("&amp;", "&")
    text = text.replace("&lt;", "<")
    text = text.replace("&gt;", ">")
    text = text.replace("&quot;", '"')
    return text


def print_results(results, title=None):
    """
    Pretty-print a list of CWGC search results.

    Args:
        results: Output of search()
        title:   Optional header string
    """
    if title:
        print(f"\n=== {title} ===")
    if not results:
        print("  No results found")
        return
    print(f"  {len(results)} result(s)")
    for r in results:
        age_str = f" (age {r['age']})" if r.get("age") else ""
        dod = r.get("date_of_death", "")
        svc = f" [{r['service_number']}]" if r.get("service_number") else ""
        cem = r.get("cemetery_memorial", "")
        grave = f" — {r['grave_ref']}" if r.get("grave_ref") else ""
        print(f"  {r['name']}, {r['rank']}{svc}{age_str}")
        print(f"    {r['regiment']} / {r['unit']}" if r.get("unit") else
              f"    {r['regiment']}")
        if dod:
            print(f"    Died {dod}")
        if cem:
            print(f"    {cem}{grave}")
        if r.get("additional_info"):
            print(f"    {r['additional_info']}")
        print()


def print_casualty(details):
    """Pretty-print full casualty details from get_casualty()."""
    if not details:
        print("  No casualty data found")
        return
    d = details
    print(f"\n{'=' * 60}")
    print(f"  {d['rank']} {d['name']}")
    print(f"{'=' * 60}")
    if d["service_number"]:
        print(f"  Service Number:    {d['service_number']}")
    if d["regiment"]:
        print(f"  Regiment:          {d['regiment']}")
    if d["unit"]:
        print(f"  Unit:              {d['unit']}")
    if d["date_of_death"]:
        age_str = f" (age {d['age']})" if d.get("age") else ""
        print(f"  Date of Death:     {d['date_of_death']}{age_str}")
    if d["cemetery_memorial"]:
        print(f"  Cemetery/Memorial: {d['cemetery_memorial']}")
    if d["grave_ref"]:
        print(f"  Grave Reference:   {d['grave_ref']}")
    if d["country"]:
        print(f"  Country:           {d['country']}")
    if d["country_of_service"]:
        print(f"  Country of Service:{d['country_of_service']}")
    if d["additional_info"]:
        print(f"  Additional Info:   {d['additional_info']}")
    print(f"  CWGC URL:          {d['cwgc_url']}")
    print(f"  Certificate:       {d['certificate_url']}")
    print()


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------
def _cli():
    """Command-line interface for cwgc.py."""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python cwgc.py search SURNAME [FORENAME] [--war=WW1|WW2]")
        print("       [--from=YEAR] [--to=YEAR]")
        print("  python cwgc.py casualty CASUALTY_ID")
        print()
        print("Examples:")
        print("  python cwgc.py search Cauldwell Robert")
        print("  python cwgc.py search Holmes William --war=WW1")
        print("  python cwgc.py search Holmes --war=WW1 --from=1914 --to=1916")
        print("  python cwgc.py casualty 434549")
        sys.exit(1)

    command = sys.argv[1].lower()

    if command == "search":
        if len(sys.argv) < 3:
            print("Error: surname required", file=sys.stderr)
            sys.exit(1)

        surname = sys.argv[2]
        first_name = ""
        war = ""
        year_from = None
        year_to = None

        # Parse remaining args
        for arg in sys.argv[3:]:
            if arg.startswith("--war="):
                war = arg.split("=", 1)[1]
            elif arg.startswith("--from="):
                year_from = int(arg.split("=", 1)[1])
            elif arg.startswith("--to="):
                year_to = int(arg.split("=", 1)[1])
            elif not first_name and not arg.startswith("--"):
                first_name = arg

        results = search(surname, first_name=first_name, war=war,
                         year_from=year_from, year_to=year_to)
        title = f"CWGC search: {surname}"
        if first_name:
            title += f" {first_name}"
        if war:
            title += f" ({war})"
        print_results(results, title=title)

    elif command == "casualty":
        if len(sys.argv) < 3:
            print("Error: casualty ID required", file=sys.stderr)
            sys.exit(1)
        casualty_id = int(sys.argv[2])
        details = get_casualty(casualty_id)
        print_casualty(details)

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        print("Use 'search' or 'casualty'", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    _cli()
