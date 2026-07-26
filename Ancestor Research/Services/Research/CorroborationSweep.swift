import Foundation
import GRDB
import AncestorKit
import os

/// #CPC-Change2 — the post-run cross-profile corroboration sweep
/// (`AncestorApp/CROSS_PROFILE_CORROBORATION_SPEC.md` §4, Change 2).
///
/// Iterates spouse edges, loads BOTH ends' persisted marriage evidence, runs
/// the pure `SpousePairCorroborator`, and emits findings through the
/// Evidence Firewall as pending facts (`marriageDate` + `marriageLocation`)
/// for human review — the sweep itself never writes tree data. Modelled on
/// `ConflictSweep`: idempotent (deterministic pending-fact ids, INSERT OR
/// IGNORE; a second pass adds zero rows), read-only except the pending_facts
/// queue, and safe to run at project open, post-persist (scoped to the
/// just-persisted profile's edges — catches the moment the second spouse's
/// run lands), or manually.
///
/// Spec deviations recorded honestly: the high-water skip named in the spec
/// component table is NOT implemented — the marriage-count pre-filter
/// short-circuits non-candidate edges before any decode, idempotent emission
/// makes re-runs free, and a high-water column would need a schema
/// migration; add it only if a large tree proves the count queries hot.
nonisolated struct CorroborationSweep {

    /// The `agent_id` stamped on every emitted pending fact — the key the
    /// `PendingFactsProcessor` exemption, the review-card routing, and the
    /// future §14 carve-out (Change 5) all match on.
    static let agentID = "cross-profile-corroboration"

    /// Diagnostic logger. Keeps the "why didn't this pair corroborate"
    /// signals at `.info` (near-miss district drift, non-keyable stale
    /// records, contradictions, ambiguity) plus the run summary; routine
    /// success and no-evidence edges drop to `.debug`. Cheap — info/debug
    /// aren't persisted to disk — and it paid for itself once already: it
    /// pinned the Ida × George stall to a July-18 record persisted before
    /// the parser captured structured vol/page/year (`no keyable marriage
    /// records`), fixed by re-researching that side.
    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research", category: "CorroborationSweep")

    struct Report: Sendable {
        var edgesScanned = 0
        var findingsEmitted = 0
        var edgesRepaired = 0
        var skippedEdgePopulated = 0
        var skippedEdgeConflict = 0
        var refusedSharedKeyClaims = 0
        var withdrawnStale = 0
        var leadsTidied = 0
        var nearMisses: [String] = []
    }

    /// Full or scoped pass. `limitToProfileID` restricts to edges touching
    /// one profile (the post-persist trigger).
    @discardableResult
    static func run(
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot,
        limitToProfileID: String? = nil
    ) throws -> Report {
        var report = Report()
        let resolver: (String) -> String? = {
            FreeBMDDistrictCatalogue.shared.district(named: $0)?.name
        }

        let spouseEdges = snapshot.relationships.filter { edge in
            edge.type == .spouse
                && (limitToProfileID == nil
                    || edge.from == limitToProfileID || edge.to == limitToProfileID)
        }

        // Phase 1 — corroborate every in-scope edge (no writes yet: the
        // key→edge claim ledger below needs the full pass, Decision 11).
        // `bothAccepted` = both matched records are already fact-verdict
        // (human-accepted), which routes an EMPTY edge to repair rather than
        // review (see emit()).
        var claims: [(edge: Relationship, finding: SpousePairCorroborator.Finding, bothAccepted: Bool)] = []
        var scannedEdgeIDs = Set<String>()

        for edge in spouseEdges {
            report.edgesScanned += 1
            scannedEdgeIDs.insert(edge.id.uuidString)
            guard let profileA = snapshot.profiles[edge.from],
                  let profileB = snapshot.profiles[edge.to] else { continue }

            // Cheap pre-filter: both ends must hold at least one marriage
            // evidence row before anything is decoded.
            guard try db.marriageEvidenceCount(profileID: profileA.id) > 0,
                  try db.marriageEvidenceCount(profileID: profileB.id) > 0
            else { continue }

            let (outcome, factRecordIDs) = try corroborateEdge(
                edge: edge, profileA: profileA, profileB: profileB,
                db: db, snapshot: snapshot, districtResolver: resolver
            )
            let pairLabel = "\(profileA.displayName) × \(profileB.displayName)"
            let edgeHasDate = edge.marriageDate != nil
            switch outcome {
            case .found(let finding):
                let bothAccepted = factRecordIDs.contains(finding.subjectRecordID)
                    && factRecordIDs.contains(finding.partnerRecordID)
                logger.debug("edge \(pairLabel): FOUND tier=\(finding.tier.rawValue) key=\(finding.canonicalKey) bothAccepted=\(bothAccepted) edgeHasDate=\(edgeHasDate)")
                claims.append((edge, finding, bothAccepted))
            case .none(let reason) where reason.hasPrefix("near-miss"):
                logger.info("edge \(pairLabel): NEAR-MISS \(reason)")
                report.nearMisses.append("\(pairLabel): \(reason)")
            case .none(let reason) where reason.contains("no scorable marriage evidence"):
                // Routine: most edges simply lack marriage evidence on a side.
                logger.debug("edge \(pairLabel): NONE (\(reason))")
            case .none(let reason):
                // Actionable: non-keyable stale records, no shared key,
                // contradictions — the "why didn't it corroborate" cases.
                logger.info("edge \(pairLabel): NONE (\(reason))")
            case .ambiguous(let reason):
                logger.info("edge \(pairLabel): AMBIGUOUS (\(reason))")
            }
        }

        // Phase 2 — sweep-wide key→edge claim ledger (Decision 11): a
        // canonical key matched by ≥2 distinct edges refuses ALL claimants.
        let byKey = Dictionary(grouping: claims, by: { $0.finding.canonicalKey })
        var validFactIDs = Set<String>()

        for (_, keyClaims) in byKey {
            guard keyClaims.count == 1, let claim = keyClaims.first else {
                report.refusedSharedKeyClaims += keyClaims.count
                continue
            }
            try emit(claim: claim, db: db, snapshot: snapshot,
                     validFactIDs: &validFactIDs, report: &report)
        }

        // Phase 3 — staleness arm (Decision 16): a still-pending fact from
        // this agent whose edge was scanned this pass but which the pass no
        // longer stands behind (justification lapsed: record discarded, lead
        // dismissed, key no longer unique) is withdrawn, visibly.
        for row in try db.loadPendingCorroborationFactRows(agentID: agentID) {
            guard let payload = CorroborationPayload.decode(row.payloadJSON),
                  scannedEdgeIDs.contains(payload.edgeID),
                  !validFactIDs.contains(row.id)
            else { continue }
            try db.updatePendingFactStatus(id: row.id, status: "withdrawn")
            report.withdrawnStale += 1
        }

        logger.info("summary: scanned=\(report.edgesScanned) emitted=\(report.findingsEmitted) repaired=\(report.edgesRepaired) skippedPopulated=\(report.skippedEdgePopulated) skippedConflict=\(report.skippedEdgeConflict) refusedKeyClaims=\(report.refusedSharedKeyClaims) withdrawn=\(report.withdrawnStale) scope=\(limitToProfileID ?? "all")")
        return report
    }

    // MARK: - Per-edge corroboration

    private static func corroborateEdge(
        edge: Relationship,
        profileA: Profile,
        profileB: Profile,
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot,
        districtResolver: @escaping (String) -> String?
    ) throws -> (outcome: SpousePairCorroborator.Outcome, factRecordIDs: Set<String>) {
        // Evidence, minus user-discarded rows (rejection-memory layer ii).
        let evidenceA = try db.loadEvidenceForProfile(profileA.id)
            .filter { $0.userStatus != .discarded }
        let evidenceB = try db.loadEvidenceForProfile(profileB.id)
            .filter { $0.userStatus != .discarded }

        // Fact-verdict (already human-accepted) record ids across both sides —
        // an empty edge whose both matched records are fact is a repair, not a
        // discovery (emit()).
        let factRecordIDs = Set((evidenceA + evidenceB)
            .filter { $0.verdict == .fact }
            .map(\.sourceRecordID))

        func marriages(_ evidence: [EvidenceRecord]) -> [(id: String, record: MarriageRecord)] {
            evidence.compactMap { row in
                guard row.verdict != .impossible, case .marriage(let m) = row.record else { return nil }
                return (id: row.sourceRecordID, record: m)
            }
        }
        let marriagesA = marriages(evidenceA)
        let marriagesB = marriages(evidenceB)
        guard !marriagesA.isEmpty, !marriagesB.isEmpty else {
            return (.none(reason: "no scorable marriage evidence on both sides"), factRecordIDs)
        }

        // Rejection-memory layer i: a DISMISSED lead's underlying record is
        // excluded (`lead_<sourceRecordID>` join).
        func dismissedRecordIDs(_ profileID: String) throws -> Set<String> {
            Set(try db.loadLeads(profileID: profileID)
                .filter { $0.status == .dismissed }
                .compactMap { lead in
                    lead.id.hasPrefix("lead_") ? String(lead.id.dropFirst(5)) : nil
                })
        }

        // CL6 parity (Decision 8): open spouseIdentity/timeline disputes on
        // either member refuse detection outright.
        func hasBlockingDispute(_ profileID: String) throws -> Bool {
            try db.openDisputes(profileID: profileID).contains {
                $0.kind == .spouseIdentity || $0.kind == .timeline
            }
        }

        let exclusions = SpousePairCorroborator.Exclusions(
            excludedSubjectRecordIDs: try dismissedRecordIDs(profileA.id),
            excludedPartnerRecordIDs: try dismissedRecordIDs(profileB.id),
            hasOpenDispute: try hasBlockingDispute(profileA.id) || hasBlockingDispute(profileB.id)
        )

        let children = childProfiles(of: [profileA.id, profileB.id], snapshot: snapshot)
        let anchors = children.compactMap { child -> SpousePairCorroborator.ChildMMNAnchor? in
            guard let mmn = childMMN(child, db: db) else { return nil }
            return .init(mothersMaidenName: mmn, birthYear: child.birthDate?.earliest)
        }

        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: marriagesA,
            partnerMarriages: marriagesB,
            subject: pairMember(profileA, snapshot: snapshot),
            partner: pairMember(profileB, snapshot: snapshot),
            childMMNAnchors: anchors,
            edgeID: edge.id.uuidString,
            exclusions: exclusions,
            districtResolver: districtResolver
        )
        return (outcome, factRecordIDs)
    }

    /// Surname set (spec §1): recorded surname + explicit married surname +
    /// the father-derived maiden axis. Birth window is PROFILE-RECORDED
    /// only — never relative-derived fallbacks (anchor-vacuity guard).
    /// Internal (not private): the in-run `CrossProfileAnnotator` builds
    /// its members through the same single definition (#CPC-Change3).
    static func pairMember(
        _ profile: Profile, snapshot: FamilyGraphSnapshot
    ) -> SpousePairCorroborator.PairMember {
        var surnames: Set<String> = []
        if let s = profile.lastName, !s.isEmpty { surnames.insert(s) }
        if let m = profile.marriedSurname, !m.isEmpty { surnames.insert(m) }
        if let father = snapshot.parentsOf(profile.id).first(where: { $0.gender == .male }),
           let fs = father.lastName, !fs.isEmpty {
            surnames.insert(fs)
        }

        let birthRange: ClosedRange<Int>? = {
            guard let e = profile.birthDate?.earliest,
                  let l = profile.birthDate?.latest, e <= l else { return nil }
            return e...l
        }()

        return SpousePairCorroborator.PairMember(
            profileID: profile.id,
            surnames: surnames,
            recordedBirthYearRange: birthRange,
            deathYear: profile.deathDate?.latest ?? profile.deathDate?.earliest,
            displayLabel: profile.displayName
        )
    }

    private static func childProfiles(
        of parentIDs: [String], snapshot: FamilyGraphSnapshot
    ) -> [Profile] {
        var seen = Set<String>()
        var out: [Profile] = []
        for parentID in parentIDs {
            for child in snapshot.childrenOf(parentID) where seen.insert(child.id).inserted {
                out.append(child)
            }
        }
        return out
    }

    /// Child's mother's-maiden-name: profile field first, else the child's
    /// own persisted birth evidence (the `childEvidenceMMNLookup` read path).
    private static func childMMN(_ child: Profile, db: ProjectDatabase) -> String? {
        if let mmn = child.mothersMaidenName, !mmn.isEmpty { return mmn }
        guard let evidence = try? db.loadEvidenceForProfile(child.id) else { return nil }
        for row in evidence where row.verdict != .impossible {
            if case .birth(let birth) = row.record,
               let mmn = birth.mothersMaidenName, !mmn.isEmpty {
                return mmn
            }
        }
        return nil
    }

    // MARK: - Emission

    private static func emit(
        claim: (edge: Relationship, finding: SpousePairCorroborator.Finding, bothAccepted: Bool),
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot,
        validFactIDs: inout Set<String>,
        report: inout Report
    ) throws {
        let finding = claim.finding
        let edge = claim.edge

        // Decision 9 — the edge's existing marriage date decides the route:
        // conflicting (non-overlapping) → skip, the conflict layer owns
        // disputes; equal-or-narrower → nothing to gain, tidy the leads;
        // wider/absent → repair or emit.
        if let existing = edge.marriageDate,
           let ee = existing.earliest, let el = existing.latest {
            let overlaps = !(finding.proposedLatestYear < ee || finding.proposedEarliestYear > el)
            if !overlaps {
                report.skippedEdgeConflict += 1
                return
            }
            if (el - ee) <= (finding.proposedLatestYear - finding.proposedEarliestYear) {
                report.skippedEdgePopulated += 1
                report.leadsTidied += try tidyLeads(finding: finding, db: db)
                return
            }
        }

        // REPAIR (#CPC follow-up 2026-07-26): the edge carries no marriage
        // date, yet BOTH spouses already hold this marriage as an accepted
        // (fact-verdict) record. That is an accept whose edge write silently
        // failed under the pre-fix apply path (Ida Louisa Land × George
        // Herbert Brooks) — complete it mechanically. This is NOT a machine
        // decision skipping review: the human already accepted these exact
        // marriage facts on both profiles; the sweep only finishes the
        // absorption. Check-Before-Overwrite (fillRelationshipMarriage) means
        // it can only fill emptiness, and it fires solely for a tree-linked
        // spouse pair sharing the exact GRO reference. Discovery-grade pairs
        // (either side still a lead) fall through to human review below.
        if edge.marriageDate == nil, claim.bothAccepted {
            let date = GenealogicalDate(
                original: finding.registrationLabel,
                earliest: finding.proposedEarliestYear,
                latest: finding.proposedLatestYear,
                isApproximate: false,
                qualifier: .exact
            )
            _ = try db.fillRelationshipMarriage(
                relationshipID: edge.id,
                candidateDate: date,
                candidateLocation: finding.proposedLocation
            )
            report.leadsTidied += try tidyLeads(finding: finding, db: db)
            report.edgesRepaired += 1
            return
        }

        let subjectName = snapshot.profiles[finding.subjectProfileID]?.displayName
            ?? finding.subjectProfileID
        let partnerName = snapshot.profiles[finding.partnerProfileID]?.displayName
            ?? finding.partnerProfileID

        // Decision 6 — one owner per pair (lexicographically-first profile
        // id; stable and documented on the card, which names both spouses).
        let ownerID = min(finding.subjectProfileID, finding.partnerProfileID)
        let sourceURL = sourceURLForFinding(finding, db: db)
        let payloadJSON = CorroborationPayload(from: finding).encoded()

        let tierLabel = finding.tier == .reciprocal
            ? "reciprocal spouse columns"
            : "same-page pairing, pre-1912-style index — verify against the register"
        let anchorLabel: String = {
            switch finding.anchor {
            case .strong(let d): return "strong anchor: \(d)"
            case .weak(let d): return "weak anchor: \(d)"
            case .none: return "no anchor — neither party's dated facts test the marriage year"
            }
        }()
        let evidenceText = "\(subjectName) and \(partnerName) each hold a marriage index entry at GRO \(finding.canonicalKey) (\(tierLabel); \(anchorLabel))"

        let dateValue = finding.registrationLabel
        let facts: [(field: String, value: String)] = [
            ("marriageDate", dateValue),
            ("marriageLocation", finding.proposedLocation ?? ""),
        ].filter { !$0.value.isEmpty }

        for (field, value) in facts {
            let id = EvidenceFirewall.idempotencyKey(
                profileID: ownerID, field: field, value: value, sourceURL: sourceURL
            )
            let fact = PendingFact(
                id: id, profileID: ownerID, field: field, value: value,
                sourceURL: sourceURL,
                sourceTitle: "Cross-profile corroboration (\(subjectName) × \(partnerName))",
                evidenceText: String(evidenceText.prefix(200)),
                reasoning: finding.trace.joined(separator: "; "),
                confidence: finding.anchor.isStrong ? "high" : "medium",
                agentID: agentID,
                submittedAt: Date(),
                // Derived from already-scored, already-cited persisted
                // evidence rows — the processor honours this as its Step-2
                // bypass instead of re-fetching the source (Decision 14).
                verificationStatus: .verified,
                payloadJSON: payloadJSON
            )
            try db.savePendingFact(fact)
            validFactIDs.insert(id)
        }
        report.findingsEmitted += facts.count
    }

    /// The citation URL travels from the subject-side evidence row — the
    /// fact cites the record it derives from, not a fresh fetch.
    private static func sourceURLForFinding(
        _ finding: SpousePairCorroborator.Finding, db: ProjectDatabase
    ) -> String {
        let rows = (try? db.loadEvidenceForProfile(finding.subjectProfileID)) ?? []
        if let row = rows.first(where: { $0.sourceRecordID == finding.subjectRecordID }) {
            if let url = row.citationURL, !url.isEmpty { return url }
            if let url = row.record.common.detailURL, !url.isEmpty { return url }
        }
        return "https://www.freebmd.org.uk/"
    }

    /// Lead tidy arm: when the edge already carries the fact, the matching
    /// lead rows resolve (`.promoted`/`.merged` — the attach-to-existing
    /// precedent). Dismissed rows are left exactly as the user set them.
    private static func tidyLeads(
        finding: SpousePairCorroborator.Finding, db: ProjectDatabase
    ) throws -> Int {
        var tidied = 0
        for (profileID, recordIDs) in [
            (finding.subjectProfileID, finding.subjectCollapsedRecordIDs),
            (finding.partnerProfileID, finding.partnerCollapsedRecordIDs),
        ] {
            for recordID in recordIDs
            where try db.resolveCorroboratedLead(profileID: profileID, sourceRecordID: recordID) {
                tidied += 1
            }
        }
        return tidied
    }
}

