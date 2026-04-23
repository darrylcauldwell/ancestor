"""
familysearch.py — FamilySearch search library

Searches FamilySearch historical records using the same backend API
as the website. Cookie-based authentication (no API keys available
for personal use).

Authentication:
    1. Log in at https://www.familysearch.org in Safari
    2. DevTools (Cmd+Opt+I) → Network tab → click any request
    3. Copy the Cookie header value or all Request Cookies
    4. Pass to FamilySearch(cookies="...")
    Cookies expire every 1-2 hours.

Usage:
    from sources.familysearch import FamilySearch, load_cookies

    fs = FamilySearch(load_cookies())   # from .familysearch-session.json
    # or
    fs = FamilySearch("fssessionid=...; JSESSIONID=...; ...")

    # Broad search (all collections)
    results, total = fs.search(surname="Marshall", given="Harry",
                                birth_place="Bakewell",
                                birth_year_from=1920, birth_year_to=1930)

    # Search with spouse
    results, total = fs.search(surname="Marshall", given="Harry",
                                spouse_surname="Twyford")

    # Census search (by residence year)
    results, total = fs.search(surname="Twyford", given="Elsie",
                                residence_place="Youlgreave",
                                residence_year=1901)

    # Print results
    print_results(results, total=total)
"""

import json
import urllib.request
import urllib.parse
from pathlib import Path


SEARCH_URL = "https://www.familysearch.org/service/search/hr/v2/personas"
SESSION_FILE = Path(__file__).parent.parent / ".familysearch-session.json"


def load_cookies() -> str:
    """Load cookies from .familysearch-session.json.

    Returns cookie string, or empty string if file missing/invalid.
    """
    if not SESSION_FILE.exists():
        return ""
    try:
        data = json.loads(SESSION_FILE.read_text())
        cookies = data.get("cookies", [])
        if isinstance(cookies, list):
            return "; ".join(f"{c['name']}={c['value']}" for c in cookies)
        return ""
    except (json.JSONDecodeError, KeyError):
        return ""


