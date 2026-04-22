"""Investigator — LLM-powered lead investigation loop.

The probabilistic middle layer of the deterministic-probabilistic-deterministic
sandwich. The LLM reads lead evidence + family context, reasons about what
to search next, and Python executes those searches through the deterministic
pipeline.

Flow per iteration:
    1. Build context from lead + twin
    2. LLM suggests searches
    3. Python executes via discover.py
    4. Results scored via scorer.py (deterministic)
    5. New evidence added to lead
    6. Loop or stop

After loop exits, deterministic extraction promotes/dismisses the lead.

Clustering: leads are grouped by household (parent name from summary +
twin relationships). One LLM call sees the whole family, one search
can resolve multiple leads.
"""

import re
from dataclasses import dataclass, field
from collections import defaultdict

from agent.leads import Lead, Evidence, NextAction, LeadStore
from agent.llm import ask_json
from agent.scorer import classify_result
from agent.config import (
    INVESTIGATION_MAX_ITERATIONS,
    INVESTIGATION_MAX_TOKENS,
)


SYSTEM_PROMPT = """You are an experienced English genealogist investigating a specific research lead.

You have one job: figure out what searches would RESOLVE the uncertainty in this lead.

CAST THE NET WIDE. Suggest searches across MULTIPLE sources in each round — don't rely on a single source. If FreeBMD has nothing, FamilySearch or parish registers might. Census records confirm household composition. Cross-referencing multiple sources builds confidence.

FamilySearch is the RICHEST source — it has births, deaths, marriages, AND census records. Always include a FamilySearch search alongside other sources.

Think step by step:
- What makes this lead uncertain? (read the failed gates and evidence)
- What would CONFIRM this is the right person? What would DISPROVE it?
- Which sources could provide answers? Suggest 2-4 searches across different sources.
- If previous searches came back empty, try DIFFERENT sources — don't repeat what failed.

Available sources (use these exact names):
- freebmd: births, deaths, marriages (1837+). Parameters: surname, given, event (births/deaths/marriages), year_start, year_end
- freecen: census records (1841-1911). Parameters: surname, given, year
- freereg: parish registers (pre-1900). Parameters: surname, given, year_start, year_end
- cwgc: Commonwealth war dead. Parameters: surname, given
- findagrave: burial memorials. Parameters: surname, given, birth_year, death_year
- familysearch: births, deaths, census. Parameters: surname, given, birth_year, death_year
- wirksworth: Derbyshire parish records. Parameters: surname
- probate: wills and administrations. Parameters: surname, given, year_from, year_to

CONSTRAINTS:
- This is a Derbyshire family. Always include relevant district or county context.
- Use narrow date ranges (5-10 years max) — wide searches return too many results.
- Only suggest sources from the list above.
- Don't repeat searches that have already been done (check ALREADY SEARCHED).
- If you believe the lead is resolved or impossible, say so in your reasoning and return an empty searches list.

Return JSON only:
{
    "reasoning": "your step-by-step chain of logic",
    "searches": [
        {
            "description": "what to search for and why",
            "source": "freebmd|freecen|freereg|cwgc|findagrave|familysearch|wirksworth|probate",
            "parameters": {"surname": "...", "given": "...", ...}
        }
    ],
    "resolved": false,
    "questions": ["things needing human input to proceed"]
}"""

CLUSTER_SYSTEM_PROMPT = """You are an experienced English genealogist investigating a FAMILY GROUP — multiple related people from the same household.

One search can resolve multiple leads. A census search for the head of household confirms ALL family members at once. A marriage record for the parents confirms parentage for every child.

Think about the family as a unit:
- What ONE search would confirm the most people? Start there.
- Census records show the whole household — search for the HEAD or a parent.
- Birth records with mother's maiden name confirm both the child AND the mother's identity.
- If one family member is found in a later census, check if others appear in the same household.

CAST THE NET WIDE. FamilySearch is the richest source — always include it.

Available sources (use these exact names):
- freebmd: births, deaths, marriages (1837+). Parameters: surname, given, event (births/deaths/marriages), year_start, year_end
- freecen: census records (1841-1911). Parameters: surname, given, year
- freereg: parish registers (pre-1900). Parameters: surname, given, year_start, year_end
- cwgc: Commonwealth war dead. Parameters: surname, given
- findagrave: burial memorials. Parameters: surname, given, birth_year, death_year
- familysearch: births, deaths, census. Parameters: surname, given, birth_year, death_year
- wirksworth: Derbyshire parish records. Parameters: surname
- probate: wills and administrations. Parameters: surname, given, year_from, year_to

CONSTRAINTS:
- Derbyshire family. Always include district or county.
- Narrow date ranges (5-10 years max).
- Only suggest sources from the list above.
- Don't repeat searches already done (check ALREADY SEARCHED).
- Suggest searches for SPECIFIC family members — name who you're searching for.

Return JSON only:
{
    "reasoning": "step-by-step logic about the whole family",
    "searches": [
        {
            "description": "what to search for and why",
            "source": "freebmd|freecen|freereg|cwgc|findagrave|familysearch|wirksworth|probate",
            "parameters": {"surname": "...", "given": "...", ...},
            "for_leads": ["lead_id_1", "lead_id_2"]
        }
    ],
    "resolved": false,
    "questions": ["things needing human input"]
}"""


