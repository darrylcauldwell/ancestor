import Foundation
import GRDB

/// Per-corpus SQLite index per spec §4 — one `index.sqlite` per
/// `corpora/<source_id>/`, separate from the project database.
///
/// Holds four pivot tables (`pages`, `page_surnames`, `page_years`,
/// `page_places`) and an FTS5 virtual table `page_fts`. The canonical
/// markdown body lives on disk in the page's `.md` file; the index
/// duplicates the body into FTS5 for full-text search but does not
/// store it in `pages` (the spec keeps that row narrow on purpose).
///
/// Concurrency: a `DatabaseQueue` is serial under the hood, so all
/// reads and writes through this type are safe. The class is
/// `Sendable` so the orchestrator can hand instances across async
/// boundaries.
nonisolated final class ProseCorpusIndex: Sendable {
    let dbQueue: DatabaseQueue

    /// Open or create the index file at `path`. Schema migrations run
    /// at init; subsequent opens are no-ops past the first.
    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_prose_corpus") { db in
            // pages — one row per indexed markdown file.
            try db.create(table: "pages") { t in
                t.primaryKey("page_hash", .text)
                t.column("source_url", .text).notNull().unique()
                t.column("title", .text)
                t.column("fetched_at", .datetime).notNull()
                t.column("content_hash", .text).notNull()
                t.column("byte_length", .integer).notNull()
                t.column("last_indexed_at", .datetime).notNull()
            }
            try db.create(index: "idx_pages_content_hash", on: "pages", columns: ["content_hash"])

            // Three pivot tables — surnames / years / places. All keyed
            // on (page_hash, value); cascade-delete from pages so the
            // refresh path (delete a page → all pivot rows go too)
            // doesn't need explicit cleanup.
            try db.create(table: "page_surnames") { t in
                t.column("page_hash", .text).notNull()
                t.column("surname_upper", .text).notNull()
                t.column("mention_count", .integer).notNull()
                t.primaryKey(["page_hash", "surname_upper"])
                t.foreignKey(["page_hash"], references: "pages", onDelete: .cascade)
            }
            try db.create(index: "idx_page_surnames_surname", on: "page_surnames", columns: ["surname_upper"])

            try db.create(table: "page_years") { t in
                t.column("page_hash", .text).notNull()
                t.column("year", .integer).notNull()
                t.column("mention_count", .integer).notNull()
                t.primaryKey(["page_hash", "year"])
                t.foreignKey(["page_hash"], references: "pages", onDelete: .cascade)
            }
            try db.create(index: "idx_page_years_year", on: "page_years", columns: ["year"])

            try db.create(table: "page_places") { t in
                t.column("page_hash", .text).notNull()
                t.column("place_lower", .text).notNull()
                t.column("mention_count", .integer).notNull()
                t.primaryKey(["page_hash", "place_lower"])
                t.foreignKey(["page_hash"], references: "pages", onDelete: .cascade)
            }
            try db.create(index: "idx_page_places_place", on: "page_places", columns: ["place_lower"])

            // FTS5 virtual table. Standalone (not external-content)
            // because the canonical body lives on disk, not in
            // `pages`. The indexer maintains this table directly —
            // no triggers, no shadow body column on `pages`.
            //
            // Tokeniser exactly as spec §4 calls for: porter stem
            // (so "marriage" hits "married"), unicode61 lowercasing
            // with remove_diacritics=1 so accented characters fold
            // to ASCII without the converter having to normalise.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE page_fts USING fts5(
                    page_hash UNINDEXED,
                    body,
                    tokenize = 'porter unicode61 remove_diacritics 1'
                )
                """)
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Read API (for indexer refresh diffs and P5 retrieval)

    /// Snapshot of `(page_hash, content_hash)` across `pages`. The
    /// indexer uses this to decide which pages on disk need re-
    /// indexing — content_hash match = skip, mismatch = delete+insert,
    /// absent on disk = delete from DB.
    func pageContentHashes() throws -> [String: String] {
        try dbQueue.read { db in
            var out: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT page_hash, content_hash FROM pages")
            for row in rows {
                let hash: String = row["page_hash"]
                let content: String = row["content_hash"]
                out[hash] = content
            }
            return out
        }
    }

    /// Read a single page row by hash. Returns nil if the page isn't
    /// in the index. Used by the indexer's refresh path and by P5's
    /// retrieval layer to confirm a hit is still valid before reading
    /// the markdown body from disk.
    func page(forHash pageHash: String) throws -> PageRow? {
        try dbQueue.read { db in
            try PageRow.fetchOne(db, sql: """
                SELECT page_hash, source_url, title, fetched_at,
                       content_hash, byte_length, last_indexed_at
                  FROM pages
                 WHERE page_hash = ?
                """, arguments: [pageHash])
        }
    }

    /// Count rows in `page_surnames` for a given surname (uppercase).
    /// Used by AC-I1 tests and by the P5 surname-driven retrieval.
    func surnamePageCount(_ surname: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM page_surnames WHERE surname_upper = ?
                """, arguments: [surname]) ?? 0
        }
    }

    /// Total rows in `pages`. Cheap sanity check + manifest reconcile.
    func totalPages() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pages") ?? 0
        }
    }

    /// Total rows in `page_fts`. AC-I3 asserts parity with `pages`.
    func totalFTSRows() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_fts") ?? 0
        }
    }

    // MARK: - Write API (indexer-only)

    /// Atomically delete every row for `pageHash` across `pages`,
    /// `page_surnames`, `page_years`, `page_places`, and `page_fts`,
    /// then re-insert from the supplied tokenised state. This is the
    /// only mutating call the indexer makes — both initial insert
    /// and refresh go through here, keeping the write path single-
    /// shot and trivially auditable.
    ///
    /// The cascade `ON DELETE` on the pivot tables takes care of
    /// `page_surnames` / `page_years` / `page_places`; `page_fts` is
    /// standalone (not external-content) so the indexer deletes its
    /// row explicitly.
    func upsertPage(_ record: UpsertRecord) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM page_fts WHERE page_hash = ?", arguments: [record.pageHash])
            try db.execute(sql: "DELETE FROM pages WHERE page_hash = ?", arguments: [record.pageHash])

            try db.execute(sql: """
                INSERT INTO pages (page_hash, source_url, title, fetched_at,
                                   content_hash, byte_length, last_indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    record.pageHash,
                    record.sourceURL,
                    record.title,
                    record.fetchedAt,
                    record.contentHash,
                    record.byteLength,
                    record.lastIndexedAt,
                ])

            for (surname, count) in record.surnames {
                try db.execute(sql: """
                    INSERT INTO page_surnames (page_hash, surname_upper, mention_count)
                    VALUES (?, ?, ?)
                    """, arguments: [record.pageHash, surname, count])
            }
            for (year, count) in record.years {
                try db.execute(sql: """
                    INSERT INTO page_years (page_hash, year, mention_count)
                    VALUES (?, ?, ?)
                    """, arguments: [record.pageHash, year, count])
            }
            for (place, count) in record.places {
                try db.execute(sql: """
                    INSERT INTO page_places (page_hash, place_lower, mention_count)
                    VALUES (?, ?, ?)
                    """, arguments: [record.pageHash, place, count])
            }

            try db.execute(sql: """
                INSERT INTO page_fts (page_hash, body) VALUES (?, ?)
                """, arguments: [record.pageHash, record.body])
        }
    }

    /// Delete every row for `pageHash`. Cascade clears the pivot
    /// tables; `page_fts` needs an explicit delete because it is
    /// standalone (not external-content).
    func deletePage(pageHash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM page_fts WHERE page_hash = ?", arguments: [pageHash])
            try db.execute(sql: "DELETE FROM pages WHERE page_hash = ?", arguments: [pageHash])
        }
    }

    // MARK: - Records

    struct UpsertRecord {
        let pageHash: String
        let sourceURL: String
        let title: String?
        let fetchedAt: Date
        let contentHash: String
        let byteLength: Int
        let lastIndexedAt: Date
        let body: String
        /// Map of surname (UPPER) → mention count.
        let surnames: [String: Int]
        /// Map of four-digit Gregorian year → mention count.
        let years: [Int: Int]
        /// Map of lowercased place token → mention count.
        let places: [String: Int]
    }

    struct PageRow: FetchableRecord, Codable, Equatable {
        let pageHash: String
        let sourceURL: String
        let title: String?
        let fetchedAt: Date
        let contentHash: String
        let byteLength: Int
        let lastIndexedAt: Date

        enum CodingKeys: String, CodingKey {
            case pageHash = "page_hash"
            case sourceURL = "source_url"
            case title
            case fetchedAt = "fetched_at"
            case contentHash = "content_hash"
            case byteLength = "byte_length"
            case lastIndexedAt = "last_indexed_at"
        }
    }
}
