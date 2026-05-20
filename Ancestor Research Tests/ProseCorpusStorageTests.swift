import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the on-disk layout and idempotency guarantees for
/// `ProseCorpusStorage`. Uses a fresh temp directory per test so failures
/// in one test can't poison another, and so the suite leaves no trace in
/// Application Support.
struct ProseCorpusStorageTests {

    // MARK: - Test fixture helper

    /// Spin up a storage instance rooted at a unique temp directory and
    /// clean it up on test exit. Returns both the storage and the path
    /// so tests can inspect the filesystem directly when they need to.
    private func makeTempStorage(sourceID: String = "test-corpus") -> (ProseCorpusStorage, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ancestor-storage-tests-\(UUID().uuidString)", isDirectory: true)
        let storage = ProseCorpusStorage(baseDirectory: tmp, sourceID: sourceID)
        return (storage, tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Hashing

    @Test func pageHashIs16HexChars() {
        let hash = ProseCorpusStorage.pageHash(sourceURL: "http://www.wirksworth.org.uk/P-CAUL-1.htm")
        #expect(hash.count == 16)
        #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func pageHashIsStableAcrossCalls() {
        let url = "http://www.wirksworth.org.uk/P-CAUL-1.htm"
        let h1 = ProseCorpusStorage.pageHash(sourceURL: url)
        let h2 = ProseCorpusStorage.pageHash(sourceURL: url)
        #expect(h1 == h2)
    }

    @Test func pageHashDiffersByURL() {
        let a = ProseCorpusStorage.pageHash(sourceURL: "http://www.wirksworth.org.uk/P-CAUL-1.htm")
        let b = ProseCorpusStorage.pageHash(sourceURL: "http://www.wirksworth.org.uk/P-CAUL-2.htm")
        #expect(a != b)
    }

    @Test func contentHashIs64HexChars() {
        let hash = ProseCorpusStorage.contentHash(body: "Some markdown body")
        #expect(hash.count == 64)
    }

    @Test func contentHashIsStableForIdenticalInput() {
        let body = "# Title\n\nThe body text."
        #expect(ProseCorpusStorage.contentHash(body: body) == ProseCorpusStorage.contentHash(body: body))
    }

    @Test func contentHashIgnoresTrailingPerLineWhitespace() {
        let withTrailing = "# Title  \n\nBody.  \n"
        let withoutTrailing = "# Title\n\nBody.\n"
        #expect(
            ProseCorpusStorage.contentHash(body: withTrailing)
            == ProseCorpusStorage.contentHash(body: withoutTrailing)
        )
    }

    @Test func contentHashIgnoresCRLFvsLF() {
        let crlf = "# Title\r\n\r\nBody.\r\n"
        let lf = "# Title\n\nBody.\n"
        #expect(
            ProseCorpusStorage.contentHash(body: crlf)
            == ProseCorpusStorage.contentHash(body: lf)
        )
    }

    @Test func contentHashDiffersWhenBodyChanges() {
        let a = ProseCorpusStorage.contentHash(body: "First")
        let b = ProseCorpusStorage.contentHash(body: "Second")
        #expect(a != b)
    }

    // MARK: - Frontmatter rendering + parsing

