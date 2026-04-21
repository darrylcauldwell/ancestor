"""Lead case management — tracks research leads across sessions.

A lead is a case file for a record that looks promising but needs
further investigation. Each lead accumulates evidence, has suggested
next actions, and is prioritised deterministically.

Hard facts go straight to WikiTree. Leads drive the research backlog.

Usage:
    from agent.leads import LeadStore, Lead, Evidence, NextAction

    store = LeadStore()
    store.load()
    store.add(lead)
    store.add_evidence(lead_id, evidence)
    top = store.by_priority("open")
    store.save()
"""

import json
import re
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path


def _leads_file():
    from project_config import config
    return config.project.data_dir / "agent-research" / "leads.json"

COMMON_SURNAMES = {
    "SMITH", "JONES", "BROWN", "WARD", "TAYLOR", "WILSON", "WRIGHT",
    "WALKER", "HALL", "WOOD", "GREEN", "CLARK", "THOMPSON", "JOHNSON",
    "WILLIAMS", "HARRIS", "MARTIN", "JACKSON", "WHITE", "LEWIS",
    "ROBINSON", "YOUNG", "KING", "MOORE", "BAKER",
}


@dataclass
class Evidence:
    """A single piece of evidence attached to a lead."""
    source: str                 # e.g. "freebmd_birth", "census_1891"
    record_summary: str         # one-line description
    reasons: list[str]          # from scorer — what matched/failed
    added_at: str = ""          # ISO timestamp
    search_type: str = ""       # birth, death, census, etc.
    raw_record: dict = field(default_factory=dict)

    def __post_init__(self):
        if not self.added_at:
            self.added_at = datetime.now(timezone.utc).isoformat()


@dataclass
class NextAction:
    """A suggested follow-up action for a lead."""
    description: str            # "Search FamilySearch 1901 census for John Cauldwell"
    source: str                 # "familysearch", "gro_cert", "freebmd", etc.
    parameters: dict = field(default_factory=dict)
    cost: str = "free"          # "free" | "paid"
    cost_detail: str = ""       # "" or "GRO certificate ~£3"
    reasoning: str = ""         # why this would help


@dataclass
class Lead:
    """A research case file for a potential record match."""
    lead_id: str
    subject_id: str             # WikiTree ID or proposed ID
    subject_name: str
    subject_birth_year: int | None = None

    category: str = ""          # birth, death, marriage, census, identity, relationship
    summary: str = ""           # one-line description

    uncertainty_reasons: list[str] = field(default_factory=list)
    evidence: list[Evidence] = field(default_factory=list)
    next_actions: list[NextAction] = field(default_factory=list)

    priority: int = 0
    status: str = "open"        # open, investigating, confirmed, dismissed
    dismissed_reason: str = ""

    opened_at: str = ""
    updated_at: str = ""
    history: list[dict] = field(default_factory=list)

    is_direct_ancestor: bool = False
    corroborating_sources: int = 0

    def __post_init__(self):
        now = datetime.now(timezone.utc).isoformat()
        if not self.opened_at:
            self.opened_at = now
        if not self.updated_at:
            self.updated_at = now


def compute_priority(lead: Lead) -> int:
    """Deterministic priority score. Higher = investigate first."""
    score = 0

    if lead.is_direct_ancestor:
        score += 10

    if lead.next_actions:
        score += 5
        has_free = any(a.cost == "free" for a in lead.next_actions)
        if has_free:
            score += 3
        else:
            score += 1

    if lead.corroborating_sources > 1:
        score += 2 * (lead.corroborating_sources - 1)

    # Penalise common surnames
    surname = lead.subject_name.split()[-1].upper() if lead.subject_name else ""
    if surname in COMMON_SURNAMES:
        score -= 3

    # Penalise pre-1837 (limited sources)
    if lead.subject_birth_year and lead.subject_birth_year < 1837:
        score -= 2

    return score


def _make_lead_id(subject_name: str, category: str, record_year: int | None) -> str:
    """Generate a deterministic lead ID."""
    name = re.sub(r'[^a-z0-9]', '_', subject_name.lower()).strip('_')
    year = str(record_year) if record_year else "unknown"
    return f"lead_{name}_{category}_{year}"


