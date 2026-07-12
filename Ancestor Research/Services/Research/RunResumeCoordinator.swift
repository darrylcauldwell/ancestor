import Foundation
import GRDB
import os

/// Checkpoint/resume hardening for sustained runs (ENGINE_FOUNDATION
/// #Change6).
///
/// The run queue (`research_run_requests`) is the checkpoint: each profile is
/// one row, walked `queued → running → completed/failed`. The `RunRequestWatcher`
/// only ever dequeues `queued` rows, so a request that was `running` when the
/// process died — an overnight budget pause that outlived the app, a crash, a
/// force-quit — is orphaned: never re-dispatched, never completed. A
/// multi-day run would silently drop every profile it happened to be mid-way
/// through at each restart.
///
/// This coordinator closes that hole. On startup it RECLAIMS stale `running`
/// rows back to `queued` so the watcher resumes them from the exact
/// `(profile, source)` checkpoint. Resume is idempotent by construction:
///
///   - Only `running` rows older than `staleThreshold` are reclaimed.
///     `completed` / `failed` / `queued` rows are never touched, so resuming
///     twice cannot re-run finished work — the second pass finds nothing to
///     reclaim (a genuine no-op).
///   - The pipeline's own writes are deterministic and UPSERT: evidence is
///     keyed by `(profileID, sourceRecordID)` and leads by a stable derived
///     id, so even a fully re-run reclaimed request re-writes the same rows
///     in place — no double-fact emission, no duplicate leads.
///   - `resume_count` / `resumed_at` make each reclaim observable for
///     debugging a stuck run (the human-readable snapshot requirement).
///
/// The clock is injected so the "6-hour wall-clock pause then resume"
/// acceptance test drives a fixed `now` instead of actually waiting.
nonisolated struct RunResumeCoordinator: Sendable {
    /// How long a row may sit in `running` before it's presumed orphaned by a
    /// dead process and eligible for reclaim. Long enough that a genuinely
    /// slow in-flight run (a FreeBMD circuit-breaker walk is ~21 min) is never
    /// yanked out from under a live watcher, short enough that a restart after
    /// an overnight pause reclaims promptly.
    let staleThreshold: TimeInterval

    /// Injected clock. Tests pass a fixed `now`; production uses `Date()`.
    let now: @Sendable () -> Date

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "RunResume")

    init(staleThreshold: TimeInterval = 30 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.staleThreshold = staleThreshold
        self.now = now
    }

    /// One reclaimed request — returned so the caller (and tests) can see
    /// exactly which `(profile, source)` checkpoints were resumed.
    nonisolated struct Reclaimed: Sendable, Equatable {
        let requestID: String
        let profileID: String?
        let leadID: String?
        let newResumeCount: Int
    }

    /// Reclaim every stale `running` request back to `queued`. Runs in ONE
    /// write transaction so a concurrent watcher can't observe a half-reclaimed
    /// queue. Idempotent: calling it again immediately reclaims nothing (the
    /// rows are now `queued`, not `running`), which is the resume-twice-is-a-
    /// no-op property. Returns the reclaimed rows, most-recently-started first.
    @discardableResult
    func reclaimStaleRunning(db: ProjectDatabase) -> [Reclaimed] {
        let cutoff = now().addingTimeInterval(-staleThreshold)
        let reclaimed: [Reclaimed] = (try? db.dbQueue.write { dbConn -> [Reclaimed] in
            // Find stale running rows first so we can report + stamp them.
            // `started_at IS NULL` guards a malformed row (running with no
            // start stamp) — treat it as stale too, it can never complete on
            // its own.
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT id, profile_id, lead_id, resume_count
                FROM research_run_requests
                WHERE status = 'running'
                  AND (started_at IS NULL OR started_at <= ?)
                ORDER BY started_at DESC
                """, arguments: [cutoff])

            var out: [Reclaimed] = []
            for row in rows {
                let id: String = row["id"]
                let priorCount: Int = row["resume_count"] ?? 0
                let newCount = priorCount + 1
                // Flip back to queued so the watcher re-dispatches it, and
                // stamp the reclaim. `run_id`/`completed_at` are left as they
                // were (still NULL for an unfinished run); the WHERE re-guards
                // status so a row that raced to `completed` between the SELECT
                // and here is not clobbered.
                try dbConn.execute(sql: """
                    UPDATE research_run_requests
                    SET status = 'queued',
                        started_at = NULL,
                        resume_count = ?,
                        resumed_at = ?
                    WHERE id = ? AND status = 'running'
                    """, arguments: [newCount, self.now(), id])
                out.append(Reclaimed(
                    requestID: id,
                    profileID: row["profile_id"],
                    leadID: row["lead_id"],
                    newResumeCount: newCount
                ))
            }
            return out
        }) ?? []

        if !reclaimed.isEmpty {
            Self.logger.info("Resume: reclaimed \(reclaimed.count) orphaned running request(s) → queued")
        }
        return reclaimed
    }

    /// A human-readable snapshot of the run queue for debugging a stuck run
    /// (#Change6 "snapshot is human-readable enough to debug"). Counts by
    /// status plus the oldest still-running row's age, so an operator can tell
    /// at a glance whether a run is progressing, parked, or wedged.
    func queueSnapshot(db: ProjectDatabase) -> QueueSnapshot {
        let counts: [String: Int] = (try? db.dbQueue.read { dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT status, COUNT(*) AS n
                FROM research_run_requests
                GROUP BY status
                """)
            var m: [String: Int] = [:]
            for row in rows { m[row["status"] as String] = row["n"] as Int }
            return m
        }) ?? [:]

        let oldestRunningAge: TimeInterval? = try? db.dbQueue.read { dbConn in
            let started: Date? = try Date.fetchOne(dbConn, sql: """
                SELECT MIN(started_at) FROM research_run_requests WHERE status = 'running'
                """)
            return started.map { self.now().timeIntervalSince($0) }
        } ?? nil

        return QueueSnapshot(
            queued: counts["queued"] ?? 0,
            running: counts["running"] ?? 0,
            completed: counts["completed"] ?? 0,
            failed: counts["failed"] ?? 0,
            oldestRunningAgeSeconds: oldestRunningAge
        )
    }

    /// Human-readable run-queue state for debugging.
    nonisolated struct QueueSnapshot: Sendable, Equatable {
        let queued: Int
        let running: Int
        let completed: Int
        let failed: Int
        let oldestRunningAgeSeconds: TimeInterval?

        /// One-line description for a log or a debug panel.
        var description: String {
            var s = "run queue — queued:\(queued) running:\(running) completed:\(completed) failed:\(failed)"
            if let age = oldestRunningAgeSeconds {
                s += " oldest-running:\(Int(age))s"
            }
            return s
        }
    }
}