VALID_SOURCES = {
    "freebmd", "freecen", "freereg", "cwgc", "findagrave",
    "familysearch", "wirksworth", "probate",
}

# Maps investigator source names to discover.py search types
SOURCE_TO_SEARCH_TYPE = {
    "freebmd": None,  # depends on event parameter
    "freecen": None,   # depends on year parameter
    "freereg": "parish_registers",
    "cwgc": "military_service",
    "findagrave": "burial_memorial",
    "familysearch": "familysearch",
    "wirksworth": "wirksworth",
    "probate": "probate",
}


@dataclass
class InvestigationResult:
    """Output of an investigation loop."""
    lead_id: str
    iterations: int = 0
    reasoning_log: list[str] = field(default_factory=list)
    searches_executed: list[dict] = field(default_factory=list)
    new_evidence: list[Evidence] = field(default_factory=list)
    facts_extracted: list[dict] = field(default_factory=list)
    verdict: str = "inconclusive"  # resolved | more_evidence | inconclusive | disproved
    questions: list[str] = field(default_factory=list)


@dataclass
class Cluster:
    """A group of related leads from the same household."""
    family_key: str             # e.g. "William Caldwell"
    leads: list[Lead] = field(default_factory=list)
    known_profiles: list[dict] = field(default_factory=list)  # twin profiles for context


def cluster_leads(lead_store: LeadStore, twin, status: str = "open") -> list[Cluster]:
    """Group open leads by household/family using summary text + twin graph.

    Returns clusters sorted by total priority (sum of lead priorities).
    """
    leads = lead_store.by_priority(status)
    groups = defaultdict(list)

    for lead in leads:
        key = _extract_family_key(lead)
        groups[key].append(lead)

    clusters = []
    for family_key, family_leads in groups.items():
        cluster = Cluster(family_key=family_key, leads=family_leads)

        # Enrich with twin profiles — find the parent/head and their family
        _enrich_cluster_from_twin(cluster, twin)

        clusters.append(cluster)

    # Sort by total priority descending
    clusters.sort(key=lambda c: sum(l.priority for l in c.leads), reverse=True)
    return clusters


def _extract_family_key(lead: Lead) -> str:
    """Extract household grouping key from lead summary."""
    match = re.search(r'(?:child|sibling|spouse|parent) of (\w+ \w+)', lead.summary)
    if match:
        return match.group(1)
    # Fall back to surname
    parts = lead.subject_name.split()
    return parts[-1] if parts else "unknown"


def _enrich_cluster_from_twin(cluster: Cluster, twin) -> None:
    """Add known twin profiles related to the cluster's family."""
    # Find any lead with a subject_id to anchor into the twin graph
    anchor_id = None
    for lead in cluster.leads:
        if lead.subject_id:
            anchor_id = lead.subject_id
            break

    if not anchor_id:
        return

    # Get the family unit from twin
    seen = {anchor_id}
    profile = twin.get(anchor_id)
    if profile:
        cluster.known_profiles.append(profile)

    for query_fn in (twin.parents_of, twin.siblings_of, twin.spouses_of, twin.children_of):
        for relative in query_fn(anchor_id):
            wt_id = relative.get("wt_id", "")
            if wt_id and wt_id not in seen:
                seen.add(wt_id)
                cluster.known_profiles.append(relative)


@dataclass
class ClusterResult:
    """Output of a cluster investigation."""
    family_key: str
    lead_count: int = 0
    iterations: int = 0
    reasoning_log: list[str] = field(default_factory=list)
    searches_executed: list[dict] = field(default_factory=list)
    new_evidence: list[Evidence] = field(default_factory=list)
    facts_extracted: list[dict] = field(default_factory=list)
    leads_resolved: int = 0
    leads_remaining: int = 0
    questions: list[str] = field(default_factory=list)