class LeadStore:
    """Persistent storage for leads across sessions."""

    def __init__(self):
        self._leads: dict[str, Lead] = {}

    def load(self) -> int:
        """Load leads from disk. Returns count loaded."""
        if not _leads_file().exists():
            return 0

        data = json.loads(_leads_file().read_text())
        for lead_data in data.get("leads", []):
            # Reconstruct dataclass from dict
            evidence = [Evidence(**e) for e in lead_data.pop("evidence", [])]
            actions = [NextAction(**a) for a in lead_data.pop("next_actions", [])]
            lead = Lead(**lead_data, evidence=evidence, next_actions=actions)
            self._leads[lead.lead_id] = lead

        return len(self._leads)

    def save(self) -> Path:
        """Save all leads to disk."""
        _leads_file().parent.mkdir(exist_ok=True)
        data = {
            "version": 1,
            "last_updated": datetime.now(timezone.utc).isoformat(),
            "lead_count": len(self._leads),
            "leads": [asdict(lead) for lead in self._leads.values()],
        }
        _leads_file().write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str))
        return _leads_file()

    def add(self, lead: Lead) -> str:
        """Add a new lead. Deduplicates by lead_id. Returns lead_id."""
        if lead.lead_id in self._leads:
            # Add evidence to existing lead instead
            existing = self._leads[lead.lead_id]
            for e in lead.evidence:
                existing.evidence.append(e)
            existing.corroborating_sources = len({e.source for e in existing.evidence})
            existing.priority = compute_priority(existing)
            existing.updated_at = datetime.now(timezone.utc).isoformat()
            existing.history.append({"action": "evidence_added", "at": existing.updated_at})
            return existing.lead_id

        lead.priority = compute_priority(lead)
        lead.history.append({"action": "opened", "at": lead.opened_at})
        self._leads[lead.lead_id] = lead
        return lead.lead_id

    def get(self, lead_id: str) -> Lead | None:
        return self._leads.get(lead_id)

    def add_evidence(self, lead_id: str, evidence: Evidence) -> None:
        """Append evidence to an existing lead."""
        lead = self._leads.get(lead_id)
        if not lead:
            return
        lead.evidence.append(evidence)
        lead.corroborating_sources = len({e.source for e in lead.evidence})
        lead.priority = compute_priority(lead)
        lead.updated_at = datetime.now(timezone.utc).isoformat()
        lead.history.append({"action": "evidence_added", "at": lead.updated_at})

    def promote_to_fact(self, lead_id: str) -> dict | None:
        """Mark lead as confirmed. Returns a fact dict for the pipeline."""
        lead = self._leads.get(lead_id)
        if not lead:
            return None

        lead.status = "confirmed"
        lead.updated_at = datetime.now(timezone.utc).isoformat()
        lead.history.append({"action": "promoted_to_fact", "at": lead.updated_at})

        # Build fact dict from lead evidence
        sources = []
        for e in lead.evidence:
            sources.append(f"{e.source}: {e.record_summary}")

        return {
            "type": lead.category,
            "value": lead.summary,
            "sources": sources,
            "confidence": "confirmed",
        }

    def dismiss(self, lead_id: str, reason: str) -> None:
        """Dismiss a lead with reason."""
        lead = self._leads.get(lead_id)
        if not lead:
            return
        lead.status = "dismissed"
        lead.dismissed_reason = reason
        lead.updated_at = datetime.now(timezone.utc).isoformat()
        lead.history.append({"action": "dismissed", "at": lead.updated_at, "reason": reason})

    def find_for_subject(self, subject_name: str, category: str = "") -> list[Lead]:
        """Find existing leads for a person."""
        name_upper = subject_name.upper()
        results = []
        for lead in self._leads.values():
            if lead.subject_name.upper() == name_upper:
                if not category or lead.category == category:
                    results.append(lead)
        return results

    def by_priority(self, status: str = "open") -> list[Lead]:
        """Return leads sorted by priority descending."""
        filtered = [l for l in self._leads.values() if l.status == status]
        return sorted(filtered, key=lambda l: l.priority, reverse=True)

    @property
    def count(self) -> int:
        return len(self._leads)

    def open_count(self) -> int:
        return sum(1 for l in self._leads.values() if l.status == "open")


