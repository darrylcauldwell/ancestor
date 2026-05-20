import Foundation
import CryptoKit

/// On-disk layout and write/read primitives for a single prose corpus.
///
/// Each corpus lives under `<baseDirectory>/corpora/<source_id>/` with the
/// shape from spec §3:
///
///     corpora/<source_id>/
///       manifest.json                    — populated by the crawler
///       pages/<page_hash>.md             — one file per source page
///       logs/crawl-<iso-timestamp>.log   — crawler diagnostics
///
/// All writes are atomic (write-to-temp + rename). Content hashing per
/// spec §5.2 — SHA-256 of the markdown body alone (trailing whitespace
/// stripped, LF line endings) so frontmatter updates that don't change
/// the body produce no `content_hash` diff.
///
/// `baseDirectory` is normally `Application Support/AncestorResearch` but
/// injectable so tests can target a tmp path.
nonisolated struct ProseCorpusStorage {
    let baseDirectory: URL
    let sourceID: String

    /// The current crawler version stamped into every frontmatter. Bumps
    /// invalidate every corpus page's content_hash on next sync because
    /// the converter's output may have changed.
    static let crawlerVersion = "1.0.0"

    init(baseDirectory: URL, sourceID: String) {
        self.baseDirectory = baseDirectory
        self.sourceID = sourceID
    }

    /// Default initializer using the app's sandboxed Application Support.
    init(sourceID: String) throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.baseDirectory = appSupport.appendingPathComponent("AncestorResearch", isDirectory: true)
        self.sourceID = sourceID
    }

    // MARK: - Paths

    var corpusDirectory: URL {
        baseDirectory
            .appendingPathComponent("corpora", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
    }

    var pagesDirectory: URL {
        corpusDirectory.appendingPathComponent("pages", isDirectory: true)
    }

    var manifestURL: URL {
        corpusDirectory.appendingPathComponent("manifest.json")
    }

    func pageURL(forPageHash pageHash: String) -> URL {
        pagesDirectory.appendingPathComponent("\(pageHash).md")
    }

    // MARK: - Hashing (deterministic, no external state)

    /// Page hash from a canonical source URL — first 16 hex chars of
    /// SHA-256. Short enough to be filesystem-friendly, long enough to
    /// avoid collision across 10⁵ pages.
    nonisolated static func pageHash(sourceURL: String) -> String {
        let digest = SHA256.hash(data: Data(sourceURL.utf8))
        let full = digest.map { String(format: "%02x", $0) }.joined()
        return String(full.prefix(16))
    }

    /// Content hash from a markdown body. Body is normalised first
    /// (trailing whitespace stripped per line, line endings → LF) so
    /// editor-induced whitespace tweaks don't produce spurious diffs.
    nonisolated static func contentHash(body: String) -> String {
        let normalised = normaliseBody(body)
        let digest = SHA256.hash(data: Data(normalised.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Spec §5.2 body normalisation. Pure function. Re-exposed so the
    /// indexer can recompute hashes against the canonical form when
    /// auditing frontmatter integrity (AC-B3).
    nonisolated static func normaliseBody(_ body: String) -> String {
        var s = body.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.map { line -> String in
            var l = String(line)
            while let last = l.last, last == " " || last == "\t" {
                l.removeLast()
            }
            return l
        }
        return trimmed.joined(separator: "\n")
    }

    // MARK: - Frontmatter

    /// Render frontmatter as a minimal YAML document. Keys are written in
    /// a fixed order so byte-for-byte stability holds across runs.
    nonisolated static func renderFrontmatter(_ fm: PageFrontmatter) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fetchedAt = formatter.string(from: fm.fetchedAt)

        var lines: [String] = ["---"]
        lines.append("source_id: \(yamlScalar(fm.sourceID))")
        lines.append("source_url: \(yamlScalar(fm.sourceURL))")
        lines.append("fetched_at: \(fetchedAt)")
        lines.append("content_hash: \(fm.contentHash)")
        lines.append("title: \(yamlScalar(fm.title ?? ""))")
        lines.append("crawler_version: \(yamlScalar(fm.crawlerVersion))")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Parse a markdown file's content into (frontmatter, body). Returns
    /// nil if the document lacks the leading `---` block or the required
    /// keys. Body is everything after the closing `---` line, with the
    /// first leading newline stripped.
    nonisolated static func parseFrontmatter(_ content: String) -> (frontmatter: PageFrontmatter, body: String)? {
        guard content.hasPrefix("---") else { return nil }
        let afterOpen = content.dropFirst(3)
        let afterOpenString = String(afterOpen)
        // Find the next `---\n` (or trailing `---`).
        let lines = afterOpenString.split(separator: "\n", omittingEmptySubsequences: false)
        var fmLines: [String] = []
        var bodyStartIndex: Int? = nil
        for (i, line) in lines.enumerated() {
            if line == "---" {
                bodyStartIndex = i + 1
                break
            }
            // Skip a blank first line that immediately follows the opening `---`.
            if i == 0, line.isEmpty { continue }
            fmLines.append(String(line))
        }
        guard let startIndex = bodyStartIndex else { return nil }

        var values: [String: String] = [:]
        for line in fmLines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            values[key] = unquoteYamlScalar(rawValue)
        }

        guard let sourceID = values["source_id"],
              let sourceURL = values["source_url"],
              let fetchedAtStr = values["fetched_at"],
              let contentHash = values["content_hash"],
              let crawlerVersion = values["crawler_version"] else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let fetchedAt = formatter.date(from: fetchedAtStr) else { return nil }

        let title = (values["title"] ?? "").isEmpty ? nil : values["title"]

        let bodyLines = lines.dropFirst(startIndex)
        var body = bodyLines.joined(separator: "\n")
        // The convention is one blank line between closing `---` and body
        // start; strip it so callers see the body's first real line first.
        if body.hasPrefix("\n") { body.removeFirst() }

        let fm = PageFrontmatter(
            sourceID: sourceID,
            sourceURL: sourceURL,
            fetchedAt: fetchedAt,
            contentHash: contentHash,
            title: title,
            crawlerVersion: crawlerVersion
        )
        return (fm, body)
    }

    /// Quote a YAML scalar value when it contains characters that would
    /// otherwise change its meaning. Pragmatic — covers the values that
    /// realistically appear in frontmatter (URLs, page titles, source
    /// ids). Not a full YAML serializer.
    nonisolated private static func yamlScalar(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needsQuoting = s.contains(":") || s.contains("#") || s.contains("\"")
            || s.contains("'") || s.first == " " || s.last == " "
            || s.first == "-" || s.first == "?" || s.first == "@"
        if !needsQuoting { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Strip surrounding quotes and unescape `\"` and `\\`. Tolerant of
    /// bare scalars (returns input unchanged).
    nonisolated private static func unquoteYamlScalar(_ raw: String) -> String {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            let inner = String(raw.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    // MARK: - I/O

    /// Outcome of a write attempt. `unchanged` means a file with the
    /// same `content_hash` already existed on disk — no write happened,
    /// the indexer can skip this page.
    enum WriteOutcome: Equatable {
        case written(pageHash: String)
        case unchanged(pageHash: String)
        case rewritten(pageHash: String, previousContentHash: String)
    }

    /// Write a page's markdown body to disk under the canonical path.
    /// Idempotent against unchanged content (the existing file is left
    /// alone; no mtime churn). Body is normalised before hashing and
    /// writing so files written via this path always satisfy
    /// `content_hash == sha256(normalised_body)`.
    func writePage(
        sourceURL: String,
        title: String?,
        body: String,
        fetchedAt: Date = Date()
    ) throws -> WriteOutcome {
        try createDirectoriesIfNeeded()

        let pageHash = Self.pageHash(sourceURL: sourceURL)
        let normalisedBody = Self.normaliseBody(body)
        let newContentHash = Self.contentHash(body: normalisedBody)
        let pageFileURL = pageURL(forPageHash: pageHash)

        if let existing = try? readPage(pageHash: pageHash) {
            if existing.frontmatter.contentHash == newContentHash {
                return .unchanged(pageHash: pageHash)
            }
            let previous = existing.frontmatter.contentHash
            try writeAtomic(
                pageURL: pageFileURL,
                sourceURL: sourceURL,
                title: title,
                body: normalisedBody,
                contentHash: newContentHash,
                fetchedAt: fetchedAt
            )
            return .rewritten(pageHash: pageHash, previousContentHash: previous)
        }

        try writeAtomic(
            pageURL: pageFileURL,
            sourceURL: sourceURL,
            title: title,
            body: normalisedBody,
            contentHash: newContentHash,
            fetchedAt: fetchedAt
        )
        return .written(pageHash: pageHash)
    }

    /// Read a page's frontmatter and body from disk. Returns nil if no
    /// file exists for the hash. Throws on filesystem error or malformed
    /// frontmatter.
    func readPage(pageHash: String) throws -> (frontmatter: PageFrontmatter, body: String)? {
        let url = pageURL(forPageHash: pageHash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let content = try String(contentsOf: url, encoding: .utf8)
        guard let parsed = Self.parseFrontmatter(content) else {
            throw StorageError.malformedFrontmatter(url: url)
        }
        return parsed
    }

    /// Delete a page file. Used by the indexer's cascade-out logic when
    /// a page disappears from the source site.
    func deletePage(pageHash: String) throws {
        let url = pageURL(forPageHash: pageHash)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Enumerate every `<page_hash>.md` under `pages/`. Returns just the
    /// hashes (the filename stem); callers join with the storage to
    /// resolve URLs or read bodies.
    func enumeratePageHashes() throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pagesDirectory.path) else { return [] }
        let contents = try fm.contentsOfDirectory(
            at: pagesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url in
            guard url.pathExtension == "md" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
    }

    /// Quick aggregate of the corpus footprint — page count and total
    /// bytes of all `.md` files under `pages/`. Used to populate
    /// `ProseCorpusManifest.pageCount` and `.totalBytes` after a sync.
    /// O(n) over the page directory; APFS handles 10⁵ entries fine.
    func corpusStats() throws -> (pageCount: Int, totalBytes: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pagesDirectory.path) else { return (0, 0) }
        let contents = try fm.contentsOfDirectory(
            at: pagesDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var pageCount = 0
        var totalBytes = 0
        for url in contents where url.pathExtension == "md" {
            pageCount += 1
            let attrs = try fm.attributesOfItem(atPath: url.path)
            totalBytes += (attrs[.size] as? Int) ?? 0
        }
        return (pageCount, totalBytes)
    }

    // MARK: - Internal helpers

    private func createDirectoriesIfNeeded() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
    }

    /// Write the markdown file via a temp file + rename so a partial
    /// write never leaves a half-written `.md` visible. macOS guarantees
    /// rename within the same volume is atomic.
    private func writeAtomic(
        pageURL: URL,
        sourceURL: String,
        title: String?,
        body: String,
        contentHash: String,
        fetchedAt: Date
    ) throws {
        let frontmatter = PageFrontmatter(
            sourceID: sourceID,
            sourceURL: sourceURL,
            fetchedAt: fetchedAt,
            contentHash: contentHash,
            title: title,
            crawlerVersion: Self.crawlerVersion
        )
        let document = Self.renderFrontmatter(frontmatter) + "\n\n" + body + "\n"
        let data = Data(document.utf8)

        let tempURL = pageURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        // `replaceItemAt` handles the cross-rename in a single transaction;
        // .atomic on Data.write alone isn't enough when an existing file
        // is being replaced because rename(2) semantics differ on APFS.
        if FileManager.default.fileExists(atPath: pageURL.path) {
            _ = try FileManager.default.replaceItemAt(pageURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: pageURL)
        }
    }

    enum StorageError: Error, CustomStringConvertible {
        case malformedFrontmatter(url: URL)

        var description: String {
            switch self {
            case .malformedFrontmatter(let url):
                return "Malformed YAML frontmatter at \(url.path)"
            }
        }
    }
}

/// YAML frontmatter shape per spec §5.1. Required keys are all
/// non-optional; `title` is the only optional because some source
/// pages legitimately lack both `<title>` and `<h1>`.
nonisolated struct PageFrontmatter: Equatable {
    let sourceID: String
    let sourceURL: String
    let fetchedAt: Date
    let contentHash: String
    let title: String?
    let crawlerVersion: String
}
