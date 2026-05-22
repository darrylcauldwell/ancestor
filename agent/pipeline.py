"""Pipeline — closed-loop architecture.

Phase 1: Python searches all standard sources and scores results
Phase 2: DeepSeek-R1 reads findings, suggests strategy
Phase 3: Python executes R1's suggestions, scores new results
Phase 4: R1 reviews updated state, suggests more (or stops)
Repeat until R1 says "done" or MAX_ITERATIONS reached.

The loop is: Search → Score → Strategise → Execute Strategy → Score → Strategise → ...
"""

import re

from agent.discover import execute_searches
from agent.scorer import score_all_results, summarise_scored_results
from agent.analyser import GenealogyAnalyser
from agent.record import save_state
from agent.validate import update_known_dates
from agent.corpus import load_corpus, find_in_corpus, get_existing_facts, flag_discrepancies, validate_corpus_relationships
from agent.config import MATCH_ACCEPT, MATCH_REJECT
from project_config import config as _cfg


MAX_ITERATIONS = 4


def research_person(person: dict) -> dict:
    """Research one person with closed-loop strategy execution.

    Returns the final state dict.
    """
    name = person.get("name", "Unknown")
    print(f"\n{'=' * 60}")
    print(f"RESEARCHING: {name}")
    print(f"{'=' * 60}")

    state = _initial_state(person)

    # --- CORPUS CHECK: what do we already know? ---
    corpus = load_corpus()
    corpus_matches = find_in_corpus(name, person.get("birth_year"), corpus)

    if corpus_matches:
        best = corpus_matches[0]
        print(f"\n[CORPUS] Found in existing research: {best['corpus_name']} "
              f"(b.{best['corpus_birth_year']}, "
              f"match score: {best['match_score']})")

        existing = get_existing_facts(best["person"])
        if existing:
            print(f"  Already known ({len(existing)} facts):")
            for fact in existing[:10]:
                print(f"    - {fact}")
            if len(existing) > 10:
                print(f"    ... and {len(existing) - 10} more")

        # Store corpus match for later comparison
        state["corpus_match"] = best

        # Use corpus birth/death years if we don't have them
        if not state["person"]["birth_year"] and best.get("corpus_birth_year"):
            state["person"]["birth_year"] = best["corpus_birth_year"]
            print(f"  Using corpus birth year: {best['corpus_birth_year']}")
        if not state["person"]["death_year"] and best.get("corpus_death_year"):
            state["person"]["death_year"] = best["corpus_death_year"]
            print(f"  Using corpus death year: {best['corpus_death_year']}")
    else:
        print(f"\n[CORPUS] Not found in existing research — new person")

    # --- CHECK: is this a living/recent person we can't search for? ---
    if _is_unsearchable(state["person"]):
        print(f"\n[SKIP SEARCH] {name} is too recent for historical sources")
        print(f"  Using provided facts only. Branching to ancestors.")

        # Add user-provided family members
        provided_family = person.get("provided_family", [])
        for member in provided_family:
            state["household_members"].append(member)
            print(f"    Known: {member['name']} ({member['relationship']})")

        # Also pull parents from corpus if available
        corpus_match = state.get("corpus_match")
        if corpus_match:
            corpus_id = corpus_match.get("corpus_id", "")
            # Validate relationships before using them
            relationship_warnings = validate_corpus_relationships(corpus_id, corpus)
            if relationship_warnings:
                print(f"    WARNING — corpus relationship issues:")
                for w in relationship_warnings:
                    print(f"      ! {w}")
                state.setdefault("warnings", []).extend(relationship_warnings)

            parent_ids = corpus_match.get("corpus_parent_ids") or \
                         corpus_match.get("person", {}).get("parent_ids", [])

            # Filter out suspicious parents (age gap < 14)
            if parent_ids and corpus:
                person_birth = state["person"].get("birth_year")
                valid_parents = []
                for pid in parent_ids:
                    parent = corpus.get(pid)
                    if parent and person_birth and parent.get("birth_year"):
                        gap = person_birth - parent["birth_year"]
                        if gap < 14:
                            print(f"    SKIPPING {parent.get('name', pid)} "
                                  f"— only {gap} years older (likely sibling)")
                            continue
                    valid_parents.append(pid)
                parent_ids = valid_parents

            if parent_ids:
                for parent_id in parent_ids:
                    # Look up parent in corpus
                    parent = corpus.get(parent_id) if corpus else None
                    if parent:
                        parent_name = parent.get("name", parent_id)
                        parent_birth = parent.get("birth_year")
                        # Check if already in household members
                        existing_names = {m["name"].upper() for m in state["household_members"]}
                        if parent_name.upper() not in existing_names:
                            state["household_members"].append({
                                "name": parent_name,
                                "relationship": "Parent",
                                "birth_year_approx": parent_birth,
                                "age": None,
                                "occupation": "",
                                "birth_place": "",
                                "census_year": None,
                                "address": "",
                                "parish": "",
                            })
                            print(f"    From corpus: {parent_name} (Parent, b.{parent_birth})")

            # Also pull spouses from corpus
            spouses = corpus_match.get("person", {}).get("spouses", [])
            for spouse in spouses:
                spouse_name = spouse.get("name", "")
                if spouse_name:
                    existing_names = {m["name"].upper() for m in state["household_members"]}
                    if spouse_name.upper() not in existing_names:
                        state["household_members"].append({
                            "name": spouse_name,
                            "relationship": "Spouse",
                            "birth_year_approx": None,
                            "age": None,
                            "occupation": "",
                            "birth_place": "",
                            "census_year": None,
                            "address": "",
                            "parish": "",
                        })
                        print(f"    From corpus: {spouse_name} (Spouse)")

        state["confirmed_facts"].append({
            "type": "person",
            "value": f"{name}, born {state['person'].get('birth_year', '?')}",
            "sources": ["user-provided"],
            "confidence": "high",
            "score": 1.0,
        })

        # Emit eval-harness verdicts on the unsearchable path too
        _emit_parent_link_verdict(state, corpus)
        _emit_identity_verdict(state)

        save_state(state)
        return state

    # --- INITIAL SEARCH: standard sources based on what we know ---
    print(f"\n[ITERATION 1: INITIAL SEARCH]")
    search_plan = _plan_searches(state)
    _execute_and_score(search_plan, state)

    # --- POST-MARRIAGE EXPANSION: women's deaths/probate ---
    # When a marriage record names a spouse surname (FreeBMD post-1912),
    # the subject may have died under that surname. Without this, we
    # systematically miss women's post-marriage deaths — Mabel Cauldwell
    # (m. Brewell 1920, d. Brewell 1928) is the canonical case.
    _expand_post_marriage_searches(state)

    # --- STRATEGY LOOP: R1 suggests, Python executes, repeat ---
    for iteration in range(2, MAX_ITERATIONS + 2):
        # Save state after each iteration (crash recovery)
        save_state(state)

        # Deterministic analysis — no LLM needed
        print(f"\n[ITERATION {iteration}: ANALYSE]")
        analyser = GenealogyAnalyser()
        strategy = analyser.analyse(state)

        if not strategy:
            print(f"  No analysis results. Stopping.")
            break

        # Display insights
        insights = strategy.get("insights", [])
        if insights:
            print(f"\n  INSIGHTS ({len(insights)}):")
            for i, insight in enumerate(insights):
                print(f"    {i+1}. {insight}")

        # Display questions
        questions = strategy.get("questions", [])
        if questions:
            print(f"\n  QUESTIONS FOR YOU:")
            for q in questions:
                print(f"    ? {q}")

        # Get suggested searches
        searches = strategy.get("searches", [])
        state["strategy"] = strategy

        if not searches:
            print(f"\n  No further searches suggested. Research complete.")
            break

        # Translate R1's suggestions into executable search plans
        executable = _translate_suggestions(searches, state)

        if not executable:
            print(f"\n  No new executable searches (all already done). Research complete.")
            break

        print(f"\n  EXECUTING {len(executable)} suggested searches:")
        for s in executable:
            print(f"    - {s['description']}")

        # Execute the suggested searches and score results
        _execute_and_score(executable, state, from_strategy=True)

    # Check for discrepancies with corpus
    corpus_match = state.get("corpus_match")
    if corpus_match and state["confirmed_facts"]:
        discrepancies = flag_discrepancies(state["confirmed_facts"], corpus_match)
        if discrepancies:
            print(f"\n[DISCREPANCIES] Agent findings differ from corpus:")
            for d in discrepancies:
                print(f"    ! {d}")
            state["discrepancies"] = discrepancies
        else:
            print(f"\n[CORPUS] Agent findings consistent with existing research")

    # Create leads from candidates
    lead_candidates = state.get("lead_candidates", [])
    if lead_candidates:
        try:
            from agent.leads import LeadStore, create_leads_from_candidates
            lead_store = LeadStore()
            lead_store.load()
            new_leads = create_leads_from_candidates(state, lead_store)
            lead_store.save()
            if new_leads:
                print(f"\n  New leads opened: {new_leads}")
        except Exception as e:
            print(f"\n  Lead creation skipped: {e}")

    # --- VERDICTS for §5.8 eval harness per-kind metric ---
    # Emit explicit verdicts for kinds the harness measures that aren't
    # otherwise covered by `confirmed_facts[].type`. Conservative: prefer
    # "inconclusive" to overclaiming "supported".
    _emit_parent_link_verdict(state, corpus)
    _emit_identity_verdict(state)

    # Final save
    save_state(state)

    # Summary
    print(f"\n{'=' * 60}")
    print(f"RESEARCH COMPLETE: {name}")
    print(f"{'=' * 60}")
    print(f"  Hard facts: {len(state['confirmed_facts'])}")
    print(f"  Leads: {len(state.get('lead_candidates', []))}")
    print(f"  Rejected: {len(state['rejected_records'])}")
    print(f"  Household members: {len(state.get('household_members', []))}")

    # Research complete — session harness handles integration + write-back

    return state


