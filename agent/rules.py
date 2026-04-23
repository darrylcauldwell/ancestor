"""Genealogy research rules — deterministic knowledge codified as Python.

Hard rules: always true, mechanically enforced. A violation means the
record is wrong or doesn't belong to this person.

Soft rules: usually true, used for scoring not rejecting. A low score
means "less likely" not "impossible."

Source rules: facts about what each data source can and can't tell you.

Pattern rules: genealogical patterns that suggest follow-up research.

These rules were discovered through seven iterations of building a
research agent (see blog: "I Built an AI Agent That Kept Getting It
Wrong"). Each iteration moved intelligence from the LLM to Python.
The LLM demonstrated the patterns; we codified them here.
"""


# ============================================================
# HARD RULES — always true, mechanically enforced
# ============================================================

def check_birth_before_death(birth_year: int, death_year: int) -> bool:
    """A person must be born before they die."""
    return birth_year <= death_year


def check_parent_age_gap(parent_birth: int, child_birth: int) -> bool:
    """A parent must be at least 14 years older than their child."""
    return (child_birth - parent_birth) >= 14


def check_marriage_age(birth_year: int, marriage_year: int) -> bool:
    """Must be at least 16 to marry."""
    return (marriage_year - birth_year) >= 16


def check_lifespan(birth_year: int, death_year: int) -> bool:
    """No one lives beyond 110 years."""
    return (death_year - birth_year) <= 110


def check_not_married_after_death(marriage_year: int, death_year: int) -> bool:
    """Can't marry after death."""
    return marriage_year <= death_year


def check_temporal_possibility(birth_year: int, event_year: int,
                                event_type: str) -> str | None:
    """Check if an event is temporally possible for a person.

    Returns None if OK, or a string describing the impossibility.
    """
    if event_type == "birth":
        diff = abs(event_year - birth_year)
        if diff > 5:
            return f"birth year {event_year} is {diff} years from expected ~{birth_year}"

    elif event_type == "death":
        if event_year < birth_year:
            return f"died {event_year} before birth {birth_year}"
        age = event_year - birth_year
        if age > 110:
            return f"died {event_year}, would be {age} years old"

    elif event_type == "marriage":
        if event_year < birth_year + 16:
            return f"married {event_year}, would be {event_year - birth_year} years old"
        if event_year > birth_year + 80:
            return f"married {event_year}, would be {event_year - birth_year} years old"

    elif event_type == "census":
        if event_year < birth_year:
            return f"census {event_year} is before birth {birth_year}"

    return None


def validate_record(record_year: int, birth_year: int | None,
                     death_year: int | None,
                     record_type: str) -> str:
    """Validate a record against known dates.

    Returns: "valid", "impossible", or "implausible" with reason.
    """
    if not birth_year:
        return "valid"

    issue = check_temporal_possibility(birth_year, record_year, record_type)
    if issue:
        if "before birth" in issue or "IMPOSSIBLE" in issue:
            return f"impossible: {issue}"
        return f"implausible: {issue}"

    if death_year:
        if record_type == "marriage" and record_year > death_year:
            return f"impossible: married {record_year} after death {death_year}"
        if record_type == "census" and record_year > death_year:
            return f"impossible: census {record_year} after death {death_year}"

    return "valid"


# ============================================================
# TOLERANCES — known variance in historical records
# ============================================================

CENSUS_AGE_TOLERANCE = 2
"""Census ages can be ±2 years from actual birth year.
Victorian self-reporting was approximate."""

BIRTH_YEAR_TOLERANCE = 2
"""FreeBMD birth year and census-derived birth year may differ by 1-2 years.
Registration quarter vs actual birth date, plus census age rounding."""

DEATH_AGE_TOLERANCE = 1
"""GRO death age is usually accurate to within 1 year."""


def years_match(year_a: int, year_b: int,
                tolerance: int = BIRTH_YEAR_TOLERANCE) -> bool:
    """Check if two years are within tolerance of each other."""
    return abs(year_a - year_b) <= tolerance


# ============================================================
# SOURCE RULES — what each source can and can't tell you
# ============================================================

CIVIL_REGISTRATION_START = 1837
"""Civil registration (GRO) begins 1 July 1837.
Before this, parish registers are the primary source."""

MOTHERS_MAIDEN_NAME_START = 1911
"""Mother's maiden name appears on FreeBMD birth entries from Sep 1911."""

SPOUSE_SURNAME_START = 1912
"""Spouse surname appears on FreeBMD marriage entries from Sep 1912."""

FREEBMD_BAKEWELL_CUTOFF = 1941
"""FreeBMD has essentially no Bakewell district coverage before 1941.
Matlock, Darley Dale, Youlgreave, Snitterton all fall within Bakewell.
Use Ancestry, FamilySearch, or GRO certificates instead."""

