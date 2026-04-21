"""WikiTree SDK — authenticated read access to WikiTree profiles.

Requires: pip install requests

Read API:
    import os
    from wikitree import WikiTreeAPI

    api = WikiTreeAPI(email=os.environ["WIKITREE_EMAIL"],
                      password=os.environ["WIKITREE_PASSWORD"])
    api.login()
    profile = api.get_profile("Smith-12345")
"""
from .api import WikiTreeAPI
from ._models import Profile, get_bio_text

__all__ = ["WikiTreeAPI", "Profile", "get_bio_text"]