def _execute_and_score(search_plan, state, from_strategy=False):
    """Execute searches and score results. Used for both initial and strategy searches."""

    if from_strategy:
        # Strategy searches come as dicts with descriptions
        raw_results = _execute_strategy_searches(search_plan, state)
    else:
        # Initial searches come as string list
        print(f"  Planned: {search_plan}")
        raw_results = execute_searches(search_plan, state)

    if not raw_results:
        print(f"  No results returned.")
        return

    # Score
    print(f"\n  [SCORE] Scoring results...")
    scored = score_all_results(raw_results, state["person"])

    # Apply scores
    _apply_scores(scored, state)

    # Extract household members
    _extract_household_members(raw_results, state)

    # Update dates from new facts
    update_known_dates(state)

    # Print summary
    summary = summarise_scored_results(scored)
    print(summary)

    print(f"\n  Confirmed: {len(state['confirmed_facts'])} facts total")
    print(f"  Rejected: {len(state['rejected_records'])} records total")
    print(f"  Uncertain: {len(state.get('uncertain_records', []))} need review")


def _execute_strategy_searches(suggestions: list, state: dict) -> dict:
    """Execute searches suggested by R1's strategy.

    R1 provides suggestions like:
    {
        "description": "Search for Elizabeth Barker marriages",
        "source": "freebmd",
        "parameters": {"surname": "Barker", "given": "Elizabeth", ...}
    }

    We translate these into actual tool calls.
    """
    import sys, os
    sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

    results = {}

    for suggestion in suggestions:
        source = suggestion.get("source", "").lower()
        params = suggestion.get("parameters", {})
        desc = suggestion.get("description", "unknown search")
        search_key = suggestion.get("search_key", desc[:40])

        # Skip if already searched
        already = {s["source"] for s in state.get("searched", [])}
        if search_key in already:
            print(f"    Skipping (already done): {search_key}")
            continue

        print(f"    Searching: {desc}...")

        try:
            if source == "freebmd":
                result = _run_freebmd(params)
            elif source == "freecen":
                result = _run_freecen(params)
            elif source == "cwgc":
                result = _run_cwgc(params)
            elif source == "findagrave":
                result = _run_findagrave(params)
            elif source == "probate":
                result = _run_probate(params)
            elif source in ("freereg", "parish_registers"):
                result = _run_freereg(params)
            elif source == "wirksworth":
                result = _run_wirksworth(params)
            elif source == "familysearch":
                result = _run_familysearch(params)
            else:
                print(f"    Unknown source: {source}")
                continue

            results[search_key] = result
            has_results = isinstance(result, list) and len(result) > 0
            state.setdefault("searched", []).append({
                "source": search_key,
                "status": "found" if has_results else "empty",
            })

        except Exception as e:
            print(f"    ERROR: {e}")
            results[search_key] = f"error: {e}"
            state.setdefault("searched", []).append({
                "source": search_key,
                "status": "error",
            })

    return results