def investigate_cluster(cluster: Cluster, twin, lead_store: LeadStore,
                        max_iterations: int = INVESTIGATION_MAX_ITERATIONS) -> ClusterResult:
    """Investigate a cluster of related leads together.

    The LLM sees the whole family. Searches are executed for individual
    members but evidence is distributed to matching leads.
    """
    result = ClusterResult(
        family_key=cluster.family_key,
        lead_count=len(cluster.leads),
    )

    print(f"\n  Cluster: {cluster.family_key} ({len(cluster.leads)} leads)")

    # Infer birth years for all leads in the cluster
    for lead in cluster.leads:
        lead.status = "investigating"
        if not lead.subject_birth_year:
            inferred = _infer_birth_year(lead, twin)
            if inferred:
                lead.subject_birth_year = inferred

    for iteration in range(max_iterations):
        print(f"\n  --- Cluster iteration {iteration + 1}/{max_iterations} ---")

        # 1. Build combined context for all leads in cluster
        context = _build_cluster_context(cluster, twin)

        # 2. Ask LLM
        llm_response = ask_json(context, system=CLUSTER_SYSTEM_PROMPT)

        if llm_response is None:
            print("  LLM unavailable, using deterministic fallback")
            for lead in cluster.leads:
                _run_deterministic_fallback(lead, twin, lead_store, InvestigationResult(lead_id=lead.lead_id))
            break

        # Handle LLM returning a list instead of dict
        if isinstance(llm_response, list):
            llm_response = llm_response[0] if llm_response else {}
        if not isinstance(llm_response, dict):
            print(f"  Unexpected LLM response type: {type(llm_response)}")
            break

        reasoning = llm_response.get("reasoning", "")
        result.reasoning_log.append(reasoning)
        print(f"  LLM reasoning: {reasoning[:300]}...")

        if llm_response.get("resolved", False):
            print("  LLM says cluster is resolved")
            break

        result.questions.extend(llm_response.get("questions", []))

        # 3. Parse suggestions — use first lead for dedup but searches apply to cluster
        searches = _parse_llm_suggestions(llm_response, cluster.leads[0])

        # Auto-inject FamilySearch for EACH lead that hasn't been searched yet.
        # The cluster head search misses individuals because FamilySearch
        # filters by birth year — each person needs their own search.
        # Always inject per-person searches regardless of LLM suggestions —
        # the LLM typically suggests one search for the head, not individuals.
        if iteration == 0:  # Only on first iteration to avoid repeats
            for lead in cluster.leads:
                fs_done = any("familysearch" in e.source for e in lead.evidence)
                if fs_done or not lead.subject_birth_year:
                    continue
                parts = lead.subject_name.split()
                surname = parts[-1] if parts else ""
                given = parts[0] if len(parts) > 1 else ""
                searches.append({
                    "source": "familysearch",
                    "description": f"FamilySearch sweep for {lead.subject_name}",
                    "parameters": {"surname": surname, "given": given},
                    "search_type": "familysearch",
                    "_target_lead": lead.lead_id,
                })

        if not searches:
            print("  No new searches suggested — stopping")
            break

        # 4. Execute searches and distribute evidence to matching leads
        new_evidence = _execute_and_score_cluster(searches, cluster, lead_store)
        result.searches_executed.extend(
            [{"iteration": iteration + 1, **s} for s in searches]
        )
        result.new_evidence.extend(new_evidence)
        result.iterations = iteration + 1

        if not new_evidence:
            for desc in [s["description"] for s in searches]:
                for lead in cluster.leads:
                    lead.uncertainty_reasons.append(f"Searched but found nothing: {desc}")
            print(f"  No new evidence — LLM will see empty results next iteration")

    # 5. Deterministic extraction for each lead in cluster
    for lead in cluster.leads:
        facts = _extract_facts(lead, lead_store)
        result.facts_extracted.extend(facts)
        if facts:
            result.leads_resolved += 1
        else:
            lead.status = "open"
            result.leads_remaining += 1

    return result


def _build_cluster_context(cluster: Cluster, twin) -> str:
    """Build combined context for all leads in a cluster."""
    lines = []

    lines.append(f"INVESTIGATING FAMILY: {cluster.family_key}")
    lines.append(f"Leads to resolve: {len(cluster.leads)}")
    lines.append("")

    # Each lead as a brief entry
    lines.append("PEOPLE TO CONFIRM:")
    for lead in cluster.leads:
        birth = f"b.~{lead.subject_birth_year}" if lead.subject_birth_year else "b.?"
        lines.append(f"  - {lead.subject_name} ({birth}) [{lead.category}]")
        lines.append(f"    {lead.summary}")

    # Combined evidence across all leads
    all_evidence = []
    for lead in cluster.leads:
        for e in lead.evidence:
            all_evidence.append((lead.subject_name, e))

    if all_evidence:
        shown = all_evidence[-20:]  # Cap for context window
        lines.append(f"\nEVIDENCE ({len(all_evidence)} items, showing latest {len(shown)}):")
        for name, e in shown:
            lines.append(f"  [{e.source}] {name}: {e.record_summary}")

    # Combined already-searched
    all_searched = set()
    for lead in cluster.leads:
        all_searched.update(e.source for e in lead.evidence)
    if all_searched:
        lines.append(f"\nALREADY SEARCHED: {', '.join(all_searched)}")

    # Empty searches
    all_empty = set()
    for lead in cluster.leads:
        for r in lead.uncertainty_reasons:
            if r.startswith("Searched but found nothing:"):
                all_empty.add(r.replace("Searched but found nothing: ", ""))
    if all_empty:
        lines.append(f"\nSEARCHED BUT EMPTY:")
        for s in list(all_empty)[:10]:
            lines.append(f"  - {s}")

    # Known family from twin
    if cluster.known_profiles:
        lines.append(f"\nKNOWN FAMILY MEMBERS (from WikiTree):")
        for p in cluster.known_profiles[:15]:
            name = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip()
            wt_id = p.get("wt_id", "")
            birth = p.get("BirthDate", "") or p.get("BirthDateDecade", "")
            death = p.get("DeathDate", "")
            lines.append(f"  {name} ({wt_id}) b.{birth} d.{death}")

    return "\n".join(lines)