// MARK: - Pending-fact payload (rides pending_facts.sources_json)

/// Machine-readable routing payload (spec Decision 6) — the accept path
/// reads THIS, never display text.
nonisolated struct CorroborationPayload: Codable, Sendable {
    var schema = "cpc-v1"
    let edgeID: String
    let subjectProfileID: String
    let partnerProfileID: String
    let subjectRecordID: String
    let partnerRecordID: String
    /// ALL collapsed record ids per side (transcription variants of the one
    /// index line — the live demonstrator surfaced a duplicate whose lead
    /// stayed open). Optional for decode-compatibility with payloads
    /// written before #CPC-Change3; fall back to the singular ids.
    let subjectRecordIDs: [String]?
    let partnerRecordIDs: [String]?
    let canonicalKey: String
    let tier: String
    let anchorKind: String
    let anchorDetail: String?
    let earliestYear: Int
    let latestYear: Int
    let registrationLabel: String
    let district: String?

    init(from finding: SpousePairCorroborator.Finding) {
        self.edgeID = finding.edgeID
        self.subjectProfileID = finding.subjectProfileID
        self.partnerProfileID = finding.partnerProfileID
        self.subjectRecordID = finding.subjectRecordID
        self.partnerRecordID = finding.partnerRecordID
        self.subjectRecordIDs = finding.subjectCollapsedRecordIDs
        self.partnerRecordIDs = finding.partnerCollapsedRecordIDs
        self.canonicalKey = finding.canonicalKey
        self.tier = finding.tier.rawValue
        switch finding.anchor {
        case .strong(let d): self.anchorKind = "strong"; self.anchorDetail = d
        case .weak(let d): self.anchorKind = "weak"; self.anchorDetail = d
        case .none: self.anchorKind = "none"; self.anchorDetail = nil
        }
        self.earliestYear = finding.proposedEarliestYear
        self.latestYear = finding.proposedLatestYear
        self.registrationLabel = finding.registrationLabel
        self.district = finding.proposedLocation
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    static func decode(_ json: String?) -> CorroborationPayload? {
        guard let json, json != "{}", let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CorroborationPayload.self, from: data),
              payload.schema == "cpc-v1"
        else { return nil }
        return payload
    }
}