def _run_freebmd(params: dict):
    """Execute a FreeBMD search from R1's parameters."""
    from sources import freebmd

    surname = params.get("surname", "")
    given = params.get("given", "")
    event = params.get("event", "All")
    year_start = params.get("year_start")
    year_end = params.get("year_end")
    district = params.get("district")
    spouse_surname = params.get("spouse_surname")

    # Map event types
    event_map = {
        "births": "Births", "birth": "Births",
        "deaths": "Deaths", "death": "Deaths",
        "marriages": "Marriages", "marriage": "Marriages",
    }
    record_type = event_map.get(event.lower(), "All") if event else "All"

    kwargs = {"given": given} if given else {}
    if year_start:
        kwargs["start"] = int(year_start)
    if year_end:
        kwargs["end"] = int(year_end)
    if spouse_surname:
        kwargs["s_surname"] = spouse_surname

    # Use district if provided (R1 should always suggest one for Derbyshire searches)
    if district:
        # FreeBMD uses district IDs — check if we have a mapping
        district_map = getattr(freebmd, '__dict__', {})
        district_upper = district.upper().replace(" ", "")
        district_id = None
        for name, val in vars(freebmd).items():
            if isinstance(val, int) and name.upper() == district_upper:
                district_id = val
                break
        if district_id:
            kwargs["district"] = district_id

    r = freebmd.search(record_type, surname, **kwargs)
    return r if isinstance(r, list) else []


