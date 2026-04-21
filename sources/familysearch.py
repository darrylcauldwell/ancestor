"""
familysearch.py — FamilySearch search library

FamilySearch (familysearch.org) provides free access to census transcriptions,
parish registers, and other genealogical records.

Authentication — cookie-based:
    1. Log in at https://www.familysearch.org in your browser (Safari)
    2. Open DevTools → Network tab → click any familysearch.org request
    3. Click "Request Cookies" (or look in Request Headers for Cookie:)
    4. You need these key cookies: fssessionid, JSESSIONID, cf_clearance,
       reese84, visid_incap_*, incap_ses_*
    5. Pass the full cookie string to FamilySearch(cookies="...")

    Session typically lasts 1–2 hours. Re-extract if you get 401/403 errors.

Usage:
    from familysearch import FamilySearch

    fs = FamilySearch(cookies="fssessionid=...; JSESSIONID=...; ...")

    # Search census/historical records
    results = fs.search(surname="Cauldwell", given="Ernest",
                        place="Derbyshire, England")
    for r in results:
        print(r["name"], r["birth_date"], r["birth_place"], r["collection"])

    # Search a specific census year
    results = fs.search_census(1901, surname="Twyford", place="Derbyshire")

    # Get full detail for a record by ARK ID
    detail = fs.get_record("XXXX-XXXX")

API endpoint:
    https://www.familysearch.org/service/search/hr/v2/personas
    Parameters: q.surname, q.givenName, q.residenceLikePlace, collectionId, count, offset

Useful collection IDs for England & Wales:
    1921 Census: 4000219
    1911 Census: 1921547
    1901 Census: 1888129
    1891 Census: 1865747
    1881 Census: 1558612
    1871 Census: 1538354
    1861 Census: 1538286
    1851 Census: 1538291
    1841 Census: 1538267
    England Births 1837-2006:    1609780
    England Marriages 1837-2005: 1609785
    England Deaths 1837-2007:    1609796
"""

import urllib.request
import urllib.parse
import json
from typing import Optional

SEARCH_URL = "https://www.familysearch.org/service/search/hr/v2/personas"
RECORD_URL = "https://www.familysearch.org/ark:/61903/1:1:{}"

# England & Wales census collection IDs
CENSUS = {
    1841: "1538267",
    1851: "1538291",
    1861: "1538286",
    1871: "1538354",
    1881: "1558612",
    1891: "1865747",
    1901: "1888129",
    1911: "1921547",
    1921: "4000219",
}

ENGLAND_BIRTHS     = "1609780"
ENGLAND_MARRIAGES  = "1609785"
ENGLAND_DEATHS     = "1609796"