// MARK: - Sweep persistence helpers

nonisolated extension ProjectDatabase {

    /// Cheap pre-filter: marriage evidence row count for one profile.
    func marriageEvidenceCount(profileID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM evidence_records
                WHERE profile_id = ? AND record_type = 'marriage'
                """, arguments: [profileID]) ?? 0
        }
    }

    /// Still-pending corroboration facts (id + payload) for the staleness arm.
    func loadPendingCorroborationFactRows(
        agentID: String
    ) throws -> [(id: String, payloadJSON: String?)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, sources_json FROM pending_facts
                WHERE agent_id = ? AND review_status = 'pending'
                """, arguments: [agentID])
            return rows.map { (id: $0["id"] as String? ?? "", payloadJSON: $0["sources_json"] as String?) }
        }
    }

    /// Resolve the lead row backing a corroborated record: `.promoted` with
    /// resolution `.merged` (evidence attached to an existing profile — the
    /// `promoteLeadToProfile` matched-fork precedent). Returns true when a
    /// row actually transitioned; dismissed/promoted rows are left alone.
    @discardableResult
    func resolveCorroboratedLead(profileID: String, sourceRecordID: String) throws -> Bool {
        let leadID = "lead_\(sourceRecordID)"
        guard let lead = try loadLeads(profileID: profileID).first(where: { $0.id == leadID }),
              lead.status == .new || lead.status == .investigating || lead.status == .investigated
        else { return false }
        let resolved = Lead(
            id: lead.id, profileID: lead.profileID, name: lead.name,
            surname: lead.surname, givenName: lead.givenName,
            birthYear: lead.birthYear, deathYear: lead.deathYear,
            ageAtDeath: lead.ageAtDeath, place: lead.place,
            relationship: lead.relationship, source: lead.source,
            status: .promoted, evidence: lead.evidence,
            createdAt: lead.createdAt, investigatedAt: lead.investigatedAt,
            resolvedAt: Date(), resolution: .merged
        )
        try upsertLead(resolved)
        return true
    }

    /// Human-accept routing for a corroboration fact (spec Decision 5 +
    /// Change 2): resolve the spouse edge from the PAYLOAD, write through
    /// `fillRelationshipMarriage` (narrower-span policy inside), and resolve
    /// both sides' lead rows. Returns false when the payload doesn't decode
    /// — the caller falls back to nothing rather than writing blind.
    @discardableResult
    func applyCorroborationFact(field: String, payloadJSON: String?) throws -> Bool {
        guard let payload = CorroborationPayload.decode(payloadJSON),
              let edgeUUID = UUID(uuidString: payload.edgeID) else { return false }

        switch field {
        case "marriageDate":
            let date = GenealogicalDate(
                original: payload.registrationLabel,
                earliest: payload.earliestYear,
                latest: payload.latestYear,
                isApproximate: false,
                qualifier: .exact
            )
            _ = try fillRelationshipMarriage(
                relationshipID: edgeUUID, candidateDate: date,
                candidateLocation: payload.district
            )
        case "marriageLocation":
            _ = try fillRelationshipMarriage(
                relationshipID: edgeUUID, candidateDate: nil,
                candidateLocation: payload.district
            )
        default:
            return false
        }

        // Walk EVERY collapsed transcription variant's lead, not just the
        // representative's (pre-Change-3 payloads carry only the singular).
        for recordID in payload.subjectRecordIDs ?? [payload.subjectRecordID] {
            try resolveCorroboratedLead(
                profileID: payload.subjectProfileID, sourceRecordID: recordID)
        }
        for recordID in payload.partnerRecordIDs ?? [payload.partnerRecordID] {
            try resolveCorroboratedLead(
                profileID: payload.partnerProfileID, sourceRecordID: recordID)
        }
        return true
    }
}