CENSUS_YEARS = [1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911, 1921]
"""Available census years. 1931 was destroyed in a fire."""

WW1_ELIGIBILITY = (1880, 1900)
"""Men born 1880-1900 were of military age during WW1 (1914-1918)."""

WW2_ELIGIBILITY = (1900, 1927)
"""Men born 1900-1927 were of military age during WW2 (1939-1945)."""

from project_config import config as _cfg

# Registration districts and covered parishes — loaded from config.yaml
DISTRICT_PARISHES = _cfg.region.district_parishes

# Districts known to be outside the research area
NON_LOCAL_DISTRICTS = _cfg.region.non_local_districts


def is_derbyshire_district(district: str) -> bool:
    """Check if a district is in Derbyshire."""
    clean = district.strip().replace(" district", "")
    return clean in DISTRICT_PARISHES


def is_non_local(district: str) -> str | None:
    """Returns the location name if district is outside the research area, else None."""
    clean = district.strip().replace(" district", "")
    return NON_LOCAL_DISTRICTS.get(clean)


def parishes_in_district(district: str) -> list[str]:
    """Return parishes covered by a registration district."""
    return DISTRICT_PARISHES.get(district, [])


def district_for_parish(parish: str) -> str | None:
    """Find which registration district covers a parish."""
    parish_lower = parish.lower()
    for district, parishes in DISTRICT_PARISHES.items():
        if any(p.lower() == parish_lower for p in parishes):
            return district
    return None


def source_available(birth_year: int | None, source: str) -> bool:
    """Check if a source is available for a person born in a given year."""
    if source == "freebmd" and birth_year and birth_year < CIVIL_REGISTRATION_START:
        return False
    if source == "census":
        return True  # census covers 1841-1921
    if source == "parish_registers":
        return True  # always available, most useful pre-1837
    if source == "cwgc" and birth_year:
        return WW1_ELIGIBILITY[0] <= birth_year <= WW2_ELIGIBILITY[1]
    if source == "probate":
        return True  # probate calendar covers 1858+
    return True


def military_eligible(birth_year: int, gender: str = "M") -> list[str]:
    """Return which wars a person was eligible for based on birth year."""
    if gender.upper() != "M":
        return []
    wars = []
    if WW1_ELIGIBILITY[0] <= birth_year <= WW1_ELIGIBILITY[1]:
        wars.append("WW1")
    if WW2_ELIGIBILITY[0] <= birth_year <= WW2_ELIGIBILITY[1]:
        wars.append("WW2")
    return wars


# ============================================================
# PATTERN RULES — genealogical patterns suggesting research
# ============================================================

def maiden_name_from_mother_in_law(household: list[dict],
                                    head_surname: str) -> str | None:
    """If mother-in-law has a different surname, that's the wife's maiden name.

    This is the five-step inference that took DeepSeek-R1 173 seconds
    and three lines of Python.
    """
    for member in household:
        rel = (member.get("relationship") or "").lower()
        if "mother" in rel and "law" in rel:
            mil_name = member.get("name", "")
            mil_parts = mil_name.split()
            if mil_parts:
                mil_surname = mil_parts[-1].upper()
                if mil_surname != head_surname.upper():
                    return mil_surname
    return None


def child_gap_suggests_death(children_birth_years: list[int],
                              threshold: int = 3) -> list[tuple[int, int]]:
    """Gaps of >threshold years between children suggest infant deaths.

    Returns list of (year_after, year_before) gap pairs.
    """
    if len(children_birth_years) < 2:
        return []
    sorted_years = sorted(children_birth_years)
    gaps = []
    for i in range(len(sorted_years) - 1):
        gap = sorted_years[i + 1] - sorted_years[i]
        if gap > threshold:
            gaps.append((sorted_years[i], sorted_years[i + 1]))
    return gaps


def absent_from_census_suggests(birth_year: int, last_seen_year: int,
                                 gender: str = "M") -> list[str]:
    """Person present in one census but absent from the next.

    Suggests: death, emigration, marriage (women), military service (men).
    """
    suggestions = ["death", "emigration"]
    if gender.upper() == "F":
        suggestions.append("marriage (changed surname)")
    if gender.upper() == "M":
        wars = military_eligible(birth_year)
        if wars:
            suggestions.append(f"military service ({', '.join(wars)})")
    return suggestions


def same_page_is_same_couple(vol_a: str, page_a: str,
                              vol_b: str, page_b: str) -> bool:
    """In FreeBMD marriage index, entries on the same page are the same couple."""
    return vol_a == vol_b and page_a == page_b


def pre_registration_birth(birth_year: int | None) -> bool:
    """Born before civil registration — needs parish registers."""
    return birth_year is not None and birth_year < CIVIL_REGISTRATION_START


