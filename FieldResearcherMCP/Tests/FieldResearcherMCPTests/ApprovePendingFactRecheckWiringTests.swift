import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// Integration tests for the actual wiring point (ENGINE_FOUNDATION #Change8):
/// `approve_pending_fact` → §14.3 gate → **§14.B.1 hallucination re-check** →
/// commit. Uses a live (temp) SQLite fixture + on-disk page-cache so the whole
/// path runs end-to-end.
///
/// Serialized because `approve_pending_fact` reads the process-global
/// `ANCESTOR_MCP_AUTO_APPROVE` env var, which these tests flip.
@Suite(.serialized)
struct ApprovePendingFactRecheckWiringTests {

    // MARK: - Fixture

    /// A temp project laid out like the app's sandbox so
    /// `CachingPageProvider.cacheDirectory(forProjectDBPath:)` resolves the
    /// page-cache as a sibling of `AncestorResearch/projects/`.
    struct Fixture {
        let root: URL
        let dbPath: String
        let pageCacheDir: URL

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c8-recheck-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let projects = appSupport.appendingPathComponent("AncestorResearch/projects", isDirectory: true)
        let pageCache = appSupport.appendingPathComponent("dev.dreamfold.Ancestor-Research/page-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pageCache, withIntermediateDirectories: true)

        let dbPath = projects.appendingPathComponent("test.sqlite").path
        try seedSchema(dbPath: dbPath)
        return Fixture(root: root, dbPath: dbPath, pageCacheDir: pageCache)
    }

    /// Minimal schema the approve/commit path touches, plus a seeded
    /// pending_fact whose §14.3 gate PASSES (birthDate = auto-approvable,
    /// freebmd = trusted host, one corroborating field_source from a different
    /// lineage → convergence ≥ 2). So the re-check is the deciding gate.
    private func seedSchema(dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            // Handler init only requires a `leads` table to exist.
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, status TEXT, resolved_at DATETIME, resolution TEXT)")

            try db.execute(sql: """
                CREATE TABLE profiles (
                    id TEXT PRIMARY KEY,
                    first_name TEXT,
                    last_name TEXT,
                    birth_date_original TEXT,
                    birth_date_earliest INTEGER,
                    birth_date_latest INTEGER,
                    death_date_original TEXT,
                    birth_location TEXT
                )
                """)
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P1','Ernest','Cauldwell')")

