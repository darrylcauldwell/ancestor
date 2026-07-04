import Testing
import Foundation
import CloudKit
import GRDB
import AncestorKit
@testable import Ancestor_Research

// PUBLISHER_SPEC Change 4 acceptance — LIVE end-to-end against the
// CloudKit development environment, using a FIXTURE tree (never a real
// project). Env-gated like the Change 3 spike:
//   env TEST_RUNNER_RUN_PUBLISH_E2E=1 xcodebuild test ... -parallel-testing-enabled NO
// Each run uses a fresh project UUID = fresh zone, so runs never collide;
// dev-environment zones are disposable (reset-schema wipes them).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_PUBLISH_E2E"] == "1"))
struct PublishEngineE2ETests {

    @Test func publishThenDeltaRepublish() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ProjectDatabase(path: dir.appendingPathComponent("p.sqlite").path)
        let projectID = UUID()

        let george = Profile(
            id: "@G@", externalIDs: [:], firstName: "George", lastName: "Brooks",
            gender: .male,
            birthDate: GenealogicalDate(parsing: "1883"), birthLocation: "Belper",
            deathDate: GenealogicalDate(parsing: "1946"), deathLocation: "Derby",
            isDeleted: false, sources: [:], disputes: [:])
        let ida = Profile(
            id: "@I@", externalIDs: [:], firstName: "Ida", lastName: "Land",
            gender: .female,
            birthDate: GenealogicalDate(parsing: "1888"), birthLocation: "Belper",
            deathDate: GenealogicalDate(parsing: "1970"), deathLocation: "Belper",
            isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(george, source: SourceOrigin(identifier: "gedcom"))
        _ = try db.addProfile(ida, source: SourceOrigin(identifier: "gedcom"))
        _ = try db.addRelationship(Relationship(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            from: "@G@", to: "@I@", type: .spouse, role: nil, subtype: .biological,
            marriageDate: GenealogicalDate(parsing: "1912"),
            marriageLocation: "Belper", divorceDate: nil))

        // Publish 1 — everything new.
        let first = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            progress: { print("E2E publish 1: \($0)") })
        #expect(first.generation == 1)
        #expect(first.stats.inserted == 4 && first.ackedRecords == first.totalRecords)
        print("E2E PASS 1 — generation 1, \(first.ackedRecords)/\(first.totalRecords) acked")

        // Publish 2 — one field changed; only the person + manifest move.
        _ = try db.editProfile(
            profileID: "@G@",
            changes: [(field: .birthLocation, oldValue: "Belper", newValue: "Duffield")],
            dateChanges: [],
            source: SourceOrigin(identifier: "manual"))
        let second = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            progress: { print("E2E publish 2: \($0)") })
        #expect(second.generation == 2, "generation strictly monotonic")
        #expect(second.stats.updated == 2 && second.stats.inserted == 0 && second.stats.deleted == 0,
                "delta republish touches only the changed person + manifest")
        #expect(second.stats.unchanged == 2)
        print("E2E PASS 2 — generation 2, delta of \(second.stats.updated) updates only")

        // Publish 3 — no changes at all: nothing moves but the manifest
        // (its publishedAtISO/generation), proving no-op cheapness.
        let third = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            progress: { _ in })
        #expect(third.generation == 3)
        #expect(third.stats.updated == 1 && third.stats.unchanged == 3,
                "idle republish moves only the manifest row")
        print("E2E PASS 3 — idle republish is manifest-only traffic")
    }
}
