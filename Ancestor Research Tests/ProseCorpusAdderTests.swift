import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the add-corpus orchestrator from spec §6.2 (verification) and
/// §3 (registry + manifest writes). Tests the two halves separately —
/// `verify(...)` against a `FixtureHTTPClient` returning canned seed
/// and robots responses; `commitAdd(...)` against a real on-disk
/// registry rooted at a temp directory; `sync(...)` end-to-end with
/// the crawler driving everything.
///
/// `@MainActor` because `FixtureHTTPClient.init` is main-isolated under
/// the project's Swift 6.2 default-isolation settings.
@MainActor
struct ProseCorpusAdderTests {

    // MARK: - Helpers

    private func makeAdder(
        fixtures: [URL: Data] = [:],
        userAgent: String = "AncestorResearch/1.0",
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_750_000_000) }
    ) -> (ProseCorpusAdder, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-adder-tests-\(UUID().uuidString)", isDirectory: true)
        let registry = ProseCorpusRegistry(baseDirectory: tmp)
        let http = FixtureHTTPClient(getFixtures: fixtures)
        let adder = ProseCorpusAdder(
            registry: registry,
            http: http,
            userAgent: userAgent,
            now: clock
        )
        return (adder, tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func html(title: String, body: String, links: [String]) -> Data {
        let anchors = links.map { "<a href=\"\($0)\">link</a>" }.joined()
        let s = """
        <html><head><title>\(title)</title></head>
        <body><h1>\(title)</h1><p>\(body)</p>\(anchors)</body></html>
        """
        return Data(s.utf8)
    }

    // MARK: - LinkFilter serialisation

    @Test func linkFilterRoundTripsAsGlob() {
        let original: ProseCorpusCrawler.LinkFilter = .glob("*/PEDIGREE.htm")
        let parsed = ProseCorpusCrawler.LinkFilter(serialised: original.serialised)
        guard case .glob(let pattern) = parsed else {
            Issue.record("Expected .glob, got \(String(describing: parsed))")
            return
        }
        #expect(pattern == "*/PEDIGREE.htm")
    }

    @Test func linkFilterRoundTripsAsRegex() {
        let original: ProseCorpusCrawler.LinkFilter = .regex("\\.htm$")
        let parsed = ProseCorpusCrawler.LinkFilter(serialised: original.serialised)
        guard case .regex(let pattern) = parsed else {
            Issue.record("Expected .regex, got \(String(describing: parsed))")
            return
        }
        #expect(pattern == "\\.htm$")
    }

    @Test func linkFilterRejectsNilAndUnknownKind() {
        #expect(ProseCorpusCrawler.LinkFilter(serialised: nil) == nil)
        #expect(ProseCorpusCrawler.LinkFilter(serialised: "") == nil)
        #expect(ProseCorpusCrawler.LinkFilter(serialised: "bogus:pattern") == nil)
    }

    // MARK: - Verify — happy path

    @Test func verifyReachableSeedWithLinks() async throws {
        let seed = URL(string: "http://example.com/index.htm")!
        let robots = URL(string: "http://example.com/robots.txt")!
        let fixtures: [URL: Data] = [
            seed: html(title: "Example Index", body: "welcome", links: ["a.htm", "b.htm", "http://elsewhere.com/x"]),
            robots: Data("User-agent: *\n".utf8),
        ]
        let (adder, tmp) = makeAdder(fixtures: fixtures)
        defer { cleanup(tmp) }

        let result = await adder.verify(seedURL: seed)
        #expect(result.reachable)
        #expect(result.robotsFetched)
        #expect(!result.seedDisallowedByRobots)
        #expect(result.outboundSameHostLinks == 2)
        #expect(result.outboundExternalLinks == 1)
        #expect(result.seedTitle == "Example Index")
        #expect(result.warnings.isEmpty)
        #expect(!result.hasBlockingProblems)
    }

    // MARK: - Verify — failure modes

    @Test func verifyMarksUnreachableSeedAsBlocking() async throws {
        // No fixture for the seed URL — FixtureHTTPClient returns a 404.
        let seed = URL(string: "http://example.com/missing")!
        let (adder, tmp) = makeAdder()
        defer { cleanup(tmp) }

        let result = await adder.verify(seedURL: seed)
        #expect(!result.reachable)
        #expect(result.unreachableReason != nil)
        #expect(result.hasBlockingProblems)
        #expect(result.warnings.contains(where: { $0.contains("Seed URL did not return") }))
    }

    @Test func verifyFlagsRobotsDisallowedSeed() async throws {
        let seed = URL(string: "http://example.com/private")!
        let robots = URL(string: "http://example.com/robots.txt")!
        let fixtures: [URL: Data] = [
            seed: html(title: "Private", body: "x", links: ["nope.htm"]),
            robots: Data("User-agent: *\nDisallow: /private\n".utf8),
        ]
        let (adder, tmp) = makeAdder(fixtures: fixtures)
        defer { cleanup(tmp) }

        let result = await adder.verify(seedURL: seed)
        #expect(result.reachable)
        #expect(result.seedDisallowedByRobots)
        #expect(result.hasBlockingProblems)
        #expect(result.warnings.contains(where: { $0.contains("robots.txt disallows") }))
    }

    @Test func verifyWarnsOnNoOutboundLinks() async throws {
        let seed = URL(string: "http://example.com/")!
        let fixtures: [URL: Data] = [
            seed: html(title: "Lonely", body: "no links here", links: []),
        ]
        let (adder, tmp) = makeAdder(fixtures: fixtures)
        defer { cleanup(tmp) }

        let result = await adder.verify(seedURL: seed)
        #expect(result.reachable)
        #expect(result.outboundSameHostLinks == 0)
        #expect(result.warnings.contains(where: { $0.contains("No outbound") }))
        // Not strictly blocking — the user may still want to crawl a
        // dead-end seed for the one page it contains.
        #expect(!result.hasBlockingProblems)
    }

    @Test func verifyTreatsMissingRobotsAsAllowAll() async throws {
        let seed = URL(string: "http://example.com/index.htm")!
        let fixtures: [URL: Data] = [
            // No /robots.txt fixture — fetch fails with 404.
            seed: html(title: "Index", body: "x", links: ["a.htm"]),
        ]
        let (adder, tmp) = makeAdder(fixtures: fixtures)
        defer { cleanup(tmp) }

        let result = await adder.verify(seedURL: seed)
        #expect(result.reachable)
        #expect(!result.robotsFetched)
        #expect(!result.seedDisallowedByRobots)
        #expect(result.outboundSameHostLinks == 1)
    }

    // MARK: - commitAdd

    @Test func commitAddWritesRegistryEntryAndManifest() async throws {
        let seed = URL(string: "http://example.com/")!
        let (adder, tmp) = makeAdder()
        defer { cleanup(tmp) }

        let result = try adder.commitAdd(
            seedURL: seed,
            displayTitle: "Example Corpus",
            crawlDepth: 5,
            pageBudget: 250,
            linkFilter: .glob("*.htm")
        )
        #expect(result.entry.sourceID == "example-com")
        #expect(result.entry.displayTitle == "Example Corpus")

        // Registry contains exactly the new entry.
        let doc = try adder.registry.load()
        #expect(doc.corpora.count == 1)
        #expect(doc.corpora.first?.sourceID == "example-com")

        // Manifest on disk matches what commitAdd returned.
        let stored = try result.storage.readManifest()
        #expect(stored == result.manifest)
        #expect(stored?.seedURL == seed)
        #expect(stored?.crawlDepth == 5)
        #expect(stored?.pageBudget == 250)
        #expect(stored?.linkFilter == "glob:*.htm")
        #expect(stored?.firstBuiltAt == nil)
        #expect(stored?.lastSyncedAt == nil)
        #expect(stored?.pageCount == 0)
    }

    @Test func commitAddClampsCrawlDepthAndPageBudget() async throws {
        let seed = URL(string: "http://example.com/")!
        let (adder, tmp) = makeAdder()
        defer { cleanup(tmp) }

        let result = try adder.commitAdd(
            seedURL: seed,
            displayTitle: "Example",
            crawlDepth: 99,          // → clamped to 12 (max)
            pageBudget: 0            // → clamped to 1
        )
        #expect(result.manifest.crawlDepth == 12)
        #expect(result.manifest.pageBudget == 1)
    }

    @Test func commitAddDerivesUniqueSourceIDsOnRepeatedAdds() async throws {
        let seed = URL(string: "http://example.com/")!
        let (adder, tmp) = makeAdder()
        defer { cleanup(tmp) }

        let first = try adder.commitAdd(seedURL: seed, displayTitle: "First")
        let second = try adder.commitAdd(seedURL: seed, displayTitle: "Second")
        #expect(first.entry.sourceID == "example-com")
        #expect(second.entry.sourceID == "example-com-2")
    }

    // MARK: - sync

    @Test func syncRunsCrawlerAndUpdatesManifest() async throws {
        let seed = URL(string: "http://example.com/index.htm")!
        let other = URL(string: "http://example.com/other.htm")!
        let fixtures: [URL: Data] = [
            seed: html(title: "Index", body: "seed", links: ["other.htm"]),
            other: html(title: "Other", body: "page two", links: []),
        ]
        var nowClock = Date(timeIntervalSince1970: 1_750_000_000)
        let clock: @Sendable () -> Date = { nowClock }
        let (adder, tmp) = makeAdder(fixtures: fixtures, clock: clock)
        defer { cleanup(tmp) }

        let added = try adder.commitAdd(
            seedURL: seed,
            displayTitle: "Example",
            crawlDepth: 2,
            pageBudget: 10
        )

        // Advance the clock so sync uses a later timestamp than addedAt.
        nowClock = Date(timeIntervalSince1970: 1_750_001_000)

        // We need to disable robots/sitemap for the test since we
        // haven't staged fixtures for them and they'd 404 — wait, the
        // crawler tolerates missing robots/sitemap (404 → no rules,
        // no URLs). Let's let it run as-is.
        let report = try await adder.sync(sourceID: added.entry.sourceID)
        #expect(report.pagesWritten == 2)
        #expect(report.stop == .complete)

        let stored = try added.storage.readManifest()
        #expect(stored?.firstBuiltAt == nowClock)
        #expect(stored?.lastSyncedAt == nowClock)
        #expect(stored?.pageCount == 2)
        #expect((stored?.totalBytes ?? 0) > 0)
    }

    @Test func syncThrowsForUnknownSourceID() async throws {
        let (adder, tmp) = makeAdder()
        defer { cleanup(tmp) }

        var threw = false
        do {
            _ = try await adder.sync(sourceID: "does-not-exist")
        } catch ProseCorpusAdder.AdderError.unknownSourceID(let id) {
            threw = true
            #expect(id == "does-not-exist")
        }
        #expect(threw)
    }

    @Test func syncPreservesFirstBuiltAtAcrossMultipleSyncs() async throws {
        let seed = URL(string: "http://example.com/")!
        let fixtures: [URL: Data] = [
            seed: html(title: "Index", body: "x", links: []),
        ]
        var nowClock = Date(timeIntervalSince1970: 1_750_000_000)
        let clock: @Sendable () -> Date = { nowClock }
        let (adder, tmp) = makeAdder(fixtures: fixtures, clock: clock)
        defer { cleanup(tmp) }

        let added = try adder.commitAdd(seedURL: seed, displayTitle: "Example")
        nowClock = Date(timeIntervalSince1970: 1_750_001_000)
        _ = try await adder.sync(sourceID: added.entry.sourceID)
        let firstBuilt = (try added.storage.readManifest())?.firstBuiltAt
        #expect(firstBuilt == nowClock)

        // Sync again — firstBuiltAt should not move, but lastSyncedAt
        // should.
        nowClock = Date(timeIntervalSince1970: 1_750_002_000)
        _ = try await adder.sync(sourceID: added.entry.sourceID)
        let second = try added.storage.readManifest()
        #expect(second?.firstBuiltAt == firstBuilt)
        #expect(second?.lastSyncedAt == nowClock)
    }

    // MARK: - remove

    @Test func removeDeletesRegistryEntryAndCorpusDirectory() async throws {
        let seed = URL(string: "http://example.com/")!
        let fixtures: [URL: Data] = [
            seed: html(title: "Index", body: "x", links: []),
        ]
        let (adder, tmp) = makeAdder(fixtures: fixtures)
        defer { cleanup(tmp) }

        let added = try adder.commitAdd(seedURL: seed, displayTitle: "Example")
        #expect(FileManager.default.fileExists(atPath: added.storage.corpusDirectory.path))

        try adder.remove(sourceID: added.entry.sourceID)

        let doc = try adder.registry.load()
        #expect(doc.corpora.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: added.storage.corpusDirectory.path))
    }
}
