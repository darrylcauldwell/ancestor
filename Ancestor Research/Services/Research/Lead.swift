import Foundation

/// A lead — a person-shaped gap discovered during research.
/// Leads come from scored records marked as "lead" and from household discoveries.
/// They can be investigated (re-run pipeline) or promoted to tree profiles.
nonisolated struct Lead: Identifiable, Codable, Sendable {
    let id: String
    let profileID: String           // The profile that generated this lead
    let name: String
    let surname: String?
    let givenName: String?
    let birthYear: Int?
    let deathYear: Int?
    let relationship: String?       // e.g. "spouse", "child", "sibling", "unknown"
    let source: LeadSource
    let status: LeadStatus
    let evidence: String            // Summary of why this is a lead
    let createdAt: Date
    var investigatedAt: Date?
    var resolvedAt: Date?
    var resolution: LeadResolution?
}

/// Where a lead came from.
nonisolated enum LeadSource: String, Codable, Sendable {
    case scoredLead         // RecordScorer returned .lead verdict
    case householdMember    // Census household extraction
    case discovery          // DiscoveryExtractor finding
    case ghostNode          // Existing ghost node in tree
}

/// Current status of a lead.
nonisolated enum LeadStatus: String, Codable, Sendable {
    case new                // Just created, not yet investigated
    case investigating      // Pipeline running for this lead
    case investigated       // Pipeline finished, awaiting user decision
    case promoted           // Lead became a real profile in the tree
    case dismissed          // User decided this lead is not relevant
}

/// How a lead was resolved.
nonisolated enum LeadResolution: String, Codable, Sendable {
    case promoted           // Added to tree as a new profile
    case merged             // Matched an existing profile
    case dismissed          // User dismissed — wrong person or not relevant
    case duplicate          // Another lead already covers this person
}