def _run_freecen(params: dict):
    """Execute a FreeCen search from R1's parameters."""
    from sources import freecen
    from agent.config import DEFAULT_COUNTY

    surname = params.get("surname", "")
    given = params.get("given", "")
    year = params.get("year")
    county = params.get("county", DEFAULT_COUNTY)

    kwargs = {}
    if given:
        kwargs["first_name"] = given
    if year:
        kwargs["year"] = int(year)
    kwargs["county"] = county

    r = freecen.search(surname, **kwargs)
    return r if isinstance(r, list) else []


def _run_cwgc(params: dict):
    """Execute a CWGC search from R1's parameters."""
    from sources import cwgc

    surname = params.get("surname", "")
    given = params.get("given", "")

    r = cwgc.search(surname, first_name=given)
    return r if isinstance(r, list) else []


def _run_findagrave(params: dict):
    """Execute a Find a Grave search from R1's parameters."""
    from sources import findagrave

    surname = params.get("surname", "")
    given = params.get("given", "")

    r = findagrave.search(surname, first_name=given,
                           location=_cfg.region.default_location or "England")
    return r if isinstance(r, list) else []


def _run_probate(params: dict):
    """Execute a Probate Calendar search."""
    from sources import probate

    surname = params.get("surname", "")
    given = params.get("given", "")
    year_from = params.get("year_from")
    year_to = params.get("year_to")

    kwargs = {}
    if given:
        kwargs["first_name"] = given
    if year_from:
        kwargs["year_from"] = int(year_from)
    if year_to:
        kwargs["year_to"] = int(year_to)

    r = probate.search(surname, **kwargs)
    return r if isinstance(r, list) else []


