"""Typed data models for WikiTree API responses."""
from typing import TypedDict


class Profile(TypedDict, total=False):
    Id: int
    Name: str
    FirstName: str
    MiddleName: str
    LastNameAtBirth: str
    LastNameCurrent: str
    LastNameOther: str
    RealName: str
    Nicknames: str
    Prefix: str
    Suffix: str
    BirthDate: str
    BirthDateDecade: str
    BirthLocation: str
    DeathDate: str
    DeathDateDecade: str
    DeathLocation: str
    Gender: str
    IsLiving: int
    Father: int
    Mother: int
    Parents: dict
    Spouses: dict
    Children: dict
    Siblings: dict
    DataStatus: dict
    Privacy: int
    Manager: int
    Bio: str
    Photo: str
    PhotoData: dict


def get_bio_text(profile: dict) -> str:
    """Return bio text regardless of 'Bio' vs 'bio' key inconsistency."""
    return profile.get("Bio") or profile.get("bio") or ""