def _execute_and_score_cluster(searches: list[dict], cluster: Cluster,
                               lead_store: LeadStore) -> list[Evidence]:
    """Execute searches and distribute evidence to matching leads in the cluster."""
    from agent.discover import _dispatch_search
    from agent.rules import name_similarity_score

    # Use the family surname for searches
    family_parts = cluster.family_key.split()
    family_surname = family_parts[-1] if family_parts else ""

    new_evidence = []

    for search in searches:
        source = search["source"]
        params = search["parameters"]
        search_type = search["search_type"]
        description = search["description"]

        # Determine which lead this search is for
        search_surname = params.get("surname", family_surname)
        search_given = params.get("given", "")

        # Use explicit target lead if specified (e.g., per-person FamilySearch)
        target_lead_id = search.get("_target_lead")
        if target_lead_id:
            target_lead = next((l for l in cluster.leads if l.lead_id == target_lead_id), None)
        else:
            target_lead = _find_target_lead(cluster, search_surname, search_given)
        birth_year = target_lead.subject_birth_year if target_lead else None
        death_year = _extract_death_year(target_lead) if target_lead else None

        print(f"    Executing: {description}")

        try:
            raw = _dispatch_search(
                search_type,
                search_surname,
                search_given or "",
                birth_year,
                death_year,
            )
        except Exception as e:
            print(f"    Search error: {e}")
            continue

        if not raw:
            print(f"    No results")
            continue

        results = raw if isinstance(raw, list) else [raw]
        print(f"    Got {len(results)} results, scoring...")

        for r in results[:10]:
            # Determine scorer type per record (FamilySearch returns mixed types)
            scorer_type = _search_type_for_scorer(search_type, r if isinstance(r, dict) else None)

            # Score against each lead in the cluster to find the best match
            best_lead, best_scored = _match_result_to_lead(r, cluster, scorer_type)

            if not best_lead:
                continue

            verdict = best_scored.get("verdict", "?")
            if verdict == "impossible":
                print(f"      [IMPOSSIBLE] {best_scored.get('record_summary', '')[:80]}")
                continue

            evidence = Evidence(
                source=f"{source}_{search_type}",
                record_summary=best_scored.get("record_summary", str(r)[:120]),
                reasons=best_scored.get("reasons", []),
                search_type=scorer_type,
                raw_record=r if isinstance(r, dict) else {},
            )

            lead_store.add_evidence(best_lead.lead_id, evidence)
            new_evidence.append(evidence)
            print(f"      [{verdict.upper()}] {best_lead.subject_name}: {evidence.record_summary[:60]}")

    return new_evidence


def _find_target_lead(cluster: Cluster, surname: str, given: str) -> Lead | None:
    """Find the lead in the cluster that best matches the search parameters."""
    from agent.rules import name_similarity_score

    best_lead = None
    best_score = 0.0

    for lead in cluster.leads:
        parts = lead.subject_name.upper().split()
        lead_surname = parts[-1] if parts else ""
        lead_given = parts[0] if len(parts) > 1 else ""

        score = name_similarity_score(lead_surname, surname.upper())
        if given:
            score += name_similarity_score(lead_given, given.upper())
        else:
            score += 0.5  # No given name to match, partial credit

        if score > best_score:
            best_score = score
            best_lead = lead

    return best_lead if best_score > 0.7 else (cluster.leads[0] if cluster.leads else None)


def _match_result_to_lead(result: dict, cluster: Cluster,
                          scorer_type: str) -> tuple[Lead | None, dict]:
    """Score a result against all leads in the cluster, return the best match."""
    best_lead = None
    best_scored = {}
    best_verdict_rank = 99  # lower = better

    verdict_rank = {"fact": 0, "lead": 1, "impossible": 2}

    for lead in cluster.leads:
        person = {
            "name": lead.subject_name,
            "birth_year": lead.subject_birth_year,
            "death_year": _extract_death_year(lead),
            "birth_location": "",
        }

        scored = classify_result(result, person, scorer_type)
        rank = verdict_rank.get(scored.get("verdict", "impossible"), 99)

        if rank < best_verdict_rank:
            best_verdict_rank = rank
            best_lead = lead
            best_scored = scored

    return best_lead, best_scored