            try db.execute(sql: """
                CREATE TABLE field_sources (
                    entity_id TEXT, entity_kind TEXT, field TEXT,
                    origin TEXT, raw TEXT, added_at DATETIME
                )
                """)
            // Corroborating source from a DIFFERENT lineage (GRO) so the
            // pending fact's own lineage (freebmd) makes 2 independent lineages.
            try db.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at)
                VALUES ('P1','profile','birthDate','import','1887 [GRO Index]', ?)
                """, arguments: [Date()])

            try db.execute(sql: """
                CREATE TABLE pending_facts (
                    id TEXT PRIMARY KEY,
                    profile_id TEXT,
                    fact_kind TEXT,
                    value_json TEXT,
                    sources_json TEXT,
                    review_status TEXT,
                    created_at DATETIME,
                    source_url TEXT,
                    source_title TEXT,
                    evidence_text TEXT,
                    reasoning TEXT,
                    agent_id TEXT,
                    verification_status TEXT,
                    reviewed_at DATETIME,
                    approval_method TEXT,
                    approval_rule_ids TEXT,
                    approved_at DATETIME
                )
                """)
        }
    }

    private func insertPendingFact(dbPath: String, value: String, evidence: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO pending_facts
                (id, profile_id, fact_kind, value_json, review_status, created_at,
                 source_url, source_title, evidence_text, reasoning, agent_id, verification_status)
                VALUES ('PF1','P1','birthDate', ?, 'pending', ?,
                        'https://www.freebmd.org.uk/cgi/search.pl', 'FreeBMD GRO',
                        ?, 'test', 'field-researcher', 'pending')
                """, arguments: [value, Date(), evidence])
        }
    }

    /// Write a page into the cache under the exact key the app uses.
    private func seedCachePage(fixture: Fixture, url: String, html: String) throws {
        let key = EvidenceMatch.idempotencyKey(profileID: "", field: "", value: "", sourceURL: url)
        let file = fixture.pageCacheDir.appendingPathComponent("\(key).html")
        try html.data(using: .utf8)!.write(to: file)
    }

    private func readStatus(dbPath: String) throws -> (review: String, hasFieldSource: Bool) {
        let queue = try DatabaseQueue(path: dbPath)
        return try queue.read { db in
            let review: String = try String.fetchOne(db, sql: "SELECT review_status FROM pending_facts WHERE id='PF1'") ?? ""
            let n: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM field_sources WHERE entity_id='P1' AND raw LIKE '%FreeBMD GRO%'") ?? 0
            return (review, n > 0)
        }
    }

    private func decode(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func withAutoApprove(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let key = "ANCESTOR_MCP_AUTO_APPROVE"
        let prior = ProcessInfo.processInfo.environment[key]
        if on { setenv(key, "1", 1) } else { unsetenv(key) }
        defer {
            if let prior { setenv(key, prior, 1) } else { unsetenv(key) }
        }
        try await body()
    }

    // MARK: - Real claim → §14.3 passes AND re-check confirms → COMMITS

    @Test func realClaimApprovesAndCommits() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try insertPendingFact(dbPath: fx.dbPath, value: "1887", evidence: "Ernest Cauldwell born 1887")
        try seedCachePage(
            fixture: fx,
            url: "https://www.freebmd.org.uk/cgi/search.pl",
            html: "<html>Registration index: Ernest Cauldwell born 1887 in Belper.</html>"
        )

        try await withAutoApprove(true) {
            let handler = try MCPHandler(dbPath: fx.dbPath)
            let text = try await handler.approvePendingFactResponseText(["pending_fact_id": "PF1"])
            let obj = decode(text)
            #expect(obj["status"] as? String == "approved")
            #expect(obj["hallucination_recheck"] as? String == "approved")

            let (review, hasFS) = try readStatus(dbPath: fx.dbPath)
            #expect(review == "accepted")     // committed
            #expect(hasFS)                     // field_source written
        }
    }

    // MARK: - Planted hallucination → §14.3 passes but re-check BOUNCES → stays pending

    @Test func plantedHallucinationBouncesAndStaysPending() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        // Fact claims 1887, but the cached page says 1901 — a fabrication.
        try insertPendingFact(dbPath: fx.dbPath, value: "1887", evidence: "Ernest Cauldwell born")
        try seedCachePage(
            fixture: fx,
            url: "https://www.freebmd.org.uk/cgi/search.pl",
            html: "<html>Registration index: Ernest Cauldwell born 1901 in Belper.</html>"
        )

        try await withAutoApprove(true) {
            let handler = try MCPHandler(dbPath: fx.dbPath)
            let text = try await handler.approvePendingFactResponseText(["pending_fact_id": "PF1"])
            let obj = decode(text)
            #expect(obj["status"] as? String == "refused")
            #expect(obj["reason"] as? String == "hallucination_recheck_failed")
            #expect(obj["hallucination_flag"] as? String == "claim_not_on_page")
            #expect(obj["still_pending"] as? Bool == true)

            let (review, hasFS) = try readStatus(dbPath: fx.dbPath)
            #expect(review == "pending")       // NOT committed — still pending
            #expect(!hasFS)                     // no field_source written
        }
    }

    // MARK: - Cache-miss → conservative bounce (no page in cache) → stays pending

    @Test func cacheMissBouncesAndStaysPending() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try insertPendingFact(dbPath: fx.dbPath, value: "1887", evidence: "Ernest Cauldwell born 1887")
        // Deliberately DO NOT seed the cache page.

        try await withAutoApprove(true) {
            let handler = try MCPHandler(dbPath: fx.dbPath)
            let text = try await handler.approvePendingFactResponseText(["pending_fact_id": "PF1"])
            let obj = decode(text)
            #expect(obj["status"] as? String == "refused")
            #expect(obj["reason"] as? String == "hallucination_recheck_failed")
            #expect(obj["hallucination_flag"] as? String == "page_not_cached")

            let (review, _) = try readStatus(dbPath: fx.dbPath)
            #expect(review == "pending")
        }
    }

    // MARK: - Env unset → auto-approval stays REFUSED (default off, unchanged)

    @Test func autoApproveStaysRefusedWhenEnvUnset() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try insertPendingFact(dbPath: fx.dbPath, value: "1887", evidence: "Ernest Cauldwell born 1887")
        try seedCachePage(
            fixture: fx,
            url: "https://www.freebmd.org.uk/cgi/search.pl",
            html: "<html>Ernest Cauldwell born 1887.</html>"
        )

        try await withAutoApprove(false) {
            #expect(!MCPHandler.isAutoApprovalEnabled())
            let handler = try MCPHandler(dbPath: fx.dbPath)
            let text = try await handler.approvePendingFactResponseText(["pending_fact_id": "PF1"])
            let obj = decode(text)
            #expect(obj["status"] as? String == "refused")
            #expect(obj["reason"] as? String == "auto_approval_gate_disabled")

            let (review, _) = try readStatus(dbPath: fx.dbPath)
            #expect(review == "pending")       // untouched
        }
    }
}
