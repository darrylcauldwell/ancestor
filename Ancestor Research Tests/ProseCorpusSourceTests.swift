import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// Pins the prose-corpus retrieval contract from spec §9 — surname is
/// the gate, year + place add to the score, top-K is deterministic,
/// dispatch fans out across every registered corpus.
@MainActor
struct ProseCorpusSourceTests {

    // MARK: - Test scaffolding

    /// Build a corpus on disk under `baseDirectory`: writes a registry
    /// entry, an initial manifest, the given markdown pages (via
    /// `writePage`), and runs the indexer to populate the SQLite
    /// index. Mirrors what `ProseCorpusAdder.commitAdd + sync` does
    /// in production, but synchronously and without any HTTP.
    private func buildCorpus(
        baseDirectory: URL,
        corpusID: String,
        displayTitle: String,
        seedURL: URL,
        pages: [(sourceURL: String, title: String?, body: String)],
        gazetteer: [GazetteerEntry]
    ) throws {
        let registry = ProseCorpusRegistry(baseDirectory: baseDirectory)
        try registry.add(ProseCorpusRegistryEntry(
            sourceID: corpusID,
            displayTitle: displayTitle,
            addedAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))

        let storage = ProseCorpusStorage(baseDirectory: baseDirectory, sourceID: corpusID)
        for page in pages {
            _ = try storage.writePage(sourceURL: page.sourceURL, title: page.title, body: page.body)
        }
        let manifest = ProseCorpusManifest(
            sourceID: corpusID,
            displayTitle: displayTitle,
            seedURL: seedURL,
            addedByUserAt: Date(timeIntervalSince1970: 1_750_000_000),
            schemaVersion: 1,
            crawlerVersion: ProseCorpusStorage.crawlerVersion,
            crawlDepth: 4,
            linkFilter: nil,
            pageBudget: 1000,
            firstBuiltAt: Date(timeIntervalSince1970: 1_750_000_100),
            lastSyncedAt: Date(timeIntervalSince1970: 1_750_000_100),
            pageCount: pages.count,
            totalBytes: 0,
            robotsTxtURL: seedURL,
            robotsTxtFetchedAt: nil,
            userAgent: "test/1"
        )
        try storage.writeManifest(manifest)

        let indexPath = storage.corpusDirectory.appendingPathComponent("index.sqlite").path
        let index = try ProseCorpusIndex(path: indexPath)
        let indexer = ProseCorpusIndexer(
            storage: storage,
            index: index,
            gazetteer: gazetteer,
            now: { Date(timeIntervalSince1970: 1_750_000_200) }
        )
        _ = try indexer.refresh()
    }

    private func sampleGazetteer() -> [GazetteerEntry] {
        [
            GazetteerEntry(id: "DBY:Wirksworth", name: "Wirksworth", county: "Derbyshire", country: "England", aliases: [], kind: nil),
            GazetteerEntry(id: "DBY:Crich", name: "Crich", county: "Derbyshire", country: "England", aliases: [], kind: nil),
            GazetteerEntry(id: "DBY:Belper", name: "Belper", county: "Derbyshire", country: "England", aliases: [], kind: nil),
            GazetteerEntry(id: "KEN:Ashford", name: "Ashford", county: "Kent", country: "England", aliases: [], kind: nil),
        ]
    }

    private func emptySurnameVariants() -> SurnameVariants {
        // SurnameVariants.shared loads from bundle; for tests we need
        // a deterministic empty stub. Reflectively building one
        // means going through .shared and accepting whatever the
        // bundle has — but the tests below use real surnames
        // ("Cauldwell") that aren't in the seed variants list, so
        // .shared returning an empty array for them is the same as
        // an injected empty.
        return SurnameVariants.shared
    }

