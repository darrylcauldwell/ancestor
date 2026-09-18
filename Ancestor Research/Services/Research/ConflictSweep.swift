import Foundation
import GRDB
import AncestorKit

/// CONFLICT_LAYER_SPEC §4.4 T-C — the standing consistency sweep
/// (`detected_by = 'consistencySweep'`).
///
/// Runs `ConflictDetector` over every profile: attested field_sources vs
/// canonical values (F1/F2), death vs later-alive evidence (F3 — the
/// retroactive, order-independent arm DS-15 proved missing), same-year
/// census duplicates (T-D tree-state arm ⟨G13⟩), parent-role duplicates
/// (F4a), and fact-grade marriage attestations vs spouse edges (F4b).
///
/// Properties: idempotent (dispute upsert identity, §4.3 — a second run
/// adds zero rows), read-only except dispute rows, skippable via the
/// `project_meta.conflict_sweep_high_water` mark when the project is
/// unchanged since the last sweep.
nonisolated struct ConflictSweep {

    struct Report: Sendable, Equatable {
        var profilesScanned = 0
        var disputesTouched = 0
        var skippedUnchanged = false
    }

    /// Every surname a profile is known by, upper-cased. A marriage record names
    /// the wife's MAIDEN surname, but she may be stored under her married surname
    /// (WikiTree convention) with the maiden in `lastName`, `marriedSurname`, or a
    /// name form. Matching only `lastName` false-fires the F4b spouse-identity
    /// conflict on those (e.g. Nora Beresford m. Rose). Match against all.
    static func knownSurnames(of profile: Profile) -> Set<String> {
        var out: Set<String> = []
        let candidates = [profile.lastName, profile.marriedSurname]
            + profile.nameForms.map(\.surname)
        for candidate in candidates {
            let value = (candidate ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            if !value.isEmpty { out.insert(value) }
        }
        return out
    }

    /// Full sweep. `force` bypasses the high-water skip (manual "Scan for
    /// conflicts", post-apply batches).
    ///
    /// High-water approximation, stated honestly: the change signal is
    /// `MAX(transactions.started_at)` — every profile/edge write path runs
    /// through the transaction system, but a write that bypasses it (e.g.
    /// a bare life-event insert) would be missed; `force` (manual +
    /// post-apply trigger) is the correctness backstop.
    @discardableResult
    static func run(
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot,
        force: Bool = false
    ) throws -> Report {
        var report = Report()

        if !force,
           let highWater = try db.conflictSweepHighWater(),
           let latestChange = try db.latestWriteTransaction(),
           highWater >= latestChange {
            report.skippedUnchanged = true
            return report
        }

        // Review F03 (2026-08-26) — one query, not one per profile. See the
        // re-derivation arm below for why the sweep needs the APPROVED half of
        // the proposal queue at all. Deliberately NOT `try?`: swallowing this
        // read would leave the retraction pass unable to re-derive the re-role
        // shape, which is precisely the state that silently closed the dispute.
        let approvedRoleProposals = try db.approvedParentRoleProposals()
        let roleProposalsBySubject = Dictionary(
            grouping: approvedRoleProposals, by: \.toProfileID)

        for profile in snapshot.profiles.values {
            report.profilesScanned += 1
            let events = snapshot.lifeEvents[profile.id] ?? []
            var conflicts: [DetectedConflict] = []

            // F1 — every attested date value vs canonical + co-attestations.
            for (field, canonical) in [(ProfileField.birthDate, profile.birthDate),
                                       (ProfileField.deathDate, profile.deathDate)] {
                let sources = try db.fieldSources(profileID: profile.id, field: field)
                for source in sources {
                    let attested = GenealogicalDate(parsing: source.raw)
                    guard attested.earliest != nil else { continue }
                    if let conflict = ConflictDetector.dateFieldConflict(
                        field: field, existing: canonical, existingSources: sources,
                        candidate: attested, candidateOrigin: source.origin,
                        profileID: profile.id, detectedBy: .consistencySweep) {
                        conflicts.append(conflict)
                    }
                }
            }

            // F2 — every attested location value vs canonical + co-attestations.
            for (field, canonical) in [(ProfileField.birthLocation, profile.birthLocation),
                                       (ProfileField.deathLocation, profile.deathLocation)] {
                let sources = try db.fieldSources(profileID: profile.id, field: field)
                // EV9 (2026-08-26): the pending-facts accept path stores raw as
                // "<value> [<sourceTitle>]" (ProjectDatabase+PendingFactsReview)
                // while the profile column holds the bare value, so comparing the
                // stored raw against the column disputed a value with itself.
                for source in sources {
                    if let conflict = ConflictDetector.stringFieldConflict(
                        field: field, existing: canonical, existingSources: sources,
                        candidate: AppliedFactTarget.parseRaw(source.raw).value,
                        candidateOrigin: source.origin,
                        profileID: profile.id, detectedBy: .consistencySweep) {
                        conflicts.append(conflict)
                    }
                }
            }

            // F3 — death (or burial/probate event) vs later alive-evidence.
            if let conflict = ConflictDetector.deathVsLaterAliveConflict(
                profileID: profile.id, deathDate: profile.deathDate,
                lifeEvents: events, detectedBy: .consistencySweep) {
                conflicts.append(conflict)
            }

            // T-D tree-state arm ⟨G13⟩ — same-year census duplicates.
            conflicts.append(contentsOf: ConflictDetector.sameEnumerationYearConflicts(
                profileID: profile.id, lifeEvents: events, detectedBy: .consistencySweep))

            // F4a — parent roles occupied by more than one distinct profile.
            let duplicates = ConflictPredicates.duplicateBiologicalParentEdges(
                subjectID: profile.id, relationships: snapshot.relationships)
            for (role, edges) in duplicates.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                guard let first = edges.first,
                      let occupant = snapshot.profiles[first.from],
                      let second = edges.dropFirst().first else { continue }
                let rivalName = snapshot.profiles[second.from]?.displayName ?? second.from
                conflicts.append(ConflictDetector.parentRoleConflict(
                    subjectID: profile.id, role: role,
                    occupant: occupant, occupantEdge: first,
                    proposedParentDescription: rivalName,
                    proposedParentOrigin: SourceOrigin(identifier: "tree"),
                    evidenceRecordIDs: [],
                    detectedBy: .consistencySweep))

                // CL6 ⟨G10⟩⟨G11⟩ — the F4a dispute seeds an engine-origin
                // identity-candidate group: the incumbent edge enters WITH
                // its provenance (the tree is a witness too), alongside
                // each rival occupant. User-seeded .parentCandidates rows
                // are untouched (distinct kind, distinct identity keys).
                let candidates = edges.compactMap { edge -> (name: String, provenance: String)? in
                    guard let parent = snapshot.profiles[edge.from] else { return nil }
                    return (parent.displayName, "tree edge \(edge.id.uuidString.prefix(8))")
                }
                let seeds = HypothesisEngine.seedParentIdentityCandidates(
                    profileID: profile.id, role: role.rawValue,
                    candidateNames: candidates)
                try db.upsertHypotheses(seeds)
            }

            // EV27 / Review F03 (2026-08-26) — the RE-ROLE arm. When an
            // approved parent proposal re-roles an EXISTING edge (same parent,
            // same child, father↔mother), `approvePendingRelationship`
            // deliberately leaves the edge alone and records the disagreement
            // as a `.parentRole` dispute keyed `role:<parentID>`.
            //
            // The F4a arm above only ever emits `father`/`mother`, so that key
            // was never in `detected` — and the retraction pass at the bottom
            // of this loop closes every open structural dispute it cannot
            // re-derive. The very next sweep therefore auto-resolved the
            // dispute while the edge kept its old role and the proposal sat
            // marked approved: the disagreement EV27 exists to preserve was
            // destroyed by an unrelated background pass, with no record
            // anywhere and nothing left asking the human to re-role.
            //
            // Re-derived here rather than exempted from retraction, because
            // exemption would only swap the failure round: a dispute nothing
            // re-derives is also a dispute nothing can CLOSE, so re-rolling
            // the edge with the in-row Father/Mother menu — exactly what the
            // dispute's own reasoning tells the user to do — would leave a
            // permanent red banner over a tree that now agrees with itself.
            // Re-derivation keeps the reconcile running in both directions.
            for proposal in roleProposalsBySubject[profile.id] ?? [] {
                guard let proposed = ParentRole(rawValue: proposal.role),
                      proposed != .unspecified,
                      let edge = snapshot.relationships.first(where: {
                          $0.type == .parent
                              && $0.from == proposal.fromProfileID
                              && $0.to == profile.id
                      }),
                      let current = edge.role,
                      current != .unspecified, current != proposed,
                      let occupant = snapshot.profiles[proposal.fromProfileID]
                else { continue }
                // Identity and competing-source RAWS reproduced verbatim from
                // `ProjectDatabase.recordParentRoleDispute`, so a re-derivation
                // JOINS the open row as a no-op (§4.3 upsert identity) instead
                // of appending a duplicate witness on every sweep.
                conflicts.append(ConflictDetector.parentRoleReassignmentConflict(
                    subjectID: profile.id, currentRole: current,
                    occupant: occupant, occupantEdge: edge,
                    proposedDescription:
                        "same parent re-roled \(current.rawValue) → \(proposed.rawValue)",
                    proposedOrigin: SourceOrigin(
                        identifier: "relationship-proposal.\(proposal.id.prefix(12))"),
                    detectedBy: .consistencySweep))
            }

            // F4b — fact-grade marriage attestations whose record spouse
            // surname matches no spouse edge (retroactive arm of the
            // apply-time hook; "accepted" = fact-grade verdict).
            let spouseEdges = snapshot.relationships.filter {
                $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id)
            }
            // User-discarded evidence must not drive conflict detection —
            // otherwise removing/discarding a record leaves its dispute
            // resurrectable by every force sweep (the F4b/F5 arms previously
            // filtered on verdict alone).
            let evidence = try db.loadEvidenceForProfile(profile.id)
                .filter { $0.userStatus != .discarded }

            // F5 (CL4) — same-witness transcription disagreements among
            // fact-grade evidence records.
            let factRecords = evidence.filter { $0.verdict == .fact }.map(\.record)
            conflicts.append(contentsOf: ConflictDetector.sameWitnessDisagreements(
                profileID: profile.id, records: factRecords,
                detectedBy: .consistencySweep))

            // F4b's contradiction is only meaningful when a spouse edge EXISTS to
            // contradict. With no spouse recorded, "matches no spouse edge" is
            // trivially true for EVERY marriage record, so a person with several
            // namesake marriage candidates (and no applied spouse) collected one
            // red spouseIdentity conflict per candidate — a Conflicts banner on a
            // profile that has no marriage at all. Those competing candidates are
            // an unresolved identity to discriminate in Triage, not a conflict.
            // (Owner report 2026-08-05: Mary E Land — four "Mary/Mary E Land"
            // marriage leads in Belper, no spouse edge.)
            if !spouseEdges.isEmpty {
                for row in evidence where row.verdict == .fact {
                    guard case .marriage(let m) = row.record else { continue }
                    let raw = (m.spouseName ?? "").trimmingCharacters(in: .whitespaces)
                    guard let surname = raw.split(separator: " ").last.map(String.init)?.uppercased(),
                          !surname.isEmpty else { continue }
                    let matchesEdge = spouseEdges.contains { edge in
                        let otherID = edge.from == profile.id ? edge.to : edge.from
                        guard let spouse = snapshot.profiles[otherID] else { return false }
                        return Self.knownSurnames(of: spouse).contains(surname)
                    }
                    if !matchesEdge {
                        conflicts.append(ConflictDetector.spouseIdentityConflict(
                            marriage: m, recordSpouseSurname: surname,
                            profileID: profile.id, spouseEdges: spouseEdges,
                            snapshot: snapshot, origin: SourceOrigin(identifier: row.sourceID),
                            detectedBy: .consistencySweep))
                    }
                }
            }

            for conflict in conflicts {
                let adjudication = DisputeResolver.adjudicate(conflict)
                _ = try db.upsertDispute(
                    profileID: profile.id, conflict: conflict,
                    adjudication: adjudication)
                report.disputesTouched += 1
            }

            // Retraction (idempotent reconciliation): a STRUCTURAL dispute the
            // sweep re-derives from current tree state but no longer detects has
            // been fixed (e.g. a spouse's maiden name now matches the marriage
            // record) — close it. Without this the sweep is add-only, so a stale
            // apply-time dispute survives every re-scan. Untouched rows only
            // (`resolution IS NULL`); a user's explicit decision/defer is never
            // overwritten. fieldValue disputes are left alone — their competing
            // values persist in field_sources until the user picks one.
            let detected = Set(conflicts.map { "\($0.kind.rawValue)|\($0.field)" })
            for open in (try? db.openDisputes(profileID: profile.id)) ?? [] {
                switch open.kind {
                case .spouseIdentity, .parentRole, .timeline: break
                case .fieldValue: continue
                }
                guard !detected.contains("\(open.kind.rawValue)|\(open.field)") else { continue }
                try db.resolveStructuralDispute(
                    profileID: profile.id, kind: open.kind, fieldKey: open.field,
                    resolution: .manual("auto-resolved — no longer detected on re-scan"))
                report.disputesTouched += 1
            }
        }

        try db.setConflictSweepHighWater(Date())
        return report
    }

    /// One-shot v41 backfill (§4.4): existing trees get their latent
    /// contradictions surfaced on first launch after the migration.
    /// Patterned on `reconcileProfileDateFields` — runs exactly once,
    /// guarded by `project_meta.v41_conflict_backfill_done`.
    @discardableResult
    static func backfillIfNeeded(
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot
    ) throws -> Report? {
        guard try !db.conflictBackfillDone() else { return nil }
        let report = try run(db: db, snapshot: snapshot, force: true)
        try db.markConflictBackfillDone()
        return report
    }
}

