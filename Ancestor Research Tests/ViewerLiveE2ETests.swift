import Testing
import Foundation
import AncestorKit
import AncestorViewerKit

// PHASE4_VIEWER_SPEC Change 1 acceptance — live fetch of the REAL
// published zone from the CloudKit development environment (which holds
// the generation-3 real-tree publish). Env-gated like the publisher E2Es:
//
//   env TEST_RUNNER_RUN_VIEWER_E2E=1 xcodebuild test \
//     -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research Tests" \
//     -destination "platform=macOS" -skipMacroValidation \
//     -parallel-testing-enabled NO \
//     -only-testing:"Ancestor Research Tests/ViewerLiveE2ETests"
//
// Unlike the publisher suites there is no sqlite-data mock to defeat —
// ZoneFetcher talks to CKContainer directly, so a run is live by
// construction. Requires this Mac's iCloud account (the tree owner).
struct ViewerLiveE2ETests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_VIEWER_E2E"] == "1"
    }

    @Test(.enabled(if: enabled)) func fetchRenderAndIncrementalRefreshAgainstDevZone() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let fetcher = ZoneFetcher(
            scope: .privateDatabase,
            assetDirectory: workDir.appendingPathComponent("assets"))
        let cache = try ViewerCache.open(at: workDir.appendingPathComponent("cache.sqlite"))
        let store = ViewerStore(fetcher: fetcher, cache: cache)

        // 1. Cold fetch — full zone into the cache.
        let manifests = try await store.refresh()
        #expect(!manifests.isEmpty, "published zone should hold at least one manifest")
        let manifest = try #require(manifests.max { $0.generation < $1.generation })
        #expect(manifest.generation >= 1)

        // 2. Build the renderable tree; counts must reconcile with the
        //    manifest (§4.3 — personCount is the completeness check).
        let tree = try await store.tree(manifestID: manifest.id)
        #expect(tree.snapshot.profiles.count == manifest.personCount)
        #expect(tree.snapshot.relationships.count == manifest.relationshipCount)
        #expect(tree.schemaExceedsSupported == false)

        // The root person exists and traverses.
        if let root = manifest.rootPerson {
            #expect(tree.snapshot.profiles[root] != nil)
        }

        // Redaction contract holds on real data: redacted persons carry
        // no vitals, no bio.
        for (id, notes) in tree.annotations where notes.isRedacted {
            let profile = try #require(tree.snapshot.profiles[id])
            #expect(profile.birthDate == nil)
            #expect(profile.deathDate == nil)
            #expect(profile.bio == nil)
        }

        // 3. Incremental refresh — nothing changed server-side, so the
        //    change token must make this a cheap no-op that leaves the
        //    cache intact.
        let again = try await store.refresh()
        #expect(again.count == manifests.count)
        let treeAgain = try await store.tree(manifestID: manifest.id)
        #expect(treeAgain.snapshot.profiles.count == tree.snapshot.profiles.count)
    }
}
