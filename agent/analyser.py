"""Deterministic genealogy analyser — replaces DeepSeek-R1 strategy.

Applies rules from rules.py to current research state and generates
specific, actionable search suggestions. Instant, reliable, no LLM needed.
"""

from agent.rules import (
    CIVIL_REGISTRATION_START,
    CENSUS_YEARS,
    WW1_ELIGIBILITY,
    maiden_name_from_mother_in_law,
    child_gap_suggests_death,
    military_eligible,
    absent_from_census_suggests,
)


class GenealogyAnalyser:
    """Deterministic pattern-based research strategy generator."""

    def analyse(self, state: dict) -> dict:
        """Analyse research state and suggest next steps.

        Returns same format as strategist.py for drop-in replacement:
        {
            "insights": [...],
            "searches": [...],
            "questions": [...]
        }
        """
        insights = []
        searches = []
        questions = []

        person = state["person"]
        facts = state.get("confirmed_facts", [])
        household = state.get("household_members", [])
        searched = {s["source"] for s in state.get("searched", [])}
        birth_year = person.get("birth_year")
        death_year = person.get("death_year")
        name = person.get("name", "")
        parts = name.split()
        surname = parts[-1] if parts else ""
        given = parts[0] if len(parts) > 1 else ""

        # Run all pattern checks
        r = self._check_maiden_names(state, household, surname)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_missing_from_census(state, household, searched)
        insights.extend(r["insights"])
        searches.extend(r["searches"])
        questions.extend(r["questions"])

        r = self._check_child_gaps(state, household)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_military_eligibility(state, household, searched)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_marriage_alternatives(state, searched, surname, given, birth_year, death_year)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_death_search(state, searched, surname, given, birth_year, death_year)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_birth_search(state, searched, surname, given, birth_year)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_census_gaps(state, searched, surname, given, birth_year, death_year)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_burial(state, searched, surname, given)
        searches.extend(r["searches"])

        r = self._check_probate(searched, surname, given, birth_year, death_year)
        searches.extend(r["searches"])

        r = self._check_parish_registers(searched, surname, given, birth_year)
        insights.extend(r["insights"])
        searches.extend(r["searches"])

        r = self._check_wirksworth(searched, surname)
        searches.extend(r["searches"])

        # Filter out searches already done
        searches = [s for s in searches if s.get("search_key", "") not in searched]

        return {
            "insights": insights,
            "searches": searches,
            "questions": questions,
        }

    def _check_maiden_names(self, state, household, family_surname):
        """Mother-in-law with different surname → maiden name clue."""
        insights = []
        searches = []

        maiden_name = maiden_name_from_mother_in_law(household, family_surname)
        if not maiden_name:
            return {"insights": [], "searches": []}

        # Find wife and head for search parameters
        wife = next((m for m in household
                     if (m.get("relationship") or "").lower() in ("wife", "w")), None)
        head = next((m for m in household
                     if (m.get("relationship") or "").lower() in ("head", "h")), None)

        wife_name = wife.get("name", "the wife") if wife else "the wife"
        census_year = next((m.get("census_year") for m in household if m.get("census_year")), "?")

        insights.append(
            f"Mother-in-law has surname {maiden_name}. "
            f"{wife_name}'s maiden name is likely {maiden_name}. "
            f"Search for marriage under {maiden_name}."
        )

        if head:
            head_parts = head.get("name", "").split()
            head_surname = head_parts[-1] if head_parts else ""
            head_given = head_parts[0] if len(head_parts) > 1 else ""
            wife_given = wife.get("name", "").split()[0] if wife else ""

            end_year = int(census_year) if str(census_year).isdigit() else 1900

            searches.append({
                "description": f"Search marriage: {wife_given} {maiden_name} marrying {head_surname}",
                "source": "freebmd",
                "parameters": {
                    "surname": maiden_name,
                    "given": wife_given,
                    "event": "marriages",
                    "year_start": (wife.get("birth_year_approx") or 1850) + 16,
                    "year_end": end_year,
                },
                "reasoning": f"Mother-in-law surname {maiden_name} reveals maiden name",
                "search_key": f"freebmd_{maiden_name}_{wife_given}_marriages",
            })

            searches.append({
                "description": f"Search marriage: {head_given} {head_surname} (to confirm)",
                "source": "freebmd",
                "parameters": {
                    "surname": head_surname,
                    "given": head_given,
                    "event": "marriages",
                    "year_start": (head.get("birth_year_approx") or 1850) + 16,
                    "year_end": end_year,
                },
                "reasoning": f"Confirm marriage — should match same quarter/district as {maiden_name} search",
                "search_key": f"freebmd_{head_surname}_{head_given}_marriages_confirm",
            })

        return {"insights": insights, "searches": searches}

    def _check_missing_from_census(self, state, household, searched):
        """Children present in one census but missing from later ones."""
        insights = []
        searches = []
        questions = []

        census_year = None
        for m in household:
            if m.get("census_year"):
                census_year = m["census_year"]
                break

        if not census_year:
            return {"insights": [], "searches": [], "questions": []}

        for member in household:
            relationship = (member.get("relationship") or "").lower()
            if relationship not in ("son", "daughter", "dau", "s", "d"):
                continue

            age = member.get("age")
            name = member.get("name", "?")
            birth_approx = member.get("birth_year_approx")

            if not birth_approx:
                continue

            # Check later census years
            for later_year in CENSUS_YEARS:
                if later_year <= int(census_year):
                    continue
                if later_year > (birth_approx + 90):
                    continue

                search_key = f"freecen_{name.replace(' ', '_')}_{later_year}"
                if search_key in searched:
                    continue

                age_at_census = later_year - birth_approx

                if age_at_census >= 16:
                    questions.append(
                        f"{name} (age {age} in {census_year}) would be {age_at_census} "
                        f"in {later_year}. May have married, moved, or enlisted."
                    )

        return {"insights": insights, "searches": searches, "questions": questions}

    def _check_child_gaps(self, state, household):
        """Gaps between children's birth years → possible infant deaths."""
        insights = []
        searches = []

        children = []
        family_surname = ""
        for m in household:
            rel = (m.get("relationship") or "").lower()
            if rel in ("son", "daughter", "dau", "s", "d"):
                if m.get("birth_year_approx"):
                    children.append(m)
            if rel in ("head", "h") and m.get("name"):
                parts = m["name"].split()
                family_surname = parts[-1] if parts else ""

        birth_years = [c["birth_year_approx"] for c in children]
        gaps = child_gap_suggests_death(birth_years, threshold=3)

        for gap_start, gap_end in gaps:
            gap = gap_end - gap_start
            # Find the children's names for reporting
            older = next((c["name"] for c in children if c["birth_year_approx"] == gap_start), "?")
            younger = next((c["name"] for c in children if c["birth_year_approx"] == gap_end), "?")

            insights.append(
                f"{gap}-year gap between {older} and {younger} "
                f"({gap_start + 1}-{gap_end - 1}). Possible infant deaths."
            )

            if family_surname and gap_start + 1 >= CIVIL_REGISTRATION_START:
                searches.append({
                    "description": f"Search for {family_surname} infant deaths {gap_start + 1}-{gap_end - 1}",
                    "source": "freebmd",
                    "parameters": {
                        "surname": family_surname,
                        "event": "deaths",
                        "year_start": gap_start + 1,
                        "year_end": gap_end - 1,
                    },
                    "reasoning": f"{gap}-year gap between siblings suggests possible infant deaths",
                    "search_key": f"freebmd_{family_surname}_deaths_{gap_start + 1}_{gap_end - 1}",
                })

        return {"insights": insights, "searches": searches}

    def _check_military_eligibility(self, state, household, searched):
        """Males of military age → check CWGC."""
        insights = []
        searches = []

        female_rels = ("daughter", "dau", "wife", "mother", "sister",
                       "ma-law", "m-law", "mo-law", "d")

        for member in household:
            rel = (member.get("relationship") or "").lower()
            name = member.get("name", "?")
            birth = member.get("birth_year_approx")

            if not birth or rel in female_rels:
                continue

            wars = military_eligible(birth, "M")
            if not wars:
                continue

            parts = name.split()
            surname = parts[-1] if parts else ""
            given = parts[0] if len(parts) > 1 else ""

            search_key = f"cwgc_{surname}_{given}"
            if search_key in searched:
                continue

            war_str = " and ".join(wars)
            insights.append(
                f"{name} (born ~{birth}) was military age during {war_str}. "
                f"Check CWGC for casualty records."
            )

            searches.append({
                "description": f"Search CWGC for {name} ({war_str} eligible)",
                "source": "cwgc",
                "parameters": {"surname": surname, "given": given},
                "reasoning": f"Born ~{birth}, military eligible for {war_str}",
                "search_key": search_key,
            })

        return {"insights": insights, "searches": searches}

    def _check_marriage_alternatives(self, state, searched, surname, given,
                                      birth_year, death_year):
        """No marriage found under current name → try alternatives."""
        insights = []
        searches = []

        # Check if marriage was already searched and found nothing
        marriage_searched = any("marriage" in s.lower() for s in searched)
        marriage_found = any(f.get("type") == "marriage"
                             for f in state.get("confirmed_facts", []))

        if not marriage_searched or marriage_found:
            return {"insights": [], "searches": []}

        # Check family context for maiden name
        family = state["person"].get("family_context")
        if family:
            notes = family.get("notes", "")
            if "maiden" in notes.lower():
                # Already handled by maiden name check
                return {"insights": [], "searches": []}

        if birth_year and not marriage_found:
            insights.append(
                f"No marriage record found for {given} {surname}. "
                f"Consider: married in different parish, non-conformist church, "
                f"or name spelled differently."
            )

        return {"insights": insights, "searches": searches}

    def _check_death_search(self, state, searched, surname, given,
                             birth_year, death_year):
        """Suggest death record search if not done."""
        insights = []
        searches = []

        if "death_registration" in searched:
            return {"insights": [], "searches": []}
        if death_year:
            return {"insights": [], "searches": []}
        if not birth_year:
            return {"insights": [], "searches": []}

        search_key = f"freebmd_{surname}_{given}_deaths"
        if search_key in searched:
            return {"insights": [], "searches": []}

        searches.append({
            "description": f"Search for {given} {surname} death record",
            "source": "freebmd",
            "parameters": {
                "surname": surname,
                "given": given,
                "event": "deaths",
                "year_start": birth_year + 15,
                "year_end": birth_year + 95,
            },
            "reasoning": "No death record found yet",
            "search_key": search_key,
        })

        return {"insights": insights, "searches": searches}

    def _check_birth_search(self, state, searched, surname, given, birth_year):
        """Suggest birth record search if not done."""
        insights = []
        searches = []

        if "birth_registration" in searched:
            return {"insights": [], "searches": []}
        if not birth_year or birth_year < CIVIL_REGISTRATION_START:
            return {"insights": [], "searches": []}

        search_key = f"freebmd_{surname}_{given}_births"
        if search_key in searched:
            return {"insights": [], "searches": []}

        searches.append({
            "description": f"Search for {given} {surname} birth record",
            "source": "freebmd",
            "parameters": {
                "surname": surname,
                "given": given,
                "event": "births",
                "year_start": birth_year - 2,
                "year_end": birth_year + 2,
            },
            "reasoning": "No birth record confirmed yet",
            "search_key": search_key,
        })

        return {"insights": insights, "searches": searches}

    def _check_census_gaps(self, state, searched, surname, given,
                            birth_year, death_year):
        """Suggest census searches for years not yet covered."""
        insights = []
        searches = []

        if not birth_year:
            return {"insights": [], "searches": []}

        for year in CENSUS_YEARS:
            if year < birth_year or year > (death_year or birth_year + 90):
                continue

            search_key = f"census_{year}"
            if search_key in searched:
                continue

            search_key_alt = f"freecen_{surname}_{given}_{year}"
            if search_key_alt in searched:
                continue

            searches.append({
                "description": f"Search {year} census for {given} {surname}",
                "source": "freecen",
                "parameters": {
                    "surname": surname,
                    "given": given,
                    "year": year,
                },
                "reasoning": f"Census {year} not yet searched (person would be age {year - birth_year})",
                "search_key": search_key,
            })

        return {"insights": insights, "searches": searches}

    def _check_burial(self, state, searched, surname, given):
        """Suggest Find a Grave if not searched."""
        searches = []

        if "burial_memorial" in searched:
            return {"searches": []}

        search_key = f"findagrave_{surname}_{given}"
        if search_key in searched:
            return {"searches": []}

        searches.append({
            "description": f"Search Find a Grave for {given} {surname}",
            "source": "findagrave",
            "parameters": {"surname": surname, "given": given},
            "reasoning": "Memorial/burial not yet searched",
            "search_key": search_key,
        })

        return {"searches": searches}

    def _check_probate(self, searched, surname, given, birth_year, death_year):
        """Suggest probate search if death found but wills not checked."""
        searches = []

        if "probate" in searched:
            return {"searches": []}

        # Only suggest if we have some date range to search
        if not birth_year and not death_year:
            return {"searches": []}

        search_key = f"probate_{surname}_{given}"
        if search_key in searched:
            return {"searches": []}

        year_from = death_year - 1 if death_year else birth_year + 40
        year_to = death_year + 5 if death_year else birth_year + 95

        searches.append({
            "description": f"Search Probate Calendar for {given} {surname} wills",
            "source": "probate",
            "parameters": {"surname": surname, "given": given,
                           "year_from": year_from, "year_to": year_to},
            "reasoning": "Probate records may name family members and addresses",
            "search_key": search_key,
        })

        return {"searches": searches}

    def _check_parish_registers(self, searched, surname, given, birth_year):
        """Suggest FreeREG if birth pre-dates civil registration or FreeBMD has gaps."""
        insights = []
        searches = []

        if "parish_registers" in searched:
            return {"insights": [], "searches": []}

        search_key = f"freereg_{surname}_{given}"
        if search_key in searched:
            return {"insights": [], "searches": []}

        from agent.config import CIVIL_REGISTRATION_START
        if birth_year and birth_year < CIVIL_REGISTRATION_START:
            insights.append(
                f"{given} {surname} born ~{birth_year}, before civil registration "
                f"began in {CIVIL_REGISTRATION_START}. Parish registers are the "
                f"primary source for this period."
            )
            searches.append({
                "description": f"Search FreeREG parish registers for {given} {surname}",
                "source": "freereg",
                "parameters": {"surname": surname, "given": given,
                               "year_start": birth_year - 10,
                               "year_end": min(birth_year + 50, 1900)},
                "reasoning": "Pre-1837 birth — parish registers needed",
                "search_key": search_key,
            })

        return {"insights": insights, "searches": searches}

    def _check_wirksworth(self, searched, surname):
        """Suggest wirksworth.org.uk search for Derbyshire families."""
        searches = []

        if "wirksworth" in searched:
            return {"searches": []}

        search_key = f"wirksworth_{surname}"
        if search_key in searched:
            return {"searches": []}

        searches.append({
            "description": f"Search wirksworth.org.uk parish records for {surname}",
            "source": "wirksworth",
            "parameters": {"surname": surname},
            "reasoning": "Local Derbyshire parish records may have entries not in FreeREG",
            "search_key": search_key,
        })

        return {"searches": searches}