def create_leads_from_candidates(state: dict, store: LeadStore) -> int:
    """Convert lead candidates from scoring into managed leads.

    Called after scoring in the pipeline. Returns count of new leads created.
    """
    candidates = state.get("lead_candidates", [])
    if not candidates:
        return 0

    person = state["person"]
    subject_name = person.get("name", "")
    subject_birth = person.get("birth_year")

    # Find WikiTree ID if matched
    corpus_match = state.get("corpus_match")
    subject_id = corpus_match.get("corpus_id", "") if corpus_match else ""

    new_count = 0
    for candidate in candidates:
        record = candidate.get("record", {})
        summary = candidate.get("record_summary", "")
        reasons = candidate.get("reasons", [])
        source = candidate.get("source", "")
        search_type = candidate.get("search_type", "")

        # Extract year from record for lead ID
        record_year = record.get("year") or record.get("birth_year")
        if isinstance(record_year, str):
            match = re.search(r'\d{4}', record_year)
            record_year = int(match.group()) if match else None

        lead_id = _make_lead_id(subject_name, search_type, record_year)

        # Build uncertainty reasons from failed gates
        failed_gates = candidate.get("failed_gates", [])
        uncertainty = [f"Failed: {g}" for g in failed_gates] if failed_gates else reasons

        # Generate next actions based on category
        actions = _suggest_actions(search_type, record, subject_name, subject_birth)

        evidence = Evidence(
            source=source,
            record_summary=summary,
            reasons=reasons,
            search_type=search_type,
            raw_record=record,
        )

        lead = Lead(
            lead_id=lead_id,
            subject_id=subject_id,
            subject_name=subject_name,
            subject_birth_year=subject_birth,
            category=search_type,
            summary=f"Possible {search_type} record — {summary}",
            uncertainty_reasons=uncertainty,
            evidence=[evidence],
            next_actions=actions,
            corroborating_sources=1,
        )

        existing = store.find_for_subject(subject_name, search_type)
        if existing:
            # Add evidence to first matching lead
            store.add_evidence(existing[0].lead_id, evidence)
        else:
            store.add(lead)
            new_count += 1

    return new_count


def check_findings_against_leads(state: dict, store: LeadStore) -> list[dict]:
    """Check if new facts resolve any open leads.

    Returns list of promoted facts.
    """
    facts = state.get("facts", state.get("confirmed_facts", []))
    person = state["person"]
    subject_name = person.get("name", "")

    promoted = []
    for fact in facts:
        category = fact.get("type", "")
        matching_leads = store.find_for_subject(subject_name, category)

        for lead in matching_leads:
            if lead.status == "open":
                promoted_fact = store.promote_to_fact(lead.lead_id)
                if promoted_fact:
                    promoted.append(promoted_fact)

    return promoted


def _suggest_actions(category: str, record: dict, name: str, birth_year: int | None) -> list[NextAction]:
    """Generate suggested next actions based on lead category."""
    actions = []
    name_parts = name.split()
    surname = name_parts[-1] if name_parts else ""
    given = name_parts[0] if len(name_parts) > 1 else ""

    if category in ("birth", "death"):
        vol = record.get("vol", "")
        page = record.get("page", "")
        district = record.get("district", "")
        if vol and page:
            actions.append(NextAction(
                description=f"Order GRO certificate ({district} vol{vol} p{page}) — confirms full name, parents, address",
                source="gro_cert",
                parameters={"vol": vol, "page": page, "district": district},
                cost="paid",
                cost_detail="GRO digital certificate ~£3",
                reasoning="Certificate is the primary source — confirms or disproves identity",
            ))

        # Suggest census cross-reference
        if birth_year:
            for census_year in [1881, 1891, 1901, 1911]:
                if birth_year <= census_year <= (birth_year + 90):
                    actions.append(NextAction(
                        description=f"Search {census_year} census for {given} {surname} to confirm address and household",
                        source="freecen",
                        parameters={"surname": surname, "given": given, "year": census_year},
                        cost="free",
                        reasoning=f"Census household at {census_year} would confirm identity via family members",
                    ))
                    break  # Just suggest one census year

    elif category == "marriage":
        actions.append(NextAction(
            description=f"Search for spouse's entry in same quarter to confirm via same-page match",
            source="freebmd",
            parameters={"surname": "", "event": "marriages"},
            cost="free",
            reasoning="FreeBMD same-page entries confirm the couple",
        ))

    elif category == "census":
        actions.append(NextAction(
            description=f"Search adjacent census years to track family across decades",
            source="freecen",
            parameters={"surname": surname, "given": given},
            cost="free",
            reasoning="Same person in multiple censuses builds confidence",
        ))

    return actions