    @Test func frontmatterRoundTrips() {
        let fm = PageFrontmatter(
            sourceID: "wirksworth",
            sourceURL: "http://www.wirksworth.org.uk/P-CAUL-1.htm",
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000),
            contentHash: String(repeating: "a", count: 64),
            title: "Cauldwell of Wirksworth — Pedigree",
            crawlerVersion: "1.0.0"
        )
        let rendered = ProseCorpusStorage.renderFrontmatter(fm)
        let document = rendered + "\n\n# Body\n\nText."
        let parsed = ProseCorpusStorage.parseFrontmatter(document)
        #expect(parsed != nil)
        #expect(parsed?.frontmatter == fm)
        #expect(parsed?.body == "# Body\n\nText.")
    }

    @Test func frontmatterRequiresLeadingDelimiter() {
        let bad = "source_id: wirksworth\n---\nbody"
        #expect(ProseCorpusStorage.parseFrontmatter(bad) == nil)
    }

    @Test func frontmatterHandlesEmptyTitle() {
        let fm = PageFrontmatter(
            sourceID: "x",
            sourceURL: "http://example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentHash: String(repeating: "0", count: 64),
            title: nil,
            crawlerVersion: "1.0.0"
        )
        let rendered = ProseCorpusStorage.renderFrontmatter(fm)
        let parsed = ProseCorpusStorage.parseFrontmatter(rendered + "\n\nbody")
        #expect(parsed?.frontmatter.title == nil)
    }

    @Test func frontmatterHandlesURLsWithColons() {
        // URLs always contain ":" — needs quoting in YAML to be unambiguous.
        let fm = PageFrontmatter(
            sourceID: "x",
            sourceURL: "https://example.org/page?q=1&r=2",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentHash: String(repeating: "0", count: 64),
            title: "Title with: colon",
            crawlerVersion: "1.0.0"
        )
        let rendered = ProseCorpusStorage.renderFrontmatter(fm)
        let parsed = ProseCorpusStorage.parseFrontmatter(rendered + "\n\nbody")
        #expect(parsed?.frontmatter == fm)
    }

    // MARK: - writePage (the core idempotency contract)

    @Test func writePageCreatesFileAndDirectories() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let outcome = try storage.writePage(
            sourceURL: "http://example.com/page",
            title: "Example",
            body: "# Example\n\nContent."
        )
        guard case .written(let pageHash) = outcome else {
            Issue.record("First write must return .written, got \(outcome)")
            return
        }
        let url = storage.pageURL(forPageHash: pageHash)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func writePageIsIdempotentForUnchangedBody() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let url = "http://example.com/page"
        let body = "# Example\n\nContent."
        let first = try storage.writePage(sourceURL: url, title: "Example", body: body)
        let second = try storage.writePage(sourceURL: url, title: "Example", body: body)

        guard case .written(let h1) = first else {
            Issue.record("First write should be .written")
            return
        }
        guard case .unchanged(let h2) = second else {
            Issue.record("Second write of same body should be .unchanged, got \(second)")
            return
        }
        #expect(h1 == h2)
    }

    @Test func writePageRewritesWhenBodyChanges() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let url = "http://example.com/page"
        _ = try storage.writePage(sourceURL: url, title: "Example", body: "Original")
        let outcome = try storage.writePage(sourceURL: url, title: "Example", body: "Changed")

        if case .rewritten(let pageHash, let prev) = outcome {
            #expect(!pageHash.isEmpty)
            #expect(prev == ProseCorpusStorage.contentHash(body: "Original"))
        } else {
            Issue.record("Changed body should produce .rewritten, got \(outcome)")
        }
    }

    @Test func writePageMtimeUnchangedWhenBodyUnchanged() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let url = "http://example.com/page"
        let body = "# Example\n\nContent."
        let first = try storage.writePage(sourceURL: url, title: "Example", body: body)
        guard case .written(let pageHash) = first else {
            Issue.record("Setup failed: first write didn't return .written")
            return
        }
        let fileURL = storage.pageURL(forPageHash: pageHash)
        let mtime1 = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        // Sleep just enough that mtime would differ if a write happened.
        Thread.sleep(forTimeInterval: 0.05)
        _ = try storage.writePage(sourceURL: url, title: "Example", body: body)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        #expect(mtime1 == mtime2)
    }

    // MARK: - readPage

    @Test func readPageReturnsParsedFrontmatterAndBody() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let sourceURL = "http://example.com/page"
        let body = "# Example\n\nLine 2."
        _ = try storage.writePage(sourceURL: sourceURL, title: "Example", body: body)

        let pageHash = ProseCorpusStorage.pageHash(sourceURL: sourceURL)
        let result = try storage.readPage(pageHash: pageHash)
        #expect(result?.frontmatter.sourceURL == sourceURL)
        #expect(result?.frontmatter.title == "Example")
        #expect(result?.body.contains("# Example") == true)
        #expect(result?.body.contains("Line 2.") == true)
    }

    @Test func readPageReturnsNilForUnknownHash() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let result = try storage.readPage(pageHash: "deadbeefcafe1234")
        #expect(result == nil)
    }

    // MARK: - enumeratePageHashes

    @Test func enumeratePageHashesListsAllWrittenPages() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let urls = (1...3).map { "http://example.com/page-\($0)" }
        for url in urls {
            _ = try storage.writePage(sourceURL: url, title: "Page", body: "Body \(url)")
        }

        let hashes = try storage.enumeratePageHashes()
        #expect(hashes.count == 3)
        let expected = Set(urls.map { ProseCorpusStorage.pageHash(sourceURL: $0) })
        #expect(Set(hashes) == expected)
    }

    @Test func enumeratePageHashesReturnsEmptyForFreshCorpus() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let hashes = try storage.enumeratePageHashes()
        #expect(hashes.isEmpty)
    }

    // MARK: - deletePage

    @Test func deletePageRemovesFileFromDisk() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        let url = "http://example.com/page"
        _ = try storage.writePage(sourceURL: url, title: "Example", body: "Body")
        let pageHash = ProseCorpusStorage.pageHash(sourceURL: url)
        let fileURL = storage.pageURL(forPageHash: pageHash)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try storage.deletePage(pageHash: pageHash)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func deletePageIsIdempotentForNonexistentHash() throws {
        let (storage, tmp) = makeTempStorage()
        defer { cleanup(tmp) }

        try storage.deletePage(pageHash: "deadbeefcafe1234")
    }

    // MARK: - On-disk layout (spec §3)

    @Test func filesLandUnderCorporaSourceIdPagesPageHashDotMd() throws {
        let (storage, tmp) = makeTempStorage(sourceID: "my-corpus")
        defer { cleanup(tmp) }

        let url = "http://example.com/page"
        let outcome = try storage.writePage(sourceURL: url, title: "X", body: "Body")
        guard case .written(let pageHash) = outcome else {
            Issue.record("Setup write failed")
            return
        }
        let expected = tmp
            .appendingPathComponent("corpora", isDirectory: true)
            .appendingPathComponent("my-corpus", isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent("\(pageHash).md")
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - End-to-end with the converter (spec §5 + §7 round-trip)

    @Test func contentHashFromConverterOutputIsStable() {
        // Conversion is deterministic per spec §7.5 and storage hashes
        // the normalised body — so a page's content_hash should not drift
        // when the same HTML round-trips through the pipeline twice.
        let html = "<h1>Example</h1><p>Body  </p>"
        let md1 = HTMLToMarkdownConverter.convert(html)
        let md2 = HTMLToMarkdownConverter.convert(html)
        #expect(ProseCorpusStorage.contentHash(body: md1) == ProseCorpusStorage.contentHash(body: md2))
    }
}
