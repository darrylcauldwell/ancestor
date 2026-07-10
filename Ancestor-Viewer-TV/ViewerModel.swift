import Foundation
import CloudKit
import AncestorKit
import AncestorViewerKit

/// App-level state for the viewer: account gate → scope probe → fetch →
/// cached tree. Renders from cache immediately when one exists
/// (render-before-refresh, PUBLISHER_SPEC §4.3), then refreshes.
///
/// Scope: the owner's Apple TV finds the tree in the PRIVATE database; a
/// family member's Apple TV finds it in the SHARED database after they
/// accept the invite once on iPhone/iPad (tvOS itself has no acceptance
/// UI — PUBLISHER_SPEC §2). The probe remembers what worked.
@Observable
@MainActor
final class ViewerModel {

    enum Phase: Equatable {
        case loading
        case noAccount
        case notPublished
        case failed(String)
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var manifests: [ManifestRow] = []
    private(set) var tree: ViewerTree?
    private(set) var isRefreshing = false
    private(set) var scope: ViewerDatabaseScope?

    private var store: ViewerStore?
    private var selectedManifestID: String?
    private static let scopeKey = "viewerDatabaseScope"

    func launch() async {
        guard store == nil else { return }

        #if DEBUG
        // Simulator visual verification without an iCloud account —
        // exercises the same SnapshotBuilder pipeline as a real fetch.
        if ProcessInfo.processInfo.environment["VIEWER_FIXTURE"] == "1" {
            loadFixture()
            return
        }
        #endif

        let container = CKContainer(identifier: ZoneFetcher.defaultContainerIdentifier)
        let status = try? await container.accountStatus()
        guard status == .available else {
            phase = .noAccount
            return
        }

        // Probe scopes, remembered-winner first. `treeNotFound` in one
        // scope is not a failure — the tree may live in the other.
        for candidate in scopeProbeOrder() {
            do {
                try configureStore(scope: candidate)
                if let store {
                    manifests = (try? await store.cachedManifests()) ?? []
                    if !manifests.isEmpty {
                        try await selectBestManifest()
                        phase = .ready
                    }
                }
                try await refresh()
                UserDefaults.standard.set(candidate.rawValue, forKey: Self.scopeKey)
                scope = candidate
                return
            } catch ViewerError.treeNotFound {
                store = nil
                continue
            } catch {
                // A failed refresh over a valid cache degrades to stale-
                // but-rendered; with no cache it is a real failure state.
                store = nil
                phase = tree == nil ? .failed(error.localizedDescription) : .ready
                return
            }
        }
        phase = tree == nil ? .notPublished : .ready
    }

    private func scopeProbeOrder() -> [ViewerDatabaseScope] {
        let saved = UserDefaults.standard.string(forKey: Self.scopeKey)
            .flatMap(ViewerDatabaseScope.init(rawValue:))
        switch saved {
        case .sharedDatabase: return [.sharedDatabase, .privateDatabase]
        default: return [.privateDatabase, .sharedDatabase]
        }
    }

    /// Per-scope cache files — switching audience never mixes replicas.
    private func configureStore(scope: ViewerDatabaseScope) throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PublishedTree-\(scope.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let fetcher = ZoneFetcher(
            scope: scope,
            assetDirectory: caches.appendingPathComponent("assets", isDirectory: true))
        let cache = try ViewerCache.open(at: caches.appendingPathComponent("cache.sqlite"))
        store = ViewerStore(fetcher: fetcher, cache: cache)
    }

    func refresh() async throws {
        guard let store, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        manifests = try await store.refresh()
        guard !manifests.isEmpty else {
            phase = tree == nil ? .notPublished : .ready
            return
        }
        try await selectBestManifest()
        phase = .ready
    }

