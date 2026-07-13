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
                for source in sources {
                    if let conflict = ConflictDetector.stringFieldConflict(
                        field: field, existing: canonical, existingSources: sources,
                        candidate: source.raw, candidateOrigin: source.origin,
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
            }

            // F4b — fact-grade marriage attestations whose record spouse
            // surname matches no spouse edge (retroactive arm of the
            // apply-time hook; "accepted" = fact-grade verdict).
            let spouseEdges = snapshot.relationships.filter {
                $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id)
            }
            let evidence = try db.loadEvidenceForProfile(profile.id)
            for row in evidence where row.verdict == .fact {
                guard case .marriage(let m) = row.record else { continue }
                let raw = (m.spouseName ?? "").trimmingCharacters(in: .whitespaces)
                guard let surname = raw.split(separator: " ").last.map(String.init)?.uppercased(),
                      !surname.isEmpty else { continue }
                let matchesEdge = spouseEdges.contains { edge in
                    let otherID = edge.from == profile.id ? edge.to : edge.from
                    return (snapshot.profiles[otherID]?.lastName ?? "").uppercased() == surname
                }
                if !matchesEdge {
                    conflicts.append(ConflictDetector.spouseIdentityConflict(
                        marriage: m, recordSpouseSurname: surname,
                        profileID: profile.id, spouseEdges: spouseEdges,
                        snapshot: snapshot, origin: SourceOrigin(identifier: row.sourceID),
                        detectedBy: .consistencySweep))
                }
            }

            for conflict in conflicts {
                let adjudication = DisputeResolver.adjudicate(conflict)
                _ = try db.upsertDispute(
                    profileID: profile.id, conflict: conflict,
                    adjudication: adjudication)
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

nonisolated extension ProjectDatabase {

    /// Attested field_sources rows for one (profile, field), oldest first.
    func fieldSources(profileID: String, field: ProfileField) throws -> [FieldSource] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT origin, raw, added_at FROM field_sources
                WHERE entity_id = ? AND entity_kind = 'profile' AND field = ?
                ORDER BY added_at ASC
                """, arguments: [profileID, field.rawValue])
            return rows.map { row in
                FieldSource(
                    origin: SourceOrigin(identifier: row["origin"] ?? "unknown"),
                    raw: row["raw"] ?? "",
                    addedAt: row["added_at"] ?? Date()
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