    private func makeQuery(
        surname: String?,
        yearFrom: Int? = nil,
        yearTo: Int? = nil,
        region: Region? = nil,
        givenName: String? = nil
    ) -> RecordQuery {
        RecordQuery(
            surname: surname,
            givenName: givenName,
            recordType: .pedigree,
            yearFrom: yearFrom,
            yearTo: yearTo,
            gender: nil,
            region: region,
            sourceParams: .generic
        )
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Pure helper tests

    @Test func surnameTokensUppercaseAndDedupe() {
        let variants = SurnameVariants.shared
        let tokens = ProseCorpusSource.surnameTokens(for: "Cauldwell", variants: variants)
        #expect(tokens.contains("CAULDWELL"))
        // Sorted output for determinism.
        #expect(tokens == tokens.sorted())
    }

    @Test func yearRangeHandlesOpenBounds() {
        let bothNil = makeQuery(surname: "X")
        #expect(ProseCorpusSource.yearRange(from: bothNil) == nil)

        let openUpper = makeQuery(surname: "X", yearFrom: 1800)
        #expect(ProseCorpusSource.yearRange(from: openUpper) == 1800...1999)

        let openLower = makeQuery(surname: "X", yearTo: 1850)
        #expect(ProseCorpusSource.yearRange(from: openLower) == 1500...1850)

        let bounded = makeQuery(surname: "X", yearFrom: 1820, yearTo: 1830)
        #expect(ProseCorpusSource.yearRange(from: bounded) == 1820...1830)
    }

    @Test func placeTokensFromCountyMapToGazetteerEntries() {
        let gazetteer = sampleGazetteer()
        let derbyTokens = ProseCorpusSource.placeTokens(for: .county("Derbyshire"), gazetteer: gazetteer)
        // All three Derbyshire entries — name lowercased, sorted.
        #expect(derbyTokens == ["belper", "crich", "wirksworth"])

        let kentTokens = ProseCorpusSource.placeTokens(for: .county("Kent"), gazetteer: gazetteer)
        #expect(kentTokens == ["ashford"])

        let nilTokens = ProseCorpusSource.placeTokens(for: nil, gazetteer: gazetteer)
        #expect(nilTokens.isEmpty)
    }

    @Test func placeTokensFromParishMapToCountyEntries() {
        let gazetteer = sampleGazetteer()
        // A parish-level region should still match every county
        // entry under Region.overlaps semantics.
        let tokens = ProseCorpusSource.placeTokens(
            for: .parish("Wirksworth", county: "Derbyshire"),
            gazetteer: gazetteer
        )
        #expect(tokens.contains("wirksworth"))
        #expect(!tokens.contains("ashford"))
    }

    // MARK: - searchCandidates — empty edge cases

    @Test func searchCandidatesReturnsEmptyForMissingSurname() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(surname: nil)
        let hits = await source.searchCandidates(query: query)
        #expect(hits.isEmpty)
    }

