import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the registry + manifest data-layer contract from spec §3.1 and
/// §3.3 — JSON shape, source_id derivation with collision suffixes,
/// atomic load/save semantics, and per-corpus manifest round-trip.
///
/// All tests target a fresh temp directory so the suite leaves no trace
/// in Application Support and tests can't poison each other.
struct ProseCorpusRegistryTests {

    // MARK: - Test helpers

    private func makeTempRegistry() -> (ProseCorpusRegistry, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-registry-tests-\(UUID().uuidString)", isDirectory: true)
        return (ProseCorpusRegistry(baseDirectory: tmp), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - source_id derivation (spec §3.3)

    @Test func deriveSourceIDStripsWWWPrefix() {
        let url = URL(string: "http://www.wirksworth.org.uk/")!
        #expect(ProseCorpusRegistry.deriveSourceID(from: url) == "wirksworth-org-uk")
    }

    @Test func deriveSourceIDIncludesFirstPathSegment() {
        let url = URL(string: "http://www.wirksworth.org.uk/PEDIGREE.htm")!
        // Path segment lowercased and sanitised; "." stays since it's in
        // the allow-set, but the leading hyphen between host and path
        // is the join character.
        #expect(ProseCorpusRegistry.deriveSourceID(from: url) == "wirksworth-org-uk-pedigree.htm")
    }

    @Test func deriveSourceIDHandlesBareHost() {
        let url = URL(string: "http://example.com")!
        #expect(ProseCorpusRegistry.deriveSourceID(from: url) == "example-com")
    }

    @Test func deriveSourceIDIsDeterministic() {
        let url = URL(string: "http://www.example.org/sub/path")!
        let a = ProseCorpusRegistry.deriveSourceID(from: url)
        let b = ProseCorpusRegistry.deriveSourceID(from: url)
        #expect(a == b)
    }

    @Test func deriveSourceIDSanitisesNonASCII() {
        // Hostnames are ASCII (IDN punycoded), but the path may contain
        // spaces or unicode. We replace anything outside [a-z0-9.-] with
        // a hyphen so the result is filesystem-safe.
        let url = URL(string: "http://example.com/some%20path")!
        let id = ProseCorpusRegistry.deriveSourceID(from: url)
        #expect(id.contains("example-com"))
        // No literal percent signs in the slug.
        #expect(!id.contains("%"))
    }

    // MARK: - availableSourceID + collision suffixes

    @Test func availableSourceIDReturnsBaseWhenUnique() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        let url = URL(string: "http://www.example.com/")!
        let id = try registry.availableSourceID(for: url)
        #expect(id == "example-com")
    }

    @Test func availableSourceIDAppendsCollisionSuffix() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        let url = URL(string: "http://www.example.com/")!
        let firstID = try registry.availableSourceID(for: url)
        try registry.add(ProseCorpusRegistryEntry(
            sourceID: firstID,
            displayTitle: "Example",
            addedAt: Date()
        ))

        // Second add of same URL should get "-2".
        let secondID = try registry.availableSourceID(for: url)
        #expect(secondID == "example-com-2")
        try registry.add(ProseCorpusRegistryEntry(
            sourceID: secondID,
            displayTitle: "Example 2",
            addedAt: Date()
        ))

        let thirdID = try registry.availableSourceID(for: url)
        #expect(thirdID == "example-com-3")
    }

    // MARK: - Load/save round-trip

