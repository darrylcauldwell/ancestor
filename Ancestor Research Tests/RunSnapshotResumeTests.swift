import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// ENGINE_FOUNDATION_SPEC §Change6 — checkpoint/resume hardening, acceptance
/// (6). The run queue (`research_run_requests`) IS the checkpoint: one row per
/// profile, walked queued → running → completed. A request left in `running`
/// by a dead process is orphaned today; `RunResumeCoordinator` reclaims it on
/// the next start so the run resumes at the exact (profile, source) it left
/// off. Resume is idempotent — reclaiming twice is a no-op, and the pipeline's
/// deterministic UPSERT writes mean a re-run emits no duplicate facts or leads.
///
/// The clock is injected, so the "6-hour wall-clock pause + restart" scenario
/// is a fixed-clock computation, not an actual wait.
struct RunSnapshotResumeTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// Insert a run-request row directly at a chosen status/started_at so we
    /// can model "was running when the process died".
    private func insertRequest(
        _ db: ProjectDatabase,
        id: String,
        profileID: String?,
        status: String,
        startedAt: Date?,
        createdAt: Date
    ) throws {
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO research_run_requests
                    (id, profile_id, lead_id, mode, scope, status, created_at, started_at, auto_accept, resume_count)
                VALUES (?, ?, NULL, 'extend', 'county', ?, ?, ?, 'none', 0)
                """, arguments: [id, profileID, status, createdAt, startedAt])
        }
    }

    private func status(_ db: ProjectDatabase, id: String) throws -> String {
        try db.dbQueue.read { dbConn in
            try String.fetchOne(dbConn, sql: "SELECT status FROM research_run_requests WHERE id = ?", arguments: [id])!
        }
    }
    private func resumeCount(_ db: ProjectDatabase, id: String) throws -> Int {
        try db.dbQueue.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT resume_count FROM research_run_requests WHERE id = ?", arguments: [id])!
        }
    }

    // MARK: - Reclaim after kill (criterion 6, part 1)

    @Test func killMidRunLeavesRunningRowReclaimableOnRestart() throws {
        let db = try makeTempDB()
        let started = Self.at("2026-07-12T02:00:00Z")
        try insertRequest(db, id: "req-A", profileID: "@P1@", status: "running",
                          startedAt: started, createdAt: started)

        // Restart happens "now" = 6 hours later. The row is well past the
        // stale threshold, so it reclaims back to queued and the watcher will
        // re-dispatch it. resume_count ticks to 1.
        let now = Self.at("2026-07-12T08:00:00Z")
        let coordinator = RunResumeCoordinator(staleThreshold: 30 * 60, now: { now })
        let reclaimed = coordinator.reclaimStaleRunning(db: db)

        #expect(reclaimed.count == 1)
        #expect(reclaimed.first?.requestID == "req-A")
        #expect(reclaimed.first?.profileID == "@P1@")
        #expect(reclaimed.first?.newResumeCount == 1)
        #expect(try status(db, id: "req-A") == "queued")
        #expect(try resumeCount(db, id: "req-A") == 1)
    }

    @Test func resumeStateMatchesPreKillProfileSet() throws {
        // Three profiles were mid-sweep: two still running, one already
        // completed. Restart must resume EXACTLY the two unfinished profiles,
        // never the completed one.
        let db = try makeTempDB()
        let old = Self.at("2026-07-12T01:00:00Z")
        try insertRequest(db, id: "req-1", profileID: "@P1@", status: "running", startedAt: old, createdAt: old)
        try insertRequest(db, id: "req-2", profileID: "@P2@", status: "running", startedAt: old, createdAt: old)
        try insertRequest(db, id: "req-3", profileID: "@P3@", status: "completed", startedAt: old, createdAt: old)

        let now = Self.at("2026-07-12T09:00:00Z")
        let coordinator = RunResumeCoordinator(staleThreshold: 30 * 60, now: { now })
        let reclaimed = coordinator.reclaimStaleRunning(db: db)

        let resumedProfiles = Set(reclaimed.compactMap(\.profileID))
        #expect(resumedProfiles == ["@P1@", "@P2@"])
        #expect(try status(db, id: "req-1") == "queued")
        #expect(try status(db, id: "req-2") == "queued")
        // The completed profile is untouched — resume never re-runs finished work.
        #expect(try status(db, id: "req-3") == "completed")
    }

    // MARK: - 6-hour pause via injected clock (criterion 6, part 2)

    @Test func sixHourPauseThenRestartResumes() throws {
        let db = try makeTempDB()
        let started = Self.at("2026-07-12T00:00:00Z")
        try insertRequest(db, id: "req-pause", profileID: "@P9@", status: "running",
                          startedAt: started, createdAt: started)

        // Inject a clock exactly 6 hours after the row started. No real wait.
        let sixHoursLater = started.addingTimeInterval(6 * 60 * 60)
        let coordinator = RunResumeCoordinator(staleThreshold: 30 * 60, now: { sixHoursLater })
        let reclaimed = coordinator.reclaimStaleRunning(db: db)
        #expect(reclaimed.count == 1)
        #expect(try status(db, id: "req-pause") == "queued")
    }

    @Test func freshlyRunningRowIsNotYankedFromLiveWatcher() throws {
        // A row that started 5 minutes ago (inside the stale threshold) is a
        // genuinely in-flight run — reclaim must NOT touch it, or two watchers
        // would fight over it.
        let db = try makeTempDB()
        let started = Self.at("2026-07-12T09:55:00Z")
        try insertRequest(db, id: "req-live", profileID: "@P0@", status: "running",
                          startedAt: started, createdAt: started)
        let now = Self.at("2026-07-12T10:00:00Z")  // only 5 min later
        let coordinator = RunResumeCoordinator(staleThreshold: 30 * 60, now: { now })
        let reclaimed = coordinator.reclaimStaleRunning(db: db)
        #expect(reclaimed.isEmpty)
        #expect(try status(db, id: "req-live") == "running")
    }

    // MARK: - Idempotency: resume twice is a no-op (criterion 6, part 3)

    @Test func reclaimingTwiceIsANoOp() throws {
        let db = try makeTempDB()
        let old = Self.at("2026-07-12T01:00:00Z")
        try insertRequest(db, id: "req-idem", profileID: "@P5@", status: "running", startedAt: old, createdAt: old)
        let now = Self.at("2026-07-12T09:00:00Z")
        let coordinator = RunResumeCoordinator(staleThreshold: 30 * 60, now: { now })

        let first = coordinator.reclaimStaleRunning(db: db)
        #expect(first.count == 1)
        #expect(try resumeCount(db, id: "req-idem") == 1)

        // Second reclaim immediately after: the row is now `queued`, not
        // `running`, so there is nothing to reclaim. resume_count stays at 1.
        let second = coordinator.reclaimStaleRunning(db: db)
        #expect(second.isEmpty)
        #expect(try status(db, id: "req-idem") == "queued")
        #expect(try resumeCount(db, id: "req-idem") == 1)
    }

    // MARK: - Data-layer idempotency proof: re-running a profile does not
    // duplicate evidence or leads (the property that makes resume safe).

    @Test func reSavingSameEvidenceUpsertsInPlaceNoDuplicates() throws {
        let db = try makeTempDB()
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, last_name, is_deleted)
                VALUES ('@P1@', '{}', 'Ernest', 'Cauldwell', 0)
                """)
        }
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(
                id: "freebmd:birth:ernest-1887",
                sourceID: "freebmd",
                name: nil,
                surname: "Cauldwell",
                givenName: "Ernest",
                detailURL: nil,
                rawFields: [:]
            ),
            birthYear: 1887,
            district: "Belper"
        ))
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "Ernest Cauldwell b.1887")

        // Save the same scored record twice — simulating a resumed re-run of
        // the same profile against the same source.
        try db.saveEvidence(profileID: "@P1@", scored: scored, citationFull: "FreeBMD", citationURL: nil)
        try db.saveEvidence(profileID: "@P1@", scored: scored, citationFull: "FreeBMD", citationURL: nil)

        let count = try db.dbQueue.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM evidence_records WHERE profile_id = '@P1@'")!
        }
        #expect(count == 1)  // UPSERT by (profileID, sourceRecordID) — no duplicate.
    }

    @MainActor
    @Test func reCreatingSameLeadUpsertsInPlaceNoDuplicates() async throws {
        let db = try makeTempDB()
        // In an async context GRDB resolves `write`/`read` to their async
        // overloads, so seed + count via a nonisolated sync helper.
        try Self.seedProfile(db, id: "@P1@")
        let member = HouseholdMember(name: "Sarah Cauldwell", relationship: "Wife", age: 30, birthYear: nil)
        let store = LeadStore(db: db)

        // Same household member, same census year, twice → deterministic id →
        // one lead row.
        _ = try await store.createFromHouseholdMember(member, profileID: "@P1@", censusYear: 1911)
        _ = try await store.createFromHouseholdMember(member, profileID: "@P1@", censusYear: 1911)

        let count = try Self.leadCount(db, profileID: "@P1@")
        #expect(count == 1)
    }

    /// Synchronous DB helpers — `nonisolated` + not `async`, so GRDB's sync
    /// `write`/`read` overloads resolve even when the caller is an async test.
    private nonisolated static func seedProfile(_ db: ProjectDatabase, id: String) throws {
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, last_name, is_deleted)
                VALUES (?, '{}', 'Ernest', 'Cauldwell', 0)
                """, arguments: [id])
        }
    }
    private nonisolated static func leadCount(_ db: ProjectDatabase, profileID: String) throws -> Int {
        try db.dbQueue.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM leads WHERE profile_id = ?", arguments: [profileID])!
        }
    }

    // MARK: - Human-readable queue snapshot (criterion 6, "debug a stuck run")

    @Test func queueSnapshotCountsByStatus() throws {
        let db = try makeTempDB()
        let t = Self.at("2026-07-12T08:00:00Z")
        try insertRequest(db, id: "q1", profileID: "@A@", status: "queued", startedAt: nil, createdAt: t)
        try insertRequest(db, id: "q2", profileID: "@B@", status: "queued", startedAt: nil, createdAt: t)
        try insertRequest(db, id: "r1", profileID: "@C@", status: "running", startedAt: t, createdAt: t)
        try insertRequest(db, id: "c1", profileID: "@D@", status: "completed", startedAt: t, createdAt: t)

        let now = Self.at("2026-07-12T08:10:00Z")
        let snap = RunResumeCoordinator(now: { now }).queueSnapshot(db: db)
        #expect(snap.queued == 2)
        #expect(snap.running == 1)
        #expect(snap.completed == 1)
        #expect(snap.failed == 0)
        // Oldest running row started 10 minutes ago.
        #expect(snap.oldestRunningAgeSeconds == 600)
    }
}