def investigate_lead(lead: Lead, twin, lead_store: LeadStore,
                     max_iterations: int = INVESTIGATION_MAX_ITERATIONS) -> InvestigationResult:
    """Run the investigation loop on a lead.

    Returns InvestigationResult with accumulated evidence and extracted facts.
    Falls back to deterministic suggestions if LLM unavailable.
    """
    result = InvestigationResult(lead_id=lead.lead_id)

    lead_store.get(lead.lead_id)  # ensure we have the live reference
    lead.status = "investigating"

    # Infer birth year if not set — many leads from census have age but no birth year
    if not lead.subject_birth_year:
        inferred = _infer_birth_year(lead, twin)
        if inferred:
            lead.subject_birth_year = inferred
            print(f"  Inferred birth year: ~{inferred}")

    for iteration in range(max_iterations):
        print(f"\n  --- Investigation iteration {iteration + 1}/{max_iterations} ---")

        # 1. Build context
        context = _build_lead_context(lead, twin)

        # 2. Ask LLM
        llm_response = ask_json(context, system=SYSTEM_PROMPT)

        if llm_response is None:
            # LLM unavailable — fall back to deterministic suggestions
            print("  LLM unavailable, using deterministic suggestions")
            _run_deterministic_fallback(lead, twin, lead_store, result)
            break

        # Handle LLM returning a list instead of dict
        if isinstance(llm_response, list):
            llm_response = llm_response[0] if llm_response else {}
        if not isinstance(llm_response, dict):
            print(f"  Unexpected LLM response type: {type(llm_response)}")
            break

        reasoning = llm_response.get("reasoning", "")
        result.reasoning_log.append(reasoning)
        print(f"  LLM reasoning: {reasoning[:200]}...")

        # Check if LLM says resolved
        if llm_response.get("resolved", False):
            print("  LLM says lead is resolved")
            break

        # Collect questions
        questions = llm_response.get("questions", [])
        result.questions.extend(questions)

        # 3. Parse and validate suggestions
        searches = _parse_llm_suggestions(llm_response, lead)

        # Always include FamilySearch if not already searched — the LLM
        # often forgets despite prompting, and it's our richest source
        fs_already = any(s["source"] == "familysearch" for s in searches)
        fs_in_evidence = any("familysearch" in e.source for e in lead.evidence)
        if not fs_already and not fs_in_evidence and lead.subject_birth_year:
            searches.append({
                "source": "familysearch",
                "description": f"Broad FamilySearch sweep for {lead.subject_name}",
                "parameters": {
                    "surname": lead.subject_name.split()[-1] if lead.subject_name else "",
                    "given": lead.subject_name.split()[0] if len(lead.subject_name.split()) > 1 else "",
                },
                "search_type": "familysearch",
            })

        if not searches:
            print("  No new searches suggested — stopping")
            break

        # 4. Execute searches and score results
        new_evidence_this_round = _execute_and_score(searches, lead, lead_store)
        result.searches_executed.extend(
            [{"iteration": iteration + 1, **s} for s in searches]
        )
        result.new_evidence.extend(new_evidence_this_round)
        result.iterations = iteration + 1

        # Record which searches returned nothing — the LLM needs to know
        # so it can try different sources on the next iteration
        if not new_evidence_this_round:
            empty_sources = [s["description"] for s in searches]
            for desc in empty_sources:
                lead.uncertainty_reasons.append(f"Searched but found nothing: {desc}")
            print(f"  No new evidence — LLM will see empty results next iteration")

    # 5. Deterministic extraction — final scoring pass
    facts = _extract_facts(lead, lead_store)
    result.facts_extracted = facts

    # 6. Determine verdict
    if facts:
        result.verdict = "resolved"
        lead.status = "confirmed" if facts else lead.status
    elif result.new_evidence:
        result.verdict = "more_evidence"
        lead.status = "open"
    else:
        result.verdict = "inconclusive"
        lead.status = "open"

    return result


