import Foundation
import os

/// Reads markdown files from `ProseCorpusStorage`, tokenises them,
/// and writes the result into `ProseCorpusIndex`. The only writer the
/// index has — every external surface (P5 retrieval, future MLX
/// extraction) is read-only.
///
/// The refresh path is idempotent (spec §8.3) — running `refresh()`
/// twice against unchanged data produces zero index mutations because
/// content_hash matches are skipped. Pages whose markdown is gone are
/// deleted from the index; pages whose hash differs are atomically
/// replaced via `ProseCorpusIndex.upsertPage(...)` (delete-then-
/// insert across all four pivot tables + FTS5 in one transaction).
nonisolated struct ProseCorpusIndexer {
    let storage: ProseCorpusStorage
    let index: ProseCorpusIndex
    /// Gazetteer used for place tokenisation. Injectable so tests can
    /// stub a small fixture set instead of loading the full
    /// `uk-places.json`. Production passes
    /// `LocationGazetteer.shared.all()`.
    let gazetteer: [GazetteerEntry]
    /// Injectable clock for `last_indexed_at` timestamps. Production
    /// passes `Date.init`.
    let now: @Sendable () -> Date

    init(
        storage: ProseCorpusStorage,
        index: ProseCorpusIndex,
        gazetteer: [GazetteerEntry],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.storage = storage
        self.index = index
        self.gazetteer = gazetteer
        self.now = now
    }

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ProseCorpusIndexer")

    // MARK: - Refresh

    /// One full pass over the storage's `pages/` directory and the
    /// index. Returns a `Stats` summary for telemetry / UI.
    @discardableResult
    func refresh() throws -> Stats {
        var stats = Stats()

        // Snapshot of (page_hash, content_hash) in DB. We mutate this
        // as we go — every page seen on disk is removed from the
        // remaining set; anything still in it at the end is on the
        // chopping block.
        var dbHashes = try index.pageContentHashes()
        let onDiskHashes = try storage.enumeratePageHashes()

        for pageHash in onDiskHashes {
            guard let (frontmatter, body) = try? storage.readPage(pageHash: pageHash) else {
                // Malformed frontmatter — log and skip. The page stays
                // in the index if it was already there (we don't have
                // a clean state to replace it with).
                Self.logger.warning("Skipping page with malformed frontmatter: \(pageHash, privacy: .public)")
                continue
            }
            if let existingHash = dbHashes[pageHash], existingHash == frontmatter.contentHash {
                // No change — skip. Remove from dbHashes so we don't
                // mistake it for a stale row later.
                dbHashes.removeValue(forKey: pageHash)
                stats.unchanged += 1
                continue
            }

            let isReplacement = dbHashes.removeValue(forKey: pageHash) != nil
            let record = makeRecord(
                pageHash: pageHash,
                frontmatter: frontmatter,
                body: body
            )
            try index.upsertPage(record)
            if isReplacement {
                stats.updated += 1
            } else {
                stats.inserted += 1
            }
        }

        // Anything left in dbHashes is a row whose markdown file
        // disappeared. Cascade-delete via the index.
        for staleHash in dbHashes.keys {
            try index.deletePage(pageHash: staleHash)
            stats.removed += 1
        }
        return stats
    }

    // MARK: - Record assembly

    private func makeRecord(
        pageHash: String,
        frontmatter: PageFrontmatter,
        body: String
    ) -> ProseCorpusIndex.UpsertRecord {
        let surnames = ProseCorpusTokeniser.surnames(in: body)
        let years = ProseCorpusTokeniser.years(in: body)
        let places = ProseCorpusTokeniser.places(in: body, gazetteer: gazetteer)
        let normalised = ProseCorpusStorage.normaliseBody(body)
        return ProseCorpusIndex.UpsertRecord(
            pageHash: pageHash,
            sourceURL: frontmatter.sourceURL,
            title: frontmatter.title,
            fetchedAt: frontmatter.fetchedAt,
            contentHash: frontmatter.contentHash,
            byteLength: normalised.utf8.count,
            lastIndexedAt: now(),
            body: normalised,
            surnames: surnames,
            years: years,
            places: places
        )
    }

    // MARK: - Stats

    struct Stats: Equatable, Sendable {
        var inserted: Int = 0
        var updated: Int = 0
        var removed: Int = 0
        var unchanged: Int = 0

        var totalChanged: Int { inserted + updated + removed }
    }
}

// MARK: - Tokeniser

