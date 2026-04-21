"""WikiTree profile matching — uses local twin, no API calls.

Loads profiles from the local digital twin (NetworkX graph) for
matching against research subjects. Zero API calls, zero rate limits.
"""

import re

_cache = {}


def load_corpus() -> dict:
    """Load existing profiles from the local twin.

    Returns {wt_id: person_dict} compatible with the pipeline's
    corpus matching format. Cached after first call.
    """
    if _cache.get("persons"):
        return _cache["persons"]

    from wikitree.twin import LocalTwin

    twin = LocalTwin()
    if not twin.load():
        print("  WARNING: No twin data — run: python -m wikitree.twin sync")
        return {}

    persons = {}
    for wt_id in twin._graph.nodes:
        node = twin.get(wt_id)
        if not node:
            continue

        first = node.get("FirstName", "")
        middle = node.get("MiddleName", "")
        lnab = node.get("LastNameAtBirth", "")
        full_name = f"{first} {middle} {lnab}".replace("  ", " ").strip()

        birth_year = _extract_year(node.get("BirthDate", ""))
        death_year = _extract_year(node.get("DeathDate", ""))

        parent_ids = []
        father = node.get("Father")
        mother = node.get("Mother")
        if father and father != 0:
            parent_ids.append(str(father))
        if mother and mother != 0:
            parent_ids.append(str(mother))

        persons[wt_id] = {
            "name": full_name,
            "birth_year": birth_year,
            "death_year": death_year,
            "birth_location": node.get("BirthLocation", ""),
            "death_location": node.get("DeathLocation", ""),
            "parent_ids": parent_ids,
            "spouses": [],
            "mentions": [],
        }

    _cache["persons"] = persons
    print(f"  [TWIN] Loaded {len(persons)} profiles from local twin")
    return persons


def find_in_corpus(name: str, birth_year: int | None = None,
                    corpus: dict | None = None) -> list[dict]:
    """Find matching persons by fuzzy name + birth year."""
    if corpus is None:
        corpus = load_corpus()

    name_parts = name.upper().split()
    surname = name_parts[-1] if name_parts else ""
    given = name_parts[0] if len(name_parts) > 1 else ""

    matches = []
    for pid, person in corpus.items():
        corpus_name = (person.get("name") or "").upper()
        corpus_parts = corpus_name.split()
        corpus_surname = corpus_parts[-1] if corpus_parts else ""
        corpus_given = corpus_parts[0] if len(corpus_parts) > 1 else ""
        corpus_birth = person.get("birth_year")

        name_score = 0.0
        if corpus_surname == surname:
            name_score += 0.5
        elif _similar(corpus_surname, surname):
            name_score += 0.3

        if corpus_given and given:
            if corpus_given == given:
                name_score += 0.3
            elif given in corpus_given or corpus_given in given:
                name_score += 0.2

        year_score = 0.0
        if birth_year and corpus_birth:
            diff = abs(birth_year - corpus_birth)
            if diff == 0:
                year_score = 0.2
            elif diff <= 2:
                year_score = 0.15
            elif diff <= 5:
                year_score = 0.05
        elif not birth_year or not corpus_birth:
            year_score = 0.05

        total = name_score + year_score
        if total >= 0.5:
            matches.append({
                "corpus_id": pid,
                "corpus_name": person.get("name"),
                "corpus_birth_year": corpus_birth,
                "corpus_death_year": person.get("death_year"),
                "corpus_spouses": person.get("spouses", []),
                "corpus_parent_ids": person.get("parent_ids", []),
                "corpus_mentions": 0,
                "match_score": round(total, 2),
                "person": person,
            })

    matches.sort(key=lambda m: m["match_score"], reverse=True)
    return matches


def get_existing_facts(corpus_person: dict) -> list[str]:
    """Extract known facts from a profile as readable strings."""
    facts = []
    p = corpus_person
    if p.get("birth_year"):
        loc = p.get("birth_location", "")
        facts.append(f"birth: ~{p['birth_year']} {loc}".strip())
    if p.get("death_year"):
        loc = p.get("death_location", "")
        facts.append(f"death: {p['death_year']} {loc}".strip())
    for parent_id in p.get("parent_ids", []):
        facts.append(f"parent: {parent_id}")
    return facts


def flag_discrepancies(agent_facts: list, corpus_match: dict) -> list[str]:
    """Compare agent findings against twin and flag differences."""
    discrepancies = []
    corpus = corpus_match["person"]

    corpus_birth = corpus.get("birth_year")
    for fact in agent_facts:
        if fact.get("type", "").startswith("birth") and corpus_birth:
            match = re.search(r"\b(1[6-9]\d{2})\b", fact.get("value", ""))
            if match:
                agent_birth = int(match.group(1))
                if abs(agent_birth - corpus_birth) > 2:
                    discrepancies.append(
                        f"BIRTH YEAR: WikiTree says {corpus_birth}, "
                        f"agent found {agent_birth}")

    corpus_death = corpus.get("death_year")
    for fact in agent_facts:
        if fact.get("type", "").startswith("death") and corpus_death:
            match = re.search(r"\b(1[6-9]\d{2})\b", fact.get("value", ""))
            if match:
                agent_death = int(match.group(1))
                if abs(agent_death - corpus_death) > 2:
                    discrepancies.append(
                        f"DEATH YEAR: WikiTree says {corpus_death}, "
                        f"agent found {agent_death}")

    return discrepancies


def validate_corpus_relationships(person_id: str, corpus: dict) -> list[str]:
    """Flag suspicious relationships."""
    warnings = []
    person = corpus.get(person_id)
    if not person:
        return warnings

    person_birth = person.get("birth_year")
    if not person_birth:
        return warnings

    for parent_id in person.get("parent_ids", []):
        parent = corpus.get(parent_id)
        if not parent:
            continue
        parent_birth = parent.get("birth_year")
        if not parent_birth:
            continue
        age_at_child_birth = person_birth - parent_birth
        if age_at_child_birth < 14:
            warnings.append(
                f"SUSPICIOUS: {parent.get('name', parent_id)} (b.{parent_birth}) "
                f"listed as parent of {person.get('name', person_id)} (b.{person_birth}) "
                f"— age gap only {age_at_child_birth} years.")

    return warnings


def _extract_year(date_str: str) -> int | None:
    if not date_str:
        return None
    match = re.match(r"(\d{4})", date_str)
    if match:
        year = int(match.group(1))
        return year if year > 0 else None
    return None


def _similar(a: str, b: str) -> bool:
    if not a or not b:
        return False
    if a in b or b in a:
        return True
    a_norm = a.replace("AU", "A").replace("OU", "O")
    b_norm = b.replace("AU", "A").replace("OU", "O")
    if a_norm == b_norm:
        return True
    if len(a) == len(b):
        diffs = sum(1 for x, y in zip(a, b) if x != y)
        if diffs <= 1:
            return True
    return False