def _run_familysearch(params: dict):
    """Execute a FamilySearch search."""
    try:
        from sources.familysearch import FamilySearch
        fs = FamilySearch()

        surname = params.get("surname", "")
        given = params.get("given", "")
        place = params.get("place", "")
        year_from = params.get("year_from") or params.get("year_start")
        year_to = params.get("year_to") or params.get("year_end")

        results, _ = fs.search_births(
            surname=surname, given=given, place=place,
            year_from=int(year_from) if year_from else None,
            year_to=int(year_to) if year_to else None,
            count=5)
        return results
    except Exception as e:
        print(f"      FamilySearch: {e}")
        return []


def _run_freereg(params: dict):
    """Execute a FreeREG parish register search."""
    from sources import freereg_search

    surname = params.get("surname", "")
    given = params.get("given", "")
    record_type = params.get("record_type", "all three types")
    start_year = params.get("year_start", 1700)
    end_year = params.get("year_end", 1900)
    county = params.get("county", "DBY")

    r = freereg_search.do_search(
        surname, given, record_type, int(start_year), int(end_year),
        chapman_codes=[county])
    return r if isinstance(r, list) else []


def _run_wirksworth(params: dict):
    """Execute a wirksworth.org.uk parish search."""
    from sources import wirksworth

    surname = params.get("surname", "")
    try:
        r = wirksworth.search_parish(surname)
        return r if isinstance(r, list) else []
    except Exception:
        return []


def _translate_suggestions(searches: list, state: dict) -> list:
    """Translate R1's suggestions into executable format.

    Filters out searches already done, adds search_key for tracking.
    """
    already = {s["source"] for s in state.get("searched", [])}
    executable = []

    for s in searches:
        desc = s.get("description", "")
        source = s.get("source", "")
        params = s.get("parameters", {})

        # Generate a unique key for dedup
        key_parts = [source, params.get("surname", ""), params.get("given", ""),
                     params.get("event", ""), str(params.get("year_start", ""))]
        search_key = "_".join(p for p in key_parts if p)

        if search_key in already:
            continue

        executable.append({
            "description": desc,
            "source": source,
            "parameters": params,
            "reasoning": s.get("reasoning", ""),
            "search_key": search_key,
        })

    return executable


def _is_unsearchable(person: dict) -> bool:
    """Check if a person is too recent for historical sources.

    FreeBMD births: closed period is ~100 years
    Census: latest is 1921 (released 2022), 1931 was destroyed
    CWGC: covers WW1+WW2 only
    Find a Grave: might have recent, but not reliable
    """
    birth_year = person.get("birth_year")
    if not birth_year:
        return False  # Unknown date — try searching anyway

    # Anyone born after 1930 won't be in FreeBMD births (100-year rule)
    # and won't be in any released census
    # Living people definitely can't be searched
    return birth_year > 1930


_MARRIAGE_SPOUSE_SURNAME_RE = re.compile(
    r"\)\s*,\s*([A-Z][A-Za-z'\-]+)\s*$"
)