class FamilySearch:
    """Client for the FamilySearch search API."""

    def __init__(self, cookies: str):
        """
        Args:
            cookies: Full cookie string from Safari DevTools.
                     Must include at minimum: fssessionid, JSESSIONID,
                     cf_clearance, reese84, visid_incap_* cookies.

        How to get:
            1. Log in at familysearch.org in Safari
            2. DevTools → Network tab → any familysearch.org request
            3. Request Headers → Cookie: value (the long string)
            OR Request Cookies tab → copy all name=value pairs joined by "; "
        """
        self.headers = {
            "Cookie": cookies,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-GB,en;q=0.9",
            "Referer": "https://www.familysearch.org/en/search/record/results",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15",
        }

    def _get(self, url: str) -> dict:
        req = urllib.request.Request(url, headers=self.headers)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            if e.code in (401, 403):
                raise RuntimeError(
                    f"HTTP {e.code} — session expired. Re-extract cookies from browser."
                ) from e
            raise RuntimeError(f"HTTP {e.code}: {body[:300]}") from e

    def _parse_entries(self, data: dict) -> list[dict]:
        """Parse GEDCOMx entries into simple dicts."""
        results = []
        for entry in data.get("entries", []):
            content = entry.get("content", {}).get("gedcomx", {})
            record = {
                "id": "",
                "name": "",
                "birth_date": "",
                "birth_place": "",
                "death_date": "",
                "death_place": "",
                "residence_date": "",
                "residence_place": "",
                "collection": "",
                "ark": "",
                "household": [],  # other persons in same record
                "raw": entry,
            }

            # Extract persons — first person is the search match; rest are household
            persons = content.get("persons", [])
            for i, person in enumerate(persons):
                names = person.get("names", [])
                full_name = ""
                if names:
                    full_name = names[0].get("nameForms", [{}])[0].get("fullText", "")

                facts = person.get("facts", [])
                birth_date = birth_place = death_date = death_place = ""
                res_date = res_place = ""
                for fact in facts:
                    ftype = fact.get("type", "").split("/")[-1]
                    date = fact.get("date", {}).get("original", "")
                    place = fact.get("place", {}).get("original", "")
                    if ftype == "Birth":
                        birth_date, birth_place = date, place
                    elif ftype == "Death":
                        death_date, death_place = date, place
                    elif ftype in ("Census", "Residence"):
                        res_date, res_place = date, place

                if i == 0:
                    # First person is the primary match
                    record["name"] = full_name
                    record["birth_date"] = birth_date
                    record["birth_place"] = birth_place
                    record["death_date"] = death_date
                    record["death_place"] = death_place
                    record["residence_date"] = res_date
                    record["residence_place"] = res_place
                    pid = person.get("id", "")
                    if pid:
                        record["id"] = pid
                        record["ark"] = f"https://www.familysearch.org/ark:/61903/1:1:{pid}"
                elif full_name:
                    record["household"].append(full_name)

            # Collection title from description
            descriptions = content.get("sourceDescriptions", [])
            if descriptions:
                record["collection"] = descriptions[0].get("titles", [{}])[0].get("value", "")

            results.append(record)
        return results

    def search(
        self,
        surname: str = "",
        given: str = "",
        place: str = "",
        collection_id: str = "",
        count: int = 20,
        offset: int = 0,
    ) -> list[dict]:
        """
        Search FamilySearch records.

        Results are ranked by relevance — records matching surname + place
        float to the top even when total count is large.

        Args:
            surname:       Surname to search
            given:         Given/first name
            place:         Any place (residence, birth, death)
                           e.g. "Derbyshire, England" or "Youlgreave, Derbyshire"
            collection_id: Restrict to a specific collection (use CENSUS[1901] etc.)
            count:         Number of results (max 50)
            offset:        Pagination offset

        Returns:
            List of dicts with: name, birth_date, birth_place, death_date,
            death_place, residence_date, residence_place, collection, ark, household
        """
        params = {}
        if surname:
            params["q.surname"] = surname
        if given:
            params["q.givenName"] = given
        if place:
            params["q.residenceLikePlace"] = place
        if collection_id:
            params["f.collectionId"] = collection_id
        params["count"] = count
        params["offset"] = offset
        params["m.defaultFacets"] = "on"

        url = f"{SEARCH_URL}?{urllib.parse.urlencode(params)}"
        data = self._get(url)
        results = self._parse_entries(data)

        total = data.get("results", 0)
        return results, total

    def search_census(
        self,
        year: int,
        surname: str = "",
        given: str = "",
        place: str = "",
        count: int = 20,
    ) -> list[dict]:
        """
        Search a specific England & Wales census year.

        Args:
            year: Census year — one of 1841, 1851, 1861, 1871, 1881, 1891,
                  1901, 1911, 1921
        """
        cid = CENSUS.get(year)
        if not cid:
            raise ValueError(f"Unknown census year {year}. Supported: {sorted(CENSUS)}")
        return self.search(surname=surname, given=given, place=place,
                           collection_id=cid, count=count)

    def get_record(self, ark_id: str) -> dict:
        """
        Fetch full detail for a record by its ARK ID.

        Args:
            ark_id: The ID portion of the ARK, e.g. "XXXX-XXXX"
                    or full URL "https://www.familysearch.org/ark:/61903/1:1:XXXX-XXXX"
        """
        if "1:1:" in ark_id:
            ark_id = ark_id.split("1:1:")[-1].rstrip("/")
        url = f"https://www.familysearch.org/ark:/61903/1:1:{ark_id}?format=json"
        return self._get(url)


def print_results(results, title: str = "", total: int = 0):
    """Pretty-print search results."""
    if title:
        print(f"\n=== {title} ===")
    if isinstance(results, str):
        print(f"  {results}")
        return
    if total:
        print(f"  {len(results)} shown of {total:,} total (ranked by relevance)")
    else:
        print(f"  {len(results)} result(s)")
    for r in results:
        name = r.get("name", "")
        birth = f"b.{r['birth_date']} {r['birth_place']}".strip() if r.get("birth_date") or r.get("birth_place") else ""
        death = f"d.{r['death_date']} {r['death_place']}".strip() if r.get("death_date") or r.get("death_place") else ""
        res = f"{r['residence_date']} {r['residence_place']}".strip() if r.get("residence_place") else ""
        coll = r.get("collection", "")[:60]
        ark = r.get("ark", "")
        household = ", ".join(r.get("household", []))

        print(f"\n  {name}")
        if birth:  print(f"    Birth:     {birth}")
        if res:    print(f"    Residence: {res}")
        if death:  print(f"    Death:     {death}")
        if household: print(f"    Household: {household}")
        if coll:   print(f"    Source:    {coll}")
        if ark:    print(f"    ARK:       {ark}")


# ---------------------------------------------------------------------------
# Demo / cookie test when run directly
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python3 familysearch.py 'full-cookie-string'")
        print()
        print("Get cookies from Safari DevTools:")
        print("  1. Log in at familysearch.org")
        print("  2. DevTools → Network tab → any familysearch.org request")
        print("  3. Request Cookies tab → copy all as name=value; name=value...")
        sys.exit(1)

    cookies = sys.argv[1]
    fs = FamilySearch(cookies)

    print("Test 1: Ernest Cauldwell in Derbyshire (all records)")
    results, total = fs.search(surname="Cauldwell", given="Ernest",
                               place="Derbyshire, England")
    print_results(results[:5], total=total)

    print("\nTest 2: Twyford births in Derbyshire (1901 census)")
    results, total = fs.search_census(1901, surname="Twyford",
                                      place="Derbyshire, England")
    print_results(results[:5], total=total)