class FamilySearch:
    """Client for FamilySearch historical record search."""

    def __init__(self, cookies: str = ""):
        """
        Args:
            cookies: Full cookie string. If empty, tries load_cookies().
        """
        if not cookies:
            cookies = load_cookies()
        if not cookies:
            raise RuntimeError(
                "No FamilySearch cookies. Log in at familysearch.org, "
                "then extract cookies from Safari DevTools."
            )
        self.headers = {
            "Cookie": cookies,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-GB,en;q=0.9",
            "Referer": "https://www.familysearch.org/en/search/record/results",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                          "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                          "Version/26.3.1 Safari/605.1.15",
        }

    def _get(self, url: str) -> dict:
        from sources._http import fetch
        body = fetch(url, headers=self.headers, timeout=20, retries=2)
        return json.loads(body)

    def search(
        self,
        surname: str = "",
        given: str = "",
        # Birth
        birth_place: str = "",
        birth_year_from: int | None = None,
        birth_year_to: int | None = None,
        # Death
        death_place: str = "",
        death_year_from: int | None = None,
        death_year_to: int | None = None,
        # Residence (census)
        residence_place: str = "",
        residence_year: int | None = None,
        # Marriage
        marriage_place: str = "",
        marriage_year_from: int | None = None,
        marriage_year_to: int | None = None,
        # Spouse
        spouse_surname: str = "",
        spouse_given: str = "",
        # Father / Mother
        father_surname: str = "",
        father_given: str = "",
        mother_surname: str = "",
        mother_given: str = "",
        # Pagination
        count: int = 20,
        offset: int = 0,
    ) -> tuple[list[dict], int]:
        """Search FamilySearch historical records.

        Uses the same parameters as the website search. All parameters
        are optional — combine as needed.

        Returns (results, total_count).
        """
        params = {}

        # Person
        if surname:
            params["q.surname"] = surname
        if given:
            params["q.givenName"] = given

        # Birth
        if birth_place:
            params["q.birthLikePlace"] = birth_place
        if birth_year_from:
            params["q.birthLikeDate.from"] = birth_year_from
        if birth_year_to:
            params["q.birthLikeDate.to"] = birth_year_to

        # Death
        if death_place:
            params["q.deathLikePlace"] = death_place
        if death_year_from:
            params["q.deathLikeDate.from"] = death_year_from
        if death_year_to:
            params["q.deathLikeDate.to"] = death_year_to

        # Residence
        if residence_place:
            params["q.residenceLikePlace"] = residence_place
        if residence_year:
            params["q.residenceDate.from"] = residence_year
            params["q.residenceDate.to"] = residence_year

        # Marriage
        if marriage_place:
            params["q.marriageLikePlace"] = marriage_place
        if marriage_year_from:
            params["q.marriageLikeDate.from"] = marriage_year_from
        if marriage_year_to:
            params["q.marriageLikeDate.to"] = marriage_year_to

        # Spouse
        if spouse_surname:
            params["q.spouseSurname"] = spouse_surname
        if spouse_given:
            params["q.spouseGivenName"] = spouse_given

        # Father / Mother
        if father_surname:
            params["q.fatherSurname"] = father_surname
        if father_given:
            params["q.fatherGivenName"] = father_given
        if mother_surname:
            params["q.motherSurname"] = mother_surname
        if mother_given:
            params["q.motherGivenName"] = mother_given

        # Pagination
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
    ) -> tuple[list[dict], int]:
        """Search a specific census year by residence date.

        Args:
            year: Census year (1841-1921)
            place: Residence place (e.g. "Youlgreave, Derbyshire")
        """
        return self.search(
            surname=surname,
            given=given,
            residence_place=place,
            residence_year=year,
            count=count,
        )

    def search_births(
        self,
        surname: str = "",
        given: str = "",
        place: str = "",
        year_from: int | None = None,
        year_to: int | None = None,
        mother_surname: str = "",
        count: int = 20,
    ) -> tuple[list[dict], int]:
        """Search birth records."""
        return self.search(
            surname=surname,
            given=given,
            birth_place=place,
            birth_year_from=year_from,
            birth_year_to=year_to,
            mother_surname=mother_surname,
            count=count,
        )

    def search_deaths(
        self,
        surname: str = "",
        given: str = "",
        place: str = "",
        year_from: int | None = None,
        year_to: int | None = None,
        count: int = 20,
    ) -> tuple[list[dict], int]:
        """Search death records."""
        return self.search(
            surname=surname,
            given=given,
            death_place=place,
            death_year_from=year_from,
            death_year_to=year_to,
            count=count,
        )

    def search_marriages(
        self,
        surname: str = "",
        given: str = "",
        place: str = "",
        year_from: int | None = None,
        year_to: int | None = None,
        spouse_surname: str = "",
        spouse_given: str = "",
        count: int = 20,
    ) -> tuple[list[dict], int]:
        """Search marriage records."""
        return self.search(
            surname=surname,
            given=given,
            marriage_place=place,
            marriage_year_from=year_from,
            marriage_year_to=year_to,
            spouse_surname=spouse_surname,
            spouse_given=spouse_given,
            count=count,
        )

    def _parse_entries(self, data: dict) -> list[dict]:
        """Parse GEDCOMx entries into simple dicts.

        Handles all FamilySearch record types:
        - Census/Residence → residence_date, residence_place
        - Birth, BirthRegistration, Christening, Baptism → birth_date, birth_place
        - Death, DeathRegistration, Burial → death_date, death_place
        - Marriage, MarriageBanns, MarriageRegistration → marriage_date, marriage_place
        - Occupation, MaritalStatus → occupation, marital_status
        - Fields: Age, RelationshipToHead, ExtRecordId
        """
        results = []
        for entry in data.get("entries", []):
            content = entry.get("content", {}).get("gedcomx", {})
            record = {
                "name": "",
                "birth_date": "",
                "birth_place": "",
                "death_date": "",
                "death_place": "",
                "residence_date": "",
                "residence_place": "",
                "marriage_date": "",
                "marriage_place": "",
                "collection": "",
                "ark": "",
                "record_type": "",
                "household": [],
                "relationships": [],
            }

            persons = content.get("persons", [])
            for i, person in enumerate(persons):
                names = person.get("names", [])
                full_name = ""
                if names:
                    full_name = names[0].get("nameForms", [{}])[0].get("fullText", "")

                facts = person.get("facts", [])
                person_data = {"name": full_name}
                for fact in facts:
                    ftype = fact.get("type", "").split("/")[-1]
                    date = fact.get("date", {}).get("original", "")
                    place = fact.get("place", {}).get("original", "")

                    # Birth-related facts
                    if ftype in ("Birth", "BirthRegistration", "Christening", "Baptism"):
                        person_data["birth_date"] = date
                        person_data["birth_place"] = place
                        if i == 0 and not record["record_type"]:
                            record["record_type"] = ftype.lower()

                    # Death-related facts
                    elif ftype in ("Death", "DeathRegistration", "Burial"):
                        person_data["death_date"] = date
                        person_data["death_place"] = place
                        if i == 0 and not record["record_type"]:
                            record["record_type"] = ftype.lower()

                    # Residence/Census
                    elif ftype in ("Census", "Residence"):
                        person_data["residence_date"] = date
                        person_data["residence_place"] = place
                        if i == 0 and not record["record_type"]:
                            record["record_type"] = "census"

                    # Marriage-related facts
                    elif ftype in ("Marriage", "MarriageBanns", "MarriageRegistration"):
                        person_data["marriage_date"] = date
                        person_data["marriage_place"] = place
                        if i == 0 and not record["record_type"]:
                            record["record_type"] = ftype.lower()

                    elif ftype == "Occupation":
                        person_data["occupation"] = date or place
                    elif ftype == "MaritalStatus":
                        person_data["marital_status"] = date

                # Extract fields — Age, RelationshipToHead, ExtRecordId
                fields = person.get("fields", [])
                for field in fields:
                    field_type = field.get("type", "").split("/")[-1]
                    values = field.get("values", [])
                    if values:
                        text = values[0].get("text", "")
                        if field_type == "Age":
                            person_data["age"] = text
                        elif field_type == "RelationshipToHead":
                            person_data["relationship"] = text
                        elif field_type == "ExtRecordId":
                            person_data["record_id"] = text
                        elif field_type == "Role":
                            person_data["role"] = text

                if i == 0:
                    record.update(person_data)
                    pid = person.get("id", "")
                    if pid:
                        record["ark"] = f"https://www.familysearch.org/ark:/61903/1:1:{pid}"
                else:
                    record["household"].append(person_data)

            # Collection title
            descriptions = content.get("sourceDescriptions", [])
            if descriptions:
                record["collection"] = descriptions[0].get("titles", [{}])[0].get("value", "")
                about = descriptions[0].get("about", "")
                if about:
                    record["collection_ark"] = about

            # Build person ID → index map for relationship resolution
            pid_to_idx = {}
            for idx, person in enumerate(persons):
                pid = person.get("id", "")
                if pid:
                    pid_to_idx[pid] = idx

            # Relationship facts (marriage dates, parent-child links)
            primary_pid = persons[0].get("id", "") if persons else ""
            for rel in content.get("relationships", []):
                rtype = rel.get("type", "").split("/")[-1]
                p1 = rel.get("person1", {}).get("resourceId", "")
                p2 = rel.get("person2", {}).get("resourceId", "")
                rel_data = {"type": rtype, "person1": p1, "person2": p2}

                # Marriage facts on relationships
                for fact in rel.get("facts", []):
                    ftype = fact.get("type", "").split("/")[-1]
                    date = fact.get("date", {}).get("original", "")
                    place = fact.get("place", {}).get("original", "")
                    if ftype in ("Marriage", "MarriageBanns", "MarriageRegistration"):
                        rel_data["marriage_date"] = date
                        rel_data["marriage_place"] = place
                        if not record.get("marriage_date"):
                            record["marriage_date"] = date
                            record["marriage_place"] = place
                        if not record["record_type"]:
                            record["record_type"] = ftype.lower()

                # Tag household members with their relationship role
                # ParentChild: p1 is parent, p2 is child
                if rtype == "ParentChild" and p2 == primary_pid:
                    # p1 is the parent of the primary person
                    parent_idx = pid_to_idx.get(p1)
                    if parent_idx is not None and parent_idx > 0:
                        hh_idx = parent_idx - 1  # household is 0-indexed from person 1
                        if hh_idx < len(record["household"]):
                            record["household"][hh_idx]["relationship"] = "parent"

                elif rtype == "Couple":
                    # Tag both as spouse if neither is primary
                    for pid in (p1, p2):
                        idx = pid_to_idx.get(pid)
                        if idx is not None and idx > 0:
                            hh_idx = idx - 1
                            if hh_idx < len(record["household"]):
                                if record["household"][hh_idx].get("relationship") != "parent":
                                    record["household"][hh_idx]["relationship"] = "spouse"

                record["relationships"].append(rel_data)

            results.append(record)
        return results