def military_death_not_in_civil_register(death_location: str) -> bool:
    """Soldiers killed abroad don't appear in civilian GRO registers.

    CWGC records and regimental casualty lists are the primary source.
    """
    abroad_keywords = ["france", "belgium", "flanders", "gallipoli",
                       "tunisia", "italy", "egypt", "burma", "germany"]
    return any(k in death_location.lower() for k in abroad_keywords)


# ============================================================
# SOFT RULES — probabilistic scoring, used for ranking
# ============================================================

# Surname rarity affects match confidence
# Common surnames (Smith, Jones) need more corroboration
# Rare surnames (Cauldwell, Wheatman) are stronger matches
RARE_SURNAME_THRESHOLD = 1000
"""Surnames with fewer than ~1000 bearers nationally are considered rare.
Wheatman (rank 24,422) is extremely rare. Cauldwell (~380 bearers) is rare.
Ward, Smith, Jones are common."""


def name_similarity_score(name_a: str, name_b: str) -> float:
    """Score name similarity, handling common genealogical variations.

    Returns 0.0-1.0. Handles:
    - Caldwell/Cauldwell (AU/A swap)
    - Mary Ann/Mary/Ann (split names)
    - Jack/John (nickname equivalents)
    """
    a = name_a.upper().strip()
    b = name_b.upper().strip()

    if a == b:
        return 1.0

    # Spelling normalisation
    a_norm = a.replace("AU", "A").replace("OU", "O")
    b_norm = b.replace("AU", "A").replace("OU", "O")
    if a_norm == b_norm:
        return 0.95

    # One contains the other
    if a in b or b in a:
        return 0.8

    # Nickname equivalents
    nicknames = {
        "JACK": "JOHN", "JOHN": "JACK",
        "HARRY": "HENRY", "HENRY": "HARRY",
        "BILL": "WILLIAM", "WILLIAM": "BILL",
        "TED": "EDWARD", "EDWARD": "TED",
        "DICK": "RICHARD", "RICHARD": "DICK",
        "POLLY": "MARY", "MARY": "POLLY",
        "PEGGY": "MARGARET", "MARGARET": "PEGGY",
        "BETTY": "ELIZABETH", "ELIZABETH": "BETTY",
        "NELL": "ELLEN", "ELLEN": "NELL",
        "JOE": "JOSEPH", "JOSEPH": "JOE",
        "KATE": "CATHERINE", "CATHERINE": "KATE",
        "WILLIE": "WILLIAM",
        "NELLIE": "ELLEN",
        "LIZZIE": "ELIZABETH",
        "FLORRIE": "FLORENCE", "FLORENCE": "FLORRIE",
    }
    if nicknames.get(a) == b or nicknames.get(b) == a:
        return 0.85

    # Single character difference (typo/transcription)
    if len(a) == len(b):
        diffs = sum(1 for x, y in zip(a, b) if x != y)
        if diffs == 1:
            return 0.7

    return 0.0


def geographic_plausibility(district: str, expected_county: str = "") -> float:
    """Score how plausible a district is for a Derbyshire family.

    Returns 0.0-1.0.
    """
    if is_derbyshire_district(district):
        return 1.0

    location = is_non_derbyshire(district)
    if location:
        return 0.1  # Different county — weak match

    # Unknown district — neutral
    return 0.5


def convergence_score(matching_sources: int) -> float:
    """More independent sources confirming the same fact = higher confidence.

    1 source: 0.5 (possible)
    2 sources: 0.75 (probable)
    3+ sources: 0.9+ (confirmed)
    """
    if matching_sources <= 0:
        return 0.0
    if matching_sources == 1:
        return 0.5
    if matching_sources == 2:
        return 0.75
    return min(0.9 + (matching_sources - 3) * 0.03, 1.0)


def validate_enrichment_date(field: str, proposed_value: str,
                            current_birth: str = "", current_death: str = "") -> str | None:
    """No death date before birth date. No birth date after death date.
    No values without a 4-digit year.

    Returns None if valid, or an error string if impossible.
    """
    import re

    proposed_year = None
    m = re.search(r"\b(1[0-9]\d{2}|20[0-2]\d)\b", str(proposed_value))
    if m:
        proposed_year = int(m.group(1))
    if not proposed_year:
        return f"no valid year in '{proposed_value}'"

    birth_year = None
    m_b = re.search(r"\b(1[0-9]\d{2}|20[0-2]\d)\b", str(current_birth))
    if m_b:
        birth_year = int(m_b.group(1))

    death_year = None
    m_d = re.search(r"\b(1[0-9]\d{2}|20[0-2]\d)\b", str(current_death))
    if m_d:
        death_year = int(m_d.group(1))

    if field in ("DeathDate", "death_date") and birth_year:
        if proposed_year < birth_year:
            return f"death {proposed_year} before birth {birth_year}"

    if field in ("BirthDate", "birth_date") and death_year:
        if proposed_year > death_year:
            return f"birth {proposed_year} after death {death_year}"

    return None


