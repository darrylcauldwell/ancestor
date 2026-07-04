import Foundation

// PUBLISHER_SPEC Change 2 — Export Family Bundle. The offline artifact:
// the §4 published schema as JSON files plus copied media, produced by
// the same projection (and the same permanent record UUIDs) the CloudKit
// publisher will use, so viewer code prototyped against bundles works
// unchanged against zones. Deliberately does NOT touch published_state
// or publish_meta — the first CloudKit publish must still see every
// record as new.

nonisolated struct FamilyBundleSummary: Sendable {
    let bundleURL: URL
    let personCount: Int
    let relationshipCount: Int
    let eventCount: Int
    let mediaCopied: Int
    /// Attachments that were opted in but whose file was missing on disk —
    /// surfaced to the user, never silently dropped.
    let missingMediaPaths: [String]
}

nonisolated enum FamilyBundleExportError: Error, LocalizedError {
    case destinationExists(URL)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let url):
            return "A file or folder already exists at \(url.path). Choose a different location."
        }
    }
}

nonisolated enum FamilyBundleExporter {

    /// Export the redaction-filtered bundle for one project.
    /// - Parameters:
    ///   - now: injected so tests get byte-identical re-exports; the UI
    ///     passes the current date.
    static func export(
        db: ProjectDatabase,
        mediaSourceDirectory: URL,
        to bundleDirectory: URL,
        now: Date
    ) throws -> FamilyBundleSummary {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleDirectory.path) {
            throw FamilyBundleExportError.destinationExists(bundleDirectory)
        }

        // Assemble projection inputs from canonical + publisher tables.
        let snapshot = try db.buildSnapshot()
        let project = try db.loadProjectMeta()
        var identity = PublishedIdentity(existing: try db.loadPublishedIdentityMap())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let inputs = PublishedTree.Inputs(
            snapshot: snapshot,
            lifeEvents: try db.loadAllLifeEvents(),
            attachments: try db.loadAttachments(),
            policies: try db.loadPublishPolicies(),
            mediaOptIns: try db.loadPublishMediaOptIns(),
            convergenceByProfile: [:],   // wired when run envelopes carry convergence (Change 4/6)
            rootProfileID: project?.homePersonID,
            currentYear: calendar.component(.year, from: now),
            generation: try db.loadPublishGeneration(),
            publishedAtISO: ISO8601DateFormatter().string(from: now)
        )
        let tree = PublishedTree.project(inputs, identity: &identity)

        // Write the bundle. Deterministic bytes: sortedKeys + stable
        // projection ordering means re-export with the same `now` is
        // byte-identical (Change 2 acceptance).
        try fm.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(tree.manifest).write(to: bundleDirectory.appendingPathComponent("manifest.json"))
        try encoder.encode(tree.persons).write(to: bundleDirectory.appendingPathComponent("people.json"))
        try encoder.encode(tree.relationships).write(to: bundleDirectory.appendingPathComponent("relationships.json"))
        try encoder.encode(tree.events).write(to: bundleDirectory.appendingPathComponent("events.json"))
        try encoder.encode(tree.media).write(to: bundleDirectory.appendingPathComponent("media.json"))

        var copied = 0
        var missing: [String] = []
        if !tree.media.isEmpty {
            let mediaDir = bundleDirectory.appendingPathComponent("media", isDirectory: true)
            try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            for item in tree.media {
                let source = mediaSourceDirectory.appendingPathComponent(item.relativePath)
                let target = mediaDir.appendingPathComponent(item.relativePath)
                guard fm.fileExists(atPath: source.path) else {
                    missing.append(item.relativePath)
                    continue
                }
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                copied += 1
            }
        }

        // Persist minted identities so the CloudKit publish (and every
        // future export) reuses them — §4.1 permanence.
        try db.savePublishedIDs(identity.minted)

        return FamilyBundleSummary(
            bundleURL: bundleDirectory,
            personCount: tree.persons.count,
            relationshipCount: tree.relationships.count,
            eventCount: tree.events.count,
            mediaCopied: copied,
            missingMediaPaths: missing
        )
    }
}