/// Manages lead persistence and lifecycle.
actor LeadStore {
    private let db: ProjectDatabase
    private var leads: [String: Lead] = [:]

    init(db: ProjectDatabase) {
        self.db = db
    }

    /// Load all leads from database.
    func loadAll() throws {
        let rows = try db.loadLeads()
        leads = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    /// Get all leads, optionally filtered by status.
    func all(status: LeadStatus? = nil) -> [Lead] {
        let all = Array(leads.values)
        guard let status else { return all.sorted { $0.createdAt > $1.createdAt } }
        return all.filter { $0.status == status }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Get leads for a specific profile.
    func forProfile(_ profileID: String) -> [Lead] {
        leads.values.filter { $0.profileID == profileID }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Create a lead from a scored record.
    ///
    /// FIXME (autonomous-discovery, 2026-05-25): `relationship` is
    /// left nil here — empirically blocks `promote_lead` autonomous
    /// promotion (the MCP gate refuses leads without an unambiguous
    /// father/mother/spouse label). Of the 90 leads produced during
    /// tonight's discovery bring-up, all carried `relationship = nil`
    /// because most reach this path via `RunRequestWatcher` /
    /// `ResearchViewModel` callers that have no kin context for the
    /// scored record. Two options to unblock tree expansion:
    ///
    /// 1. Add an optional `relationship` parameter and have the
    ///    callers pass it when they know (e.g. the dispatcher that
    ///    scored a marriage record has bride/groom context; a parent
    ///    inference pipeline emitting via this path has gender).
    /// 2. Carve a separate inference-aware lead emitter for
    ///    `.parentInferred(supported)` hypotheses that DOES know the
    ///    relationship + gender, leaving this generic emitter alone
    ///    for the "could be anyone" scored-record case.
    func createFromScoredRecord(_ scored: ScoredRecord, profileID: String) throws -> Lead {
        let lead = Lead(
            id: "lead_\(scored.id)",
            profileID: profileID,
            name: [scored.record.givenName, scored.record.surname].compactMap { $0 }.joined(separator: " "),
            surname: scored.record.surname,
            givenName: scored.record.givenName,
            birthYear: extractBirthYear(from: scored.record),
            deathYear: extractDeathYear(from: scored.record),
            relationship: nil,
            source: .scoredLead,
            status: .new,
            evidence: scored.summary,
            createdAt: Date()
        )
        leads[lead.id] = lead
        try db.saveLead(lead)
        return lead
    }

    /// Create a lead from a `.parentInferred(gender, surname)` hypothesis
    /// that's been graded `.supported`. Unlike `createFromScoredRecord`
    /// — which has no kin context for the matched record — this emitter
    /// fires only when the hypothesis itself carries the relationship
    /// (gender → father/mother) and the surname (MMN for mother;
    /// subject's surname for father). The resulting lead is shaped to
    /// pass `promote_lead`'s gate: relationship is set, surname is set.
    /// Given name + birth year stay nil — the BMD index doesn't carry
    /// either for parents, so this is genuinely all the engine can
    /// know at this point.
    ///
    /// Deterministic id from the hypothesis's identity key so re-grading
    /// the same hypothesis across runs doesn't duplicate the lead.
    func createFromParentInferredHypothesis(
        _ hypothesis: ResearchHypothesis
    ) throws -> Lead? {
        guard case .parentInferred(let gender, let surname) = hypothesis.kind else {
            return nil
        }
        guard hypothesis.verdict == .supported else { return nil }
        let trimmed = surname.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let subjectProfileID = hypothesis.subjectProfileID else {
            return nil
        }
        let relationship: String
        switch gender {
        case .male: relationship = "father"
        case .female: relationship = "mother"
        case .other, .unknown: return nil
        }
        let lead = Lead(
            id: "lead_parentInferred_\(hypothesis.id)",
            profileID: subjectProfileID,
            name: "[\(relationship)] /\(trimmed)/",
            surname: trimmed,
            givenName: nil,
            birthYear: nil,
            deathYear: nil,
            relationship: relationship,
            source: .discovery,
            status: .new,
            evidence: hypothesis.reasoning,
            createdAt: Date()
        )
        guard leads[lead.id] == nil else { return leads[lead.id] }
        leads[lead.id] = lead
        try db.saveLead(lead)
        return lead
    }

    /// Create a lead from a household member discovery.
    func createFromHouseholdMember(_ member: HouseholdMember, profileID: String, censusYear: Int) throws -> Lead {
        // Deterministic id — Swift's `hashValue` is process-randomised, so
        // the same name+year would produce different ids each app launch
        // and break cross-run dedup. Normalise to uppercase + underscores.
        let key = member.name
            .uppercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        let lead = Lead(
            id: "lead_hh_\(key)_\(censusYear)",
            profileID: profileID,
            name: member.name,
            surname: member.name.split(separator: " ").last.map(String.init),
            givenName: member.name.split(separator: " ").first.map(String.init),
            birthYear: member.birthYear ?? member.age.map { censusYear - $0 },
            deathYear: nil,
            relationship: member.relationship,
            source: .householdMember,
            status: .new,
            evidence: "\(member.relationship) in \(censusYear) census, age \(member.age.map(String.init) ?? "?")",
            createdAt: Date()
        )

        // Deduplicate
        guard leads[lead.id] == nil else { return leads[lead.id]! }

        leads[lead.id] = lead
        try db.saveLead(lead)
        return lead
    }

    /// Build a ResearchSubject from a lead for investigation.
    func subjectForInvestigation(_ lead: Lead) -> ResearchSubject {
        ResearchSubject(
            surname: lead.surname,
            givenName: lead.givenName,
            birthYearFrom: lead.birthYear,
            birthYearTo: lead.birthYear,
            deathYearFrom: lead.deathYear,
            deathYearTo: lead.deathYear,
            gender: nil,
            region: .county("Derbyshire"),
            mode: .discover
        )
    }

    /// Update lead status.
    func updateStatus(_ leadID: String, status: LeadStatus) throws {
        guard var lead = leads[leadID] else { return }
        lead = Lead(
            id: lead.id, profileID: lead.profileID,
            name: lead.name, surname: lead.surname, givenName: lead.givenName,
            birthYear: lead.birthYear, deathYear: lead.deathYear,
            relationship: lead.relationship, source: lead.source,
            status: status, evidence: lead.evidence,
            createdAt: lead.createdAt,
            investigatedAt: status == .investigating ? Date() : lead.investigatedAt,
            resolvedAt: status == .promoted || status == .dismissed ? Date() : lead.resolvedAt,
            resolution: lead.resolution
        )
        leads[leadID] = lead
        try db.upsertLead(lead)
    }

    /// Promote a lead — mark as promoted and dismiss competitors.
    func promote(_ leadID: String) throws {
        try updateStatus(leadID, status: .promoted)

        // Dismiss other leads with same name that aren't already resolved
        guard let promoted = leads[leadID] else { return }
        let competitors = leads.values.filter {
            $0.id != leadID &&
            $0.status != .promoted && $0.status != .dismissed &&
            $0.surname?.uppercased() == promoted.surname?.uppercased() &&
            $0.givenName?.uppercased() == promoted.givenName?.uppercased()
        }
        for competitor in competitors {
            var dismissed = competitor
            dismissed = Lead(
                id: dismissed.id, profileID: dismissed.profileID,
                name: dismissed.name, surname: dismissed.surname, givenName: dismissed.givenName,
                birthYear: dismissed.birthYear, deathYear: dismissed.deathYear,
                relationship: dismissed.relationship, source: dismissed.source,
                status: .dismissed, evidence: dismissed.evidence,
                createdAt: dismissed.createdAt,
                investigatedAt: dismissed.investigatedAt,
                resolvedAt: Date(),
                resolution: .duplicate
            )
            leads[dismissed.id] = dismissed
            try db.upsertLead(dismissed)
        }
    }

    /// Dismiss a lead.
    func dismiss(_ leadID: String) throws {
        try updateStatus(leadID, status: .dismissed)
    }

    // MARK: - Helpers

    private func extractBirthYear(from record: SourceRecord) -> Int? {
        switch record {
        case .birth(let r): return r.birthYear
        case .census(let r): return r.birthYear
        case .pedigree(let r): return r.birthYear
        default: return nil
        }
    }

    private func extractDeathYear(from record: SourceRecord) -> Int? {
        switch record {
        case .death(let r): return r.deathYear
        case .burial(let r): return r.deathYear
        case .military(let r): return r.deathYear
        case .probate(let r): return r.deathYear
        default: return nil
        }
    }
}