def validate_enrichment_location(proposed_place: str, profile_birth_location: str = "",
                                 profile_birth_place: str = "") -> str | None:
    """Reject enrichment if the proposed record is from a different county
    than the profile's known location.

    Returns None if compatible, or an error string if wrong county.
    """
    if not proposed_place:
        return None

    # Build set of known counties from profile
    known = profile_birth_location or profile_birth_place or ""
    if not known:
        return None  # Can't validate without a known location

    known_lower = known.lower()

    ENGLISH_COUNTIES = [
        "derbyshire", "nottinghamshire", "staffordshire", "leicestershire",
        "yorkshire", "lancashire", "cheshire", "warwickshire", "lincolnshire",
        "kent", "surrey", "middlesex", "sussex", "essex", "suffolk", "norfolk",
        "cambridgeshire", "oxfordshire", "berkshire", "hampshire", "dorset",
        "somerset", "devon", "cornwall", "wiltshire", "gloucestershire",
        "worcestershire", "herefordshire", "shropshire", "rutland",
        "huntingdonshire", "bedfordshire", "hertfordshire", "buckinghamshire",
        "northamptonshire", "westmorland", "cumberland", "durham",
        "northumberland",
    ]

    profile_county = None
    for county in ENGLISH_COUNTIES:
        if county in known_lower:
            profile_county = county
            break

    if not profile_county:
        return None  # Profile county not recognised — can't validate

    proposed_lower = proposed_place.lower()

    # Check if proposed place contains the same county
    if profile_county in proposed_lower:
        return None  # Same county — compatible

    # Check if proposed place contains a DIFFERENT county
    for county in ENGLISH_COUNTIES:
        if county in proposed_lower and county != profile_county:
            return f"record from {county} but profile is from {profile_county}"

    # Proposed place doesn't mention any county — can't reject
    return None


def validate_enrichment_parents(record_parents: list[str],
                                twin_parents: list[str]) -> str | None:
    """Reject enrichment if christening names parents that don't match
    the parents already linked in the twin.

    Returns None if compatible, or an error string if parents mismatch.
    """
    if not record_parents or not twin_parents:
        return None  # Can't validate without both sets

    # Check if any record parent matches any twin parent (fuzzy)
    for rp in record_parents:
        rp_upper = rp.upper().strip()
        if not rp_upper:
            continue
        for tp in twin_parents:
            tp_upper = tp.upper().strip()
            # Check if surnames match
            rp_parts = rp_upper.split()
            tp_parts = tp_upper.split()
            if rp_parts and tp_parts:
                # Compare last names
                if rp_parts[-1] == tp_parts[-1]:
                    return None  # At least one parent surname matches
                # Compare first names (parent might be listed by first name only)
                if rp_parts[0] == tp_parts[0]:
                    return None

    record_str = ", ".join(record_parents)
    twin_str = ", ".join(twin_parents)
    return f"record parents [{record_str}] don't match twin parents [{twin_str}]"


def normalise_location(location: str) -> str:
    """Normalise a location string to WikiTree's expected format.

    WikiTree standard: "Town, County, England"
    Ensures English counties always end with ", England".
    """
    if not location:
        return location

    ENGLISH_COUNTIES = {
        "derbyshire", "nottinghamshire", "staffordshire", "leicestershire",
        "yorkshire", "lancashire", "cheshire", "warwickshire", "lincolnshire",
        "kent", "surrey", "middlesex", "sussex", "essex", "suffolk", "norfolk",
        "cambridgeshire", "oxfordshire", "berkshire", "hampshire", "dorset",
        "somerset", "devon", "cornwall", "wiltshire", "gloucestershire",
        "worcestershire", "herefordshire", "shropshire", "rutland",
        "huntingdonshire", "bedfordshire", "hertfordshire", "buckinghamshire",
        "northamptonshire", "westmorland", "cumberland", "durham",
        "northumberland",
    }

    parts = [p.strip() for p in location.split(",")]
    last = parts[-1].lower()

    # Already has country
    if last in ("england", "united kingdom", "wales", "scotland"):
        return ", ".join(parts)

    # Check if last part is an English county
    if last in ENGLISH_COUNTIES:
        parts.append("England")

    return ", ".join(parts)


def census_birthplace_reliability() -> str:
    """Census birthplaces are self-reported and vary between enumerations.

    The same person might give:
    - 1871: "Mugginton"
    - 1881: "Windley" (adjacent village)
    - 1901: "Windley"
    - 1911: "Windley Derby"

    All refer to the same area. Adjacent parishes are not contradictions.
    """
    return "Census birthplaces are self-reported and may vary between enumerations. Adjacent parishes are not contradictions."