    @Test func searchCandidatesReturnsEmptyForEmptyRegistry() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(surname: "Cauldwell")
        let hits = await source.searchCandidates(query: query)
        #expect(hits.isEmpty)
    }

    // MARK: - searchCandidates — single corpus

    @Test func searchCandidatesReturnsPagesWithSurnameMatch() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        try buildCorpus(
            baseDirectory: tmp,
            corpusID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com/")!,
            pages: [
                ("http://example.com/cauldwell", "Cauldwell page", "Cauldwell of Wirksworth born 1820 died 1880."),
                ("http://example.com/holmes", "Holmes page", "Holmes family of Crich, born 1810."),
                ("http://example.com/neither", "Random page", "Just some text with no surnames."),
            ],
            gazetteer: sampleGazetteer()
        )

        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(surname: "Cauldwell")
        let hits = await source.searchCandidates(query: query)
        // Only the Cauldwell page contains the surname.
        #expect(hits.count == 1)
        #expect(hits.first?.sourceURL == "http://example.com/cauldwell")
        #expect(hits.first?.title == "Cauldwell page")
        #expect(hits.first?.surnameHits == 1)
    }

    @Test func searchCandidatesWeightingFavoursSurnameOverYearOverPlace() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        // Three pages, all matching the surname once. Year/place add
        // to the score per spec 3:2:1.
        try buildCorpus(
            baseDirectory: tmp,
            corpusID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com/")!,
            pages: [
                // Page A: surname + year + place = 3 + 2 + 1 = 6
                ("http://example.com/a", "A", "Cauldwell born at Wirksworth in 1820."),
                // Page B: surname + year = 3 + 2 = 5
                ("http://example.com/b", "B", "Cauldwell born somewhere in 1820."),
                // Page C: surname only = 3
                ("http://example.com/c", "C", "Cauldwell."),
            ],
            gazetteer: sampleGazetteer()
        )

        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(
            surname: "Cauldwell",
            yearFrom: 1815, yearTo: 1825,
            region: .county("Derbyshire")
        )
        let hits = await source.searchCandidates(query: query, limit: 10)
        // Order: A (score 6) > B (5) > C (3).
        #expect(hits.count == 3)
        #expect(hits[0].sourceURL == "http://example.com/a")
        #expect(hits[1].sourceURL == "http://example.com/b")
        #expect(hits[2].sourceURL == "http://example.com/c")
    }

    @Test func searchCandidatesRespectsLimit() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let pages = (1...10).map { i in
            ("http://example.com/p\(i)", "P\(i)", "Cauldwell mention \(i).")
        }
        try buildCorpus(
            baseDirectory: tmp,
            corpusID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com/")!,
            pages: pages,
            gazetteer: sampleGazetteer()
        )

        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(surname: "Cauldwell")
        let hits = await source.searchCandidates(query: query, limit: 3)
        #expect(hits.count == 3)
    }

    @Test func searchCandidatesIsDeterministicAcrossRuns() async throws {
        // AC-R3: same query against the same corpus → identical K
        // pages in identical order.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let pages = (1...5).map { i in
            ("http://example.com/p\(i)", "P\(i)", "Cauldwell mention \(i) at Wirksworth.")
        }
        try buildCorpus(
            baseDirectory: tmp,
            corpusID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com/")!,
            pages: pages,
            gazetteer: sampleGazetteer()
        )

        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(surname: "Cauldwell", region: .county("Derbyshire"))
        let first = await source.searchCandidates(query: query, limit: 5)
        let second = await source.searchCandidates(query: query, limit: 5)
        #expect(first == second)
    }

    @Test func searchCandidatesReturnsEmptyForUnknownSurname() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        try buildCorpus(
            baseDirectory: tmp,
            corpusID: "test-corpus",
            displayTitle: "Test",
            seedURL: URL(string: "http://example.com/")!,
            pages: [
                ("http://example.com/a", "A", "Just Cauldwell content."),
            ],
            gazetteer: sampleGazetteer()
        )

        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(surname: "Nobody")
        let hits = await source.searchCandidates(query: query)
        #expect(hits.isEmpty)
    }

    // MARK: - searchCandidates — multi-corpus dispatch

    @Test func searchCandidatesFansOutAcrossCorpora() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }

        // Two corpora, each with one Cauldwell page.
        try buildCorpus(
            baseDirectory: tmp,
            corpusID: "corpus-a",
            displayTitle: "Corpus A",
            seedURL: URL(string: "http://a.example.com/")!,
            pages: [("http://a.example.com/p", "A page", "Cauldwell from A.")],
            gazetteer: sampleGazetteer()
        )
        try buildCorpus(
            baseDirectory: tmp,
            corpusID: "corpus-b",
            displayTitle: "Corpus B",
            seedURL: URL(string: "http://b.example.com/")!,
            pages: [("http://b.example.com/p", "B page", "Cauldwell from B at Wirksworth in 1820.")],
            gazetteer: sampleGazetteer()
        )

        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(
            surname: "Cauldwell",
            yearFrom: 1815, yearTo: 1825,
            region: .county("Derbyshire")
        )
        let hits = await source.searchCandidates(query: query, limit: 10)
        #expect(hits.count == 2)
        // B has surname + year + place (score 6) so it ranks above A (score 3).
        #expect(hits[0].sourceID == "corpus-b")
        #expect(hits[1].sourceID == "corpus-a")
    }

    // MARK: - RecordSource protocol surface

    @Test func searchViaRecordSourceProtocolIsEmpty() async throws {
        // ProseCorpusSource conforms to RecordSource but declares
        // recordTypes = []. The protocol's `search(_:)` is a no-op
        // (returns empty results) so prose candidates never leak
        // into the structured-record dispatch pipeline.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(tmp) }
        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        let query = makeQuery(surname: "Cauldwell")
        let result = await source.search(query)
        if case .results(let records) = result {
            #expect(records.isEmpty)
        } else {
            Issue.record("Expected .results, got \(result)")
        }
    }

    @Test func sourceIDIsProseCorpus() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-source-tests-\(UUID().uuidString)", isDirectory: true)
        let source = ProseCorpusSource(
            registryBaseDirectory: tmp,
            surnameVariants: SurnameVariants.shared,
            gazetteer: sampleGazetteer()
        )
        #expect(source.sourceID == "prose-corpus")
    }
}
