import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// RESEARCH_PIPELINE_SPEC §5.15.2 Slice 1 — seed intake validation and
/// watcher materialisation. `HypothesisSeedService.materialiseQueuedSeeds`
/// is the app-side half of Decision E2: external surfaces write only the
/// v32 `user_hypothesis_seeds` staging table; the watcher validates each
/// queued seed and either upserts one `research_hypotheses` row with
/// `origin = .user` or refuses with a structured reason code.
///
/// Doctrine pin: a seeded hypothesis is invisible to the tree — the
/// materialisation writes touch `user_hypothesis_seeds` and
/// `research_hypotheses` only, never `profiles` / `relationships` /
/// `life_events` / `citations`.
@MainActor
struct HypothesisSeedServiceTests {

    // MARK: - Fixtures

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func insertProfile(
        id: String,
        birthDate: String? = "1887",
        into db: ProjectDatabase
    ) throws {
        let profile = Profile(
            id: id, externalIDs: [:],
            firstName: "George", lastName: "Wheeldon", gender: .male,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
    }

    @discardableResult
    private func insertSeed(
        id: String = "seed_1",
        profileID: String = "p1",
        kindDiscriminator: String = "parentCandidates",
        payload: [String: Any],
        into db: ProjectDatabase
    ) throws -> String {
        let json = String(
            data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8
        )!
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO user_hypothesis_seeds
                (id, profile_id, kind_discriminator, payload, requested_by, created_at)
                VALUES (?, ?, ?, ?, 'mcp', ?)
                """, arguments: [id, profileID, kindDiscriminator, json, Date()])
        }
        return id
    }

    private func seedRow(id: String, db: ProjectDatabase) throws -> Row? {
        try db.dbQueue.read { dbConn in
            try Row.fetchOne(dbConn, sql: """
                SELECT * FROM user_hypothesis_seeds WHERE id = ?
                """, arguments: [id])
        }
    }

    private func hypothesisCount(db: ProjectDatabase) throws -> Int {
        try db.dbQueue.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM research_hypotheses") ?? -1
        }
    }

    // MARK: - Materialisation (acceptance criterion 1)

    @Test func wellFormedSeedMaterialisesUserOriginHypothesis() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        try insertSeed(payload: ["father_given": "Bob", "mother_given": "Sue"], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.count == 1)
        guard case .materialised(let hypothesisID) = outcomes.first?.outcome else {
            Issue.record("expected materialised, got \(String(describing: outcomes.first))")
            return
        }
        // Default window mirrors .parentMarriage: 1887 − 30 … 1887 + 1.
        #expect(hypothesisID == "parentCandidates:p1:BOBxxSUEx:1857-1888")

        let h = try #require(try db.loadHypothesis(id: hypothesisID))
        #expect(h.origin == .user)
        #expect(h.kind.discriminator == "parentCandidates")
        #expect(h.verdict == .inconclusive)
        #expect(h.attempts == 0)
        #expect(h.isModelAssisted == false)
        #expect(h.subjectProfileID == "p1")
        guard case .parentCandidates(let fg, let fs, let mg, let mms, let window) = h.kind else {
            Issue.record("expected parentCandidates kind")
            return
        }
        // Payload holds exactly what was asserted — nothing defaulted in.
        #expect(fg == "Bob")
        #expect(fs == nil)
        #expect(mg == "Sue")
        #expect(mms == nil)
        #expect(window == 1857...1888)

        // Seed row flipped to materialised and linked to the hypothesis.
        let seed = try #require(try seedRow(id: "seed_1", db: db))
        #expect(seed["status"] == "materialised")
        #expect(seed["hypothesis_id"] == hypothesisID)
        #expect((seed["refusal_reason"] as String?) == nil)
    }

    @Test func suppliedWindowBoundsOverrideDerivedDefaults() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        try insertSeed(payload: [
            "mother_maiden_surname": "Smith",
            "marriage_window_start": 1860,
            "marriage_window_end": 1870,
        ], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)
        guard case .materialised(let id) = outcomes.first?.outcome else {
            Issue.record("expected materialised")
            return
        }
        #expect(id == "parentCandidates:p1:xxxSMITH:1860-1870")
    }

    @Test func explicitWindowWorksWithoutBirthEstimate() throws {
        // A window supplied by the user makes the birth estimate unnecessary.
        let db = try makeTempDB()
        try insertProfile(id: "p1", birthDate: nil, into: db)
        try insertSeed(payload: [
            "father_surname": "Wheeldon",
            "marriage_window_start": 1850,
            "marriage_window_end": 1880,
        ], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)
        guard case .materialised(let id) = outcomes.first?.outcome else {
            Issue.record("expected materialised")
            return
        }
        #expect(id == "parentCandidates:p1:xWHEELDONxx:1850-1880")
    }

    // MARK: - Upsert dedup (acceptance criterion 2)

    @Test func reseedingIdenticalHintsUpsertsNoDuplicates() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        let payload: [String: Any] = ["father_given": "Bob", "mother_given": "Sue"]

        try insertSeed(id: "seed_1", payload: payload, into: db)
        HypothesisSeedService.materialiseQueuedSeeds(db: db)
        try insertSeed(id: "seed_2", payload: payload, into: db)
        let second = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        guard case .materialised = second.first?.outcome else {
            Issue.record("re-seed should materialise (upsert), not refuse")
            return
        }
        #expect(try hypothesisCount(db: db) == 1)
        let seed2 = try #require(try seedRow(id: "seed_2", db: db))
        #expect(seed2["status"] == "materialised")
    }

    // MARK: - Refusals (§5.15.2; acceptance criterion 3)

    @Test func allEmptyHintsRefusedWithNoNameHints() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        // Whitespace-only hints are not assertions.
        try insertSeed(payload: ["father_given": "  ", "mother_given": ""], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.first?.outcome == .refused(.noNameHints))
        #expect(try hypothesisCount(db: db) == 0)
        let seed = try #require(try seedRow(id: "seed_1", db: db))
        #expect(seed["status"] == "refused")
        #expect(seed["refusal_reason"] == "no_name_hints")
    }

    @Test func softDeletedProfileRefusedWithProfileNotFound() throws {
        // The FK guarantees the profile row existed at seeding time; a
        // soft-delete between seeding and materialisation is the
        // profile_not_found case the watcher can actually hit.
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        try insertSeed(payload: ["father_given": "Bob"], into: db)
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: "UPDATE profiles SET is_deleted = 1 WHERE id = 'p1'")
        }

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.first?.outcome == .refused(.profileNotFound))
        #expect(try hypothesisCount(db: db) == 0)
    }

    @Test func noBirthEstimateAndNoWindowRefused() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", birthDate: nil, into: db)
        try insertSeed(payload: ["father_given": "Bob"], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.first?.outcome == .refused(.noSubjectBirthEstimate))
        #expect(try hypothesisCount(db: db) == 0)
    }

    @Test func previouslyRejectedHunchRefusesReseed() throws {
        // §5.15.2: re-seeding a dismissed hunch must be a deliberate
        // un-reject, not a silent revival.
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        let payload: [String: Any] = ["father_given": "Bob", "mother_given": "Sue"]
        try insertSeed(id: "seed_1", payload: payload, into: db)
        let first = HypothesisSeedService.materialiseQueuedSeeds(db: db)
        guard case .materialised(let hypothesisID) = first.first?.outcome else {
            Issue.record("setup materialisation failed")
            return
        }
        try db.rejectHypothesis(id: hypothesisID)

        try insertSeed(id: "seed_2", payload: payload, into: db)
        let second = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(second.first?.outcome == .refused(.previouslyRejected))
        let seed2 = try #require(try seedRow(id: "seed_2", db: db))
        #expect(seed2["status"] == "refused")
        #expect(seed2["refusal_reason"] == "previously_rejected")
        // The rejected row itself is untouched — still rejected.
        let stillRejected = try db.dbQueue.read { dbConn in
            try Int.fetchOne(dbConn, sql: """
                SELECT user_rejected FROM research_hypotheses WHERE id = ?
                """, arguments: [hypothesisID])
        }
        #expect(stillRejected == 1)
    }

    @Test func unsupportedKindRefused() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        try insertSeed(kindDiscriminator: "burialAtParish",
                       payload: ["father_given": "Bob"], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.first?.outcome == .refused(.unsupportedKind))
        #expect(try hypothesisCount(db: db) == 0)
    }

    @Test func malformedPayloadRefusedNotCrashed() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO user_hypothesis_seeds
                (id, profile_id, kind_discriminator, payload, requested_by, created_at)
                VALUES ('seed_1', 'p1', 'parentCandidates', 'not json at all', 'mcp', ?)
                """, arguments: [Date()])
        }

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.first?.outcome == .refused(.invalidPayload))
        #expect(try hypothesisCount(db: db) == 0)
    }

    @Test func backwardsWindowRefused() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        try insertSeed(payload: [
            "father_given": "Bob",
            "marriage_window_start": 1900,
            "marriage_window_end": 1850,
        ], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.first?.outcome == .refused(.invalidWindow))
        #expect(try hypothesisCount(db: db) == 0)
    }

    // MARK: - Doctrine pin (§5.15 opening block; acceptance criterion 7 scope)

    @Test func materialisationWritesNothingToTheTree() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)

        func treeCounts() throws -> [Int] {
            try db.dbQueue.read { dbConn in
                // Citations live as citation_json on field_sources in this
                // schema, so the field_sources count covers §5.15.5's
                // "citations". pending_facts + leads pin doctrine item 3:
                // a hunch is not evidence and must not enter those pipes.
                try [
                    Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM profiles") ?? -1,
                    Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM relationships") ?? -1,
                    Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM life_events") ?? -1,
                    Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM field_sources") ?? -1,
                    Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM pending_facts") ?? -1,
                    Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM leads") ?? -1,
                ]
            }
        }

        let before = try treeCounts()
        try insertSeed(payload: [
            "father_given": "Bob", "father_surname": "Wheeldon",
            "mother_given": "Sue", "mother_maiden_surname": "Smith",
        ], into: db)
        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)
        let after = try treeCounts()

        guard case .materialised = outcomes.first?.outcome else {
            Issue.record("expected materialised")
            return
        }
        #expect(before == after, "a hunch is a search directive, never data")
    }

    // MARK: - Batch behaviour

    @Test func oneRefusedSeedDoesNotBlockOthers() throws {
        let db = try makeTempDB()
        try insertProfile(id: "p1", into: db)
        try insertSeed(id: "seed_bad", payload: [:], into: db)   // no hints
        try insertSeed(id: "seed_good", payload: ["mother_given": "Sue"], into: db)

        let outcomes = HypothesisSeedService.materialiseQueuedSeeds(db: db)

        #expect(outcomes.count == 2)
        #expect(outcomes.first { $0.seedID == "seed_bad" }?.outcome == .refused(.noNameHints))
        guard case .materialised = outcomes.first(where: { $0.seedID == "seed_good" })?.outcome else {
            Issue.record("good seed should materialise despite bad sibling")
            return
        }
        #expect(try hypothesisCount(db: db) == 1)
    }
}
