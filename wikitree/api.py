"""WikiTree API read client (api.wikitree.com).

Auth: supply email + password; call login() which restores a saved
session or authenticates fresh via the clientLogin two-step flow.
Session cookies are persisted to disk as JSON.

All API calls include appId to avoid strict rate limits.

Reads: getProfile, getPeople (batch up to 1000), getBio, getRelatives,
getAncestors, getDescendants, searchPerson, getWatchlist.

Writes: NOT via this module — see wikitree.editor for Playwright-
driven edits to profile forms.
"""
import json
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import requests
from requests.utils import cookiejar_from_dict, dict_from_cookiejar

from ._models import Profile

API_URL = "https://api.wikitree.com/api.php"

DEFAULT_FIELDS = ",".join([
    "Id", "Name", "FirstName", "MiddleName", "LastNameAtBirth",
    "LastNameCurrent", "LastNameOther", "RealName", "Nicknames",
    "Prefix", "Suffix", "ColloquialName",
    "BirthDate", "BirthDateDecade", "BirthLocation",
    "DeathDate", "DeathDateDecade", "DeathLocation",
    "Gender", "IsLiving",
    "Father", "Mother", "Parents", "Spouses", "Children", "Siblings",
    "DataStatus", "Privacy", "Manager",
    "Bio", "Photo", "PhotoData",
    "Derived.BirthName", "Derived.LongName",
])


