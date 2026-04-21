"""Shared HTTP helper with retry logic for all source libraries.

Handles transient server errors (500, 502, 503) with exponential backoff.
Used by all source libraries instead of raw urllib.request.urlopen.
"""

import time
import urllib.request
import urllib.error


def fetch(url: str, headers: dict = None, timeout: int = 20,
          retries: int = 3, backoff: float = 2.0) -> str:
    """Fetch a URL with retry on transient server errors.

    Args:
        url:      URL to fetch
        headers:  HTTP headers dict
        timeout:  Request timeout in seconds
        retries:  Max attempts (default 3)
        backoff:  Backoff multiplier (wait = backoff ** attempt)

    Returns:
        Response body as string

    Raises:
        urllib.error.HTTPError: On non-retryable HTTP errors (4xx)
        Exception: On final failure after all retries
    """
    req = urllib.request.Request(url, headers=headers or {})
    last_error = None

    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as e:
            last_error = e
            if e.code in (500, 502, 503) and attempt < retries - 1:
                wait = backoff ** attempt
                time.sleep(wait)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last_error = e
            if attempt < retries - 1:
                wait = backoff ** attempt
                time.sleep(wait)
                continue
            raise

    raise last_error or RuntimeError("fetch failed after retries")


def fetch_quiet(url: str, headers: dict = None, timeout: int = 20,
                retries: int = 3, label: str = "") -> str | None:
    """Fetch with retry, returning None on failure instead of raising.

    Prints a single-line warning on final failure.
    """
    try:
        return fetch(url, headers=headers, timeout=timeout, retries=retries)
    except Exception as e:
        source = f"{label}: " if label else ""
        print(f"  {source}unavailable ({e})")
        return None