def _build_lead_context(lead: Lead, twin) -> str:
    """Build compact text context for the LLM from lead + twin."""
    lines = []

    # Lead summary
    lines.append(f"INVESTIGATING LEAD: {lead.summary}")
    lines.append(f"Subject: {lead.subject_name}, born ~{lead.subject_birth_year or '?'}")
    lines.append(f"Category: {lead.category}")

    if lead.uncertainty_reasons:
        lines.append(f"\nWHY UNCERTAIN:")
        for reason in lead.uncertainty_reasons:
            lines.append(f"  - {reason}")

    # Evidence accumulated so far — show most recent 15 to stay within
    # context window of a 14B model
    if lead.evidence:
        total = len(lead.evidence)
        shown = lead.evidence[-15:]
        lines.append(f"\nEVIDENCE ({total} items, showing latest {len(shown)}):")
        for e in shown:
            lines.append(f"  [{e.source}] {e.record_summary}")
            for r in e.reasons:
                lines.append(f"    {r}")

    # Already searched (don't repeat) — includes empty results
    searched_sources = {e.source for e in lead.evidence}
    if searched_sources:
        lines.append(f"\nALREADY SEARCHED (had results): {', '.join(searched_sources)}")

    # Show what was tried but returned nothing
    empty_searches = [r for r in lead.uncertainty_reasons if r.startswith("Searched but found nothing:")]
    if empty_searches:
        lines.append(f"\nSEARCHED BUT EMPTY (try different source):")
        for s in empty_searches:
            lines.append(f"  - {s.replace('Searched but found nothing: ', '')}")

    # Family context from twin
    family_context = _get_family_context(lead, twin)
    if family_context:
        lines.append(f"\nFAMILY TREE CONTEXT:")
        lines.append(family_context)

    return "\n".join(lines)


def _get_family_context(lead: Lead, twin) -> str:
    """Query twin for family members around the lead subject."""
    wt_id = lead.subject_id
    if not wt_id:
        return ""

    lines = []

    profile = twin.get(wt_id)
    if profile:
        birth = profile.get("BirthDate", "") or profile.get("BirthDateDecade", "")
        death = profile.get("DeathDate", "") or profile.get("DeathDateDecade", "")
        location = profile.get("BirthLocation", "")
        lines.append(f"  Profile: {wt_id}")
        if birth:
            lines.append(f"  Birth: {birth} {location}")
        if death:
            lines.append(f"  Death: {death}")

    # Parents
    parents = twin.parents_of(wt_id)
    if parents:
        lines.append(f"  Parents:")
        for p in parents:
            name = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip()
            birth = p.get("BirthDate", "") or p.get("BirthDateDecade", "")
            lines.append(f"    {name} b.{birth}")

    # Spouses
    spouses = twin.spouses_of(wt_id)
    if spouses:
        lines.append(f"  Spouses:")
        for sp in spouses:
            name = f"{sp.get('FirstName', '')} {sp.get('LastNameAtBirth', '')}".strip()
            lines.append(f"    {name}")

    # Siblings
    siblings = twin.siblings_of(wt_id)
    if siblings:
        lines.append(f"  Siblings ({len(siblings)}):")
        for sib in siblings[:8]:
            name = f"{sib.get('FirstName', '')} {sib.get('LastNameAtBirth', '')}".strip()
            birth = sib.get("BirthDate", "") or sib.get("BirthDateDecade", "")
            lines.append(f"    {name} b.{birth}")

    # Children
    children = twin.children_of(wt_id)
    if children:
        lines.append(f"  Children ({len(children)}):")
        for ch in children[:10]:
            name = f"{ch.get('FirstName', '')} {ch.get('LastNameAtBirth', '')}".strip()
            birth = ch.get("BirthDate", "") or ch.get("BirthDateDecade", "")
            lines.append(f"    {name} b.{birth}")

    return "\n".join(lines)


def _parse_llm_suggestions(response: dict, lead: Lead) -> list[dict]:
    """Parse LLM response into executable search dicts.

    Validates sources exist, filters already-searched, extracts parameters.
    """
    raw_searches = response.get("searches", [])
    if not raw_searches:
        return []

    searched_sources = {e.source for e in lead.evidence}
    valid = []

    for s in raw_searches:
        source = (s.get("source", "") or "").lower().strip()
        if source not in VALID_SOURCES:
            print(f"    Skipping unknown source: {source}")
            continue

        params = s.get("parameters", {})
        description = s.get("description", "")

        # Build a search key to avoid repeats — include event/year to
        # distinguish birth vs death searches for the same person
        event = params.get("event", params.get("year", ""))
        search_key = f"{source}_{params.get('surname', '')}_{params.get('given', '')}_{event}"
        if search_key in searched_sources:
            print(f"    Skipping already searched: {search_key}")
            continue

        valid.append({
            "source": source,
            "description": description,
            "parameters": params,
            "search_type": _resolve_search_type(source, params),
        })

    return valid


def _resolve_search_type(source: str, params: dict) -> str:
    """Map source + parameters to a discover.py search type."""
    mapped = SOURCE_TO_SEARCH_TYPE.get(source)
    if mapped:
        return mapped

    if source == "freebmd":
        event = (params.get("event", "") or "").lower()
        if "birth" in event:
            return "birth_registration"
        if "death" in event:
            return "death_registration"
        if "marriage" in event:
            return "marriage"
        return "birth_registration"

    if source == "freecen":
        year = params.get("year")
        if year:
            return f"census_{year}"
        return "census_all"

    return source