    @Test func loadReturnsEmptyDocumentWhenFileMissing() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        let doc = try registry.load()
        #expect(doc.corpora.isEmpty)
        #expect(doc.schemaVersion == 1)
    }

    @Test func saveAndLoadRoundTrips() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        let entry = ProseCorpusRegistryEntry(
            sourceID: "wirksworth-org-uk",
            displayTitle: "Wirksworth Parish Records 1600-1900",
            addedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let doc = ProseCorpusRegistryDocument(schemaVersion: 1, corpora: [entry])
        try registry.save(doc)

        let reloaded = try registry.load()
        #expect(reloaded == doc)
    }

    @Test func loadRejectsUnsupportedSchemaVersion() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        // Hand-write a future-schema registry to disk.
        try FileManager.default.createDirectory(at: registry.corporaDirectory, withIntermediateDirectories: true)
        let body = """
        { "schema_version": 99, "corpora": [] }
        """
        try Data(body.utf8).write(to: registry.registryURL)

        var threw = false
        do {
            _ = try registry.load()
        } catch ProseCorpusRegistry.RegistryError.unsupportedSchemaVersion(let v) {
            threw = true
            #expect(v == 99)
        }
        #expect(threw)
    }

    // MARK: - Add / Remove

    @Test func addAppendsToRegistry() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        let entry = ProseCorpusRegistryEntry(
            sourceID: "example-com",
            displayTitle: "Example",
            addedAt: Date()
        )
        let doc = try registry.add(entry)
        #expect(doc.corpora.count == 1)
        #expect(doc.corpora.first?.sourceID == "example-com")
    }

    @Test func addRejectsDuplicateSourceID() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        let entry = ProseCorpusRegistryEntry(
            sourceID: "example-com",
            displayTitle: "Example",
            addedAt: Date()
        )
        try registry.add(entry)
        var threw = false
        do {
            try registry.add(entry)
        } catch ProseCorpusRegistry.RegistryError.duplicateSourceID(let id) {
            threw = true
            #expect(id == "example-com")
        }
        #expect(threw)
    }

    @Test func removeDeletesEntry() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        try registry.add(ProseCorpusRegistryEntry(
            sourceID: "a",
            displayTitle: "A",
            addedAt: Date()
        ))
        try registry.add(ProseCorpusRegistryEntry(
            sourceID: "b",
            displayTitle: "B",
            addedAt: Date()
        ))
        let after = try registry.remove(sourceID: "a")
        #expect(after.corpora.count == 1)
        #expect(after.corpora.first?.sourceID == "b")
    }

    @Test func removeIsIdempotentForUnknownSourceID() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        try registry.add(ProseCorpusRegistryEntry(
            sourceID: "a",
            displayTitle: "A",
            addedAt: Date()
        ))
        let after = try registry.remove(sourceID: "does-not-exist")
        #expect(after.corpora.count == 1)
    }

    @Test func removeCorpusDirectoryDeletesTree() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        // Stand up a fake corpus directory under the registry's base.
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: "to-be-removed")
        _ = try storage.writePage(
            sourceURL: "http://example.com/p",
            title: "P",
            body: "Body."
        )
        #expect(FileManager.default.fileExists(atPath: storage.corpusDirectory.path))

        try registry.removeCorpusDirectory(sourceID: "to-be-removed")
        #expect(!FileManager.default.fileExists(atPath: storage.corpusDirectory.path))
    }

    // MARK: - JSON shape matches spec §3.3

    @Test func registryJSONUsesSnakeCaseKeys() throws {
        let (registry, tmp) = makeTempRegistry()
        defer { cleanup(tmp) }

        try registry.add(ProseCorpusRegistryEntry(
            sourceID: "example-com",
            displayTitle: "Example",
            addedAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))
        let raw = try String(contentsOf: registry.registryURL, encoding: .utf8)
        #expect(raw.contains("\"schema_version\""))
        #expect(raw.contains("\"source_id\""))
        #expect(raw.contains("\"display_title\""))
        #expect(raw.contains("\"added_at\""))
    }

    // MARK: - Manifest I/O on ProseCorpusStorage

    @Test func manifestRoundTripsThroughStorage() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: "wirksworth")

        let manifest = ProseCorpusManifest(
            sourceID: "wirksworth",
            displayTitle: "Wirksworth Parish Records 1600-1900",
            seedURL: URL(string: "http://www.wirksworth.org.uk/PEDIGREE.htm")!,
            addedByUserAt: Date(timeIntervalSince1970: 1_750_000_000),
            schemaVersion: 1,
            crawlerVersion: "1.0.0",
            crawlDepth: 4,
            linkFilter: nil,
            pageBudget: 10_000,
            firstBuiltAt: Date(timeIntervalSince1970: 1_750_001_000),
            lastSyncedAt: Date(timeIntervalSince1970: 1_750_010_000),
            pageCount: 2187,
            totalBytes: 31_285_194,
            robotsTxtURL: URL(string: "http://www.wirksworth.org.uk/robots.txt")!,
            robotsTxtFetchedAt: Date(timeIntervalSince1970: 1_750_000_500),
            userAgent: "AncestorResearch/1.0"
        )
        try storage.writeManifest(manifest)

        let reloaded = try storage.readManifest()
        #expect(reloaded == manifest)
    }

    @Test func readManifestReturnsNilWhenMissing() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: "never-built")

        let result = try storage.readManifest()
        #expect(result == nil)
    }

    @Test func manifestJSONUsesSnakeCaseKeys() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: "test")

        let manifest = ProseCorpusManifest(
            sourceID: "test",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com")!,
            addedByUserAt: Date(timeIntervalSince1970: 1_750_000_000),
            schemaVersion: 1,
            crawlerVersion: "1.0.0",
            crawlDepth: 4,
            linkFilter: "glob:*.htm",
            pageBudget: 100,
            firstBuiltAt: nil,
            lastSyncedAt: nil,
            pageCount: 0,
            totalBytes: 0,
            robotsTxtURL: URL(string: "http://example.com/robots.txt")!,
            robotsTxtFetchedAt: nil,
            userAgent: "AR/1"
        )
        try storage.writeManifest(manifest)
        let raw = try String(contentsOf: storage.manifestURL, encoding: .utf8)
        // Spec §3.1 calls out these exact keys.
        for key in [
            "\"source_id\"",
            "\"display_title\"",
            "\"seed_url\"",
            "\"added_by_user_at\"",
            "\"schema_version\"",
            "\"crawler_version\"",
            "\"crawl_depth\"",
            "\"link_filter\"",
            "\"page_budget\"",
            "\"page_count\"",
            "\"total_bytes\"",
            "\"robots_txt_url\"",
            "\"user_agent\"",
        ] {
            #expect(raw.contains(key), "Expected snake_case key \(key) in manifest JSON")
        }
    }
}