class WikiTreeAPI:
    """Authenticated read client for api.wikitree.com.

    Usage:
        api = WikiTreeAPI(email="you@example.com", password="secret")
        api.login()
        profile = api.get_profile("Cauldwell-103")
    """

    def __init__(self, email: str, password: str,
                 app_id: str = "ancestor-genealogy",
                 session_file: Path = Path(".wikitree-session.json"),
                 rate_limit: float = 0.3):
        self._email = email
        self._password = password
        self._app_id = app_id
        self._session_file = Path(session_file)
        self._rate_limit_seconds = rate_limit
        self._session = requests.Session()

    def login(self) -> dict:
        """Restore saved session if still valid, else authenticate fresh."""
        if self._session_file.exists():
            try:
                cookies = json.loads(self._session_file.read_text())
                self._session.cookies = cookiejar_from_dict(cookies)
                me = self.whoami()
                if me:
                    return me
            except (json.JSONDecodeError, ValueError):
                pass  # corrupt file — fall through to fresh auth
        return self._authenticate()

    def _authenticate(self) -> dict:
        """Two-step clientLogin: POST credentials -> capture authcode -> confirm."""
        r = self._session.post(API_URL, data={
            "action": "clientLogin", "doLogin": "1",
            "wpEmail": self._email, "wpPassword": self._password,
        }, allow_redirects=False)
        location = r.headers.get("Location", "")
        authcode = parse_qs(urlparse(location).query).get("authcode", [None])[0]
        if not authcode:
            raise RuntimeError(
                f"Login failed: no authcode in redirect. "
                f"Status={r.status_code}, Location={location!r}"
            )
        # clientLogin returns {"clientLogin": {"result": "Success", ...}}
        raw = self._session.post(API_URL, data={
            "action": "clientLogin", "authcode": authcode,
            "appId": self._app_id, "format": "json",
        })
        raw.raise_for_status()
        data = raw.json()
        login_result = data.get("clientLogin") or {}
        if login_result.get("result", "").lower() != "success":
            raise RuntimeError(f"Login confirmation failed: {data}")
        self._save_session()
        me = self.whoami()
        if not me:
            raise RuntimeError("Authenticated but whoami() returned None")
        return me

    def _save_session(self):
        cookies = dict_from_cookiejar(self._session.cookies)
        self._session_file.write_text(json.dumps(cookies, indent=2))

    def _post(self, params: dict) -> list:
        """POST to API; returns parsed JSON (list of response objects)."""
        payload = {**params, "appId": self._app_id, "format": "json"}
        r = self._session.post(API_URL, data=payload)
        r.raise_for_status()
        return r.json()

    def _wait(self):
        """Rate-limit pause between batch calls."""
        time.sleep(self._rate_limit_seconds)

    # --- Read methods ---

    def whoami(self) -> dict | None:
        """Return logged-in user info, or None if not authenticated.

        Uses getProfile on the logged-in user's own profile as a lightweight
        auth check. Falls back to getWatchlist if needed.
        """
        # Try getWatchlist — if we get a watchlist back, we're authenticated.
        # Extract user info from the first watchlist entry.
        try:
            resp = self._post({"action": "getWatchlist", "limit": "1"})
        except Exception:
            return None
        if isinstance(resp, list) and resp:
            first = resp[0] if isinstance(resp[0], dict) else {}
            # Old Playwright API returned user_id/user_name at top level;
            # requests-based flow puts them in the watchlist entries.
            watchlist = first.get("watchlist") or []
            if watchlist:
                entry = watchlist[0]
                return {
                    "user_id": entry.get("Id") or entry.get("user_id"),
                    "user_name": entry.get("Name") or entry.get("user_name"),
                    "watchlist_count": len(watchlist),
                }
            # Some responses have user_id/user_name at the top level
            if first.get("user_id") and first.get("user_name"):
                return {
                    "user_id": first["user_id"],
                    "user_name": first["user_name"],
                    "watchlist_count": first.get("watchlistCount", 0),
                }
        return None

    def get_profile(self, wt_id: str, fields: str = DEFAULT_FIELDS) -> Profile | None:
        """Fetch a single profile by WikiTree ID."""
        resp = self._post({"action": "getProfile", "key": wt_id,
                           "fields": fields, "bioFormat": "wiki"})
        if isinstance(resp, list) and resp:
            return resp[0].get("profile")
        return None

    def get_profiles(self, wt_ids, fields: str = DEFAULT_FIELDS,
                     progress=None) -> dict[str, Profile]:
        """Fetch many profiles. Returns dict keyed by Name.

        Uses getPeople internally (up to 1000 per call).
        """
        results = {}
        wt_ids = list(wt_ids)
        for i in range(0, len(wt_ids), 1000):
            chunk = wt_ids[i:i + 1000]
            resp = self._post({"action": "getPeople", "keys": ",".join(chunk),
                               "fields": fields, "bioFormat": "wiki"})
            if isinstance(resp, list) and resp:
                people = resp[0].get("people", {})
                for p in people.values():
                    if isinstance(p, dict) and p.get("Name"):
                        results[p["Name"]] = p
            if progress:
                progress(min(i + 1000, len(wt_ids)), len(wt_ids))
            self._wait()
        return results

    def get_bio(self, wt_id: str) -> str:
        """Fetch raw MediaWiki biography text for a profile."""
        resp = self._post({"action": "getBio", "key": wt_id, "bioFormat": "wiki"})
        if isinstance(resp, list) and resp:
            return resp[0].get("bio") or ""
        return ""

    def get_relatives(self, wt_ids, get_parents=True, get_children=True,
                      get_siblings=True, get_spouses=True) -> list:
        """Fetch parents, children, siblings, and/or spouses."""
        if isinstance(wt_ids, str):
            wt_ids = [wt_ids]
        params = {"action": "getRelatives", "keys": ",".join(wt_ids)}
        if get_parents:
            params["getParents"] = "1"
        if get_children:
            params["getChildren"] = "1"
        if get_siblings:
            params["getSiblings"] = "1"
        if get_spouses:
            params["getSpouses"] = "1"
        resp = self._post(params)
        return resp if isinstance(resp, list) else []

    def get_ancestors(self, wt_id: str, depth: int = 4,
                      fields: str = DEFAULT_FIELDS) -> list[Profile]:
        """Fetch multiple generations of ancestors."""
        resp = self._post({"action": "getAncestors", "key": wt_id,
                           "depth": str(depth), "fields": fields,
                           "bioFormat": "wiki"})
        if isinstance(resp, list) and resp:
            return resp[0].get("ancestors", [])
        return []

    def get_descendants(self, wt_id: str, depth: int = 4,
                        fields: str = DEFAULT_FIELDS) -> list[Profile]:
        """Fetch multiple generations of descendants."""
        resp = self._post({"action": "getDescendants", "key": wt_id,
                           "depth": str(depth), "fields": fields,
                           "bioFormat": "wiki"})
        if isinstance(resp, list) and resp:
            return resp[0].get("descendants", [])
        return []

    def search_person(self, first_name: str = "", last_name: str = "",
                      birth_date: str = "", death_date: str = "",
                      birth_location: str = "", death_location: str = "",
                      **extra) -> tuple[list[Profile], int]:
        """Search for person profiles. Returns (matches, total_count).

        Uses explicit parameter names for common fields to catch typos;
        pass additional WikiTree search params via **extra.
        """
        params = {"action": "searchPerson", **extra}
        if first_name:
            params["FirstName"] = first_name
        if last_name:
            params["LastName"] = last_name
        if birth_date:
            params["BirthDate"] = birth_date
        if death_date:
            params["DeathDate"] = death_date
        if birth_location:
            params["BirthLocation"] = birth_location
        if death_location:
            params["DeathLocation"] = death_location
        resp = self._post(params)
        if isinstance(resp, list) and resp:
            data = resp[0]
            return data.get("matches", []), data.get("total", 0)
        return [], 0

    def get_watchlist(self, fields: str = "Id,Name,FirstName,LastNameAtBirth,BirthDate",
                      page_size: int = 1000, limit: int | None = None) -> list:
        """Paged fetch of entire watchlist."""
        results = []
        offset = 0
        while True:
            resp = self._post({
                "action": "getWatchlist", "limit": str(page_size),
                "offset": str(offset), "fields": fields, "getPerson": "1",
            })
            if not isinstance(resp, list) or not resp:
                break
            watchlist = resp[0].get("watchlist") or []
            if not watchlist:
                break
            results.extend(watchlist)
            if len(watchlist) < page_size:
                break
            offset += page_size
            if limit and len(results) >= limit:
                break
            self._wait()
        return results[:limit] if limit else results
