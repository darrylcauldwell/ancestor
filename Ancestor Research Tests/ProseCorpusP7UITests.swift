import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the P7 UI substrate — the persistent `CrawlStopReason`
/// round-trip used for the Settings partial-crawl chip, and the
/// agent-origin matcher behind the Pending Facts filter picker.
///
/// `@MainActor` because `PendingFactsReviewView.AgentFilter` is a
/// nested type on a SwiftUI View — MainActor-isolated under the
/// project's Swift 6.2 default isolation, so its `matches(...)`
/// method has to be called from a main-actor context.
@MainActor
struct ProseCorpusP7UITests {

    // MARK: - CrawlStopReason round-trip

    @Test func crawlStopReasonRawValueRoundTripsForSimpleCases() {
        let cases: [CrawlStopReason] = [.complete, .budgetExhausted, .circuitBreakerExhausted]
        for original in cases {
            let raw = original.rawValue
            let parsed = CrawlStopReason(rawValue: raw)
            #expect(parsed == original)
        }
    }

    @Test func crawlStopReasonSeedFailedRoundTripsWithReason() {
        let original = CrawlStopReason.seedFailed(reason: "DNS lookup failed")
        let parsed = CrawlStopReason(rawValue: original.rawValue)
        #expect(parsed == original)
    }

    @Test func crawlStopReasonRejectsUnknownRaw() {
        #expect(CrawlStopReason(rawValue: "something_else") == nil)
        #expect(CrawlStopReason(rawValue: "") == nil)
    }

    @Test func crawlStopReasonIsPartialOnlyForNonComplete() {
        #expect(CrawlStopReason.complete.isPartial == false)
        #expect(CrawlStopReason.budgetExhausted.isPartial == true)
        #expect(CrawlStopReason.circuitBreakerExhausted.isPartial == true)
        #expect(CrawlStopReason.seedFailed(reason: "x").isPartial == true)
    }

    // MARK: - Adder mapper

    @Test func adderMapsCrawlerStopReasonToManifestProjection() {
        #expect(ProseCorpusAdder.crawlStopReason(from: .complete) == .complete)
        #expect(ProseCorpusAdder.crawlStopReason(from: .budgetExhausted) == .budgetExhausted)
        #expect(ProseCorpusAdder.crawlStopReason(from: .circuitBreakerExhausted) == .circuitBreakerExhausted)
        let failure = ProseCorpusAdder.crawlStopReason(from: .seedFailed("404"))
        #expect(failure == .seedFailed(reason: "404"))
    }

    // MARK: - Manifest persists across save/load

    @Test func manifestPersistsStopReasonAcrossSaveAndLoad() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-p7-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: "test-corpus")

        let manifest = ProseCorpusManifest(
            sourceID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com")!,
            addedByUserAt: Date(timeIntervalSince1970: 1),
            schemaVersion: 1,
            crawlerVersion: "1.0.0",
            crawlDepth: 4,
            linkFilter: nil,
            pageBudget: 10,
            firstBuiltAt: Date(timeIntervalSince1970: 2),
            lastSyncedAt: Date(timeIntervalSince1970: 3),
            pageCount: 5,
            totalBytes: 100,
            robotsTxtURL: URL(string: "http://example.com/robots.txt")!,
            robotsTxtFetchedAt: nil,
            userAgent: "test/1",
            lastSyncStopReason: CrawlStopReason.budgetExhausted.rawValue
        )
        try storage.writeManifest(manifest)
        let reloaded = try storage.readManifest()
        #expect(reloaded?.lastSyncStopReason == CrawlStopReason.budgetExhausted.rawValue)
        #expect(reloaded?.lastSyncWasPartial == true)
    }

    @Test func manifestPartialFlagIsFalseWhenStopReasonIsNil() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-p7-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: "test-corpus")

        let manifest = ProseCorpusManifest(
            sourceID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com")!,
            addedByUserAt: Date(timeIntervalSince1970: 1),
            schemaVersion: 1,
            crawlerVersion: "1.0.0",
            crawlDepth: 4,
            linkFilter: nil,
            pageBudget: 10,
            firstBuiltAt: nil,
            lastSyncedAt: nil,
            pageCount: 0,
            totalBytes: 0,
            robotsTxtURL: URL(string: "http://example.com/robots.txt")!,
            robotsTxtFetchedAt: nil,
            userAgent: "test/1",
            lastSyncStopReason: nil
        )
        try storage.writeManifest(manifest)
        let reloaded = try storage.readManifest()
        #expect(reloaded?.lastSyncWasPartial == false)
    }

    @Test func manifestPartialFlagIsFalseWhenStopReasonIsComplete() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-p7-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: "test-corpus")

        let manifest = ProseCorpusManifest(
            sourceID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com")!,
            addedByUserAt: Date(timeIntervalSince1970: 1),
            schemaVersion: 1,
            crawlerVersion: "1.0.0",
            crawlDepth: 4,
            linkFilter: nil,
            pageBudget: 10,
            firstBuiltAt: Date(timeIntervalSince1970: 2),
            lastSyncedAt: Date(timeIntervalSince1970: 3),
            pageCount: 5,
            totalBytes: 100,
            robotsTxtURL: URL(string: "http://example.com/robots.txt")!,
            robotsTxtFetchedAt: nil,
            userAgent: "test/1",
            lastSyncStopReason: CrawlStopReason.complete.rawValue
        )
        try storage.writeManifest(manifest)
        let reloaded = try storage.readManifest()
        #expect(reloaded?.lastSyncWasPartial == false)
    }

    // MARK: - AgentFilter (pending-facts review)

    @Test func agentFilterAllMatchesEveryAgent() {
        let f = PendingFactsReviewView.AgentFilter.all
        #expect(f.matches(agentID: "prose-extractor:wirksworth"))
        #expect(f.matches(agentID: "field-researcher"))
        #expect(f.matches(agentID: "claude-code"))
        #expect(f.matches(agentID: ""))
    }

    @Test func agentFilterProseCorpusOnlyMatchesProseExtractor() {
        let f = PendingFactsReviewView.AgentFilter.proseCorpus
        #expect(f.matches(agentID: "prose-extractor:wirksworth"))
        #expect(f.matches(agentID: "prose-extractor:freereg-narratives"))
        #expect(!f.matches(agentID: "field-researcher"))
        #expect(!f.matches(agentID: "claude-code"))
    }

    @Test func agentFilterFieldResearcherExcludesProseExtractor() {
        let f = PendingFactsReviewView.AgentFilter.fieldResearcher
        #expect(!f.matches(agentID: "prose-extractor:wirksworth"))
        #expect(f.matches(agentID: "field-researcher"))
        #expect(f.matches(agentID: "claude-code"))
        #expect(f.matches(agentID: "unknown"))
    }
}