def _expand_post_marriage_searches(state: dict) -> None:
    """After iteration 1, if any confirmed marriage names a spouse surname,
    re-run death and probate searches under that surname.

    Subject's surname is not necessarily her maiden name — for women whose
    marriages we surface, deaths/probate may only be findable under the
    married surname. This step has no effect on subjects whose marriages
    weren't found, didn't name a spouse, or whose searches already
    covered the spouse surname (e.g. men).

    Two sources of spouse surnames, in priority order:

      1. Regex extraction from a confirmed marriage fact's value string —
         works for post-Sep-1912 FreeBMD marriages where the
         spouse_or_mother field is populated.

      2. LocalTwin lookup by the subject's wt_id — fills the gap for
         pre-1912 marriages where FreeBMD doesn't index the spouse
         surname. Catherine Hannah Bown (m. 1892, d. as WARD) and
         Lydia Kenworthy (m. 1882, d. as TWYFORD) both hit this path —
         their twin records carry the spouse but FreeBMD's marriage
         row doesn't.
    """
    name = (state["person"].get("name") or "").strip()
    parts = name.split()
    if len(parts) < 2:
        return
    original_surname = parts[-1].upper()
    given_part = " ".join(parts[:-1])

    spouse_surnames: set[str] = set()
    for fact in state.get("confirmed_facts", []):
        if fact.get("type") != "marriage":
            continue
        m = _MARRIAGE_SPOUSE_SURNAME_RE.search(fact.get("value") or "")
        if not m:
            continue
        s = m.group(1).strip()
        if not s or s.upper() == original_surname:
            continue
        spouse_surnames.add(s)

    # Fall back to LocalTwin when the regex found nothing — typically
    # the pre-1912 case described above.
    if not spouse_surnames:
        corpus_match = state.get("corpus_match") or {}
        wt_id = corpus_match.get("corpus_id")
        if wt_id:
            try:
                from wikitree.twin import LocalTwin
                twin = LocalTwin()
                if twin.load():
                    for spouse in twin.spouses_of(wt_id):
                        ln = (spouse.get("LastNameAtBirth") or "").strip()
                        if ln and ln.upper() != original_surname:
                            spouse_surnames.add(ln)
            except Exception:
                pass

    if not spouse_surnames:
        return

    print(f"\n[POST-MARRIAGE] Spouse surnames discovered: {sorted(spouse_surnames)}")
    # Swap surname in place so discover.py and the scorer both see the
    # married name, then restore after each pass.
    extra_plan = ["death_registration", "probate", "burial_memorial"]
    for surname in sorted(spouse_surnames):
        state["person"]["name"] = f"{given_part} {surname}"
        # discover.execute_searches dedupes on search_type only; clear the
        # entries we're about to re-run so the surname-variant pass isn't
        # blocked by iteration 1's maiden-name pass.
        state["searched"] = [
            s for s in state.get("searched", []) if s.get("source") not in extra_plan
        ]
        print(f"  Re-running death/probate/memorial under '{surname}'")
        _execute_and_score(extra_plan, state)
    state["person"]["name"] = name


def _plan_searches(state: dict) -> list:
    """Initial search plan based on known information."""
    person = state["person"]
    birth_year = person.get("birth_year")
    death_year = person.get("death_year")
    gender = (person.get("gender") or "").upper()

    searches = []

    if birth_year:
        searches.append("birth_registration")
        if death_year:
            searches.append("death_registration")

        from agent.config import CENSUS_YEARS, CIVIL_REGISTRATION_START
        for year in CENSUS_YEARS:
            if birth_year <= year <= (death_year or birth_year + 90):
                searches.append(f"census_{year}")

        from agent.config import WW1_START, WW1_END
        if gender != "F" and WW1_START <= birth_year <= WW1_END:
            searches.append("military_service")

        searches.append("marriage")
        searches.append("burial_memorial")
        searches.append("probate")
        searches.append("wirksworth")
        searches.append("familysearch")

        # Parish registers for pre-civil-registration births
        if birth_year < CIVIL_REGISTRATION_START:
            searches.append("parish_registers")
    else:
        searches.append("census_all")
        searches.append("burial_memorial")
        searches.append("wirksworth")
        searches.append("parish_registers")

    return searches