def _extract_death_year(lead: Lead) -> int | None:
    """Try to find a death year from lead evidence or raw records."""
    for e in lead.evidence:
        raw = e.raw_record
        if not raw:
            continue
        for field in ("death_year", "year"):
            val = raw.get(field)
            if isinstance(val, int) and e.search_type == "death":
                return val
    return None


def _infer_birth_year(lead: Lead, twin) -> int | None:
    """Try to infer birth year from lead evidence, twin, or lead ID.

    Sources checked:
    1. lead.subject_birth_year (explicit)
    2. Twin profile (BirthDate)
    3. Census evidence (birth_year field or age + census_year)
    4. Lead ID (contains year hint from census)
    """
    if lead.subject_birth_year:
        return lead.subject_birth_year

    # Check evidence FIRST — census age/birth year is from the actual
    # record that created this lead, more reliable than a WikiTree profile
    # which might be a different person with the same name
    for e in lead.evidence:
        raw = e.raw_record
        if not raw:
            continue
        # Direct birth year
        birth_yr = raw.get("birth_year")
        if isinstance(birth_yr, int):
            return birth_yr
        # Age + census year
        age = raw.get("age")
        census_yr = raw.get("census_year")
        if isinstance(age, int) and isinstance(census_yr, int):
            return census_yr - age

    # Check lead summary for census year — "found in 1861 census" means
    # person was alive then. Extract year from summary as a last resort.
    import re
    census_match = re.search(r"(\d{4}) census", lead.summary or "")
    if census_match:
        census_year = int(census_match.group(1))
        if 1841 <= census_year <= 1911:
            # Person was alive at census — rough estimate, but better than
            # using a potentially wrong twin profile
            return census_year - 10

    # Fall back to twin profile — but this might be the wrong person
    # if the lead's subject_id was a tentative match
    if lead.subject_id:
        profile = twin.get(lead.subject_id)
        if profile:
            import re
            for field in ("BirthDate", "BirthDateDecade"):
                val = profile.get(field, "")
                if val:
                    match = re.search(r"\b(1[6-9]\d{2}|20[0-2]\d)\b", str(val))
                    if match:
                        return int(match.group(1))

    return None


def _execute_and_score(searches: list[dict], lead: Lead,
                       lead_store: LeadStore) -> list[Evidence]:
    """Execute searches via discover.py and score results via scorer.py."""
    from agent.discover import _dispatch_search

    death_year = _extract_death_year(lead)
    person = {
        "name": lead.subject_name,
        "birth_year": lead.subject_birth_year,
        "death_year": death_year,
        "birth_location": "",
    }

    name_parts = lead.subject_name.split()
    surname = name_parts[-1] if name_parts else ""
    given = name_parts[0] if len(name_parts) > 1 else ""

    new_evidence = []

    for search in searches:
        source = search["source"]
        params = search["parameters"]
        search_type = search["search_type"]
        description = search["description"]

        print(f"    Executing: {description}")

        try:
            raw = _dispatch_search(
                search_type,
                params.get("surname", surname),
                params.get("given", given),
                lead.subject_birth_year,
                death_year,
            )
        except Exception as e:
            print(f"    Search error: {e}")
            continue

        if not raw:
            print(f"    No results")
            continue

        # Flatten results
        results = raw if isinstance(raw, list) else [raw]
        print(f"    Got {len(results)} results, scoring...")

        # Score each result through deterministic gates
        for r in results[:10]:  # cap to avoid excessive processing
            scorer_type = _search_type_for_scorer(search_type, r if isinstance(r, dict) else None)
            scored = classify_result(r, person, scorer_type)
            verdict = scored.get("verdict", "?")

            # Only keep facts and leads as evidence — discard impossibles
            if verdict == "impossible":
                print(f"      [IMPOSSIBLE] {scored.get('record_summary', '')[:80]}")
                continue

            evidence = Evidence(
                source=f"{source}_{search_type}",
                record_summary=scored.get("record_summary", str(r)[:120]),
                reasons=scored.get("reasons", []),
                search_type=scorer_type,
                raw_record=r if isinstance(r, dict) else {},
            )

            lead_store.add_evidence(lead.lead_id, evidence)
            new_evidence.append(evidence)
            print(f"      [{verdict.upper()}] {evidence.record_summary[:80]}")

    return new_evidence


def _search_type_for_scorer(search_type: str, record: dict | None = None) -> str:
    """Map discover.py search types to scorer categories.

    For FamilySearch results, checks the _fs_type field on the record
    since FamilySearch returns mixed record types from one search.
    """
    if "birth" in search_type:
        return "birth"
    if "death" in search_type:
        return "death"
    if "marriage" in search_type:
        return "marriage"
    if "census" in search_type:
        return "census"
    if "military" in search_type or "cwgc" in search_type:
        return "death"
    if "burial" in search_type or "grave" in search_type:
        return "burial"

    # FamilySearch broad sweep — check record's _fs_type
    if record and isinstance(record, dict):
        fs_type = record.get("_fs_type", "")
        if fs_type in ("birth", "death", "marriage", "census"):
            return fs_type
        # Infer from record fields
        if record.get("birth_date") and not record.get("death_date") and not record.get("residence_place"):
            return "birth"
        if record.get("residence_place") or record.get("census_year"):
            return "census"
        if record.get("death_date"):
            return "death"
        if record.get("marriage_date"):
            return "marriage"

    return "unknown"