    func select(manifestID: String) async {
        selectedManifestID = manifestID
        do {
            tree = try await store?.tree(manifestID: manifestID)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    private func loadFixture() {
        let manifest = ManifestRow(id: "FIX", generation: 1, rootPerson: "P1",
                                   personCount: 6, relationshipCount: 6,
                                   publishedAtISO: "2026-07-09T00:00:00Z")
        let persons = [
            PersonRow(id: "P1", manifestID: "FIX", displayName: "Ernest Cauldwell",
                      givenName: "Ernest", familyName: "Cauldwell", genderRaw: "male",
                      birthOriginal: "1887", birthEarliest: 1887, birthLatest: 1887,
                      birthQualifierRaw: "yearOnly", birthIsApproximate: false,
                      birthPlace: "Crich, Derbyshire",
                      deathOriginal: "1953", deathEarliest: 1953, deathLatest: 1953,
                      deathQualifierRaw: "yearOnly", deathIsApproximate: false,
                      deathPlace: "Belper, Derbyshire",
                      bioText: "Ernest Cauldwell was born in 1887 in Crich, Derbyshire. He worked as a framework knitter, appearing in the 1911 census at King Street with his wife Mary and their two children. He died in 1953 in Belper."),
            PersonRow(id: "P2", manifestID: "FIX", displayName: "Mary Cauldwell",
                      isRedacted: true),
            PersonRow(id: "P3", manifestID: "FIX", displayName: "George Cauldwell",
                      givenName: "George", familyName: "Cauldwell", genderRaw: "male",
                      birthOriginal: "ABT 1860", birthEarliest: 1855, birthLatest: 1865,
                      birthQualifierRaw: "about", birthIsApproximate: true,
                      birthPlace: "Wirksworth, Derbyshire",
                      bioText: "George Cauldwell was born about 1860 in Wirksworth."),
            PersonRow(id: "P4", manifestID: "FIX", displayName: "Hannah Cauldwell",
                      givenName: "Hannah", familyName: "Cauldwell", genderRaw: "female",
                      birthOriginal: "1862", birthEarliest: 1862, birthLatest: 1862,
                      birthQualifierRaw: "yearOnly", birthIsApproximate: false,
                      birthPlace: "Crich, Derbyshire"),
            PersonRow(id: "P5", manifestID: "FIX", displayName: "Helen Cauldwell",
                      givenName: "Helen", familyName: "Cauldwell", genderRaw: "female",
                      birthOriginal: "1912", birthEarliest: 1912, birthLatest: 1912,
                      birthQualifierRaw: "yearOnly", birthIsApproximate: false),
            PersonRow(id: "P6", manifestID: "FIX", displayName: "Albert Cauldwell",
                      givenName: "Albert", familyName: "Cauldwell", genderRaw: "male",
                      birthOriginal: "1889", birthEarliest: 1889, birthLatest: 1889,
                      birthQualifierRaw: "yearOnly", birthIsApproximate: false,
                      birthPlace: "Crich, Derbyshire")
        ]
        let relationships = [
            RelationshipRow(id: "R1", fromPersonID: "P1", toPersonID: "P2",
                            typeRaw: "spouse", subtypeRaw: "unknown",
                            marriageOriginal: "1911", marriageEarliest: 1911,
                            marriageLatest: 1911, marriageQualifierRaw: "yearOnly",
                            marriageIsApproximate: false, marriageLocation: "Belper"),
            RelationshipRow(id: "R2", fromPersonID: "P3", toPersonID: "P1",
                            typeRaw: "parent", roleRaw: "father", subtypeRaw: "biological"),
            RelationshipRow(id: "R3", fromPersonID: "P4", toPersonID: "P1",
                            typeRaw: "parent", roleRaw: "mother", subtypeRaw: "biological"),
            RelationshipRow(id: "R4", fromPersonID: "P1", toPersonID: "P5",
                            typeRaw: "parent", roleRaw: "father", subtypeRaw: "biological"),
            RelationshipRow(id: "R5", fromPersonID: "P3", toPersonID: "P6",
                            typeRaw: "parent", roleRaw: "father", subtypeRaw: "biological"),
            RelationshipRow(id: "R6", fromPersonID: "P4", toPersonID: "P6",
                            typeRaw: "parent", roleRaw: "mother", subtypeRaw: "biological")
        ]
        let events = [
            EventRow(id: "E1", personID: "P1", kindRaw: "census",
                     dateOriginal: "1911", dateEarliest: 1911, dateLatest: 1911,
                     dateQualifierRaw: "yearOnly", dateIsApproximate: false,
                     location: "King Street, Crich"),
            EventRow(id: "E2", personID: "P1", kindRaw: "occupation",
                     dateEarliest: 1905, dateLatest: 1911, location: "Crich")
        ]
        tree = SnapshotBuilder.build(
            manifest: manifest, persons: persons,
            relationships: relationships, events: events, media: [])
        manifests = [manifest]
        phase = .ready
    }
    #endif

    private func selectBestManifest() async throws {
        guard let store else { return }
        let current = selectedManifestID.flatMap { id in manifests.first { $0.id == id } }
        let chosen = current ?? manifests.max { $0.generation < $1.generation }
        guard let chosen else { return }
        selectedManifestID = chosen.id
        tree = try await store.tree(manifestID: chosen.id)
    }
}