def _apply_scores(scored: dict, state: dict) -> None:
    """Classify results as facts, leads, or impossible."""
    for source, results in scored.items():
        source_kind = _classify_search_type(source)

        for r in results:
            verdict = r["verdict"]
            record_summary = r["record_summary"]
            reasons = r["reasons"]
            failed_gates = r.get("failed_gates", [])
            # FamilySearch returns mixed record types under one source key —
            # prefer the per-record `record_type` so census hits land as
            # `census` rather than `unknown`.
            per_record_type = (r.get("result") or {}).get("record_type")
            search_type = per_record_type if per_record_type else source_kind

            if verdict == "fact":
                existing_values = {f["value"] for f in state["confirmed_facts"]}
                if record_summary not in existing_values:
                    state["confirmed_facts"].append({
                        "type": search_type,
                        "value": record_summary,
                        "sources": [f"{source}: {record_summary}"],
                        "confidence": "confirmed",
                        "gates": r.get("gates", {}),
                    })
            elif verdict == "lead":
                existing_leads = {lc["record_summary"] for lc in state.get("lead_candidates", [])}
                if record_summary not in existing_leads and len(state.get("lead_candidates", [])) < 50:
                    state.setdefault("lead_candidates", []).append({
                        "record": r.get("result", {}),
                        "record_summary": record_summary,
                        "reasons": reasons,
                        "failed_gates": failed_gates,
                        "source": source,
                        "search_type": search_type,
                    })
            elif verdict == "impossible":
                if len(state["rejected_records"]) < 50:
                    state["rejected_records"].append({
                        "record": record_summary,
                        "reason": "; ".join(reasons),
                    })


def _extract_household_members(raw_results: dict, state: dict) -> None:
    """Extract household members from census results."""
    person_name = state["person"].get("name", "").upper()
    existing = {m.get("name", "").upper() for m in state.get("household_members", [])}

    for source, data in raw_results.items():
        if not (source.startswith("census") or "census" in source.lower()):
            continue

        results = data if isinstance(data, list) else []
        if isinstance(data, dict):
            for year_results in data.values():
                if isinstance(year_results, list):
                    results.extend(year_results)

        for result in results:
            household = None
            if isinstance(result, dict) and "household" in result:
                household = result.get("household")

            if not household or not household.get("members"):
                continue

            census_year = None
            if isinstance(result, dict) and "search_match" in result:
                census_year = result["search_match"].get("census_year")

            dwelling = household.get("dwelling", {})

            for member in household["members"]:
                name = (member.get("name", "") or "").upper()
                if not name or name in person_name or person_name in name:
                    continue
                if name in existing:
                    continue

                age = member.get("age")
                birth_year_approx = None
                if age and census_year:
                    try:
                        birth_year_approx = int(census_year) - int(age)
                    except (ValueError, TypeError):
                        pass

                state["household_members"].append({
                    "name": member.get("name", "Unknown"),
                    "relationship": member.get("relationship", "Unknown"),
                    "age": age,
                    "birth_year_approx": birth_year_approx,
                    "occupation": member.get("occupation", ""),
                    "birth_place": member.get("birth_place", ""),
                    "census_year": census_year,
                    "address": dwelling.get("address", ""),
                    "parish": dwelling.get("parish", ""),
                })
                existing.add(name)

    if state["household_members"]:
        print(f"    Household members: {len(state['household_members'])}")
        for m in state["household_members"]:
            print(f"      - {m['name']}, {m['relationship']}, age {m['age']}")


