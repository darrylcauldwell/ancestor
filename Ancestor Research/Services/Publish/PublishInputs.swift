import Foundation

// PUBLISHER_SPEC Change 4 — one assembly point for projection inputs,
// shared by the bundle exporter (Change 2) and the PublishEngine
// (Change 4) so the two surfaces can never drift.
nonisolated enum PublishInputs {

    /// Load everything the pure projection needs from one project DB.
    /// - Parameters:
    ///   - generation: the generation to stamp into the manifest — the
    ///     bundle exporter passes the CURRENT stored generation (read-only);
    ///     the publish engine passes current + 1 (it owns the bump).
    static func load(
        db: ProjectDatabase,
        now: Date,
        generation: Int
    ) throws -> (inputs: PublishedTree.Inputs, identity: PublishedIdentity) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let inputs = PublishedTree.Inputs(
            snapshot: try db.buildSnapshot(),
            lifeEvents: try db.loadAllLifeEvents(),
            attachments: try db.loadAttachments(),
            policies: try db.loadPublishPolicies(),
            mediaOptIns: try db.loadPublishMediaOptIns(),
            convergenceByProfile: [:],   // run envelopes don't carry convergence yet (spec §4.2: absent ⇒ omitted)
            rootProfileID: try db.loadProjectMeta()?.homePersonID,
            currentYear: calendar.component(.year, from: now),
            generation: generation,
            publishedAtISO: ISO8601DateFormatter().string(from: now)
        )
        let identity = PublishedIdentity(existing: try db.loadPublishedIdentityMap())
        return (inputs, identity)
    }
}