// MARK: - Sweep persistence helpers

/// One APPROVED `pending_relationships` parent proposal that names a role —
/// the input `ConflictSweep` needs to re-derive EV27's role-reassignment
/// dispute (Review F03, 2026-08-26).
nonisolated struct ApprovedParentRoleProposal: Sendable, Equatable {
    let id: String
    /// The proposed PARENT — the `from` side of the parent edge, and the
    /// second half of the dispute's `role:<parentID>` field key.
    let fromProfileID: String
    /// The CHILD — the profile the dispute is filed against.
    let toProfileID: String
    /// Raw `pending_relationships.role`; parsed by the caller so an
    /// unparseable value is skipped exactly as `approvePendingRelationship`
    /// skips it (it coerces to `.unspecified`, which writes no dispute).
    let role: String
}

nonisolated extension ProjectDatabase {

    /// Approved parent proposals that name a real role, oldest first.
    /// Read-only — the Evidence Firewall's write rules are untouched.
    func approvedParentRoleProposals() throws -> [ApprovedParentRoleProposal] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, from_profile_id, to_profile_id, role
                FROM pending_relationships
                WHERE review_status = 'approved'
                  AND rel_type = 'parent'
                  AND role IS NOT NULL
                  AND role NOT IN ('', 'unspecified')
                ORDER BY created_at ASC
                """)
            return rows.map { row in
                ApprovedParentRoleProposal(
                    id: row["id"] ?? "",
                    fromProfileID: row["from_profile_id"] ?? "",
                    toProfileID: row["to_profile_id"] ?? "",
                    role: row["role"] ?? "")
            }
        }
    }

    /// Attested field_sources rows for one (profile, field), oldest first.
    /// Carries each row's stored `Citation` (repository/collection/page/url)
    /// when the apply path recorded one — the provenance the resolution UI
    /// shows so two same-source rows are distinguishable.
    func fieldSources(profileID: String, field: ProfileField) throws -> [FieldSource] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT origin, raw, added_at, citation_json, evidence_quality, fact_confidence
                FROM field_sources
                WHERE entity_id = ? AND entity_kind = 'profile' AND field = ?
                ORDER BY added_at ASC
                """, arguments: [profileID, field.rawValue])
            return rows.map { row in
                var citation: Citation?
                if let json: String = row["citation_json"], let data = json.data(using: .utf8) {
                    citation = try? JSONDecoder().decode(Citation.self, from: data)
                }
                return FieldSource(
                    origin: SourceOrigin(identifier: row["origin"] ?? "unknown"),
                    raw: row["raw"] ?? "",
                    addedAt: row["added_at"] ?? Date(),
                    citation: citation,
                    quality: (row["evidence_quality"] as Int?).flatMap(EvidenceQuality.init(rawValue:)),
                    confidence: (row["fact_confidence"] as Int?).flatMap(FactConfidence.init(rawInt:))
                )
            }
        }
    }

    func conflictSweepHighWater() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT conflict_sweep_high_water FROM project_meta LIMIT 1")
        }
    }

    func setConflictSweepHighWater(_ date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE project_meta SET conflict_sweep_high_water = ?",
                           arguments: [date])
        }
    }

    func latestWriteTransaction() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(started_at) FROM transactions")
        }
    }

    func conflictBackfillDone() throws -> Bool {
        try dbQueue.read { db in
            let flag = try String.fetchOne(
                db, sql: "SELECT v41_conflict_backfill_done FROM project_meta LIMIT 1")
            return flag == "done"
        }
    }

    func markConflictBackfillDone() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE project_meta SET v41_conflict_backfill_done = 'done'")
        }
    }
}