/// Pure-function tokeniser used by the indexer. Exposed as a separate
/// type so the rules can be unit-tested without spinning up an index.
///
/// Spec §8.1:
/// - **Surnames** — capitalised tokens of length ≥ 3, trailing `'s`
///   stripped, uppercased, stop-word filtered. Mention counts are raw
///   integers.
/// - **Years** — four-digit integers in the range 1500-1999. Two-digit
///   dates are deliberately not recognised in v1.
/// - **Places** — lowercased tokens matching the existing
///   `LocationGazetteer` entries. Best-effort, no fuzzy matching, no
///   Levenshtein.
nonisolated enum ProseCorpusTokeniser {

    // MARK: - Stop words

    /// Stop list for surname tokenisation. Per spec §14.3 this is an
    /// open question — the empirically-grounded list (tokens
    /// appearing in >40% of pages) is future work. For v1 we hard-
    /// code the obvious offenders: month/day names, common
    /// title-case English words, and a handful of generic
    /// geography terms that show up on nearly every genealogy page.
    ///
    /// All entries are stored uppercase to match `surname_upper`.
    nonisolated static let surnameStopWords: Set<String> = [
        // Months
        "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
        "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
        "JAN", "FEB", "MAR", "APR", "JUN", "JUL", "AUG", "SEP", "SEPT",
        "OCT", "NOV", "DEC",
        // Days
        "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY",
        "SATURDAY", "SUNDAY",
        // Common title-case English words that survive a "capitalised
        // tokens length ≥ 3" filter on real genealogy prose.
        "THE", "AND", "FOR", "WITH", "FROM", "INTO", "OUT",
        "OUR", "HIS", "HER", "THEY", "THEIR", "WHO", "WHOM", "WHICH",
        "WHEN", "WHERE", "WHAT", "WHILE", "AFTER", "BEFORE",
        "BORN", "DIED", "MARRIED", "BURIED", "BAPTISED", "BAPTIZED",
        "CHRISTENED", "AGED", "DAUGHTER", "SON", "WIFE", "HUSBAND",
        "FATHER", "MOTHER", "BROTHER", "SISTER", "CHILD",
        "PARISH", "CHURCH", "CHAPEL", "VILLAGE", "TOWN", "COUNTY",
        "STREET", "ROAD", "LANE",
        "ENGLAND", "BRITAIN", "GREAT", "UNITED", "KINGDOM",
        "MISTER", "MRS", "MISS", "REV", "REVEREND",
        "GENERATION", "PAGE", "PEDIGREE",
    ]

    // MARK: - Surnames

    /// Extract surname tokens. Returns a `[String: Int]` mapping
    /// `surname_upper` → raw mention count.
    static func surnames(in body: String) -> [String: Int] {
        // Tokenise on whitespace + most punctuation. Apostrophes are
        // preserved so we can strip a trailing 's after the fact —
        // splitting on `'` would lose the boundary.
        var counts: [String: Int] = [:]
        let pattern = "[A-Za-z][A-Za-z']{2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }
        let range = NSRange(body.startIndex..., in: body)
        regex.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match = match, let r = Range(match.range, in: body) else { return }
            var token = String(body[r])
            // First character must be uppercase ("capitalised").
            guard let first = token.first, first.isUppercase else { return }
            // Strip trailing `'s` or `'S` after the uppercase check.
            if token.hasSuffix("'s") || token.hasSuffix("'S") {
                token.removeLast(2)
            }
            // Strip stray trailing apostrophe ("Cauldwell'").
            while token.hasSuffix("'") { token.removeLast() }
            guard token.count >= 3 else { return }
            let upper = token.uppercased()
            guard !surnameStopWords.contains(upper) else { return }
            counts[upper, default: 0] += 1
        }
        return counts
    }

    // MARK: - Years

    /// Extract four-digit years in the inclusive range 1500-1999.
    /// Two-digit dates ("in 76") are deliberately not recognised in
    /// v1 — spec §8.1 calls them out as a v1.x refinement target.
    static func years(in body: String) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        // \b on either side so "11500" doesn't yield "1500".
        let pattern = "\\b\\d{4}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }
        let range = NSRange(body.startIndex..., in: body)
        regex.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match = match, let r = Range(match.range, in: body) else { return }
            guard let year = Int(body[r]), year >= 1500, year <= 1999 else { return }
            counts[year, default: 0] += 1
        }
        return counts
    }

    // MARK: - Places

    /// Extract place tokens by matching gazetteer entries' names +
    /// aliases against the body as whole-word, case-insensitive
    /// substrings. Multi-word entries ("Burton on Trent") are matched
    /// as a single regex.
    ///
    /// The key in the output map is the lowercased canonical *name*
    /// (not the alias that hit), so the index stores one row per
    /// place regardless of which surface form appeared in the body —
    /// matches the spec's "place_lower" column semantics where one
    /// place is one canonical token.
    static func places(in body: String, gazetteer: [GazetteerEntry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in gazetteer {
            let canonical = entry.name.lowercased()
            // Build the candidate-surface set once: entry name + any
            // alias. Empty aliases are ignored.
            var surfaces: Set<String> = [canonical]
            for alias in entry.aliases where !alias.isEmpty {
                surfaces.insert(alias.lowercased())
            }
            var total = 0
            for surface in surfaces {
                total += countWholeWordMatches(of: surface, in: body)
            }
            if total > 0 {
                counts[canonical, default: 0] += total
            }
        }
        return counts
    }

    /// Whole-word, case-insensitive substring count. Word boundaries
    /// use `\b` — Unicode-aware via the default NSRegularExpression
    /// settings. Escapes regex metacharacters in the needle so
    /// gazetteer entries with `.` or `-` don't surprise us.
    private static func countWholeWordMatches(of needle: String, in haystack: String) -> Int {
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return regex.numberOfMatches(in: haystack, options: [], range: range)
    }
}
