import Foundation
import GRDB
import os

/// Materialises queued `user_hypothesis_seeds` rows (migration v32) into
/// `research_hypotheses` rows with `origin = .user`.
///
/// RESEARCH_PIPELINE_SPEC §5.15.2 (Decision E2): external surfaces never
/// write `research_hypotheses` directly — that table is engine-owned.
/// Intake mirrors the sanctioned `research_run_requests` orchestration
/// pattern: the MCP `submit_hypothesis` tool (phase a) and the future
/// Workbench "Add a hunch" form (phase b) INSERT seed rows; the app-side
/// request watcher (`RunRequestWatcher.pollOnce`) calls
/// `materialiseQueuedSeeds` to validate each and either upsert one typed
/// hypothesis row or refuse with a structured reason.
///
/// **Doctrine — a hunch is a search directive, never data.** Nothing here
/// touches `profiles`, `relationships`, `life_events`, or `citations`;
/// the only writes are the seed row's status flip and the
/// `research_hypotheses` upsert. The hypothesis stays invisible to the
/// tree until Slice 2's probes surface real records that survive the
/// standard scorer → cluster → accept path.
nonisolated enum HypothesisSeedService {

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "HypothesisSeedService"
    )

    /// Default marriage-window offsets relative to the subject's birth
    /// year — `subjectBirthYear − 30 … subjectBirthYear + 1`, mirroring
    /// `.parentMarriage` (§5.14.3 / §5.15.1).
    static let windowLowerOffset = -30
    static let windowUpperOffset = 1

    /// Structured refusal codes (§5.15.2). Raw values are persisted in
    /// `user_hypothesis_seeds.refusal_reason`.
    enum RefusalReason: String, Sendable, Equatable {
        /// All four name hints empty — the seed asserts nothing.
        case noNameHints = "no_name_hints"
        /// `profile_id` unknown (or soft-deleted since seeding).
        case profileNotFound = "profile_not_found"
        /// No derivable marriage window: subject has no usable
        /// birth-year estimate and the seed supplied no bounds.
        case noSubjectBirthEstimate = "no_subject_birth_estimate"
        /// The matching hypothesis row exists with `user_rejected = 1` —
        /// the user dismissed this exact hunch; re-seeding must be a
        /// deliberate un-reject, not a silent revival.
        case previouslyRejected = "previously_rejected"
        /// Defensive codes beyond §5.15.2's four: malformed external
        /// input must not reach the engine (§5.15.1) — and must not
        /// wedge the watcher either.
        case unsupportedKind = "unsupported_kind"
        case invalidPayload = "invalid_payload"
        /// Window bounds present but backwards (start > end). Same code
        /// the MCP tool's synchronous validation returns.
        case invalidWindow = "invalid_window"
    }

    /// JSON shape of `user_hypothesis_seeds.payload`. Written by the MCP
    /// `submit_hypothesis` tool; keys match the tool's parameter names.
    /// Hints record exactly what the user asserted — the effective
    /// window is resolved here at materialisation time, never persisted
    /// back into the seed.
    struct SeedPayload: Codable, Sendable {
        var fatherGiven: String?
        var fatherSurname: String?
        var motherGiven: String?
        var motherMaidenSurname: String?
        var marriageWindowStart: Int?
        var marriageWindowEnd: Int?

        enum CodingKeys: String, CodingKey {
            case fatherGiven = "father_given"
            case fatherSurname = "father_surname"
            case motherGiven = "mother_given"
            case motherMaidenSurname = "mother_maiden_surname"
            case marriageWindowStart = "marriage_window_start"
            case marriageWindowEnd = "marriage_window_end"
        }
    }

    /// Outcome of one seed's materialisation attempt.
    enum Outcome: Equatable, Sendable {
        case materialised(hypothesisID: String)
        case refused(RefusalReason)
    }

    // MARK: - Watcher entry point

    /// Process every queued seed. Called from the request watcher's poll
    /// loop; each seed is validated against *current* state (the tree may
    /// have changed between MCP-side synchronous validation and this
    /// materialisation) and either upserted as a `.parentCandidates`
    /// hypothesis with `origin = .user` or refused with a reason code.
    /// Returns the per-seed outcomes keyed by seed id (ordered oldest
    /// first) for logging; errors on one seed never block the rest.
    @discardableResult
    static func materialiseQueuedSeeds(db: ProjectDatabase) -> [(seedID: String, outcome: Outcome)] {
        let queued: [QueuedSeed]
        do {
            queued = try fetchQueuedSeeds(db: db)
        } catch {
            // Table missing (pre-v32 DB mid-migration) or read failure —
            // nothing to do this poll; the next poll retries.
            logger.error("Seed fetch failed: \(error.localizedDescription)")
            return []
        }
        guard !queued.isEmpty else { return [] }

        var outcomes: [(seedID: String, outcome: Outcome)] = []
        for seed in queued {
            do {
                let outcome = try materialise(seed: seed, db: db)
                outcomes.append((seed.id, outcome))
                switch outcome {
                case .materialised(let hid):
                    logger.info("Seed \(seed.id) materialised → hypothesis \(hid)")
                case .refused(let reason):
                    logger.info("Seed \(seed.id) refused: \(reason.rawValue)")
                }
            } catch {
                // Leave the seed queued; a transient write failure gets
                // retried on the next poll. Never silently swallowed.
                logger.error("Seed \(seed.id) materialisation error: \(error.localizedDescription)")
            }
        }
        return outcomes
    }

    // MARK: - Per-seed materialisation

    /// One `user_hypothesis_seeds` row as fetched for processing.
    struct QueuedSeed: Sendable {
        let id: String
        let profileID: String
        let kindDiscriminator: String
        let payloadJSON: String
        let requestedBy: String
    }

    private static func fetchQueuedSeeds(db: ProjectDatabase) throws -> [QueuedSeed] {
        try db.dbQueue.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id, profile_id, kind_discriminator, payload, requested_by
                FROM user_hypothesis_seeds
                WHERE status = 'queued'
                ORDER BY created_at ASC
                """).map { row in
                QueuedSeed(
                    id: row["id"],
                    profileID: row["profile_id"],
                    kindDiscriminator: row["kind_discriminator"],
                    payloadJSON: row["payload"],
                    requestedBy: row["requested_by"] ?? "mcp"
                )
            }
        }
    }

    /// Validate + materialise one seed. Validation order follows
    /// §5.15.2's listing: name hints, profile, window, rejection memory.
    static func materialise(seed: QueuedSeed, db: ProjectDatabase) throws -> Outcome {
        // Defensive gates first — this epic ships one kind only, and a
        // payload that doesn't parse can't be validated at all.
        guard seed.kindDiscriminator == "parentCandidates" else {
            return try refuse(seed: seed, reason: .unsupportedKind, db: db)
        }
        guard let data = seed.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SeedPayload.self, from: data) else {
            return try refuse(seed: seed, reason: .invalidPayload, db: db)
        }

        // Empty-after-trim hints are not assertions — normalise to nil so
        // the typed payload records exactly what the user claimed and the
        // identityKey stays deterministic across whitespace variants.
        let fatherGiven = normalised(payload.fatherGiven)
        let fatherSurname = normalised(payload.fatherSurname)
        let motherGiven = normalised(payload.motherGiven)
        let motherMaidenSurname = normalised(payload.motherMaidenSurname)

        // §5.15.2 rule 1 — at least one of the four name hints non-empty.
        guard fatherGiven != nil || fatherSurname != nil
                || motherGiven != nil || motherMaidenSurname != nil else {
            return try refuse(seed: seed, reason: .noNameHints, db: db)
        }

        // §5.15.2 rule 2 — profile must exist (loadProfile excludes
        // soft-deleted rows, so a profile deleted since seeding refuses).
        guard let profile = try db.loadProfile(id: seed.profileID) else {
            return try refuse(seed: seed, reason: .profileNotFound, db: db)
        }

        // §5.15.2 rule 3 — marriage window: user bounds win where given;
        // missing bounds default from the subject's birth-year estimate
        // (birthYear − 30 … birthYear + 1). No estimate and incomplete
        // bounds → underivable.
        let birthYearEstimate = profile.birthDate?.earliest ?? profile.birthDate?.latest
        let lower = payload.marriageWindowStart
            ?? birthYearEstimate.map { $0 + windowLowerOffset }
        let upper = payload.marriageWindowEnd
            ?? birthYearEstimate.map { $0 + windowUpperOffset }
        guard let lower, let upper else {
            return try refuse(seed: seed, reason: .noSubjectBirthEstimate, db: db)
        }
        guard lower <= upper else {
            return try refuse(seed: seed, reason: .invalidWindow, db: db)
        }

        let kind = HypothesisKind.parentCandidates(
            fatherGiven: fatherGiven,
            fatherSurname: fatherSurname,
            motherGiven: motherGiven,
            motherMaidenSurname: motherMaidenSurname,
            marriageWindow: lower...upper
        )
        let identityKey = kind.identityKey(subjectProfileID: seed.profileID)

        // §5.15.2 rule 4 — rejection memory: the user dismissed this
        // exact hunch; re-seeding must be a deliberate un-reject.
        let isRejected = try db.dbQueue.read { dbConn in
            try Int.fetchOne(dbConn, sql: """
                SELECT user_rejected FROM research_hypotheses WHERE id = ?
                """, arguments: [identityKey]) ?? 0
        }
        if isRejected != 0 {
            return try refuse(seed: seed, reason: .previouslyRejected, db: db)
        }

        // Materialise. Re-seeding identical hints collides on the
        // identityKey and upserts — no duplicate rows (§5.15.2). The
        // upsert preserves created_at, user_rejected, and origin.
        let now = Date()
        let hintSummary = [
            fatherGiven.map { "father given \"\($0)\"" },
            fatherSurname.map { "father surname \"\($0)\"" },
            motherGiven.map { "mother given \"\($0)\"" },
            motherMaidenSurname.map { "mother maiden surname \"\($0)\"" },
        ].compactMap(\.self).joined(separator: ", ")
        let hypothesis = ResearchHypothesis(
            id: identityKey,
            subjectProfileID: seed.profileID,
            kind: kind,
            origin: .user,
            verdict: .inconclusive,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "User-seeded hunch (via \(seed.requestedBy)): \(hintSummary); "
                + "marriage window \(lower)–\(upper). Not yet probed.",
            createdAt: now,
            lastTestedAt: now,
            attempts: 0,
            history: []
        )
        try db.upsertHypothesis(hypothesis)
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE user_hypothesis_seeds
                SET status = 'materialised', hypothesis_id = ?
                WHERE id = ?
                """, arguments: [identityKey, seed.id])
        }
        return .materialised(hypothesisID: identityKey)
    }

    // MARK: - Helpers

    /// Refusal writes the reason onto the seed row and nothing else —
    /// no hypothesis row, no tree data (§5.15.2: "refuse with a reason,
    /// write nothing").
    private static func refuse(
        seed: QueuedSeed,
        reason: RefusalReason,
        db: ProjectDatabase
    ) throws -> Outcome {
        try db.dbQueue.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE user_hypothesis_seeds
                SET status = 'refused', refusal_reason = ?
                WHERE id = ?
                """, arguments: [reason.rawValue, seed.id])
        }
        return .refused(reason)
    }

    private static func normalised(_ hint: String?) -> String? {
        guard let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