def _emit_parent_link_verdict(state: dict, corpus: dict | None) -> None:
    """Set state['parent_link_verdict'] based on whether any household
    member's surname matches a corpus parent.

    Conservative rule:
      - supported   : a parent record can be resolved (via corpus wt_id
                      lookup OR LocalTwin numeric-Id lookup) AND that
                      parent's surname appears in any household member's
                      name token (case-insensitive).
      - inconclusive: no corpus_match, no household members, no resolvable
                      parent record, or no surname overlap.

    Note: an earlier revision had a tier-3 fallback that used the
    subject's own corpus-surname when no parent record could be resolved
    ("subject's surname typically equals the father's"). That heuristic
    misfires when `household_members` is populated from census-search
    results — which can contain dozens of same-surname people from
    *different* households (Sarah Byard's 1891 search returned 30 Byards
    across 5+ households). Without per-household scoping, a shared
    surname is not parent-link evidence; tier-3 was removed.
    """
    corpus_match = state.get("corpus_match")
    if not corpus_match:
        state["parent_link_verdict"] = "inconclusive"
        return

    parent_ids = corpus_match.get("corpus_parent_ids") or \
                 corpus_match.get("person", {}).get("parent_ids", []) or []
    household_members = state.get("household_members") or []
    if not household_members:
        state["parent_link_verdict"] = "inconclusive"
        return

    member_name_tokens: set[str] = set()
    for m in household_members:
        name = (m.get("name") or "").upper()
        member_name_tokens.update(name.split())

    # Collect candidate parent surnames.
    parent_surnames: set[str] = set()

    # 1. Direct lookup by wt_id (works if parent_ids are already wt_ids).
    if corpus:
        for pid in parent_ids:
            parent = corpus.get(pid)
            if parent:
                pname = (parent.get("name") or "").upper().split()
                if pname:
                    parent_surnames.add(pname[-1])

    # 2. Lookup by numeric WikiTree Id via local twin (handles the
    #    common case where parent_ids are numeric strings like
    #    "50137350" but corpus is keyed by wt_id like "Cauldwell-143").
    if parent_ids and not parent_surnames:
        try:
            from wikitree.twin import LocalTwin
            twin = LocalTwin()
            if twin.load():
                wanted = {str(pid) for pid in parent_ids}
                for wt_id in twin._graph.nodes:
                    node = twin.get(wt_id)
                    if not node:
                        continue
                    if str(node.get("Id", "")) in wanted:
                        surname = (node.get("LastNameAtBirth") or "").upper()
                        if surname:
                            parent_surnames.add(surname)
        except Exception:
            pass

    if parent_surnames and (parent_surnames & member_name_tokens):
        state["parent_link_verdict"] = "supported"
        return

    state["parent_link_verdict"] = "inconclusive"


def _emit_identity_verdict(state: dict) -> None:
    """Set state['identity_verdict'] based on the corpus-match score.

    Conservative rule:
      - supported   : corpus_match exists with match_score >= 0.9
      - inconclusive: no corpus_match, or corpus_match below threshold
    """
    corpus_match = state.get("corpus_match")
    if not corpus_match:
        state["identity_verdict"] = "inconclusive"
        return
    score = corpus_match.get("match_score")
    if isinstance(score, (int, float)) and score >= 0.9:
        state["identity_verdict"] = "supported"
    else:
        state["identity_verdict"] = "inconclusive"


def _initial_state(person: dict) -> dict:
    return {
        "person": {
            "name": person.get("name", "Unknown"),
            "birth_year": person.get("birth_year"),
            "death_year": person.get("death_year"),
            "gender": person.get("gender"),
            "birth_location": person.get("birth_location"),
            "family_context": person.get("family_context"),
        },
        "confirmed_facts": [],
        "rejected_records": [],
        "uncertain_records": [],
        "conflicts": [],
        "searched": [],
        "objectives": _initial_objectives(person),
        "household_members": [],
        "strategy": None,
    }


def _initial_objectives(person: dict) -> dict:
    gender = (person.get("gender") or "").upper()
    birth_year = person.get("birth_year")

    objectives = {
        "birth_registration": "unknown",
        "death_registration": "unknown",
        "marriage": "unknown",
        "census": "unknown",
        "burial_memorial": "unknown",
    }

    from agent.config import WW1_START, WW1_END
    if gender == "F":
        objectives["military_service"] = "not_applicable"
    elif birth_year and (birth_year < WW1_START or birth_year > WW1_END):
        objectives["military_service"] = "not_applicable"
    else:
        objectives["military_service"] = "unknown"

    return objectives


def _classify_search_type(source_key: str) -> str:
    key = source_key.lower()
    if "death" in key:
        return "death"
    if "birth" in key:
        return "birth"
    if "marriage" in key:
        return "marriage"
    if "census" in key:
        return "census"
    if "military" in key or "cwgc" in key:
        return "military"
    if "burial" in key or "grave" in key:
        return "burial"
    return "unknown"
