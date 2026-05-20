import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// Pins the indexer contract from spec §4 (schema) and §8 (extraction +
/// refresh). Three concerns covered:
///
/// 1. Tokeniser purity — surname / year / place extraction rules.
/// 2. Index storage — schema migration, upsert/delete semantics,
///    FTS5 parity with `pages` (AC-I3), FK cascade on delete.
/// 3. Indexer orchestration — refresh stats, content-hash skip path,
///    stale-row cleanup when markdown disappears (AC-B6).
@MainActor
struct ProseCorpusIndexerTests {

    // MARK: - Test fixtures

    private func makeTempStorage(sourceID: String = "test-corpus") -> (ProseCorpusStorage, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-indexer-tests-\(UUID().uuidString)", isDirectory: true)
        return (ProseCorpusStorage(baseDirectory: tmp, sourceID: sourceID), tmp)
    }

    private func makeTempIndex() throws -> (ProseCorpusIndex, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-index-tests-\(UUID().uuidString).sqlite")
        let index = try ProseCorpusIndex(path: tmp.path)
        return (index, tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func sampleGazetteer() -> [GazetteerEntry] {
        [
            GazetteerEntry(id: "DBY:Wirksworth", name: "Wirksworth", county: "Derbyshire", country: "England", aliases: [], kind: nil),
            GazetteerEntry(id: "DBY:Crich", name: "Crich", county: "Derbyshire", country: "England", aliases: ["Cryche"], kind: nil),
            GazetteerEntry(id: "DBY:Belper", name: "Belper", county: "Derbyshire", country: "England", aliases: [], kind: nil),
        ]
    }

    // MARK: - Tokeniser — surnames

    @Test func surnameTokeniserExtractsCapitalisedTokens() {
        let body = "Thomas Cauldwell married Sarah Holmes at Wirksworth in 1820."
        let surnames = ProseCorpusTokeniser.surnames(in: body)
        #expect(surnames["CAULDWELL"] == 1)
        #expect(surnames["HOLMES"] == 1)
        // First names appear too — the tokeniser doesn't try to
        // distinguish given names from surnames. That's the
        // tokeniser's job at the index level; the retriever
        // disambiguates with SurnameVariants at query time.
        #expect(surnames["THOMAS"] == 1)
        #expect(surnames["SARAH"] == 1)
    }

    @Test func surnameTokeniserStripsTrailingApostropheS() {
        let body = "It was Cauldwell's farm near Holmes's mill."
        let surnames = ProseCorpusTokeniser.surnames(in: body)
        #expect(surnames["CAULDWELL"] == 1)
        #expect(surnames["HOLMES"] == 1)
    }

    @Test func surnameTokeniserCountsMultipleMentions() {
        let body = "Cauldwell, John. Cauldwell, Thomas. Cauldwell, Mary."
        let surnames = ProseCorpusTokeniser.surnames(in: body)
        #expect(surnames["CAULDWELL"] == 3)
    }

    @Test func surnameTokeniserSkipsStopWords() {
        // Month / day / common English title-case tokens — should not
        // pollute `page_surnames`.
        let body = "On Monday the 12th of January, the Reverend John Cauldwell baptised the child."
        let surnames = ProseCorpusTokeniser.surnames(in: body)
        #expect(surnames["MONDAY"] == nil)
        #expect(surnames["JANUARY"] == nil)
        #expect(surnames["REVEREND"] == nil)
        #expect(surnames["THE"] == nil)
        #expect(surnames["CAULDWELL"] == 1)
    }

    @Test func surnameTokeniserSkipsShortTokens() {
        let body = "Mr Cauldwell of NG"
        let surnames = ProseCorpusTokeniser.surnames(in: body)
        #expect(surnames["CAULDWELL"] == 1)
        // Length 2 — below the ≥ 3 threshold.
        #expect(surnames["NG"] == nil)
        #expect(surnames["MR"] == nil)
    }

    @Test func surnameTokeniserSkipsLowercaseTokens() {
        let body = "the cauldwell family"
        let surnames = ProseCorpusTokeniser.surnames(in: body)
        // Lowercase "cauldwell" doesn't match the "capitalised"
        // requirement — surname tokens must start uppercase.
        #expect(surnames["CAULDWELL"] == nil)
    }

    // MARK: - Tokeniser — years

    @Test func yearTokeniserCaptures4DigitYearsInRange() {
        let body = "Born 1782, married 1810, died 1856."
        let years = ProseCorpusTokeniser.years(in: body)
        #expect(years[1782] == 1)
        #expect(years[1810] == 1)
        #expect(years[1856] == 1)
    }

    @Test func yearTokeniserRejectsOutOfRange() {
        let body = "Year 1499 too early; 1500 OK; 1999 OK; 2000 too late."
        let years = ProseCorpusTokeniser.years(in: body)
        #expect(years[1499] == nil)
        #expect(years[1500] == 1)
        #expect(years[1999] == 1)
        #expect(years[2000] == nil)
    }

    @Test func yearTokeniserIgnoresTwoDigitDates() {
        let body = "in '76 he travelled"
        let years = ProseCorpusTokeniser.years(in: body)
        #expect(years.isEmpty)
    }

    @Test func yearTokeniserCountsRepeatedMentions() {
        let body = "1820 1820 1820"
        let years = ProseCorpusTokeniser.years(in: body)
        #expect(years[1820] == 3)
    }

    // MARK: - Tokeniser — places

    @Test func placeTokeniserMatchesGazetteerNames() {
        let body = "Born at Wirksworth, baptised at Crich."
        let places = ProseCorpusTokeniser.places(in: body, gazetteer: sampleGazetteer())
        #expect(places["wirksworth"] == 1)
        #expect(places["crich"] == 1)
        #expect(places["belper"] == nil)
    }

    @Test func placeTokeniserCountsAliasesAgainstCanonicalName() {
        // "Cryche" is an alias for Crich — should land under the
        // canonical key, not as a separate row.
        let body = "Mentioned at Cryche in 1610 and Crich in 1680."
        let places = ProseCorpusTokeniser.places(in: body, gazetteer: sampleGazetteer())
        #expect(places["crich"] == 2)
        #expect(places["cryche"] == nil)
    }

    @Test func placeTokeniserIsCaseInsensitive() {
        let body = "WIRKSWORTH wirksworth Wirksworth"
        let places = ProseCorpusTokeniser.places(in: body, gazetteer: sampleGazetteer())
        #expect(places["wirksworth"] == 3)
    }

    @Test func placeTokeniserMatchesWholeWordsOnly() {
        // "Wirksworthian" should not match "Wirksworth".
        let body = "He was a Wirksworthian by birth."
        let places = ProseCorpusTokeniser.places(in: body, gazetteer: sampleGazetteer())
        #expect(places["wirksworth"] == nil)
    }

    // MARK: - Index schema

    @Test func indexMigrationCreatesAllTables() throws {
        let (index, tmp) = try makeTempIndex()
        defer { cleanup(tmp) }

        try index.dbQueue.read { db in
            // Spec §4 — all four pivot tables + FTS5 virtual table.
            let pagesExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pages'") ?? false
            let surnamesExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_surnames'") ?? false
            let yearsExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_years'") ?? false
            let placesExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_places'") ?? false
            let ftsExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_fts'") ?? false
            #expect(pagesExists)
            #expect(surnamesExists)
            #expect(yearsExists)
            #expect(placesExists)
            #expect(ftsExists)
        }
    }

    @Test func upsertPageInsertsRowsAcrossAllTables() throws {
        let (index, tmp) = try makeTempIndex()
        defer { cleanup(tmp) }

        let record = ProseCorpusIndex.UpsertRecord(
            pageHash: "deadbeefcafe1234",
            sourceURL: "http://example.com/p",
            title: "Page",
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000),
            contentHash: String(repeating: "a", count: 64),
            byteLength: 42,
            lastIndexedAt: Date(timeIntervalSince1970: 1_750_001_000),
            body: "Body text mentioning Cauldwell 1820 Wirksworth.",
            surnames: ["CAULDWELL": 1],
            years: [1820: 1],
            places: ["wirksworth": 1]
        )
        try index.upsertPage(record)

        #expect(try index.totalPages() == 1)
        #expect(try index.totalFTSRows() == 1)
        #expect(try index.surnamePageCount("CAULDWELL") == 1)

        let row = try index.page(forHash: "deadbeefcafe1234")
        #expect(row?.sourceURL == "http://example.com/p")
        #expect(row?.title == "Page")
        #expect(row?.byteLength == 42)
    }

    @Test func upsertPageReplacesPriorRows() throws {
        let (index, tmp) = try makeTempIndex()
        defer { cleanup(tmp) }

        let v1 = ProseCorpusIndex.UpsertRecord(
            pageHash: "abc1234567890def",
            sourceURL: "http://example.com/p",
            title: "v1",
            fetchedAt: Date(timeIntervalSince1970: 1),
            contentHash: "hash1",
            byteLength: 10,
            lastIndexedAt: Date(timeIntervalSince1970: 1),
            body: "Cauldwell mentioned once.",
            surnames: ["CAULDWELL": 1],
            years: [:],
            places: [:]
        )
        try index.upsertPage(v1)

        let v2 = ProseCorpusIndex.UpsertRecord(
            pageHash: "abc1234567890def",
            sourceURL: "http://example.com/p",
            title: "v2",
            fetchedAt: Date(timeIntervalSince1970: 2),
            contentHash: "hash2",
            byteLength: 20,
            lastIndexedAt: Date(timeIntervalSince1970: 2),
            body: "Holmes mentioned twice. Holmes again.",
            surnames: ["HOLMES": 2],
            years: [:],
            places: [:]
        )
        try index.upsertPage(v2)

        #expect(try index.totalPages() == 1)
        #expect(try index.surnamePageCount("CAULDWELL") == 0)
        #expect(try index.surnamePageCount("HOLMES") == 1)
        let row = try index.page(forHash: "abc1234567890def")
        #expect(row?.title == "v2")
        #expect(row?.contentHash == "hash2")
    }

    @Test func deletePageCascadesAcrossAllTables() throws {
        let (index, tmp) = try makeTempIndex()
        defer { cleanup(tmp) }

        let record = ProseCorpusIndex.UpsertRecord(
            pageHash: "0123456789abcdef",
            sourceURL: "http://example.com/p",
            title: nil,
            fetchedAt: Date(),
            contentHash: "hash",
            byteLength: 1,
            lastIndexedAt: Date(),
            body: "body",
            surnames: ["X": 1],
            years: [1800: 1],
            places: ["wirksworth": 1]
        )
        try index.upsertPage(record)
        #expect(try index.totalPages() == 1)
        try index.deletePage(pageHash: "0123456789abcdef")
        #expect(try index.totalPages() == 0)
        #expect(try index.totalFTSRows() == 0)
        // The FK cascade should have cleared the pivots.
        try index.dbQueue.read { db in
            let surnameCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_surnames") ?? 0
            let yearCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_years") ?? 0
            let placeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_places") ?? 0
            #expect(surnameCount == 0)
            #expect(yearCount == 0)
            #expect(placeCount == 0)
        }
    }

    // MARK: - Indexer orchestration

    @Test func indexerRefreshInsertsAllPages() throws {
        let (storage, storageTmp) = makeTempStorage()
        defer { cleanup(storageTmp) }
        let (index, indexTmp) = try makeTempIndex()
        defer { cleanup(indexTmp) }

        _ = try storage.writePage(
            sourceURL: "http://example.com/a",
            title: "A",
            body: "Cauldwell of Wirksworth born 1820."
        )
        _ = try storage.writePage(
            sourceURL: "http://example.com/b",
            title: "B",
            body: "Holmes of Crich died 1880."
        )

        let indexer = ProseCorpusIndexer(
            storage: storage,
            index: index,
            gazetteer: sampleGazetteer()
        )
        let stats = try indexer.refresh()
        #expect(stats.inserted == 2)
        #expect(stats.updated == 0)
        #expect(stats.removed == 0)
        #expect(stats.unchanged == 0)
        #expect(try index.totalPages() == 2)
        #expect(try index.totalFTSRows() == 2)
        #expect(try index.surnamePageCount("CAULDWELL") == 1)
        #expect(try index.surnamePageCount("HOLMES") == 1)
    }

    @Test func indexerRefreshIsIdempotent() throws {
        let (storage, storageTmp) = makeTempStorage()
        defer { cleanup(storageTmp) }
        let (index, indexTmp) = try makeTempIndex()
        defer { cleanup(indexTmp) }

        _ = try storage.writePage(
            sourceURL: "http://example.com/a",
            title: "A",
            body: "Cauldwell of Wirksworth born 1820."
        )

        let indexer = ProseCorpusIndexer(
            storage: storage,
            index: index,
            gazetteer: sampleGazetteer()
        )
        let first = try indexer.refresh()
        let second = try indexer.refresh()

        #expect(first.inserted == 1)
        #expect(second.inserted == 0)
        #expect(second.updated == 0)
        #expect(second.unchanged == 1)
        #expect(try index.totalPages() == 1)
    }

    @Test func indexerRefreshDetectsBodyChange() throws {
        let (storage, storageTmp) = makeTempStorage()
        defer { cleanup(storageTmp) }
        let (index, indexTmp) = try makeTempIndex()
        defer { cleanup(indexTmp) }

        let url = "http://example.com/a"
        _ = try storage.writePage(sourceURL: url, title: "A", body: "Original Cauldwell content.")
        let indexer = ProseCorpusIndexer(
            storage: storage,
            index: index,
            gazetteer: sampleGazetteer()
        )
        _ = try indexer.refresh()
        #expect(try index.surnamePageCount("CAULDWELL") == 1)
        #expect(try index.surnamePageCount("HOLMES") == 0)

        // Update body — content hash changes → update path.
        _ = try storage.writePage(sourceURL: url, title: "A", body: "Updated Holmes content here.")
        let stats = try indexer.refresh()
        #expect(stats.updated == 1)
        #expect(stats.inserted == 0)
        #expect(try index.surnamePageCount("CAULDWELL") == 0)
        #expect(try index.surnamePageCount("HOLMES") == 1)
    }

    @Test func indexerRefreshCleansUpDeletedPages() throws {
        // Spec AC-B6 — a page that's gone from disk should cascade
        // out of every index table.
        let (storage, storageTmp) = makeTempStorage()
        defer { cleanup(storageTmp) }
        let (index, indexTmp) = try makeTempIndex()
        defer { cleanup(indexTmp) }

        _ = try storage.writePage(sourceURL: "http://example.com/a", title: "A", body: "Cauldwell.")
        let indexer = ProseCorpusIndexer(
            storage: storage,
            index: index,
            gazetteer: sampleGazetteer()
        )
        _ = try indexer.refresh()
        #expect(try index.totalPages() == 1)

        let hashA = ProseCorpusStorage.pageHash(sourceURL: "http://example.com/a")
        try storage.deletePage(pageHash: hashA)
        let stats = try indexer.refresh()
        #expect(stats.removed == 1)
        #expect(try index.totalPages() == 0)
        #expect(try index.totalFTSRows() == 0)
    }

    @Test func indexerPopulatesFTSWithBodyText() throws {
        // AC-I3 — page_fts row count matches pages row count, and
        // the body is searchable via FTS5 MATCH.
        let (storage, storageTmp) = makeTempStorage()
        defer { cleanup(storageTmp) }
        let (index, indexTmp) = try makeTempIndex()
        defer { cleanup(indexTmp) }

        _ = try storage.writePage(
            sourceURL: "http://example.com/a",
            title: "A",
            body: "The marriage of John and Sarah at Wirksworth."
        )
        let indexer = ProseCorpusIndexer(
            storage: storage,
            index: index,
            gazetteer: sampleGazetteer()
        )
        _ = try indexer.refresh()

        let matchCount = try index.dbQueue.read { db in
            // Exact-word search hits via FTS5 indexing — proper noun
            // so no stem ambiguity. The Porter tokeniser still
            // lowercases for matching, so a lowercase query against
            // a mixed-case indexed body should hit.
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM page_fts WHERE page_fts MATCH 'wirksworth'"
            ) ?? 0
        }
        #expect(matchCount == 1)
        // Parity assertion — every `pages` row has a `page_fts`
        // row (AC-I3). These helpers each open their own
        // `dbQueue.read`, so they must run outside the block above
        // (GRDB forbids recursive `read` calls on the same queue).
        #expect(try index.totalFTSRows() == index.totalPages())
    }
}