def _extract_facts(lead: Lead, lead_store: LeadStore) -> list[dict]:
    """Final deterministic pass — extract ALL facts from accumulated evidence.

    Each piece of evidence is re-scored. Every result that passes all gates
    becomes a fact. Records with household data must also pass a household
    match — the person must appear in a household containing expected family
    members. This prevents promoting a name+date match in the wrong family.
    """
    from agent.rules import name_similarity_score

    person = {
        "name": lead.subject_name,
        "birth_year": lead.subject_birth_year,
        "death_year": _extract_death_year(lead),
        "birth_location": "",
    }

    # Build list of expected family names from the lead context
    expected_family = _get_expected_family(lead)

    facts = []
    seen_categories = set()

    for evidence in lead.evidence:
        if not evidence.raw_record:
            continue

        scorer_type = evidence.search_type or "unknown"
        scored = classify_result(evidence.raw_record, person, scorer_type)

        if scored.get("verdict") != "fact":
            continue

        # Household validation — if the record has household members,
        # at least one must match an expected family member
        raw = evidence.raw_record
        household = raw.get("household", [])
        if household and expected_family:
            if not _household_matches_family(household, expected_family):
                continue  # Wrong family — skip this record

        # Deduplicate — one fact per category (birth, death, marriage, etc.)
        if scorer_type in seen_categories:
            continue
        seen_categories.add(scorer_type)

        # Include household match info in the fact
        household_confirmed = bool(household and expected_family and
                                   _household_matches_family(household, expected_family))

        facts.append({
            "type": scorer_type,
            "value": scored.get("record_summary", ""),
            "sources": [evidence.source],
            "confidence": "confirmed" if household_confirmed else "gates_only",
            "household_confirmed": household_confirmed,
            "raw_record": raw,
        })

    # Promote the lead only after extracting all facts
    if facts:
        lead_store.promote_to_fact(lead.lead_id)

    return facts


def _get_expected_family(lead: Lead) -> list[str]:
    """Extract expected family member names from the lead summary and evidence.

    Returns a list of surname strings to match against household members.
    """
    names = []

    # Extract parent/family name from lead summary
    match = re.search(r'(?:child|sibling|spouse|parent) of (\w+ \w+)', lead.summary)
    if match:
        names.append(match.group(1).upper())

    # Also extract the lead's own surname as a family indicator
    parts = lead.subject_name.split()
    if parts:
        names.append(parts[-1].upper())

    return names


def _household_matches_family(household: list[dict], expected_family: list[str]) -> bool:
    """Check if any household member's name matches expected family names.

    A match means any household member shares a surname with the expected
    family, OR the household collection title mentions a family member.
    """
    from agent.rules import name_similarity_score

    for member in household:
        if isinstance(member, str):
            member_name = member.upper()
        elif isinstance(member, dict):
            member_name = (member.get("name", "") or "").upper()
        else:
            continue
        if not member_name:
            continue

        member_parts = member_name.split()
        member_surname = member_parts[-1] if member_parts else ""

        for expected in expected_family:
            expected_parts = expected.split()
            expected_surname = expected_parts[-1] if expected_parts else expected

            # Surname match (handles Caldwell/Cauldwell etc.)
            if name_similarity_score(member_surname, expected_surname) >= 0.7:
                return True

            # Full name match
            if name_similarity_score(member_name, expected) >= 0.7:
                return True

    return False


def _run_deterministic_fallback(lead: Lead, twin, lead_store: LeadStore,
                                result: InvestigationResult):
    """When LLM unavailable, execute existing next_actions deterministically."""
    if not lead.next_actions:
        result.verdict = "inconclusive"
        return

    # Convert NextActions to search dicts
    searches = []
    for action in lead.next_actions:
        if action.cost != "free":
            continue
        searches.append({
            "source": action.source,
            "description": action.description,
            "parameters": action.parameters,
            "search_type": _resolve_search_type(action.source, action.parameters),
        })

    if searches:
        result.reasoning_log.append(
            "LLM unavailable — executing deterministic next actions"
        )
        new_evidence = _execute_and_score(searches, lead, lead_store)
        result.new_evidence.extend(new_evidence)
        result.searches_executed.extend(searches)
        result.iterations = 1

        facts = _extract_facts(lead, lead_store)
        result.facts_extracted = facts
        result.verdict = "resolved" if facts else "more_evidence" if new_evidence else "inconclusive"