def print_results(results, title: str = "", total: int = 0):
    """Pretty-print search results."""
    if title:
        print(f"\n=== {title} ===")
    if total:
        print(f"  {len(results)} shown of {total:,} total")
    else:
        print(f"  {len(results)} result(s)")

    for r in results:
        name = r.get("name", "?")
        birth = f"b.{r['birth_date']} {r['birth_place']}".strip() if r.get("birth_date") or r.get("birth_place") else ""
        death = f"d.{r['death_date']} {r['death_place']}".strip() if r.get("death_date") or r.get("death_place") else ""
        res = f"res.{r['residence_date']} {r['residence_place']}".strip() if r.get("residence_place") else ""
        marriage = f"m.{r['marriage_date']} {r['marriage_place']}".strip() if r.get("marriage_date") or r.get("marriage_place") else ""
        coll = r.get("collection", "")
        ark = r.get("ark", "")

        print(f"\n  {name}")
        if birth:     print(f"    {birth}")
        if res:       print(f"    {res}")
        if marriage:  print(f"    {marriage}")
        if death:     print(f"    {death}")
        if coll:      print(f"    [{coll}]")
        if ark:       print(f"    {ark}")

        for h in r.get("household", [])[:5]:
            hname = h.get("name", "?")
            hbirth = h.get("birth_date", "")
            hplace = h.get("birth_place", "")
            print(f"    + {hname} b.{hbirth} {hplace}")
        if len(r.get("household", [])) > 5:
            print(f"    + ... and {len(r['household']) - 5} more")


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python3 familysearch.py 'cookie-string'")
        print("   or: python3 familysearch.py --session  (uses .familysearch-session.json)")
        sys.exit(1)

    cookies = load_cookies() if sys.argv[1] == "--session" else sys.argv[1]
    fs = FamilySearch(cookies)

    print("Test: Elsie Twyford born Bakewell 1925-1930")
    results, total = fs.search_births(surname="Twyford", given="Elsie",
                                       place="Bakewell",
                                       year_from=1925, year_to=1930)
    print_results(results, total=total)
